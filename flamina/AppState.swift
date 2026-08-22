//
//  AppState.swift
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
    /// 递增的拖拽代次，用于丢弃过期异步回调，避免“打开以前的东西”或并发覆盖。
    private var currentDropGeneration: UInt64 = 0

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

    /// 当前内容是否为视频文档（复用图片内容通道，但不经缓存）。
    public var isVideoDocument: Bool {
        guard let name = originalImageName else { return false }
        return Self.isVideoFileName(name)
    }

    /// 当前内容是否为音频文档（复用图片内容通道，但不经缓存）。
    public var isAudioDocument: Bool {
        guard let name = originalImageName else { return false }
        return Self.isAudioFileName(name)
    }

    /// 视频或音频：均引用原始文件并依赖安全范围书签。
    public var isExternalMediaDocument: Bool {
        isVideoDocument || isAudioDocument
    }

    /// 按扩展名判断是否属于视频类型；仅作快速预筛，实际能否播放需在打开时验证。
    public static func isVideoFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    public static func isVideoFile(url: URL) -> Bool {
        isVideoFileName(url.lastPathComponent)
    }

    /// 按扩展名判断是否属于系统音频类型；影片文件不视为音频。
    public static func isAudioFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .movie) { return false }
        return type.conforms(to: .audio)
    }

    public static func isAudioFile(url: URL) -> Bool {
        isAudioFileName(url.lastPathComponent)
    }

    public static func isExternalMediaFileName(_ name: String) -> Bool {
        isVideoFileName(name) || isAudioFileName(name)
    }

    public static func isExternalMediaFile(url: URL) -> Bool {
        isExternalMediaFileName(url.lastPathComponent)
    }

    /// 为视频/音频原始文件创建安全范围书签，用于跨进程生命周期保留沙盒访问授权。
    public static func makeSecurityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 解析视频安全范围书签并校验文件仍存在；返回解析后的 URL（文件移动后可解析到新路径）。
    /// 仅在内部临时持有访问授权完成存在性检查，不会长期占用授权。
    public static func resolveVideoBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        // 重启后尚未持有授权，fileExists 需在安全范围内检查才准确
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
                // 视频/音频不复制到应用缓存目录，仅记录原始文件路径。
                if !Self.isExternalMediaFile(url: url) {
                    // 切到非媒体内容时释放旧文件的安全范围访问授权
                    stopVideoAccess()
                    let cacheDir = getCachedImageURL()?.deletingLastPathComponent()
                    let isAlreadyCached = cacheDir.map { url.path.hasPrefix($0.path) } ?? false
                    if !isAlreadyCached {
                        if let cachedURL = cacheImage(from: url) {
                            imageURL = cachedURL
                        }
                    }
                }
                saveState()
            } else {
                stopVideoAccess()
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
            } else if !isInteractiveZooming {
                saveState()
                updateRenderedMarkdown()
            } else {
                updateRenderedMarkdown()
            }
        }
    }

    @Published public var webZoom: Double {
        didSet {
            let clamped = Self.clampWebZoom(webZoom)
            if clamped != webZoom {
                webZoom = clamped
            } else if !isInteractiveZooming {
                saveState()
            }
        }
    }

    /// 视频/音频循环播放开关；仅媒体模式生效，默认开启。
    @Published public var isVideoLooping: Bool {
        didSet {
            saveState()
        }
    }

    /// 视频/音频原始文件的安全范围书签；沙盒授权仅随进程有效，靠它在 app 重启后恢复访问。
    public var videoBookmarkData: Data?
    /// 当前已通过书签持有访问授权的媒体 URL，切换内容或销毁时需停止访问。
    private var accessingVideoURL: URL?

    private enum DroppedItem {
        case image(NSImage, originalName: String?)
        case url(URL)
    }

    // MARK: - Cache Management Helpers

    /// 将旧版本 Flofoil 的数据目录迁移到 Flamina，仅在新目录不存在时执行。
    @discardableResult
    private static func migrateLegacySupportDirectoryIfNeeded() -> Bool {
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

    private static func getFlaminaDirectoryURL() -> URL? {
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

    private func getCachedImageURL(for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
        getCachedContentURL(kind: "image", for: windowId, extension: ext)
    }

    private func getCachedContentURL(kind: String, for windowId: UUID? = nil, extension ext: String? = nil) -> URL? {
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

    private static func findCachedImageInDirectory(for id: UUID) -> URL? {
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

    private static func findLegacyCachedImageInDirectory() -> URL? {
        for baseURL in cacheDirectoryURLs() {
            if let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("cached_image") && !file.lastPathComponent.contains("_") {
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
        self.isVideoLooping = config.isVideoLooping

        if let path = config.imagePath {
            let url = URL(fileURLWithPath: path)
            // 视频/音频经安全范围书签恢复沙盒访问（重启后路径直接不可达）
            if Self.isExternalMediaFileName(config.originalImageName ?? path) {
                if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                    self.accessingVideoURL = restored.accessedURL
                    self.videoBookmarkData = restored.bookmark
                    self.imageURL = restored.url
                } else {
                    self.videoBookmarkData = nil
                    self.imageURL = nil
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
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
        // 在调用 saveState 时避免触发死循环；视频经书签恢复后可能重建了书签，也需要落盘
        if let path = config.imagePath, !FileManager.default.fileExists(atPath: path) {
            if Self.findCachedImageInDirectory(for: config.id) != nil || Self.findLegacyCachedImageInDirectory() != nil {
                saveState()
            }
        }
        if Self.isExternalMediaFileName(config.originalImageName ?? ""), videoBookmarkData != config.videoBookmark {
            saveState()
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
        self.isVideoLooping = true
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
        self.isVideoLooping = config.isVideoLooping

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
            // 视频/音频经安全范围书签恢复沙盒访问（重启后路径直接不可达）
            if Self.isExternalMediaFileName(config.originalImageName ?? path) {
                // 加载新配置前先释放旧的媒体授权
                stopVideoAccess()
                if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                    self.accessingVideoURL = restored.accessedURL
                    self.videoBookmarkData = restored.bookmark
                    self.imageURL = restored.url
                } else {
                    self.videoBookmarkData = nil
                    self.imageURL = nil
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
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
            webZoom: webZoom,
            isVideoLooping: isVideoLooping,
            videoBookmark: videoBookmarkData
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

    /// 打开本地视频；与图片不同，视频不复制到缓存目录，仅记录原始路径。
    public func openVideo(url: URL) {
        openExternalMedia(url: url, holdsSecurityAccess: false)
    }

    /// 打开本地音频；与视频相同，不复制到缓存目录，仅记录原始路径。
    public func openAudio(url: URL) {
        openExternalMedia(url: url, holdsSecurityAccess: false)
    }

    /// 打开本地音视频：引用原始文件并创建安全范围书签。
    /// - Parameter holdsSecurityAccess: 调用方已对 `url` 调用过 `startAccessingSecurityScopedResource` 且交由本窗口持有。
    private func openExternalMedia(url: URL, holdsSecurityAccess: Bool) {
        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
        }
        if imageURL != nil || webURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.id = UUID()
        }
        stopVideoAccess()
        self.originalImageName = url.lastPathComponent
        self.sourceFingerprint = Self.localSourceFingerprint(for: url)
        self.imageSource = nil
        self.showBorder = false
        self.imageScale = 1.0
        // 新打开的媒体恢复默认的循环播放
        self.isVideoLooping = true
        self.createdAt = Date()
        self.webURL = nil
        self.actualWebURL = nil
        // 窗口打开期间保持沙盒访问，同目录封面才能作为关联项读取
        if holdsSecurityAccess {
            accessingVideoURL = url
        } else if url.startAccessingSecurityScopedResource() {
            accessingVideoURL = url
        }
        // 创建安全范围书签，保证 app 重启后仍能访问原始文件
        self.videoBookmarkData = Self.makeSecurityScopedBookmark(for: url)
        self.imageURL = url
    }

    /// 停止当前媒体文件的安全范围访问授权。
    private func stopVideoAccess() {
        accessingVideoURL?.stopAccessingSecurityScopedResource()
        accessingVideoURL = nil
    }

    /// 从历史配置恢复视频文件的沙盒访问：优先解析安全范围书签重新授权；
    /// 书签缺失或失效时，进程内仍有授权（如拖入后未重启）则直接使用原始路径。
    /// 返回 (播放 URL, 应持久化的书签, 已持有授权的 URL)；无法访问时返回 nil。
    private static func restoreVideoAccess(config: WindowConfig, fallbackURL: URL) -> (url: URL, bookmark: Data?, accessedURL: URL?)? {
        if let bookmark = config.videoBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                let accessed = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) {
                    // 书签过期（如文件被移动）时按解析出的新位置重建并持久化
                    let newBookmark = isStale ? Self.makeSecurityScopedBookmark(for: url) : bookmark
                    return (url, newBookmark, accessed ? url : nil)
                }
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return (fallbackURL, Self.makeSecurityScopedBookmark(for: fallbackURL), nil)
    }

    /// UTType 对音视频的声明较宽（MKV/AVI 等也归为 movie），需再确认 macOS 原生可播放后才打开。
    /// - Parameter holdsSecurityAccess: 已对 `url` 取得安全范围访问；不可播放时由本方法释放，可播放时转交窗口持有。
    private func openExternalMediaIfPlayable(url: URL, holdsSecurityAccess: Bool = false) {
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard isPlayable, let self else {
                if holdsSecurityAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            self.openExternalMedia(url: url, holdsSecurityAccess: holdsSecurityAccess)
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
        if Self.isExternalMediaFile(url: url) {
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
        } else if Self.isExternalMediaFile(url: url) {
            let accessed = url.startAccessingSecurityScopedResource()
            openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
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

    private func isCurrentDrop(_ generation: UInt64) -> Bool {
        generation == currentDropGeneration
    }

    public func handleDrop(providers: [NSItemProvider], completion: @escaping (Bool) -> Void = { _ in }) {
        NSLog("handleDrop started for \(providers.count) providers")
        for (index, p) in providers.enumerated() {
            NSLog("Provider [\(index)] types: \(p.registeredTypeIdentifiers), suggestedName: \(p.suggestedName ?? "nil")")
        }

        // 递增代次，后续所有异步回调需校验仍为当前代次，否则丢弃（防止并发覆盖与“打开以前的东西”）。
        currentDropGeneration &+= 1
        let generation = currentDropGeneration

        // 直接基于 providers 解析，不再读取全局 drag pasteboard，避免读取到过期/残留的粘贴板内容导致误打开旧数据。
        tryLoadProviders(providers, index: 0, generation: generation, completion: { [weak self] success in
            guard let self else {
                completion(false)
                return
            }
            // 若在处理期间已发生更新的拖拽，本次结果视为过期。
            guard self.isCurrentDrop(generation) else {
                NSLog("handleDrop completion discarded due to newer drop (generation \(generation) vs \(self.currentDropGeneration))")
                completion(false)
                return
            }
            completion(success)
        })
    }

    private func tryLoadProviders(_ providers: [NSItemProvider], index: Int, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        guard index < providers.count else {
            completion(false)
            return
        }

        self.tryLoadProvider(providers[index], generation: generation) { [weak self] success in
            guard let self else {
                completion(false)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(false)
                return
            }
            if success {
                completion(true)
            } else {
                self.tryLoadProviders(providers, index: index + 1, generation: generation, completion: completion)
            }
        }
    }

    private func tryLoadProvider(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        // 1. 尝试以 URL 载入（包括 fileURL 与 http(s) URL）
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }

                if let error {
                    NSLog("loadObject URL failed for provider: \(error.localizedDescription)")
                }

                if let droppedURL = url, self.isSupportedDroppedURL(droppedURL) {
                    NSLog("Successfully loaded supported URL: \(droppedURL.absoluteString)")
                    self.openDroppedURL(droppedURL, generation: generation) { success in
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        if success {
                            completion(true)
                        } else {
                            // URL 处理失败，尝试加载为 Image / Fallback
                            self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
                        }
                    }
                } else if let droppedURL = url, droppedURL.isFileURL {
                    // 文件类型不受支持时，不能回退读取其 Finder 图标。
                    completion(false)
                } else {
                    // 没有得到 URL，或者 URL 不受支持，尝试加载为 Image / Fallback
                    self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
                }
            }
        } else {
            // 不能作为 URL 载入，尝试加载为 Image / Fallback
            self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
        }
    }

    private func tryLoadProviderAsImage(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if let error {
                    NSLog("loadObject NSImage failed for provider: \(error.localizedDescription)")
                }
                if let nsImage = image as? NSImage {
                    NSLog("Successfully loaded NSImage object from provider")
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        self.openImage(image: nsImage, originalName: provider.suggestedName)
                        completion(true)
                    }
                } else {
                    self.tryLoadProviderAsImageData(provider, generation: generation, completion: completion)
                }
            }
        } else {
            self.tryLoadProviderAsImageData(provider, generation: generation, completion: completion)
        }
    }

    private func tryLoadProviderAsImageData(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        let imageIdentifiers = provider.registeredTypeIdentifiers.filter { ident in
            if let utType = UTType(ident) {
                return utType.conforms(to: .image)
            }
            return false
        }

        if !imageIdentifiers.isEmpty {
            NSLog("Found image identifiers in provider: \(imageIdentifiers)")
            self.tryLoadImageData(from: provider, with: imageIdentifiers, index: 0, generation: generation) { [weak self] image in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if let image {
                    NSLog("Successfully loaded NSImage from data representation")
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        self.openImage(image: image, originalName: provider.suggestedName)
                        completion(true)
                    }
                } else {
                    self.tryLoadProviderAsFallback(provider, generation: generation, completion: completion)
                }
            }
        } else {
            self.tryLoadProviderAsFallback(provider, generation: generation, completion: completion)
        }
    }

    private func tryLoadProviderAsFallback(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
    }

    private func tryLoadImageData(
        from provider: NSItemProvider,
        with identifiers: [String],
        index: Int,
        generation: UInt64,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard isCurrentDrop(generation) else {
            completion(nil)
            return
        }
        guard index < identifiers.count else {
            completion(nil)
            return
        }

        let typeId = identifiers[index]
        NSLog("Attempting to loadDataRepresentation for type: \(typeId)")

        provider.loadDataRepresentation(forTypeIdentifier: typeId) { [weak self] data, error in
            guard let self else {
                completion(nil)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            if let error {
                NSLog("Failed loadDataRepresentation for \(typeId): \(error.localizedDescription)")
            }
            if let data, let image = NSImage(data: data) {
                NSLog("Successfully loaded NSImage from type: \(typeId)")
                completion(image)
            } else {
                self.tryLoadImageFileRepresentation(from: provider, typeIdentifier: typeId, generation: generation) { image in
                    guard self.isCurrentDrop(generation) else {
                        completion(nil)
                        return
                    }
                    if let image {
                        completion(image)
                    } else {
                        self.tryLoadImageData(from: provider, with: identifiers, index: index + 1, generation: generation, completion: completion)
                    }
                }
            }
        }
    }

    private func tryLoadImageFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        generation: UInt64,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard isCurrentDrop(generation) else {
            completion(nil)
            return
        }
        NSLog("Attempting to loadFileRepresentation for type: \(typeIdentifier)")
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else {
                completion(nil)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            if let error {
                NSLog("Failed loadFileRepresentation for \(typeIdentifier): \(error.localizedDescription)")
            }

            guard let url else {
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
                self.loadDownloadedImage(from: url, generation: generation, completion: completion)
            }
        }
    }

    private func handleDropFallback(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        NSLog("handleDropFallback started")
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if let error {
                    NSLog("Failed to loadObject URL: \(error.localizedDescription)")
                }
                if let fileURL = url {
                    NSLog("Loaded URL: \(fileURL.absoluteString) (isFileURL: \(fileURL.isFileURL))")
                    self.openDroppedURL(fileURL, generation: generation, completion: completion)
                    return
                }
                self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
            }
        } else {
            NSLog("Provider cannot load URL, trying loadItem fallback")
            self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
        }
    }

    private func loadAsItemRepresentation(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        let identifiers = fallbackTypeIdentifiers(for: provider)
        NSLog("Attempting loadItem fallback for identifiers: \(identifiers)")

        tryLoadDroppedItem(from: provider, with: identifiers, index: 0, generation: generation) { [weak self] item in
            guard let self else {
                completion(false)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(false)
                return
            }

            switch item {
            case let .image(image, originalName):
                DispatchQueue.main.async {
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    self.openImage(image: image, originalName: originalName)
                    completion(true)
                }
            case let .url(url):
                self.openDroppedURL(url, generation: generation, completion: completion)
            case nil:
                NSLog("loadItem fallback failed, trying loadAsImage fallback")
                self.loadAsImage(provider: provider, generation: generation, completion: completion)
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
        generation: UInt64,
        completion: @escaping (DroppedItem?) -> Void
    ) {
        guard isCurrentDrop(generation) else {
            completion(nil)
            return
        }
        guard index < identifiers.count else {
            completion(nil)
            return
        }

        let typeIdentifier = identifiers[index]
        NSLog("Attempting loadItem for type: \(typeIdentifier)")
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else {
                completion(nil)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(nil)
                return
            }

            if let error {
                NSLog("Failed loadItem for \(typeIdentifier): \(error.localizedDescription)")
            }

            if let droppedItem = self.droppedItem(from: item, typeIdentifier: typeIdentifier, suggestedName: provider.suggestedName) {
                completion(droppedItem)
            } else {
                self.tryLoadDroppedItem(from: provider, with: identifiers, index: index + 1, generation: generation, completion: completion)
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

    private func openDroppedURL(_ url: URL, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        if url.isFileURL {
            // 拖拽文件可能为安全范围 URL，需临时获取访问授权；临时拷贝路径则无需授权亦可读取
            let canOpen: Bool = {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return canOpenFile(url: url)
            }()
            if canOpen {
                DispatchQueue.main.async {
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if Self.isExternalMediaFile(url: url) {
                        // 音视频异步验证可播性；保持安全范围访问直到打开完成或失败，以便读取同目录封面。
                        let accessed = url.startAccessingSecurityScopedResource()
                        self.openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
                    } else {
                        let accessed = url.startAccessingSecurityScopedResource()
                        self.openFile(url: url)
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    completion(true)
                }
            } else {
                completion(false)
            }
        } else {
            // 远程 URL：优先尝试作为图片下载，失败则回退为网页打开，避免“拖进去没反应”
            downloadImage(from: url, generation: generation, isHTMLFallbackAllowed: true) { [weak self] success in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if success {
                    completion(true)
                } else {
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        NSLog("Remote URL not decoded as image, opening as web: \(url.absoluteString)")
                        self.openWeb(url: url)
                        completion(true)
                    }
                }
            }
        }
    }

    private func loadAsImage(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if let error {
                    NSLog("Failed to loadObject NSImage: \(error.localizedDescription)")
                }
                guard let nsImage = image as? NSImage else {
                    completion(false)
                    return
                }
                DispatchQueue.main.async {
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    self.openImage(image: nsImage)
                    completion(true)
                }
            }
        } else {
            completion(false)
        }
    }

    private func downloadImage(from url: URL, generation: UInt64, isHTMLFallbackAllowed: Bool = true, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        NSLog("downloadImage started for \(url.absoluteString)")
        loadDownloadedImage(from: url, generation: generation) { [weak self] image in
            guard let self else {
                completion(false)
                return
            }
            guard self.isCurrentDrop(generation) else {
                completion(false)
                return
            }

            if let image {
                DispatchQueue.main.async {
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    self.openImage(image: image, originalName: url.lastPathComponent)
                    completion(true)
                }
                return
            }

            if isHTMLFallbackAllowed {
                self.downloadHTMLImageFallback(from: url, generation: generation, completion: completion)
            } else {
                NSLog("Failed to decode downloaded image data from \(url.absoluteString)")
                completion(false)
            }
        }
    }

    private func loadDownloadedImage(from url: URL, generation: UInt64, completion: @escaping (NSImage?) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, self.isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            if let error {
                NSLog("Failed to download image from \(url.absoluteString): \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data else {
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

    private func downloadHTMLImageFallback(from url: URL, generation: UInt64, completion: @escaping (Bool) -> Void) {
        guard isCurrentDrop(generation) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, self.isCurrentDrop(generation) else {
                completion(false)
                return
            }
            if let error {
                NSLog("Failed to download HTML fallback from \(url.absoluteString): \(error.localizedDescription)")
                completion(false)
                return
            }

            guard let data,
                  let htmlString = String(data: data, encoding: .utf8),
                  htmlString.range(of: "<html", options: .caseInsensitive) != nil else {
                completion(false)
                return
            }

            NSLog("Downloaded content is HTML. Attempting to extract og:image or twitter:image.")
            if let extractedURL = self.extractImageURL(from: htmlString) {
                NSLog("Extracted image URL: \(extractedURL.absoluteString). Retrying download.")
                self.downloadImage(from: extractedURL, generation: generation, isHTMLFallbackAllowed: false, completion: completion)
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
        self.isVideoLooping = true
        self.videoBookmarkData = nil
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
        stopVideoAccess()
    }

    private var renderTask: Task<Void, Never>?

    // 根据当前系统外观判断是否为暗色模式，需在主线程调用
    private static func isDarkMode() -> Bool {
        guard Thread.isMainThread else { return false }
        let appearance = NSApp.effectiveAppearance
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        // 兼容自定义外观名称
        return appearance.name.rawValue.lowercased().contains("dark")
    }

    /// 供视图层在系统明暗外观切换时主动触发重新渲染
    func refreshMarkdownRendering() {
        updateRenderedMarkdown()
    }

    private func updateRenderedMarkdown() {
        // 性能防御：如果当前不是预览模式或者不是 Markdown 文档，直接跳过 markdown 解析，保证打字零开销！
        guard isMarkdownPreview && isMarkdownDocument else { return }

        renderTask?.cancel()

        let textToRender = self.text
        let fontSize = self.textFontSize
        // 在主线程捕获当前外观，避免后台任务无法正确获取有效外观
        let isDark = Self.isDarkMode()

        renderTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let htmlBody = Self.cmarkToHTML(textToRender)
            if Task.isCancelled { return }

            // 根据当前明暗外观显式生成对应配色的 CSS，避免依赖 @media 查询导致 NSAttributedString 在后台解析时颜色固化
            let textColor = isDark ? "#ffffff" : "#000000"
            let borderColor = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.1)"
            let codeBg = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.06)"
            let preBg = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.04)"
            let blockquoteColor = isDark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.6)"
            let blockquoteBorder = isDark ? "rgba(255,255,255,0.25)" : "rgba(0,0,0,0.2)"
            let tableBorder = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)"
            let thBg = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.04)"
            let trEvenBg = isDark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.02)"

            // 构建包含 CSS 的完整 HTML，支持自适应系统明暗主题与字号大小缩放
            let htmlContent = """
            <html>
            <head>
            <style>
            body, p, li, blockquote {
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                font-size: \(fontSize)px;
                line-height: 1.8;
                color: \(textColor);
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
            h1 { font-size: 1.6em; border-bottom: 1px solid \(borderColor); padding-bottom: 0.3em; }
            h2 { font-size: 1.4em; border-bottom: 1px solid \(borderColor); padding-bottom: 0.3em; }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1.15em; }
            code {
                padding: 0.2em 0.4em;
                margin: 0;
                font-size: 85%;
                background-color: \(codeBg);
                border-radius: 6px;
                font-family: Menlo, Consolas, monospace;
            }
            pre {
                padding: 16px;
                overflow: auto;
                font-size: 85%;
                line-height: 1.45;
                background-color: \(preBg);
                border-radius: 6px;
            }
            pre code {
                background-color: transparent;
                padding: 0;
                border-radius: 0;
            }
            blockquote {
                padding: 0 1em;
                color: \(blockquoteColor);
                border-left: 0.25em solid \(blockquoteBorder);
                margin: 0 0 16px 0;
            }
            ul, ol {
                padding-left: 2em;
                margin-top: 0;
                margin-bottom: 16px;
            }
            table {
                width: 100%;
                border-collapse: collapse;
                margin: 16px 0;
                font-size: 0.9em;
                line-height: 1.5;
            }
            th, td {
                border: 1px solid \(tableBorder);
                padding: 6px 10px;
                text-align: left;
                vertical-align: top;
                word-break: break-word;
            }
            th {
                background-color: \(thBg);
                font-weight: 600;
            }
            tr:nth-child(even) td {
                background-color: \(trEvenBg);
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

    // MARK: - Markdown 表格支持（GFM）

    private enum MarkdownTableAlignment {
        case none
        case left
        case center
        case right
    }

    private enum MarkdownSegment {
        case text(String)
        case table(String)
    }

    public static func cmarkToHTML(_ text: String) -> String {
        // 若不含表格特征，直接走 cmark 原路径以保持原有性能与行为
        let segments = parseMarkdownSegmentsWithTables(text)
        // 仅有一段普通文本时，保持单次 cmark 调用
        if segments.count == 1, case .text(let md) = segments[0] {
            return cmarkHTML(md)
        }
        var html = ""
        for segment in segments {
            switch segment {
            case .text(let md):
                html += cmarkHTML(md)
            case .table(let tableHTML):
                html += tableHTML
            }
        }
        return html
    }

    /// 纯 cmark 调用（不含表格预处理），用于文本段与单元格 inline 渲染
    private static func cmarkHTML(_ markdown: String) -> String {
        // 空段直接返回，避免产生空 <p>
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard let cString = cmark_markdown_to_html(markdown, markdown.utf8.count, 0) else {
            return ""
        }
        let result = String(cString: cString)
        free(cString)
        return result
    }

    /// 将单元格内的 inline Markdown 转为 HTML 片段（去除外层 <p> 包裹）
    private static func inlineMarkdownToHTML(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let html = cmarkHTML(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        // cmark 会将行内内容包裹为 <p>...</p>，此处剥离以嵌入 <td>/<th>
        if html.hasPrefix("<p>") && html.hasSuffix("</p>") {
            var inner = String(html.dropFirst(3).dropLast(4))
            // 处理 cmark 可能输出的换行
            inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return inner
        }
        // 若为多段或特殊情况，去除首尾的 <p> 标签对
        if html.hasPrefix("<p>") {
            // 仅移除首个 <p> 与末尾的 </p>，保留中间内容
            if let rangeStart = html.range(of: "<p>"), let rangeEnd = html.range(of: "</p>", options: .backwards) {
                let inner = String(html[rangeStart.upperBound..<rangeEnd.lowerBound])
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return html
    }

    private static func escapeHTML(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }

    // 解析 Markdown 文本，将 GFM 表格块抽出为独立段，其余文本保持为普通段
    private static func parseMarkdownSegmentsWithTables(_ text: String) -> [MarkdownSegment] {
        // 快速路径：不含表格关键字符时无需扫描
        guard text.contains("|") else { return [.text(text)] }

        let lines = text.components(separatedBy: "\n")
        var segments: [MarkdownSegment] = []
        var textBuffer: [String] = []
        var inFencedCodeBlock = false
        var fenceChar: Character = "`"
        var fenceLength = 0

        func flushTextBuffer() {
            if !textBuffer.isEmpty {
                let md = textBuffer.joined(separator: "\n")
                segments.append(.text(md))
                textBuffer.removeAll()
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmedForFence = line.trimmingCharacters(in: .whitespaces)

            // 检测围栏代码块边界，避免将代码块内的 | 误判为表格
            if trimmedForFence.hasPrefix("```") || trimmedForFence.hasPrefix("~~~") {
                let fenceMarker: Character = trimmedForFence.first!
                let count = trimmedForFence.prefix(while: { $0 == fenceMarker }).count
                if !inFencedCodeBlock {
                    inFencedCodeBlock = true
                    fenceChar = fenceMarker
                    fenceLength = count
                } else if fenceMarker == fenceChar && count >= fenceLength {
                    inFencedCodeBlock = false
                }
                textBuffer.append(line)
                i += 1
                continue
            }

            if inFencedCodeBlock {
                textBuffer.append(line)
                i += 1
                continue
            }

            // 尝试识别表格：当前行 + 下一行为分隔行
            if i + 1 < lines.count, let alignments = parseTableDelimiterLine(lines[i + 1]) {
                // 分隔行有效，检查表头行是否像表格行（包含 |）
                if isPotentialTableRow(line) {
                    let headerCells = splitTableRow(line)
                    // 列数以分隔行为准，允许表头列数不一致但需至少 1 列
                    let columnCount = alignments.count
                    if columnCount > 0 {
                        // 收集后续正文行
                        var bodyRows: [[String]] = []
                        var j = i + 2
                        while j < lines.count {
                            let bodyLine = lines[j]
                            if bodyLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                            // 遇到围栏代码块开始则终止表格
                            let trimmedBody = bodyLine.trimmingCharacters(in: .whitespaces)
                            if trimmedBody.hasPrefix("```") || trimmedBody.hasPrefix("~~~") { break }
                            // 非表格行则终止
                            if !isPotentialTableRow(bodyLine) { break }
                            // 若再次出现分隔行样式的行，视为新表格或终止
                            if parseTableDelimiterLine(bodyLine) != nil { break }
                            let cells = splitTableRow(bodyLine)
                            bodyRows.append(cells)
                            j += 1
                        }
                        // 至少要有表头+分隔行即可成表；允许无正文行
                        flushTextBuffer()
                        let tableHTML = buildTableHTML(headerCells: headerCells, alignments: alignments, bodyRows: bodyRows, columnCount: columnCount)
                        segments.append(.table(tableHTML))
                        i = j
                        continue
                    }
                }
            }

            textBuffer.append(line)
            i += 1
        }

        flushTextBuffer()
        if segments.isEmpty { return [.text(text)] }
        return segments
    }

    private static func isPotentialTableRow(_ line: String) -> Bool {
        // 包含 | 且非空即视为潜在表格行
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return line.contains("|")
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // 移除首尾的管道符（GFM 允许省略）
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        // 处理转义的 \|，用占位符临时替换
        let placeholder = "\u{FFFD}PIPE\u{FFFD}"
        let escaped = trimmed.replacingOccurrences(of: "\\|", with: placeholder)
        let rawParts = escaped.components(separatedBy: "|")
        return rawParts.map { part in
            part.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseTableDelimiterLine(_ line: String) -> [MarkdownTableAlignment]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // 分隔行仅允许包含 | : - 及空格
        let allowed = CharacterSet(charactersIn: "|-: ").inverted
        if trimmed.rangeOfCharacter(from: allowed) != nil { return nil }

        let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for part in parts {
            if part.isEmpty { return nil }
            let hasLeftColon = part.hasPrefix(":")
            let hasRightColon = part.hasSuffix(":")
            var core = part
            if hasLeftColon { core.removeFirst() }
            if hasRightColon { core.removeLast() }
            if core.isEmpty { return nil }
            // 核心必须全为 -
            if core.contains(where: { $0 != "-" }) { return nil }
            // 至少一个 -
            if alignments.count == 0 && parts.count == 1 && core.count < 1 { return nil }
            if hasLeftColon && hasRightColon {
                alignments.append(.center)
            } else if hasLeftColon {
                alignments.append(.left)
            } else if hasRightColon {
                alignments.append(.right)
            } else {
                alignments.append(.none)
            }
        }
        return alignments
    }

    private static func buildTableHTML(headerCells: [String], alignments: [MarkdownTableAlignment], bodyRows: [[String]], columnCount: Int) -> String {
        func alignAttribute(_ align: MarkdownTableAlignment) -> String {
            switch align {
            case .left: return " align=\"left\""
            case .center: return " align=\"center\""
            case .right: return " align=\"right\""
            case .none: return ""
            }
        }

        func normalizedCells(_ cells: [String], count: Int) -> [String] {
            if cells.count == count { return cells }
            if cells.count > count { return Array(cells.prefix(count)) }
            // 列数不足时补空
            return cells + Array(repeating: "", count: count - cells.count)
        }

        let normalizedHeader = normalizedCells(headerCells, count: columnCount)
        var html = "<table>\n<thead>\n<tr>"
        for (idx, cell) in normalizedHeader.enumerated() {
            let align = idx < alignments.count ? alignments[idx] : .none
            let content = cell.isEmpty ? "" : inlineMarkdownToHTML(cell)
            // 空单元格保留 &nbsp; 以维持表格结构可见性，但此处保持空亦可
            html += "<th\(alignAttribute(align))>\(content)</th>"
        }
        html += "</tr>\n</thead>\n"
        if !bodyRows.isEmpty {
            html += "<tbody>\n"
            for row in bodyRows {
                let normalized = normalizedCells(row, count: columnCount)
                html += "<tr>"
                for (idx, cell) in normalized.enumerated() {
                    let align = idx < alignments.count ? alignments[idx] : .none
                    let content = cell.isEmpty ? "" : inlineMarkdownToHTML(cell)
                    html += "<td\(alignAttribute(align))>\(content)</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        html += "</table>\n"
        return html
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
    public static let createNewFlaminaFromImage = Notification.Name("createNewFlaminaFromImage")
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
    public static let shouldToggleVideoPlayback = Notification.Name("shouldToggleVideoPlayback")
}
