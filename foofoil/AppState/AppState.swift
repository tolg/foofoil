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
    /// 缓存当前解码图片，避免缩放重绘时反复从磁盘创建 NSImage。
    var loadedImageCache: (url: URL, image: NSImage)?
    var isBatchUpdating = false
    /// 递增的拖拽代次，用于丢弃过期异步回调，避免“打开以前的东西”或并发覆盖。
    var currentDropGeneration: UInt64 = 0
    /// 目录扫描令牌；新的拖放会主动终止仍在枚举的旧目录。
    var activeDirectoryDropScan: DroppedFileScanCancellation?

    @Published public var isCommandKeyPressed: Bool = false
    /// 由窗口内容区的 AppKit tracking area 驱动，供需要整窗 hover 的内容控件使用。
    @Published var isPointerInsideWindow: Bool = false
    /// 音视频控制条独立于整窗 hover。视频在鼠标静止超时后即使仍在窗口内也会隐藏；
    /// 音频由暂停状态与箔窗/目录 hover 推导显隐，不做静止超时。
    @Published var isMediaPlaybackControlsVisible: Bool = false
    /// 由窗口级 Finder 文件拖放接收器驱动，用于保留整窗拖放高亮反馈。
    @Published var isFileDropTargeted: Bool = false
    @Published public var isLoading: Bool = false
    /// 原生全屏只是一种瞬时展示状态，不写入窗口历史；退出后恢复原有边框偏好。
    @Published public var isFullScreen: Bool = false
    /// 仅用于路由网页编辑控件的键盘快捷键，不需要持久化。
    @Published public var isWebEditableElementFocused: Bool = false
    /// 扩展会话仅通过可序列化描述驱动宿主展示，不让扩展 View 穿过 ABI/XPC 边界。
    @Published var extensionSession: ContentSession? {
        didSet {
            let oldSessionID = oldValue?.id
            let newSessionID = extensionSession?.id
            guard oldSessionID != newSessionID else { return }
            let oldID = oldValue?.extensionID
            let newID = extensionSession?.extensionID
            if let oldValue { ExtensionHost.shared.closeSession(oldValue) }
            if let oldID { ExtensionHost.shared.releaseSession(extensionID: oldID) }
            if let newID { ExtensionHost.shared.retainSession(extensionID: newID) }
        }
    }
    @Published var extensionFallbackProviderID: String?
    var extensionStateReference: String?

    /// Built-in 与扩展统一投影到同一宿主导航模型；同一窗口只会有一个主内容来源。
    @Published var builtInNavigatorContributions: [NavigatorContribution] = []
    var navigatorContributions: [NavigatorContribution] {
        if !builtInNavigatorContributions.isEmpty { return builtInNavigatorContributions }
        return extensionSession?.navigatorContributions ?? []
    }
    var builtInNavigatorActionHandler: ((NavigatorAction) -> Void)?
    /// 内置同类型文件列表；仅当 items >= 2 时投影到导航面板。
    @Published var fileList: FileListState?
    var fileListRevision: UInt64 = 0
    /// 媒体总时长在后台读取；按列表项缓存以免每次刷新导航都重复打开文件。
    var navigatorMediaDurationBadges: [String: String] = [:]
    var navigatorMediaDurationLoadingIDs: Set<String> = []

    @Published var navigatorPanelSide: NavigatorPanelSide {
        didSet { saveState() }
    }
    @Published var navigatorPanelVisibilityMode: NavigatorPanelVisibilityMode {
        didSet { saveState() }
    }
    @Published var navigatorPanelWidth: Double {
        didSet {
            let clamped = NavigatorPanelMetrics.clampWidth(navigatorPanelWidth)
            if clamped != navigatorPanelWidth {
                navigatorPanelWidth = clamped
            } else if !isAdjustingNavigatorPanelWidth {
                saveState()
            }
        }
    }
    @Published var isNavigatorPanelExplicitlyVisible = false
    let navigatorHover = NavigatorHoverState()
    var isNavigatorPanelHovered: Bool {
        get { navigatorHover.isPanelHovered }
        set { navigatorHover.isPanelHovered = newValue }
    }
    var isNavigatorEdgeHovered: Bool {
        get { navigatorHover.isPointerInside }
        set { navigatorHover.isPointerInside = newValue }
    }
    @Published var activeNavigatorContributionID: String?
    @Published var expandedNavigatorItemIDs: Set<String> = []
    var isAdjustingNavigatorPanelWidth = false

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
            loadedImageCache = nil
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
    var imageListSlideshowWorkItem: DispatchWorkItem?

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
            guard showBorder != oldValue else { return }
            saveState()
            NotificationCenter.default.post(name: .showBorderDidChange, object: self)
        }
    }

    /// 全屏中不存在边框概念，但不修改用户在窗口态选择的 showBorder。
    public var effectiveShowBorder: Bool {
        showBorder && !isFullScreen
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

    /// 当前音视频是否正在播放；由媒体视图从播放控制器桥接，供导航面板显示“正在播放”图标状态。
    @Published public var isMediaPlaying = false

    /// 视频/音频播放模式；仅媒体模式生效，默认顺序循环。
    @Published public var mediaPlaybackMode: MediaPlaybackMode {
        didSet {
            saveState()
        }
    }

    /// 当前项播完后是否由播放器自己从头循环（单曲循环，或无列表时的顺序/随机循环）。
    var shouldLoopCurrentItem: Bool {
        mediaPlaybackMode.shouldLoopCurrentItem(hasPresentableFileList: fileList?.isPresentable == true)
    }

    func cycleMediaPlaybackMode() {
        mediaPlaybackMode = mediaPlaybackMode.cycled
    }

    /// 视频/音频原始文件的安全范围书签；沙盒授权仅随进程有效，靠它在 app 重启后恢复访问。
    public var videoBookmarkData: Data?
    /// 当前已通过书签持有访问授权的媒体 URL，切换内容或销毁时需停止访问。
    var accessingVideoURL: URL?
    /// 播放 CUE 曲目时保持对 CUE 文件的安全范围访问，以便读取同目录音频。
    var accessingCueURL: URL?
    var cueRelatedPresenter: CueRelatedFilePresenter?
    /// 音频同目录封面所在文件夹的安全范围书签；重启后恢复访问，保证封面无需再次授权即可显示。
    var mediaSidecarBookmarkData: Data?
    /// 当前持有访问授权的封面所在文件夹 URL，切换内容或销毁时需停止访问。
    var accessingSidecarDirectoryURL: URL?

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
        self.mediaPlaybackMode = config.mediaPlaybackMode
        self.extensionSession = nil
        self.extensionFallbackProviderID = nil
        self.extensionStateReference = config.extensionStateReference
        self.navigatorPanelSide = config.navigatorPanelSide
        self.navigatorPanelVisibilityMode = config.navigatorPanelVisibilityMode
        self.navigatorPanelWidth = NavigatorPanelMetrics.clampWidth(config.navigatorPanelWidth)
        self.fileList = nil
        self.fileListRevision = 0

        if let path = config.imagePath {
            let url = URL(fileURLWithPath: path)
            // 视频/音频经安全范围书签恢复沙盒访问（重启后路径直接不可达）
            if Self.isExternalMediaFileName(config.originalImageName ?? path) {
                if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                    self.accessingVideoURL = restored.accessedURL
                    self.videoBookmarkData = restored.bookmark
                    self.imageURL = restored.url
                    // 音频再恢复同目录封面文件夹的访问，保证封面在重启后仍可读取
                    if Self.isAudioFileName(config.originalImageName ?? path),
                       let sidecarBookmark = config.mediaSidecarBookmark,
                       let sidecar = Self.restoreSidecarCoverAccess(bookmark: sidecarBookmark) {
                        if sidecar.accessed { accessingSidecarDirectoryURL = sidecar.directory }
                        mediaSidecarBookmarkData = sidecar.refreshedBookmark ?? sidecarBookmark
                    }
                } else {
                    self.videoBookmarkData = nil
                    self.mediaSidecarBookmarkData = nil
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
        restoreExtensionSession(from: config)
        restoreFileList(from: config)
        // 在调用 saveState 时避免触发死循环；视频经书签恢复后可能重建了书签，也需要落盘
        if let path = config.imagePath, !FileManager.default.fileExists(atPath: path) {
            if Self.findCachedImageInDirectory(for: config.id) != nil || Self.findLegacyCachedImageInDirectory() != nil {
                saveState()
            }
        }
        if Self.isExternalMediaFileName(config.originalImageName ?? ""),
           videoBookmarkData != config.videoBookmark || mediaSidecarBookmarkData != config.mediaSidecarBookmark {
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
        self.mediaPlaybackMode = .sequentialLoop
        self.extensionSession = nil
        self.extensionFallbackProviderID = nil
        self.extensionStateReference = nil
        self.navigatorPanelSide = SettingsStore.shared.navigatorPanelSide
        self.navigatorPanelVisibilityMode = SettingsStore.shared.navigatorPanelVisibilityMode
        self.navigatorPanelWidth = SettingsStore.shared.navigatorPanelWidth
        self.fileList = nil
        self.fileListRevision = 0
        super.init()
        updateRenderedMarkdown()
    }

    deinit {
        renderTask?.cancel()
        saveTask?.cancel()
        imageListSlideshowWorkItem?.cancel()
        stopVideoAccess()
        if let session = extensionSession {
            ExtensionHost.shared.closeSession(session)
            if let extensionID = session.extensionID {
                ExtensionHost.shared.releaseSession(extensionID: extensionID)
            }
        }
    }
}
