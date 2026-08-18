//
//  AppState.swift
//  flofoil
//
//  Created by tolg on 2026/7/6.
//

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO
import SwiftUI

public class AppState: NSObject, ObservableObject, Identifiable {
    public static let defaultTextFontSize: Double = 16.0
    public static let minTextFontSize: Double = 8.0
    public static let maxTextFontSize: Double = 48.0
    public static let minImageScale: Double = 0.05
    public static let maxImageScale: Double = 8.0

    public var id: UUID
    private var sourceFingerprint: String?
    public var isInteractiveZooming: Bool = false
    private var isBatchUpdating = false

    @Published public var isCommandKeyPressed: Bool = false
    @Published public var isLoading: Bool = false
    /// 仅用于路由网页编辑控件的键盘快捷键，不需要持久化。
    @Published public var isWebEditableElementFocused: Bool = false

    @Published public var svgColor: String? {
        didSet {
            saveState()
        }
    }

    /// 窗体与 PDF 阅读区共用的背景色；为空时沿用系统默认背景。
    @Published public var backgroundColorHex: String? {
        didSet {
            saveState()
        }
    }

    public var isSVG: Bool {
        guard let name = originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".svg")
    }

    public var isPDFDocument: Bool {
        guard let name = originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".pdf")
    }

    @Published public var originalImageName: String? {
        didSet {
            saveState()
        }
    }

    public var imageSource: ImageSource?

    @Published public var imageURL: URL? {
        didSet {
            if let url = imageURL {
                let cacheDir = getCachedImageURL()?.deletingLastPathComponent()
                let isAlreadyCached = cacheDir.map { url.path.hasPrefix($0.path) } ?? false
                if !isAlreadyCached {
                    if let cachedURL = cacheImage(from: url) {
                        imageURL = cachedURL
                    }
                }
                saveState()
            } else {
                saveState()
                clearCachedImages()
            }
        }
    }

    @Published public var webURL: URL? {
        didSet {
            isWebEditableElementFocused = false
            saveState()
        }
    }

    @Published public var actualWebURL: URL? {
        didSet {
            saveState()
        }
    }

    @Published public var textURL: URL? {
        didSet {
            saveState()
        }
    }

    private var saveTask: Task<Void, Never>?

    @Published public var text: String {
        didSet {
            updateRenderedMarkdown()

            if !isBatchUpdating {
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000) // 800ms 防抖落盘
                    if Task.isCancelled { return }
                    self.saveState()
                }
            }
        }
    }

    @Published public var renderedMarkdown: NSAttributedString = NSAttributedString()

    @Published public var isMarkdownPreview: Bool {
        didSet {
            saveState()
            if isMarkdownPreview {
                updateRenderedMarkdown()
            }
        }
    }

    public var isMarkdownDocument: Bool {
        guard let name = originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".md") || name.hasSuffix(".markdown")
    }

    public var isCSVDocument: Bool {
        guard let name = originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".csv")
    }

    @Published public var isPinned: Bool {
        didSet {
            saveState()
        }
    }

    @Published public var opacity: Double {
        didSet {
            // 舍入到小数点后一位以防止浮点数精度误差（如 0.4 - 0.1 = 0.30000000000000004）
            let rounded = (opacity * 10).rounded() / 10
            let clamped = max(0.3, min(1.0, rounded))
            if clamped != opacity {
                // 再次赋值以触发 clamp 修正，不会引起无限递归，因为第二次必定相等
                opacity = clamped
            } else {
                saveState()
            }
        }
    }

    public var windowFrame: String?
    @Published public var createdAt: Date?

    @Published public var showBorder: Bool {
        didSet {
            saveState()
            NotificationCenter.default.post(name: .showBorderDidChange, object: self)
        }
    }

    @Published public var imageScale: Double {
        didSet {
            let clamped = Self.clampImageScale(imageScale)
            if clamped != imageScale {
                imageScale = clamped
            } else {
                if !isInteractiveZooming {
                    saveState()
                }
            }
        }
    }

    @Published public var textFontSize: Double {
        didSet {
            let clamped = Self.clampTextFontSize(textFontSize)
            if clamped != textFontSize {
                textFontSize = clamped
            } else {
                saveState()
                updateRenderedMarkdown()
            }
        }
    }

    @Published public var webZoom: Double {
        didSet {
            let clamped = Self.clampWebZoom(webZoom)
            if clamped != webZoom {
                webZoom = clamped
            } else {
                saveState()
            }
        }
    }

    private enum DroppedItem {
        case image(NSImage, originalName: String?)
        case url(URL)
    }

    // MARK: - Cache Management Helpers

    private static func getFlofoilDirectoryURL() -> URL? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL.appendingPathComponent("Flofoil", isDirectory: true)
    }

    /// 返回应用自建缓存目录。
    public static func cacheDirectoryURLs() -> [URL] {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        let currentURL = appSupportURL.appendingPathComponent("Flofoil", isDirectory: true)
        return FileManager.default.fileExists(atPath: currentURL.path) ? [currentURL] : []
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

    private func getCachedImageURL(for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
        getCachedContentURL(kind: "image", for: windowId, extension: ext)
    }

    private func getCachedContentURL(kind: String, for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
        guard let flofoilURL = AppState.getFlofoilDirectoryURL() else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: flofoilURL.path) {
            try? FileManager.default.createDirectory(at: flofoilURL, withIntermediateDirectories: true, attributes: nil)
        }
        let targetId = windowId ?? self.id
        let filename = "cached_\(kind)_\(targetId.uuidString)"
        if let ext = ext, !ext.isEmpty {
            return flofoilURL.appendingPathComponent("\(filename).\(ext)", isDirectory: false)
        } else {
            return flofoilURL.appendingPathComponent(filename, isDirectory: false)
        }
    }

    /// 将用户打开的本地文件复制到应用缓存，之后不再依赖源文件。
    private func cacheImportedFile(from sourceURL: URL, kind: String, for windowId: UUID? = nil) -> URL? {
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
    private static func localSourceFingerprint(for url: URL) -> String? {
        guard url.isFileURL, !isManagedCacheURL(url) else { return nil }
        return "file:\(url.resolvingSymlinksInPath().standardizedFileURL.path)"
    }

    private func clearCachedImages() {
        guard let flofoilURL = AppState.getFlofoilDirectoryURL() else {
            return
        }
        guard FileManager.default.fileExists(atPath: flofoilURL.path) else { return }

        // 获取历史记录里被引用的所有图片路径，防止物理删除仍然被历史引用的图片
        let historyPaths = HistoryManager.shared.historyConfigs.compactMap { $0.imagePath }

        if let files = try? FileManager.default.contentsOfDirectory(at: flofoilURL, includingPropertiesForKeys: nil) {
            for file in files {
                if file.lastPathComponent.hasPrefix("cached_image_\(id.uuidString)") {
                    if !historyPaths.contains(file.path) {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
    }

    private static func findCachedImageInDirectory(for id: UUID) -> URL? {
        guard let flofoilURL = getFlofoilDirectoryURL() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: flofoilURL.path) else { return nil }

        if let files = try? FileManager.default.contentsOfDirectory(at: flofoilURL, includingPropertiesForKeys: nil) {
            for file in files {
                if file.lastPathComponent.hasPrefix("cached_image_\(id.uuidString)") {
                    return file
                }
            }
        }
        return nil
    }

    private static func findLegacyCachedImageInDirectory() -> URL? {
        guard let flofoilURL = getFlofoilDirectoryURL() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: flofoilURL.path) else { return nil }

        if let files = try? FileManager.default.contentsOfDirectory(at: flofoilURL, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix("cached_image") && !name.contains("_") {
                    return file
                }
            }
        }
        return nil
    }

    private func convertToHEIC(sourceURL: URL, destURL: URL, quality: Float = 0.85) -> Bool {
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

    private func convertNSImageToHEIC(image: NSImage, destURL: URL, quality: Float = 0.8, backingScaleFactor: CGFloat = 1.0) -> Bool {
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

    public func createNewFlofoilFromScreenshot(image: NSImage, backingScaleFactor: CGFloat) {
        let webTitle = self.originalImageName ?? NSLocalizedString("Untitled Page", comment: "")
        let formattedTitle = String(format: NSLocalizedString("Web Screenshot: %@", comment: ""), webTitle)

        let newId = UUID()
        guard let destURL = self.getCachedImageURL(for: newId, extension: "heic") else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.convertNSImageToHEIC(image: image, destURL: destURL, quality: 0.8, backingScaleFactor: backingScaleFactor) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .createNewFlofoilFromImage,
                        object: nil,
                        userInfo: [
                            "id": newId,
                            "imageURL": destURL,
                            "originalName": formattedTitle
                        ]
                    )
                }
            } else {
                print("Failed to compress and save heic image flofoil")
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

    private func cacheImage(from sourceURL: URL) -> URL? {
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

    public init(config: WindowConfig) {
        self.id = config.id
        self.sourceFingerprint = config.sourceFingerprint
        self.isPinned = config.isPinned
        self.opacity = config.opacity
        if let path = config.textPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.textURL = url
                do {
                    self.text = try Self.readTextContent(from: url)
                } catch {
                    self.text = config.text
                }
            } else {
                self.textURL = nil
                self.text = config.text
            }
        } else {
            self.textURL = nil
            self.text = config.text
        }
        self.isMarkdownPreview = config.isMarkdownPreview
        self.windowFrame = config.windowFrame
        self.originalImageName = config.originalImageName
        self.imageSource = config.imageSource
        self.showBorder = config.showBorder
        self.imageScale = Self.clampImageScale(config.imageScale)
        self.textFontSize = Self.clampTextFontSize(config.textFontSize)
        self.webZoom = Self.clampWebZoom(config.webZoom)
        self.createdAt = config.createdAt
        self.svgColor = config.svgColor
        self.backgroundColorHex = config.backgroundColorHex

        if let path = config.imagePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.imageURL = url
            } else if let resolvedURL = Self.findCachedImageInDirectory(for: config.id) {
                self.imageURL = resolvedURL
                self.svgColor = config.svgColor
            } else if let legacyURL = Self.findLegacyCachedImageInDirectory() {
                self.imageURL = legacyURL
                self.svgColor = config.svgColor
            } else {
                self.imageURL = nil
            }
        } else {
            self.imageURL = nil
        }

        if let webStr = config.webURLString, let url = URL(string: webStr) {
            self.webURL = url
        } else {
            self.webURL = nil
        }

        if let actualWebStr = config.actualWebURLString, let url = URL(string: actualWebStr) {
            self.actualWebURL = url
        } else {
            self.actualWebURL = nil
        }
        super.init()
        // 在调用 saveState 时避免触发死循环
        if let path = config.imagePath, !FileManager.default.fileExists(atPath: path) {
            if Self.findCachedImageInDirectory(for: config.id) != nil || Self.findLegacyCachedImageInDirectory() != nil {
                saveState()
            }
        }
        updateRenderedMarkdown()
    }

    public init(id: UUID = UUID()) {
        self.id = id
        self.sourceFingerprint = nil
        self.isPinned = false
        self.opacity = 1.0
        self.text = ""
        self.isMarkdownPreview = false
        self.windowFrame = nil
        self.imageURL = nil
        self.webURL = nil
        self.actualWebURL = nil
        self.textURL = nil
        self.originalImageName = nil
        self.imageSource = nil
        self.showBorder = true
        self.imageScale = 1.0
        self.textFontSize = Self.defaultTextFontSize
        self.webZoom = 1.0
        self.createdAt = Date()
        self.svgColor = nil
        self.backgroundColorHex = nil
        super.init()
        updateRenderedMarkdown()
    }

    public func saveState() {
        guard !isBatchUpdating else { return }
        let config = toConfig()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if imageURL != nil || webURL != nil || textURL != nil || !trimmedText.isEmpty {
            HistoryManager.shared.addToHistory(config)
        }
    }

    public func loadConfig(_ config: WindowConfig) {
        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
            updateRenderedMarkdown()
        }

        // 载入历史项必须沿用原 UUID，否则随后的自动保存会创建一条重复历史。
        self.id = config.id
        self.sourceFingerprint = config.sourceFingerprint
        self.isPinned = config.isPinned
        self.opacity = config.opacity
        self.originalImageName = config.originalImageName
        self.imageSource = config.imageSource
        self.showBorder = config.showBorder
        self.imageScale = Self.clampImageScale(config.imageScale)
        self.textFontSize = Self.clampTextFontSize(config.textFontSize)
        self.webZoom = Self.clampWebZoom(config.webZoom)
        self.isMarkdownPreview = config.isMarkdownPreview
        self.windowFrame = config.windowFrame
        self.createdAt = config.createdAt
        self.svgColor = config.svgColor
        self.backgroundColorHex = config.backgroundColorHex

        // 载入历史记录时，一律尝试通知窗口控制器恢复当初保存的窗口位置与尺寸
        if let frameString = config.windowFrame {
            NotificationCenter.default.post(
                name: .shouldRestoreFrame,
                object: nil,
                userInfo: ["frame": frameString, "id": id]
            )
        }

        if let path = config.imagePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.imageURL = url
            } else {
                self.imageURL = nil
            }
        } else {
            self.imageURL = nil
        }

        if let webStr = config.webURLString, let url = URL(string: webStr) {
            self.webURL = url
        } else {
            self.webURL = nil
        }

        if let actualWebStr = config.actualWebURLString, let url = URL(string: actualWebStr) {
            self.actualWebURL = url
        } else {
            self.actualWebURL = nil
        }
        if let path = config.textPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.textURL = url
                do {
                    self.text = try Self.readTextContent(from: url)
                } catch {
                    self.text = config.text
                }
            } else {
                self.textURL = nil
                self.text = config.text
            }
        } else {
            self.textURL = nil
            self.text = config.text
        }
    }

    public func toConfig() -> WindowConfig {
        return WindowConfig(
            id: id,
            imagePath: imageURL?.path,
            webURLString: webURL?.absoluteString,
            actualWebURLString: actualWebURL?.absoluteString,
            originalImageName: originalImageName,
            imageSource: imageSource,
            text: text,
            isPinned: isPinned,
            opacity: opacity,
            windowFrame: windowFrame,
            showBorder: showBorder,
            imageScale: imageScale,
            textFontSize: textFontSize,
            isMarkdownPreview: isMarkdownPreview,
            createdAt: createdAt,
            svgColor: svgColor,
            backgroundColorHex: backgroundColorHex,
            textPath: textURL?.path,
            contentKind: HistoryContentKind.infer(from: WindowConfig(
                id: id,
                imagePath: imageURL?.path,
                webURLString: webURL?.absoluteString,
                originalImageName: originalImageName,
                text: text,
                isMarkdownPreview: isMarkdownPreview,
                textPath: textURL?.path
            )),
            sourceFingerprint: sourceFingerprint,
            webZoom: webZoom
        )
    }

    public func openImage(url: URL) {
        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
        }
        if imageURL != nil || webURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.id = UUID()
        }
        self.originalImageName = url.lastPathComponent
        self.sourceFingerprint = Self.localSourceFingerprint(for: url)
        self.imageSource = nil
        self.showBorder = false
        self.createdAt = Date()
        self.webURL = nil
        self.actualWebURL = nil
        if let cachedURL = cacheImage(from: url) {
            self.imageURL = cachedURL
        } else {
            self.imageURL = url
        }
    }

    public func openWeb(url: URL) {
        let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? UUID()
            : id
        let cachedURL: URL
        if url.isFileURL {
            guard let copiedURL = cacheImportedFile(from: url, kind: "web", for: targetID) else { return }
            cachedURL = copiedURL
        } else {
            // 远程网页以 URL 为内容来源，不属于本地文件缓存。
            cachedURL = url
        }

        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
        }
        self.id = targetID
        self.sourceFingerprint = Self.localSourceFingerprint(for: url)
        self.originalImageName = url.lastPathComponent
        self.imageSource = nil
        self.showBorder = true
        self.imageScale = 1.0
        self.createdAt = Date()
        self.imageURL = nil
        self.webURL = cachedURL
        self.actualWebURL = nil
    }

    private static func readTextContent(from url: URL) throws -> String {
        // 1. 尝试以系统的自动编码探测读取
        var usedEncoding: String.Encoding = .utf8
        if let content = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return content
        }

        // 2. 尝试显式以 UTF-8 读取
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        // 3. 尝试以 GBK / GB18030 读取
        let gbkEncodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbkEncoding = String.Encoding(rawValue: gbkEncodingValue)
        if let content = try? String(contentsOf: url, encoding: gbkEncoding) {
            return content
        }

        // 4. 尝试以 UTF-16 读取
        if let content = try? String(contentsOf: url, encoding: .utf16) {
            return content
        }

        // 5. 尝试以 Windows CP1252 / ASCII 读取
        if let content = try? String(contentsOf: url, encoding: .ascii) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
            return content
        }

        // 兜底：如果都失败，抛出最后的异常（用 utf8 读取抛出的错误，这样至少有报错堆栈）
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func openTextFile(url: URL) {
        let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? UUID()
            : id
        guard let cachedURL = cacheImportedFile(from: url, kind: "text", for: targetID) else { return }

        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
        }

        do {
            let content = try Self.readTextContent(from: cachedURL)
            self.id = targetID
            self.sourceFingerprint = Self.localSourceFingerprint(for: url)
            self.text = content
            self.textURL = cachedURL
            self.originalImageName = url.lastPathComponent
            self.imageSource = nil
            self.imageURL = nil
            self.webURL = nil
            self.actualWebURL = nil
            self.showBorder = true
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                self.isMarkdownPreview = true
            } else {
                self.isMarkdownPreview = false
            }
            self.createdAt = Date()
        } catch {
            print("Failed to read text file: \(error)")
        }
    }

    private func isTextFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let webExtensions = ["html", "htm", "webarchive", "xhtml"]
        if webExtensions.contains(ext) {
            return false
        }

        let textExtensions = ["txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "ini", "conf", "plist", "log", "swift", "py", "js", "ts", "sh", "css", "php", "c", "cpp", "h", "java", "go", "rs", "sql", "rb"]
        if textExtensions.contains(ext) {
            return true
        }

        if let type = UTType(filenameExtension: ext) {
            if ext == "svg" || type.conforms(to: .svg) {
                return false
            }
            return type.conforms(to: .text)
        }
        return false
    }

    /// 判断本应用能否按内容打开本地文件，避免将未知文件的 Finder 图标当成图片。
    public func canOpenFile(url: URL) -> Bool {
        guard url.isFileURL else { return false }

        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "webarchive", "xhtml"].contains(ext) || isTextFile(url: url) {
            return true
        }
        return NSImage(contentsOf: url) != nil
    }

    public func openFile(url: URL) {
        guard canOpenFile(url: url) else { return }

        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "webarchive", "xhtml"].contains(ext) {
            openWeb(url: url)
        } else if isTextFile(url: url) {
            openTextFile(url: url)
        } else {
            openImage(url: url)
        }
    }

    @discardableResult
    public func copyCurrentImageToPasteboard() -> Bool {
        guard webURL == nil,
              let imageURL,
              let image = NSImage(contentsOf: imageURL) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    public func saveWebScreenshot(_ image: NSImage, triggerSavePanel: Bool = false) {
        guard webURL != nil else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let tiffData = image.tiffRepresentation,
                  let bitmapImage = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                return
            }

            guard let destURL = self.getCachedImageURL(extension: "png") else { return }

            do {
                try pngData.write(to: destURL)
                DispatchQueue.main.async {
                    guard self.webURL != nil else { return }
                    self.imageURL = destURL

                    if triggerSavePanel {
                        NotificationCenter.default.post(
                            name: .webSnapshotReadyForSave,
                            object: nil,
                            userInfo: ["id": self.id]
                        )
                    }
                }
            } catch {
                print("Failed to save web screenshot: \(error)")
            }
        }
    }

    public func openImage(image: NSImage, originalName: String? = nil, imageSource: ImageSource? = nil) {
        if imageURL != nil || webURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.id = UUID()
        }
        self.isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let tiffData = image.tiffRepresentation,
                  let bitmapImage = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                return
            }

            self.clearCachedImages()
            guard let destURL = self.getCachedImageURL(extension: "png") else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                return
            }

            do {
                try pngData.write(to: destURL)
                DispatchQueue.main.async {
                    self.isBatchUpdating = true
                    self.sourceFingerprint = nil
                    self.originalImageName = originalName ?? "dropped_image.png"
                    self.imageSource = imageSource
                    self.showBorder = false
                    self.createdAt = Date()
                    self.webURL = nil
                    self.actualWebURL = nil
                    self.imageURL = destURL
                    self.isBatchUpdating = false
                    self.isLoading = false
                    self.saveState()
                }
            } catch {
                print("Failed to save dropped image to cache: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }

    public func handleDrop(providers: [NSItemProvider], completion: @escaping (Bool) -> Void = { _ in }) {
        NSLog("handleDrop started for \(providers.count) providers")
        for (index, p) in providers.enumerated() {
            NSLog("Provider [\(index)] types: \(p.registeredTypeIdentifiers), suggestedName: \(p.suggestedName ?? "nil")")
        }

        // 首先尝试从 drag pasteboard 获取数据
        self.tryLoadFromDragPasteboard { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            if success {
                completion(true)
            } else {
                // 如果从 pasteboard 载入失败，则回退到通过 providers 逐个载入
                NSLog("Pasteboard loading failed or yielded no results, falling back to providers.")
                self.tryLoadProviders(providers, index: 0, completion: completion)
            }
        }
    }

    private func tryLoadFromDragPasteboard(completion: @escaping (Bool) -> Void) {
        let pb = NSPasteboard(name: .drag)
        NSLog("Attempting to parse from drag pasteboard. Available types: \(pb.types ?? [])")

        // 1. 尝试读取 URL
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            NSLog("Found URLs in drag pasteboard: \(urls.map { $0.absoluteString })")
            // 筛选出受支持 of URL
            let supportedURLs = urls.filter { self.isSupportedDroppedURL($0) }
            if !supportedURLs.isEmpty {
                self.tryOpenPasteboardURLs(supportedURLs, index: 0) { success in
                    if success {
                        completion(true)
                    } else {
                        // 文件拖入失败时不读取 Finder 提供的文件图标。
                        completion(false)
                    }
                }
                return
            }

            // 剪贴板中已有文件 URL，但它们都不受支持：直接忽略。
            if urls.contains(where: \.isFileURL) {
                completion(false)
                return
            }
        }

        // 2. 尝试读取 Image
        self.tryLoadImageFromPasteboard(pb, completion: completion)
    }

    private func tryOpenPasteboardURLs(_ urls: [URL], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < urls.count else {
            completion(false)
            return
        }

        self.openDroppedURL(urls[index]) { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            if success {
                completion(true)
            } else {
                self.tryOpenPasteboardURLs(urls, index: index + 1, completion: completion)
            }
        }
    }

    private func tryLoadImageFromPasteboard(_ pb: NSPasteboard, completion: @escaping (Bool) -> Void) {
        // 尝试直接读取 NSImage 对象
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
                NSLog("Successfully read NSImage from drag pasteboard")
                DispatchQueue.main.async {
                    self.openImage(image: firstImage)
                    completion(true)
                }
                return
            }
        }

        // 尝试读取原始的图片 Data (tiff, png)
        let imageTypes = [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType.png]
        for type in imageTypes {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                NSLog("Successfully loaded NSImage from drag pasteboard data type: \(type.rawValue)")
                DispatchQueue.main.async {
                    self.openImage(image: image)
                    completion(true)
                }
                return
            }
        }

        completion(false)
    }

    private func tryLoadProviders(_ providers: [NSItemProvider], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < providers.count else {
            completion(false)
            return
        }

        self.tryLoadProvider(providers[index]) { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }
            if success {
                completion(true)
            } else {
                self.tryLoadProviders(providers, index: index + 1, completion: completion)
            }
        }
    }

    private func tryLoadProvider(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        // 1. 尝试以 URL 载入
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                guard let self = self else {
                    completion(false)
                    return
                }

                if let error = error {
                    NSLog("loadObject URL failed for provider: \(error.localizedDescription)")
                }

                if let droppedURL = url, self.isSupportedDroppedURL(droppedURL) {
                    NSLog("Successfully loaded supported URL: \(droppedURL.absoluteString)")
                    self.openDroppedURL(droppedURL) { success in
                        if success {
                            completion(true)
                        } else {
                            // URL 处理失败，尝试加载为 Image / Fallback
                            self.tryLoadProviderAsImage(provider, completion: completion)
                        }
                    }
                } else if let droppedURL = url, droppedURL.isFileURL {
                    // 文件类型不受支持时，不能回退读取其 Finder 图标。
                    completion(false)
                } else {
                    // 没有得到 URL，或者 URL 不受支持，尝试加载为 Image / Fallback
                    self.tryLoadProviderAsImage(provider, completion: completion)
                }
            }
        } else {
            // 不能作为 URL 载入，尝试加载为 Image / Fallback
            self.tryLoadProviderAsImage(provider, completion: completion)
        }
    }

    private func tryLoadProviderAsImage(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                guard let self = self else {
                    completion(false)
                    return
                }
                if let error = error {
                    NSLog("loadObject NSImage failed for provider: \(error.localizedDescription)")
                }
                if let nsImage = image as? NSImage {
                    NSLog("Successfully loaded NSImage object from provider")
                    DispatchQueue.main.async {
                        self.openImage(image: nsImage, originalName: provider.suggestedName)
                        completion(true)
                    }
                } else {
                    self.tryLoadProviderAsImageData(provider, completion: completion)
                }
            }
        } else {
            self.tryLoadProviderAsImageData(provider, completion: completion)
        }
    }

    private func tryLoadProviderAsImageData(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        let imageIdentifiers = provider.registeredTypeIdentifiers.filter { ident in
            if let utType = UTType(ident) {
                return utType.conforms(to: .image)
            }
            return false
        }

        if !imageIdentifiers.isEmpty {
            NSLog("Found image identifiers in provider: \(imageIdentifiers)")
            self.tryLoadImageData(from: provider, with: imageIdentifiers, index: 0) { [weak self] image in
                guard let self = self else {
                    completion(false)
                    return
                }
                if let image = image {
                    NSLog("Successfully loaded NSImage from data representation")
                    DispatchQueue.main.async {
                        self.openImage(image: image, originalName: provider.suggestedName)
                        completion(true)
                    }
                } else {
                    self.tryLoadProviderAsFallback(provider, completion: completion)
                }
            }
        } else {
            self.tryLoadProviderAsFallback(provider, completion: completion)
        }
    }

    private func tryLoadProviderAsFallback(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        self.loadAsItemRepresentation(provider: provider, completion: completion)
    }

    private func tryLoadImageData(
        from provider: NSItemProvider,
        with identifiers: [String],
        index: Int,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard index < identifiers.count else {
            completion(nil)
            return
        }

        let typeId = identifiers[index]
        NSLog("Attempting to loadDataRepresentation for type: \(typeId)")

        provider.loadDataRepresentation(forTypeIdentifier: typeId) { [weak self] data, error in
            guard let self = self else {
                completion(nil)
                return
            }
            if let error = error {
                NSLog("Failed loadDataRepresentation for \(typeId): \(error.localizedDescription)")
            }
            if let data = data, let image = NSImage(data: data) {
                NSLog("Successfully loaded NSImage from type: \(typeId)")
                completion(image)
            } else {
                self.tryLoadImageFileRepresentation(from: provider, typeIdentifier: typeId) { image in
                    if let image = image {
                        completion(image)
                    } else {
                        self.tryLoadImageData(from: provider, with: identifiers, index: index + 1, completion: completion)
                    }
                }
            }
        }
    }

    private func tryLoadImageFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        completion: @escaping (NSImage?) -> Void
    ) {
        NSLog("Attempting to loadFileRepresentation for type: \(typeIdentifier)")
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            if let error = error {
                NSLog("Failed loadFileRepresentation for \(typeIdentifier): \(error.localizedDescription)")
            }

            guard let self = self, let url = url else {
                completion(nil)
                return
            }

            if url.isFileURL {
                let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) ?? NSImage(contentsOf: url)
                if image != nil {
                    NSLog("Successfully loaded NSImage from file representation: \(typeIdentifier)")
                }
                completion(image)
            } else {
                self.loadDownloadedImage(from: url, completion: completion)
            }
        }
    }

    private func handleDropFallback(provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        NSLog("handleDropFallback started")
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                if let error = error {
                    NSLog("Failed to loadObject URL: \(error.localizedDescription)")
                }
                guard let self = self else {
                    completion(false)
                    return
                }
                if let fileURL = url {
                    NSLog("Loaded URL: \(fileURL.absoluteString) (isFileURL: \(fileURL.isFileURL))")
                    self.openDroppedURL(fileURL, completion: completion)
                    return
                }
                self.loadAsItemRepresentation(provider: provider, completion: completion)
            }
        } else {
            NSLog("Provider cannot load URL, trying loadItem fallback")
            self.loadAsItemRepresentation(provider: provider, completion: completion)
        }
    }

    private func loadAsItemRepresentation(provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        let identifiers = fallbackTypeIdentifiers(for: provider)
        NSLog("Attempting loadItem fallback for identifiers: \(identifiers)")

        tryLoadDroppedItem(from: provider, with: identifiers, index: 0) { [weak self] item in
            guard let self = self else {
                completion(false)
                return
            }

            switch item {
            case let .image(image, originalName):
                DispatchQueue.main.async {
                    self.openImage(image: image, originalName: originalName)
                    completion(true)
                }
            case let .url(url):
                self.openDroppedURL(url, completion: completion)
            case nil:
                NSLog("loadItem fallback failed, trying loadAsImage fallback")
                self.loadAsImage(provider: provider, completion: completion)
            }
        }
    }

    private func fallbackTypeIdentifiers(for provider: NSItemProvider) -> [String] {
        let additionalIdentifiers = [
            UTType.url.identifier,
            UTType.fileURL.identifier,
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            UTType.html.identifier
        ]
        var seen = Set<String>()
        return (provider.registeredTypeIdentifiers + additionalIdentifiers).filter { seen.insert($0).inserted }
    }

    private func tryLoadDroppedItem(
        from provider: NSItemProvider,
        with identifiers: [String],
        index: Int,
        completion: @escaping (DroppedItem?) -> Void
    ) {
        guard index < identifiers.count else {
            completion(nil)
            return
        }

        let typeIdentifier = identifiers[index]
        NSLog("Attempting loadItem for type: \(typeIdentifier)")
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self = self else {
                completion(nil)
                return
            }

            if let error = error {
                NSLog("Failed loadItem for \(typeIdentifier): \(error.localizedDescription)")
            }

            if let droppedItem = self.droppedItem(from: item, typeIdentifier: typeIdentifier, suggestedName: provider.suggestedName) {
                completion(droppedItem)
            } else {
                self.tryLoadDroppedItem(from: provider, with: identifiers, index: index + 1, completion: completion)
            }
        }
    }

    private func droppedItem(from item: NSSecureCoding?, typeIdentifier: String, suggestedName: String?) -> DroppedItem? {
        if let url = item as? URL {
            NSLog("Loaded URL from item representation \(typeIdentifier): \(url.absoluteString)")
            return .url(url)
        }

        if let url = item as? NSURL, let swiftURL = url as URL? {
            NSLog("Loaded NSURL from item representation \(typeIdentifier): \(swiftURL.absoluteString)")
            return .url(swiftURL)
        }

        if let image = item as? NSImage {
            NSLog("Loaded NSImage from item representation \(typeIdentifier)")
            return .image(image, originalName: suggestedName)
        }

        if let data = item as? Data {
            if let image = NSImage(data: data) {
                NSLog("Loaded image data from item representation \(typeIdentifier)")
                return .image(image, originalName: suggestedName)
            }
            if let text = String(data: data, encoding: .utf8), let url = imageURLFromText(text) {
                NSLog("Loaded URL text from data item representation \(typeIdentifier): \(url.absoluteString)")
                return .url(url)
            }
        }

        if let text = item as? String, let url = imageURLFromText(text) {
            NSLog("Loaded URL text from item representation \(typeIdentifier): \(url.absoluteString)")
            return .url(url)
        }

        if let text = item as? NSString, let url = imageURLFromText(text as String) {
            NSLog("Loaded NSString URL from item representation \(typeIdentifier): \(url.absoluteString)")
            return .url(url)
        }

        return nil
    }

    private func imageURLFromText(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), isSupportedDroppedURL(url) {
            return url
        }

        if trimmed.range(of: "<html", options: .caseInsensitive) != nil,
           let extractedURL = extractImageURL(from: trimmed) {
            return extractedURL
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              let range = Range(match.range, in: trimmed),
              let url = URL(string: String(trimmed[range])),
              isSupportedDroppedURL(url) else {
            return nil
        }

        return url
    }

    private func isSupportedDroppedURL(_ url: URL) -> Bool {
        if url.isFileURL {
            return canOpenFile(url: url)
        }
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func openDroppedURL(_ url: URL, completion: @escaping (Bool) -> Void) {
        if url.isFileURL {
            if canOpenFile(url: url) {
                DispatchQueue.main.async {
                    self.openFile(url: url)
                    completion(true)
                }
            } else {
                completion(false)
            }
        } else {
            downloadImage(from: url, completion: completion)
        }
    }

    private func loadAsImage(provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                if let error = error {
                    NSLog("Failed to loadObject NSImage: \(error.localizedDescription)")
                }
                guard let self = self, let nsImage = image as? NSImage else {
                    completion(false)
                    return
                }
                DispatchQueue.main.async {
                    self.openImage(image: nsImage)
                    completion(true)
                }
            }
        } else {
            completion(false)
        }
    }

    private func downloadImage(from url: URL, isHTMLFallbackAllowed: Bool = true, completion: @escaping (Bool) -> Void) {
        NSLog("downloadImage started for \(url.absoluteString)")
        loadDownloadedImage(from: url) { [weak self] image in
            guard let self = self else {
                completion(false)
                return
            }

            if let image = image {
                DispatchQueue.main.async {
                    self.openImage(image: image, originalName: url.lastPathComponent)
                    completion(true)
                }
                return
            }

            if isHTMLFallbackAllowed {
                self.downloadHTMLImageFallback(from: url, completion: completion)
            } else {
                NSLog("Failed to decode downloaded image data from \(url.absoluteString)")
                completion(false)
            }
        }
    }

    private func loadDownloadedImage(from url: URL, completion: @escaping (NSImage?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                NSLog("Failed to download image from \(url.absoluteString): \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data else {
                NSLog("No data returned from \(url.absoluteString)")
                completion(nil)
                return
            }

            if let image = NSImage(data: data) {
                NSLog("Successfully downloaded and decoded image from \(url.absoluteString)")
                completion(image)
            } else {
                NSLog("Failed to decode downloaded image data from \(url.absoluteString)")
                completion(nil)
            }
        }
        task.resume()
    }

    private func downloadHTMLImageFallback(from url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error = error {
                NSLog("Failed to download HTML fallback from \(url.absoluteString): \(error.localizedDescription)")
                completion(false)
                return
            }

            guard let self = self,
                  let data = data,
                  let htmlString = String(data: data, encoding: .utf8),
                  htmlString.range(of: "<html", options: .caseInsensitive) != nil else {
                completion(false)
                return
            }

            NSLog("Downloaded content is HTML. Attempting to extract og:image or twitter:image.")
            if let extractedURL = self.extractImageURL(from: htmlString) {
                NSLog("Extracted image URL: \(extractedURL.absoluteString). Retrying download.")
                self.downloadImage(from: extractedURL, isHTMLFallbackAllowed: false, completion: completion)
            } else {
                NSLog("Failed to extract any cover image URL from HTML.")
                completion(false)
            }
        }
        task.resume()
    }

    private func extractImageURL(from html: String) -> URL? {
        // Simple search for og:image
        var searchRange = html.startIndex..<html.endIndex
        while let ogImageRange = html.range(of: "og:image", options: [], range: searchRange) {
            let startOfSearch = ogImageRange.lowerBound
            if let metaStartRange = html.range(of: "<meta", options: .backwards, range: html.startIndex..<startOfSearch),
               let metaEndRange = html.range(of: ">", options: [], range: startOfSearch..<html.endIndex) {

                let metaTag = html[metaStartRange.lowerBound...metaEndRange.lowerBound]
                if let contentRange = metaTag.range(of: "content="),
                   let valStart = metaTag.range(of: "\"", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                    if let valEnd = metaTag.range(of: "\"", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                        let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                        if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                            return url
                        }
                    }
                }
                if let contentRange = metaTag.range(of: "content="),
                   let valStart = metaTag.range(of: "'", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                    if let valEnd = metaTag.range(of: "'", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                        let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                        if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                            return url
                        }
                    }
                }
            }
            searchRange = ogImageRange.upperBound..<html.endIndex
        }

        // Fallback to twitter:image
        searchRange = html.startIndex..<html.endIndex
        while let twitterImageRange = html.range(of: "twitter:image", options: [], range: searchRange) {
            let startOfSearch = twitterImageRange.lowerBound
            if let metaStartRange = html.range(of: "<meta", options: .backwards, range: html.startIndex..<startOfSearch),
               let metaEndRange = html.range(of: ">", options: [], range: startOfSearch..<html.endIndex) {

                let metaTag = html[metaStartRange.lowerBound...metaEndRange.lowerBound]
                if let contentRange = metaTag.range(of: "content="),
                   let valStart = metaTag.range(of: "\"", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                    if let valEnd = metaTag.range(of: "\"", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                        let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                        if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                            return url
                        }
                    }
                }
            }
            searchRange = twitterImageRange.upperBound..<html.endIndex
        }

        return nil
    }

    public func resetContent() {
        NotificationCenter.default.post(
            name: .willResetContent,
            object: self
        )

        isBatchUpdating = true
        self.originalImageName = nil
        self.imageSource = nil
        self.imageURL = nil
        self.webURL = nil
        self.actualWebURL = nil
        self.textURL = nil
        self.text = ""
        self.sourceFingerprint = nil
        self.imageScale = 1.0
        self.id = UUID()
        self.createdAt = Date()
        self.svgColor = nil
        isBatchUpdating = false

        NotificationCenter.default.post(
            name: .shouldResetWindowFrame,
            object: self
        )
    }

    public func togglePin() {
        self.isPinned.toggle()
    }

    public func increaseOpacity() {
        self.opacity = opacity + 0.1
    }

    public func decreaseOpacity() {
        self.opacity = opacity - 0.1
    }

    public func increaseTextFontSize() {
        textFontSize += 1.0
    }

    public func decreaseTextFontSize() {
        textFontSize -= 1.0
    }

    public static func clampImageScale(_ value: Double) -> Double {
        max(minImageScale, min(maxImageScale, value))
    }

    public static func clampTextFontSize(_ value: Double) -> Double {
        max(minTextFontSize, min(maxTextFontSize, value))
    }

    public static func clampWebZoom(_ value: Double) -> Double {
        max(0.25, min(5.0, value))
    }

    deinit {
        renderTask?.cancel()
        saveTask?.cancel()
    }

    private var renderTask: Task<Void, Never>?

    private func updateRenderedMarkdown() {
        // 性能防御：如果当前不是预览模式或者不是 Markdown 文档，直接跳过 markdown 解析，保证打字零开销！
        guard isMarkdownPreview && isMarkdownDocument else { return }

        renderTask?.cancel()

        let textToRender = self.text
        let fontSize = self.textFontSize

        renderTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let htmlBody = Self.cmarkToHTML(textToRender)
            if Task.isCancelled { return }

            // 构建包含 CSS 的完整 HTML，支持自适应系统明暗主题与字号大小缩放
            let htmlContent = """
            <html>
            <head>
            <style>
            body, p, li, blockquote {
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                font-size: \(fontSize)px;
                line-height: 1.8;
                color: #000000;
                background-color: transparent;
            }
            body {
                margin: 0;
                padding: 0;
            }
            p {
                margin-top: 0;
                margin-bottom: 14px;
            }
            h1, h2, h3, h4, h5, h6 {
                font-weight: 600;
                margin-top: 24px;
                margin-bottom: 16px;
                line-height: 1.25;
            }
            h1 { font-size: 1.6em; border-bottom: 1px solid rgba(0,0,0,0.1); padding-bottom: 0.3em; }
            h2 { font-size: 1.4em; border-bottom: 1px solid rgba(0,0,0,0.1); padding-bottom: 0.3em; }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1.15em; }
            code {
                padding: 0.2em 0.4em;
                margin: 0;
                font-size: 85%;
                background-color: rgba(0,0,0,0.06);
                border-radius: 6px;
                font-family: Menlo, Consolas, monospace;
            }
            pre {
                padding: 16px;
                overflow: auto;
                font-size: 85%;
                line-height: 1.45;
                background-color: rgba(0,0,0,0.04);
                border-radius: 6px;
            }
            pre code {
                background-color: transparent;
                padding: 0;
                border-radius: 0;
            }
            blockquote {
                padding: 0 1em;
                color: rgba(0,0,0,0.6);
                border-left: 0.25em solid rgba(0,0,0,0.2);
                margin: 0 0 16px 0;
            }
            ul, ol {
                padding-left: 2em;
                margin-top: 0;
                margin-bottom: 16px;
            }
            @media (prefers-color-scheme: dark) {
                body {
                    color: #ffffff;
                }
                h1, h2 {
                    border-bottom-color: rgba(255,255,255,0.15);
                }
                code {
                    background-color: rgba(255,255,255,0.15);
                }
                pre {
                    background-color: rgba(255,255,255,0.1);
                }
                blockquote {
                    color: rgba(255,255,255,0.6);
                    border-left-color: rgba(255,255,255,0.25);
                }
            }
            </style>
            </head>
            <body>
            \(htmlBody)
            </body>
            </html>
            """

            await MainActor.run {
                if let data = htmlContent.data(using: .utf8),
                   let attr = try? NSAttributedString(
                       data: data,
                       options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                       documentAttributes: nil
                   ) {
                    // 后处理：直接遍历并修改富文本段落样式 (NSParagraphStyle) 以强制行高和段落间距生效
                    let mutableAttr = NSMutableAttributedString(attributedString: attr)
                    let fullRange = NSRange(location: 0, length: mutableAttr.length)

                    mutableAttr.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
                        let paragraphStyle = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
                        let mutableParagraphStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle

                        // 强制注入 1.45 倍行高
                        mutableParagraphStyle.lineHeightMultiple = 1.45
                        // 强制注入 12pt 段落底部留白
                        mutableParagraphStyle.paragraphSpacing = 12.0

                        mutableAttr.addAttribute(.paragraphStyle, value: mutableParagraphStyle, range: range)
                    }
                    self.renderedMarkdown = mutableAttr
                } else {
                    self.renderedMarkdown = NSAttributedString(string: textToRender)
                }
            }
        }
    }

    public static func cmarkToHTML(_ text: String) -> String {
        guard let cString = cmark_markdown_to_html(text, text.utf8.count, 0) else {
            return ""
        }
        let result = String(cString: cString)
        free(cString)
        return result
    }

    // MARK: - NSColorPanel Support

    public func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        if let hex = svgColor, let nsColor = NSColor(hex: hex) {
            panel.color = nsColor
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))

        // 创建一个重置按钮的 accessoryView，当点击时重置为原色
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let button = NSButton(title: NSLocalizedString("Reset Color", comment: ""), target: self, action: #selector(resetColorFromPanel))
        button.frame = NSRect(x: 10, y: 4, width: 180, height: 24)
        button.bezelStyle = .rounded
        accessory.addSubview(button)
        panel.accessoryView = accessory

        panel.makeKeyAndOrderFront(nil)
    }

    /// 打开窗体与 PDF 共用的背景色选择器，支持设置颜色透明度。
    public func showBackgroundColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        if let hex = backgroundColorHex, let color = NSColor(hex: hex) {
            panel.color = color
        } else {
            panel.color = .windowBackgroundColor
        }
        panel.setTarget(self)
        panel.setAction(#selector(backgroundColorPanelChanged(_:)))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let button = NSButton(
            title: NSLocalizedString("Reset Background Color", comment: ""),
            target: self,
            action: #selector(resetBackgroundColorFromPanel)
        )
        button.frame = NSRect(x: 10, y: 4, width: 180, height: 24)
        button.bezelStyle = .rounded
        accessory.addSubview(button)
        panel.accessoryView = accessory
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        // 确保应用处于活动状态，且颜色面板当前是可见的
        guard NSApplication.shared.isActive else { return }
        guard sender.isVisible else { return }

        // 确保只有当前处于主窗口（mainWindow）或关键窗口（keyWindow）状态的 AppState 才接受颜色面板的修改事件
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let activeWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
        let activeState = appDelegate.windowControllers.first(where: { $0.window == activeWindow })?.appState
        guard activeState === self else { return }

        if let hex = sender.color.toHex() {
            self.svgColor = hex
        }
    }

    @objc private func backgroundColorPanelChanged(_ sender: NSColorPanel) {
        // 将色板颜色以 sRGB（含 Alpha）保存，供窗体背景与 PDFView 共用。
        guard NSApplication.shared.isActive, sender.isVisible else { return }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let activeWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
        let activeState = appDelegate.windowControllers.first(where: { $0.window == activeWindow })?.appState
        guard activeState === self,
              let color = sender.color.usingColorSpace(.sRGB) else { return }

        backgroundColorHex = color.toHex()
    }

    @objc private func resetBackgroundColorFromPanel() {
        backgroundColorHex = nil

        // 避免为同步色板颜色而再次触发颜色回调，导致默认状态被覆盖。
        let panel = NSColorPanel.shared
        panel.setAction(nil)
        panel.color = .windowBackgroundColor
        panel.setAction(#selector(backgroundColorPanelChanged(_:)))
    }

    @objc private func resetColorFromPanel() {
        self.svgColor = nil
        // 同步把调色盘重设为某个默认值，防止用户误以为没生效，不过其实重置为原色后，调色盘里的颜色本身没有硬性规定
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0

        } else {
            return nil
        }

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func toHex() -> String? {
        guard let rgbColor = self.usingColorSpace(.sRGB) else {
            return nil
        }
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent

        if a == 1.0 {
            return String(format: "#%02X%02X%02X",
                          Int(round(r * 255)),
                          Int(round(g * 255)),
                          Int(round(b * 255)))
        } else {
            return String(format: "#%02X%02X%02X%02X",
                          Int(round(r * 255)),
                          Int(round(g * 255)),
                          Int(round(b * 255)),
                          Int(round(a * 255)))
        }
    }
}

extension Color {
    init?(hex: String) {
        guard let nsColor = NSColor(hex: hex) else { return nil }
        self.init(nsColor)
    }
}

extension Notification.Name {
    public static let webSnapshotReadyForSave = Notification.Name("webSnapshotReadyForSave")
    public static let createNewFlofoilFromImage = Notification.Name("createNewFlofoilFromImage")
    public static let shouldRestoreFrame = Notification.Name("shouldRestoreFrame")
    public static let shouldFitImageToWindowWidth = Notification.Name("shouldFitImageToWindowWidth")
    public static let shouldZoomIn = Notification.Name("shouldZoomIn")
    public static let shouldCloseWindow = Notification.Name("shouldCloseWindow")
    public static let shouldFitWindowToImage = Notification.Name("shouldFitWindowToImage")
    public static let shouldResizeWindowWithPinch = Notification.Name("shouldResizeWindowWithPinch")
    public static let shouldEndWindowPinchResize = Notification.Name("shouldEndWindowPinchResize")
    public static let shouldResetWindowFrame = Notification.Name("shouldResetWindowFrame")
    public static let willResetContent = Notification.Name("willResetContent")
    public static let showBorderDidChange = Notification.Name("showBorderDidChange")
    public static let shouldGoToPreviousPDFPage = Notification.Name("shouldGoToPreviousPDFPage")
    public static let shouldGoToNextPDFPage = Notification.Name("shouldGoToNextPDFPage")
    public static let shouldPromptForPDFPage = Notification.Name("shouldPromptForPDFPage")
    public static let pdfPageSizeDidChange = Notification.Name("pdfPageSizeDidChange")
    public static let pdfPageDidChange = Notification.Name("pdfPageDidChange")
    public static let shouldFitPDFToWindow = Notification.Name("shouldFitPDFToWindow")
    public static let shouldMatchPDFWindowAspectRatio = Notification.Name("shouldMatchPDFWindowAspectRatio")
    public static let shouldApplyPDFScaleToWindow = Notification.Name("shouldApplyPDFScaleToWindow")
}
