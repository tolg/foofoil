//  AppState+Cache.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        // MARK: - Cache Management Helpers

        /// 将旧版本 Flofoil 的数据目录迁移到 Flamina，仅在新目录不存在时执行。
        @discardableResult
        static func migrateLegacySupportDirectoryIfNeeded() -> Bool {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
            let legacyURL = appSupportURL.appendingPathComponent("Flofoil", isDirectory: true)
            let targetURL = appSupportURL.appendingPathComponent("Flamina", isDirectory: true)
            guard FileManager.default.fileExists(atPath: legacyURL.path),
                  !FileManager.default.fileExists(atPath: targetURL.path) else { return false }
            do {
                try FileManager.default.moveItem(at: legacyURL, to: targetURL)
                return true
            } catch {
                NSLog("迁移 Flofoil 支持目录到 Flamina 失败：%@", error.localizedDescription)
                return false
            }
        }

        static func getFlaminaDirectoryURL() -> URL? {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            _ = migrateLegacySupportDirectoryIfNeeded()
            return appSupportURL.appendingPathComponent("Flamina", isDirectory: true)
        }

        /// 返回应用自建缓存目录，兼容旧版 Flofoil 目录以防迁移失败。
        public static func cacheDirectoryURLs() -> [URL] {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return []
            }
            _ = migrateLegacySupportDirectoryIfNeeded()
            let currentURL = appSupportURL.appendingPathComponent("Flamina", isDirectory: true)
            let legacyURL = appSupportURL.appendingPathComponent("Flofoil", isDirectory: true)
            var urls: [URL] = []
            if FileManager.default.fileExists(atPath: currentURL.path) { urls.append(currentURL) }
            if FileManager.default.fileExists(atPath: legacyURL.path) { urls.append(legacyURL) }
            // 若两者都不存在，返回目标路径供后续创建使用
            if urls.isEmpty { urls.append(currentURL) }
            return urls
        }

        /// 仅识别由本应用写入的缓存文件，避免误删 Application Support 中的其他内容。
        public static func isManagedCacheURL(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            return name.hasPrefix("cached_image") ||
                name.hasPrefix("cached_text_") ||
                name.hasPrefix("cached_web_")
        }

        /// 当前窗口正在使用的本地缓存路径。
        public var cachedContentPaths: Set<String> {
            [imageURL, textURL, webURL]
                .compactMap { $0 }
                .filter { $0.isFileURL && Self.isManagedCacheURL($0) }
                .map(\.path)
                .reduce(into: Set<String>()) { $0.insert($1) }
        }

        func getCachedImageURL(for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
            getCachedContentURL(kind: "image", for: windowId, extension: ext)
        }

        func getCachedContentURL(kind: String, for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
            guard let flaminaURL = AppState.getFlaminaDirectoryURL() else {
                return nil
            }
            if !FileManager.default.fileExists(atPath: flaminaURL.path) {
                try? FileManager.default.createDirectory(at: flaminaURL, withIntermediateDirectories: true, attributes: nil)
            }
            let targetId = windowId ?? self.id
            let filename = "cached_\(kind)_\(targetId.uuidString)"
            if let ext = ext, !ext.isEmpty {
                return flaminaURL.appendingPathComponent("\(filename).\(ext)", isDirectory: false)
            } else {
                return flaminaURL.appendingPathComponent(filename, isDirectory: false)
            }
        }

        /// 将用户打开的本地文件复制到应用缓存，之后不再依赖源文件。
        func cacheImportedFile(from sourceURL: URL, kind: String, for windowId: UUID? = nil) -> URL? {
            guard sourceURL.isFileURL else { return sourceURL }
            guard !Self.isManagedCacheURL(sourceURL) else { return sourceURL }
            guard let destinationURL = getCachedContentURL(kind: kind, for: windowId, extension: sourceURL.pathExtension) else { return nil }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                print("Failed to copy \(kind) file to cache: \(error)")
                return nil
            }
        }

        /// 缓存文件名包含窗口 UUID，不能用于识别重复来源；这里保留规范化后的原文件路径。
        static func localSourceFingerprint(for url: URL) -> String? {
            guard url.isFileURL, !isManagedCacheURL(url) else { return nil }
            return "file:\(url.resolvingSymlinksInPath().standardizedFileURL.path)"
        }

        func clearCachedImages() {
            guard let flaminaURL = AppState.getFlaminaDirectoryURL() else {
                return
            }
            guard FileManager.default.fileExists(atPath: flaminaURL.path) else { return }

            // 获取历史记录里被引用的所有图片路径，防止物理删除仍然被历史引用的图片
            let historyPaths = HistoryManager.shared.historyConfigs.compactMap { $0.imagePath }

            if let files = try? FileManager.default.contentsOfDirectory(at: flaminaURL, includingPropertiesForKeys: nil) {
                for file in files {
                    if file.lastPathComponent.hasPrefix("cached_image_\(id.uuidString)") {
                        if !historyPaths.contains(file.path) {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                }
            }
        }

        static func findCachedImageInDirectory(for id: UUID) -> URL? {
            // 优先在新目录查找，找不到则回退到旧 Flofoil 目录
            for baseURL in cacheDirectoryURLs() {
                if let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
                    for file in files where file.lastPathComponent.hasPrefix("cached_image_\(id.uuidString)") {
                        return file
                    }
                }
            }
            return nil
        }

        static func findLegacyCachedImageInDirectory() -> URL? {
            for baseURL in cacheDirectoryURLs() {
                if let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
                    for file in files where file.lastPathComponent.hasPrefix("cached_image") && !file.lastPathComponent.contains("_") {
                        return file
                    }
                }
            }
            return nil
        }

        func convertToHEIC(sourceURL: URL, destURL: URL, quality: Float = 0.85) -> Bool {
            guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return false
            }

            guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                return false
            }

            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]

            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            return CGImageDestinationFinalize(destination)
        }

        func convertNSImageToHEIC(image: NSImage, destURL: URL, quality: Float = 0.8, backingScaleFactor: CGFloat = 1.0) -> Bool {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return false
            }

            guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                return false
            }

            let dpi = 72.0 * Double(backingScaleFactor)
            let tiffProperties: [CFString: Any] = [
                kCGImagePropertyTIFFXResolution: dpi,
                kCGImagePropertyTIFFYResolution: dpi,
                kCGImagePropertyTIFFResolutionUnit: 2 // Inches
            ]

            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: tiffProperties
            ]

            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            return CGImageDestinationFinalize(destination)
        }

        public func createNewFlaminaFromScreenshot(image: NSImage, backingScaleFactor: CGFloat) {
            let webTitle = self.originalImageName ?? NSLocalizedString("Untitled Page", comment: "")
            let formattedTitle = String(format: NSLocalizedString("Web Screenshot: %@", comment: ""), webTitle)

            let newId = UUID()
            guard let destURL = self.getCachedImageURL(for: newId, extension: "heic") else { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if self.convertNSImageToHEIC(image: image, destURL: destURL, quality: 0.8, backingScaleFactor: backingScaleFactor) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .createNewFlaminaFromImage,
                            object: nil,
                            userInfo: [
                                "id": newId,
                                "imageURL": destURL,
                                "originalName": formattedTitle
                            ]
                        )
                    }
                } else {
                    print("Failed to compress and save heic image flamina")
                }
            }
        }

        public func loadImage(from url: URL) -> NSImage? {
            guard let image = NSImage(contentsOf: url) else { return nil }

            if url.pathExtension.lowercased() == "heic",
               url.lastPathComponent.hasPrefix("cached_image_") {
                if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {

                    var dpi: Double = 72.0
                    if let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                       let xRes = tiffDict[kCGImagePropertyTIFFXResolution] as? Double {
                        dpi = xRes
                    } else if let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Double {
                        dpi = dpiWidth
                    }

                    let scale = dpi / 72.0
                    if scale > 0 {
                        if let rep = image.representations.first {
                            let pixelWidth = rep.pixelsWide
                            let pixelHeight = rep.pixelsHigh
                            if pixelWidth > 0 && pixelHeight > 0 {
                                image.size = NSSize(
                                    width: CGFloat(pixelWidth) / CGFloat(scale),
                                    height: CGFloat(pixelHeight) / CGFloat(scale)
                                )
                            }
                        }
                    }
                }
            }
            return image
        }

        func cacheImage(from sourceURL: URL) -> URL? {
            clearCachedImages()

            let ext = sourceURL.pathExtension.lowercased()
            let shouldCompressToHEIC = ["png", "bmp", "tiff", "tif"].contains(ext)

            if shouldCompressToHEIC, let destURL = getCachedImageURL(extension: "heic") {
                if convertToHEIC(sourceURL: sourceURL, destURL: destURL) {
                    return destURL
                }
                // 如果 HEIC 压缩失败，继续尝试使用原始格式拷贝
            }

            guard let destURL = getCachedImageURL(extension: sourceURL.pathExtension) else { return nil }

            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                return destURL
            } catch {
                print("Failed to copy image to cache: \(error)")
                if let data = try? Data(contentsOf: sourceURL) {
                    do {
                        try data.write(to: destURL)
                        return destURL
                    } catch {
                        print("Failed to write image data to cache: \(error)")
                    }
                }
            }
            return nil
        }
}
