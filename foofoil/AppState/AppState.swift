//  AppState.swift
//  foofoil
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
    var sourceFingerprint: String?
    public var isInteractiveZooming: Bool = false
    var isBatchUpdating = false
    /// 递增的拖拽代次，用于丢弃过期异步回调，避免“打开以前的东西”或并发覆盖。
    var currentDropGeneration: UInt64 = 0

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

    var saveTask: Task<Void, Never>?

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
    var accessingVideoURL: URL?

    var renderTask: Task<Void, Never>?

    enum DroppedItem {
        case image(NSImage, originalName: String?)
        case url(URL)
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

    deinit {
        renderTask?.cancel()
        saveTask?.cancel()
        stopVideoAccess()
    }
}
