//
//  FloatingWindowController.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import Cocoa
import SwiftUI
import Combine
import AVFoundation
import QuartzCore

/// 根内容视图作为 AppKit 拖放目标，鼠标位于任意箔片内容上时都能取得 Finder 的完整文件批次。
final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    private let appState: AppState

    init(rootView: Content, appState: AppState) {
        self.appState = appState
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(from: sender) else { return [] }
        appState.isFileDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(from: sender) else { return [] }
        appState.isFileDropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        appState.isFileDropTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { appState.isFileDropTargeted = false }
        let urls = droppedFileURLs(from: sender)
        if !urls.isEmpty {
            return appState.handleDroppedFileURLs(urls)
        }

        let providers = droppedItemProviders(from: sender)
        guard !providers.isEmpty else { return false }
        appState.handleDrop(providers: providers)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        appState.isFileDropTargeted = false
    }

    private func droppedFileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
    }

    private func canAcceptDrop(from sender: any NSDraggingInfo) -> Bool {
        if !droppedFileURLs(from: sender).isEmpty { return true }
        return sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.URL.rawValue,
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue
        ])
    }

    /// 非文件内容仍转回既有 NSItemProvider 管线，保留网页 URL、文字和位图拖放能力。
    private func droppedItemProviders(from sender: any NSDraggingInfo) -> [NSItemProvider] {
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            let representations = item.types.compactMap { type -> (String, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
            guard !representations.isEmpty else { return nil }

            let provider = NSItemProvider()
            for (typeIdentifier, data) in representations {
                provider.registerDataRepresentation(
                    forTypeIdentifier: typeIdentifier,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
    }
}

/// 置顶切换的光晕环视图：圆角描边加柔光投影，透明度做一次脉冲后保持隐藏。
private final class PinGlowView: NSView {
    /// 光晕面板比箔窗四周扩出的距离；需容纳 ringOutset + 柔光半径，避免光晕被裁切。
    static let panelPadding: CGFloat = 26
    /// 光晕环相对箔窗外缘的外扩距离。
    static let ringOutset: CGFloat = 3
    private static let strokeWidth: CGFloat = 2.5
    private static let glowRadius: CGFloat = 14
    private static let flashAnimationKey = "pinGlowFlash"

    private let glowColor: NSColor

    init(frame frameRect: NSRect, color: NSColor, cornerRadius: CGFloat) {
        glowColor = color
        super.init(frame: frameRect)
        wantsLayer = true
        if let layer {
            layer.cornerRadius = cornerRadius
            layer.borderWidth = Self.strokeWidth
            layer.borderColor = glowColor.withAlphaComponent(0.85).cgColor
            layer.shadowColor = glowColor.cgColor
            layer.shadowOpacity = 0.85
            layer.shadowRadius = Self.glowRadius
            layer.shadowOffset = .zero
            layer.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            layer.opacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 透明度脉冲：快速亮起、短暂保持后淡出；结束后由控制器移除临时面板。
    func startFlash(duration: CFTimeInterval, completion: @escaping () -> Void) {
        guard let layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 1, 0]
        flash.keyTimes = [0, 0.15, 0.45, 1]
        flash.duration = duration
        flash.fillMode = .forwards
        flash.isRemovedOnCompletion = false
        layer.add(flash, forKey: Self.flashAnimationKey)
        CATransaction.commit()
    }
}

public class FloatingWindowController: NSWindowController, NSWindowDelegate {

    public let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var isRestoringFrame = false
    private var isLiveResizing = false
    private var pendingFrameSave: DispatchWorkItem?
    private var pendingZoomCommit: DispatchWorkItem?
    private var currentImageSize: NSSize? // 缓存当前加载的图片原始尺寸
    private var currentMediaSize: NSSize? // 缓存视频原始尺寸或音频封面/默认卡片尺寸
    private let borderedImageInset: CGFloat = 24
    private let zoomStep: Double = 1.1
    private let initialImageScreenLimit: CGFloat = 0.8
    private var isFirstImageURLChange = true
    private var isRestoringSavedImageFrame = false
    /// 正在恢复历史窗口框：跳过初始自适应，保留已保存的位置与大小。
    private var pendingSavedFrameRestore = false
    private var isFirstWebURLChange = true
    private var isRestoringSavedWebFrame = false
    private var pinchResizeInitialSize: NSSize?
    /// 图片捏合开始时的缩放，手势结束前相对此值计算。
    private var pinchImageBaseScale: Double?
    private var pdfResizeInitialSize: NSSize?
    private var pendingPDFFitWorkItem: DispatchWorkItem?
    private var currentPDFPageSize: NSSize?
    private let navigatorPanelController: NavigatorPanelController
    private var pendingNavigatorPanelHide: DispatchWorkItem?
    private var pendingNavigatorWidthCommit: DispatchWorkItem?
    private var pendingMediaPlaybackControlsHide: DispatchWorkItem?
    private var navigatorHoverLocalMonitor: Any?
    private var navigatorHoverGlobalMonitor: Any?
    private var isTransitioningFullScreen = false
    private var windowedFrameDescriptorBeforeFullScreen: String?
    /// 置顶切换光晕的临时面板；仅在做提示动画时存在。
    private var pinGlowPanel: NSPanel?
    /// 是否已收到过 isPinned 的首次发射，用于跳过订阅初始值。
    private var hasReceivedPinStateUpdate = false
    private static let pinGlowColor = NSColor.systemRed
    private static let unpinGlowColor = NSColor.systemGray
    private static let pinGlowFlashDuration: CFTimeInterval = 0.8

    public init(appState: AppState) {
        self.appState = appState
        self.navigatorPanelController = NavigatorPanelController(appState: appState)
        self.isRestoringSavedImageFrame = (appState.windowFrame != nil && appState.imageURL != nil)
        self.isRestoringSavedWebFrame = (appState.windowFrame != nil && appState.webURL != nil)
        self.pendingSavedFrameRestore = self.isRestoringSavedImageFrame

        // 初始大小默认 400x400，如果是网页模式则默认 512x512
        let width: CGFloat = appState.webURL != nil ? 512 : 400
        let height: CGFloat = appState.webURL != nil ? 512 : 400
        let defaultRect = NSRect(x: 200, y: 200, width: width, height: height)
        let window = FloatingWindow(contentRect: defaultRect, defer: false)

        super.init(window: window)

        window.delegate = self

        // 尝试恢复上次保存的窗口位置与大小
        if let savedFrame = appState.windowFrame {
            window.setFrame(from: savedFrame)
        } else {
            window.center()
        }

        // 装载 SwiftUI 视图
        let contentView = ContentView(appState: appState)
        let hostingView = FileDropHostingView(rootView: contentView, appState: appState)
        window.contentView = hostingView
        window.installResizeCursorTracking(in: hostingView)

        applyWindowSizeLimits()

        // 预先缓存可能已有的图片/视频/音频展示尺寸
        if let url = appState.imageURL {
            if appState.isExternalMediaDocument {
                fetchMediaPresentationSize(for: url) { [weak self] size in
                    guard let self, self.appState.imageURL == url else { return }
                    self.currentMediaSize = size
                }
            } else if let nsImage = appState.loadImage(from: url) {
                self.currentImageSize = AudioMetadataLoader.layoutSize(nsImage)
            }
        }

        // 绑定状态监听
        setupBindings()
        setupNavigatorPanelBindings()
        NotificationCenter.default.publisher(for: .imageListSlideshowIntervalDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.appState.scheduleImageListSlideshowAdvance()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .mediaPlaybackControlsAutoHideIntervalDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.appState.isMediaPlaybackControlsVisible else { return }
                // 音频控制条不做静止超时，隐藏延迟仅作用于视频。
                guard !self.appState.isAudioDocument else { return }
                self.scheduleMediaPlaybackControlsHide()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBindings() {
        guard let window = window else { return }

        // 监听图片变化以实时缓存图片/媒体原始尺寸
        appState.$imageURL
            .sink { [weak self] imageURL in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard let url = imageURL else {
                        self.hideMediaPlaybackControls()
                        self.currentImageSize = nil
                        self.currentMediaSize = nil
                        return
                    }
                    self.applyWindowSizeLimits()
                    if self.appState.isExternalMediaDocument {
                        self.currentImageSize = nil
                        self.revealMediaPlaybackControlsIfPointerIsInside()
                        self.fetchMediaPresentationSize(for: url) { size in
                            guard self.appState.imageURL == url else { return }
                            self.currentMediaSize = size
                        }
                    } else {
                        self.hideMediaPlaybackControls()
                        self.currentMediaSize = nil
                        if let image = self.appState.loadImage(from: url) {
                            self.currentImageSize = AudioMetadataLoader.layoutSize(image)
                        } else {
                            self.currentImageSize = nil
                        }
                    }
                    // 内容类型切换后同步音频控制条对目录面板全局监听的依赖。
                    self.updateNavigatorHoverMonitors()
                }
            }
            .store(in: &cancellables)

        // 音频暂停时常显控制条；恢复播放后按箔窗/目录 hover 推导显隐。视频显隐不随播放状态变化。
        appState.$isMediaPlaying
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAudioPlaybackControlsVisibility() }
            }
            .store(in: &cancellables)

        // 监听 Pin/Unpin 状态，更新窗口层级
        appState.$isPinned
            .sink { [weak self, weak window] isPinned in
                guard let self = self else { return }
                // @Published 在 willSet 同步发射，此刻读取批量更新标志可识别历史载入等程序性变更，恢复状态时不闪光晕。
                let isRestoringState = self.appState.isBatchUpdating
                let isFirstEmission = !self.hasReceivedPinStateUpdate
                self.hasReceivedPinStateUpdate = true
                DispatchQueue.main.async {
                    window?.level = self.appState.isFullScreen == true ? .normal : (isPinned ? .floating : .normal)
                    if let window { self.navigatorPanelController.synchronizeAppearance(with: window) }
                    // 仅用户主动切换置顶时在箔窗外缘闪一圈提示光晕
                    if !isFirstEmission, !isRestoringState {
                        self.flashPinGlow(pinned: isPinned)
                    }
                }
            }
            .store(in: &cancellables)

        // 监听透明度变化，更新窗口透明度
        appState.$opacity
            .sink { [weak self, weak window] opacity in
                DispatchQueue.main.async {
                    window?.alphaValue = CGFloat(opacity)
                    if let window { self?.navigatorPanelController.synchronizeAppearance(with: window) }
                }
            }
            .store(in: &cancellables)

        // 监听新图片/视频拖入或载入以进行一次自适应大小调整
        appState.$imageURL
            .sink { [weak self] imageURL in
                guard let self = self, let url = imageURL else { return }
                let isFirst = self.isFirstImageURLChange
                self.isFirstImageURLChange = false

                DispatchQueue.main.async {
                    if self.appState.isExternalMediaDocument {
                        self.fetchMediaPresentationSize(for: url) { size in
                            guard self.appState.imageURL == url, let size else { return }
                            self.applyMediaPresentationSize(size, animated: !isFirst)
                        }
                        return
                    }
                    // 恢复历史窗口框时不要按图片原始尺寸重算大小，但仍要按图片校正比例。
                    if self.isRestoringFrame || self.pendingSavedFrameRestore || (isFirst && self.isRestoringSavedImageFrame) {
                        if !self.isRestoringFrame {
                            self.pendingSavedFrameRestore = false
                            if let size = self.imageContentSize(at: url) {
                                self.restoreSavedMediaFrameIfNeeded(contentSize: size)
                            }
                        }
                        return
                    }
                    if let size = self.imageContentSize(at: url) {
                        if !isFirst, self.shouldPreserveImageListDisplayArea {
                            self.applyImageListSuccessorLayout(imageSize: size, animated: true)
                        } else {
                            self.initializeImageLayout(imageSize: size, animated: !isFirst)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 监听新网页载入以调整窗口大小为默认的 512*512
        appState.$webURL
            .sink { [weak self] webURL in
                guard let self = self, let _ = webURL else { return }
                let isFirst = self.isFirstWebURLChange
                self.isFirstWebURLChange = false

                DispatchQueue.main.async {
                    // 如果是正在从历史记录恢复窗口大小，或者是初次启动恢复保存的窗口大小，我们都不执行自适应大小调整，以保留关闭时的大小
                    if self.isRestoringFrame {
                        return
                    }
                    if isFirst && self.isRestoringSavedWebFrame {
                        return
                    }

                    // 新打开网页，将窗口调整为 512*512 默认大小
                    self.setWindowSize(NSSize(width: 512, height: 512), keepWidth: false, animated: !isFirst)
                }
            }
            .store(in: &cancellables)

        // 监听边框显示状态变化 (通过 didSet 后的通知进行同步更新，消除闪烁)
        NotificationCenter.default.publisher(for: .showBorderDidChange)
            .sink { [weak self] notification in
                guard let self = self,
                      let targetState = notification.object as? AppState,
                      targetState === self.appState,
                      self.isImageMode else { return }

                let showBorder = targetState.showBorder
                if showBorder {
                    self.window?.resizeIncrements = NSSize(width: 1.0, height: 1.0)
                }
                self.applyWindowSizeLimits()
                // 同步调整窗口大小，使窗口物理尺寸调整与 SwiftUI 视图的最新状态在同一 RunLoop 内同步渲染完成
                self.fitWindowToCurrentImageSize(showBorderOverride: showBorder, animated: false)
            }
            .store(in: &cancellables)

        // PDF 每页的尺寸可能不同；无边框时需与当前页同步调整窗口大小。
        NotificationCenter.default.publisher(for: .pdfPageSizeDidChange)
            .sink { [weak self] notification in
                guard let self = self,
                      let targetId = notification.userInfo?["id"] as? UUID,
                      targetId == self.appState.id,
                      let pageSize = notification.userInfo?["size"] as? NSSize else { return }

                self.currentPDFPageSize = pageSize
                self.currentImageSize = pageSize
                if !self.appState.showBorder {
                    self.fitWindowToCurrentImageSize(animated: false)
                }
            }
            .store(in: &cancellables)

        // 无边框 PDF 在缩放结束后，先将窗口比例校正为当前页比例，再缩放 PDF 填满窗口。
        NotificationCenter.default.publisher(for: .shouldMatchPDFWindowAspectRatio)
            .sink { [weak self] notification in
                guard let self = self,
                      let targetId = notification.userInfo?["id"] as? UUID,
                      targetId == self.appState.id,
                      let pageSize = notification.userInfo?["size"] as? NSSize else { return }

                self.matchPDFWindowAspectRatio(to: pageSize)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .shouldApplyPDFScaleToWindow,
                        object: nil,
                        userInfo: ["id": self.appState.id]
                    )
                }
            }
            .store(in: &cancellables)

        // 监听并处理窗口恢复 Frame 的通知
        NotificationCenter.default.publisher(for: .shouldRestoreFrame)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetId = notification.userInfo?["id"] as? UUID,
                   targetId == self.appState.id,
                   let frameString = notification.userInfo?["frame"] as? String {
                    self.isRestoringFrame = true
                    self.pendingSavedFrameRestore = true
                    DispatchQueue.main.async {
                        self.window?.setFrame(from: frameString)
                        // 在主线程下一个循环中重置标志位，确保只屏蔽本次因历史记录载入触发的 imageURL 自动大小调整
                        DispatchQueue.main.async {
                            self.isRestoringFrame = false
                            self.correctRestoredContentWindowAspect()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 监听双击“适合窗口宽度”的通知
        NotificationCenter.default.publisher(for: .shouldFitImageToWindowWidth)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetId = notification.userInfo?["id"] as? UUID,
                   targetId == self.appState.id {
                    DispatchQueue.main.async {
                        self.fitImageToWindowWidth(animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        // 监听双击“放大”的通知
        NotificationCenter.default.publisher(for: .shouldZoomIn)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetId = notification.userInfo?["id"] as? UUID,
                   targetId == self.appState.id {
                    DispatchQueue.main.async {
                        self.zoomIn()
                    }
                }
            }
            .store(in: &cancellables)

        // 监听关闭窗口的通知
        NotificationCenter.default.publisher(for: .shouldCloseWindow)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetId = notification.userInfo?["id"] as? UUID,
                   targetId == self.appState.id {
                    DispatchQueue.main.async {
                        self.close()
                    }
                }
            }
            .store(in: &cancellables)

        // 监听手势缩放调整窗口大小的通知
        NotificationCenter.default.publisher(for: .shouldFitWindowToImage)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetId = notification.userInfo?["id"] as? UUID,
                   targetId == self.appState.id {
                    let animated = notification.userInfo?["animated"] as? Bool ?? true
                    DispatchQueue.main.async {
                        self.fitWindowToCurrentImageSize(animated: animated)
                    }
                }
            }
            .store(in: &cancellables)

        // 笔记、Markdown 与网页模式的捏合只调整窗口尺寸，不改变内容缩放比例。
        NotificationCenter.default.publisher(for: .shouldResizeWindowWithPinch)
            .sink { [weak self] notification in
                guard let self = self,
                      let targetId = notification.userInfo?["id"] as? UUID,
                      targetId == self.appState.id,
                      let magnification = notification.userInfo?["magnification"] as? CGFloat else { return }

                self.resizeWindowForPinch(magnification: magnification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .shouldEndWindowPinchResize)
            .sink { [weak self] notification in
                guard let self = self,
                      let targetId = notification.userInfo?["id"] as? UUID,
                      targetId == self.appState.id else { return }

                self.pinchResizeInitialSize = nil
                self.commitInteractiveZoom()
            }
            .store(in: &cancellables)

        // 监听重置窗口大小的通知
        NotificationCenter.default.publisher(for: .shouldResetWindowFrame)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetState = notification.object as? AppState,
                   targetState === self.appState {
                    DispatchQueue.main.async {
                        let defaultSize = self.appState.webURL != nil ? NSSize(width: 512, height: 512) : NSSize(width: 400, height: 400)
                        self.setWindowSize(defaultSize, keepWidth: false, animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        // 监听即将重置内容通知，保存当前窗口 frame 并同步持久化
        NotificationCenter.default.publisher(for: .willResetContent)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let targetState = notification.object as? AppState,
                   targetState === self.appState {
                    self.pendingFrameSave?.cancel()
                    if self.appState.isFullScreen || self.isTransitioningFullScreen {
                        self.appState.windowFrame = self.windowedFrameDescriptorBeforeFullScreen
                            ?? self.appState.windowFrame
                    } else if let window = self.window {
                        self.appState.windowFrame = window.frameDescriptor
                    }
                    self.appState.saveState()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .mediaPlaybackDidFinish)
            .sink { [weak self] notification in
                guard let self,
                      let id = notification.userInfo?["id"] as? UUID,
                      id == self.appState.id else { return }
                self.appState.advanceFileListAfterPlayback()
            }
            .store(in: &cancellables)
    }

    /// 置顶切换的瞬时反馈：在箔窗外缘闪一圈光晕（开启红色，关闭灰色），动画结束后自动移除。
    private func flashPinGlow(pinned: Bool) {
        guard let window, window.isVisible else { return }
        // 快速连续切换时先撤掉上一轮光晕，避免叠加闪烁
        removePinGlowPanel()

        let padding = PinGlowView.panelPadding
        let panelFrame = window.frame.insetBy(dx: -padding, dy: -padding)
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 光晕纯为视觉提示：不拦截鼠标、不抢焦点，层级跟随箔窗。
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = window.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.wantsLayer = true
        // 光晕环贴在箔窗外缘 ringOutset 处，圆角与 ContentView 的窗口圆角规则保持一致。
        let ringRect = container.bounds.insetBy(
            dx: padding - PinGlowView.ringOutset,
            dy: padding - PinGlowView.ringOutset
        )
        let glowView = PinGlowView(
            frame: ringRect,
            color: pinned ? Self.pinGlowColor : Self.unpinGlowColor,
            cornerRadius: pinGlowWindowCornerRadius + PinGlowView.ringOutset
        )
        container.addSubview(glowView)
        panel.contentView = container

        window.addChildWindow(panel, ordered: .below)
        panel.orderFrontRegardless()
        pinGlowPanel = panel

        glowView.startFlash(duration: Self.pinGlowFlashDuration) { [weak self] in
            guard let self, self.pinGlowPanel === panel else { return }
            self.removePinGlowPanel()
        }
    }

    private func removePinGlowPanel() {
        guard let panel = pinGlowPanel else { return }
        pinGlowPanel = nil
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// 与 ContentView 的圆角规则保持一致：全屏或隐藏边框时窗口内容无圆角。
    private var pinGlowWindowCornerRadius: CGFloat {
        let hidesBorder = appState.isFullScreen
            || ((appState.imageURL != nil || appState.webURL != nil) && !appState.showBorder)
        return hidesBorder ? 0 : 12
    }

    private func setupNavigatorPanelBindings() {
        appState.$extensionSession
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.$builtInNavigatorContributions
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.$fileList
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.$navigatorPanelVisibilityMode
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.$isNavigatorPanelExplicitlyVisible
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.navigatorHover.$isPanelHovered
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.navigatorHover.$isPointerInside
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigatorPanelVisibility() }
            }
            .store(in: &cancellables)

        appState.$navigatorPanelSide
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let window = self.window else { return }
                    self.navigatorPanelController.updateFrame(relativeTo: window)
                }
            }
            .store(in: &cancellables)

        appState.$navigatorPanelWidth
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let window = self.window else { return }
                    self.navigatorPanelController.updateFrame(relativeTo: window)
                }
            }
            .store(in: &cancellables)

        updateNavigatorPanelVisibility()
    }

    private var shouldShowNavigatorPanel: Bool {
        guard !appState.navigatorContributions.isEmpty else { return false }
        if appState.navigatorPanelVisibilityMode == .always { return true }
        return appState.isNavigatorPanelExplicitlyVisible
            || appState.isNavigatorPanelHovered
            || appState.isNavigatorEdgeHovered
    }

    /// 全屏覆盖层下，指针落在导航栏区域内时 ⌘+滚轮改宽度而不是缩放箔片。
    func shouldCommandScrollResizeNavigator(at pointInWindow: NSPoint) -> Bool {
        guard appState.isFullScreen,
              !appState.navigatorContributions.isEmpty,
              let window,
              shouldShowNavigatorPanel else { return false }
        let width = CGFloat(NavigatorPanelMetrics.clampWidth(appState.navigatorPanelWidth))
        let overlay: NSRect
        switch appState.navigatorPanelSide {
        case .left:
            overlay = NSRect(x: 0, y: 0, width: width, height: window.frame.height)
        case .right:
            overlay = NSRect(x: window.frame.width - width, y: 0, width: width, height: window.frame.height)
        }
        return overlay.contains(pointInWindow)
    }

    func handleNavigatorCommandScroll(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let next = NavigatorPanelMetrics.width(
            afterScroll: appState.navigatorPanelWidth,
            delta: Double(delta),
            precise: event.hasPreciseScrollingDeltas
        )
        guard next != appState.navigatorPanelWidth else { return }
        appState.isAdjustingNavigatorPanelWidth = true
        appState.navigatorPanelWidth = next
        pendingNavigatorWidthCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appState.isAdjustingNavigatorPanelWidth = false
            SettingsStore.shared.navigatorPanelWidth = self.appState.navigatorPanelWidth
            self.appState.saveState()
        }
        pendingNavigatorWidthCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func updateNavigatorPanelVisibility() {
        guard let window else { return }
        if appState.isFullScreen || isTransitioningFullScreen {
            pendingNavigatorPanelHide?.cancel()
            pendingNavigatorPanelHide = nil
            navigatorPanelController.hide()
            return
        }
        if shouldShowNavigatorPanel {
            pendingNavigatorPanelHide?.cancel()
            pendingNavigatorPanelHide = nil
            navigatorPanelController.show(attachedTo: window)
            updateNavigatorHoverMonitors()
            return
        }

        pendingNavigatorPanelHide?.cancel()
        if appState.navigatorContributions.isEmpty {
            navigatorPanelController.hide()
            updateNavigatorHoverMonitors()
            return
        }
        // 鼠标跨过主窗口与伴随面板之间的间隙时保留短暂宽限，避免 hover 闪烁。
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.shouldShowNavigatorPanel else { return }
            self.navigatorPanelController.hide()
            self.updateNavigatorHoverMonitors()
        }
        pendingNavigatorPanelHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NavigatorPanelMetrics.hoverHideDelay, execute: workItem)
    }

    func updateNavigatorEdgeHover(at point: NSPoint?) {
        // 子窗口上的导航面板不会让箔片收到 mouseExited；以屏幕坐标核对箔片 ∪ 面板。
        refreshNavigatorHoverFromPointer(windowPoint: point)
    }

    func refreshNavigatorHoverFromPointer(windowPoint: NSPoint? = nil, screenPoint: NSPoint? = nil) {
        refreshWindowHoverFromPointer(windowPoint: windowPoint, screenPoint: screenPoint)
        guard let window, !appState.navigatorContributions.isEmpty else {
            if appState.isNavigatorEdgeHovered || appState.isNavigatorPanelHovered {
                appState.isNavigatorEdgeHovered = false
                appState.isNavigatorPanelHovered = false
                updateNavigatorPanelVisibility()
            } else {
                updateNavigatorHoverMonitors()
            }
            return
        }

        let pointer = screenPoint ?? NSEvent.mouseLocation
        let inWindowEvent = windowPoint.map { point in
            point.x >= 0
                && point.y >= 0
                && point.x <= window.frame.width
                && point.y <= window.frame.height
        } ?? false
        var hoverRegion = window.frame
        if navigatorPanelController.isVisible, let panel = navigatorPanelController.window {
            hoverRegion = hoverRegion.union(panel.frame)
        }
        let inRegion = hoverRegion.contains(pointer)
        let inPanel = navigatorPanelController.isVisible
            && (navigatorPanelController.window?.frame.contains(pointer) ?? false)
        let inside = inWindowEvent || inRegion

        let wasInside = appState.isNavigatorEdgeHovered || appState.isNavigatorPanelHovered
        appState.isNavigatorEdgeHovered = inside
        appState.isNavigatorPanelHovered = inPanel
        if wasInside != inside {
            updateNavigatorPanelVisibility()
        } else {
            updateNavigatorHoverMonitors()
        }
        if appState.isAudioDocument {
            // 音频播放中从目录面板移出时没有箔窗事件可触发隐藏，由这里统一推导显隐。
            let resolvedScreenPoint = screenPoint
                ?? windowPoint.map { window.convertToScreen(NSRect(origin: $0, size: .zero)).origin }
            updateAudioPlaybackControlsVisibility(screenPoint: resolvedScreenPoint)
        }
    }

    /// SwiftUI 子视图增删会改变自身 tracking area；始终以窗口坐标判断，避免 hover 瞬时丢失。
    private func refreshWindowHoverFromPointer(windowPoint: NSPoint? = nil, screenPoint: NSPoint? = nil) {
        guard let window else {
            appState.isPointerInsideWindow = false
            return
        }
        let insideFromEvent = windowPoint.map {
            $0.x >= 0 && $0.y >= 0 && $0.x <= window.frame.width && $0.y <= window.frame.height
        } ?? false
        let inside = insideFromEvent || window.frame.contains(screenPoint ?? NSEvent.mouseLocation)
        let wasInside = appState.isPointerInsideWindow
        if wasInside != inside {
            appState.isPointerInsideWindow = inside
        }
        if inside {
            if !wasInside { revealMediaPlaybackControls() }
        } else if wasInside {
            handleMediaPointerExit(screenPoint: screenPoint)
        }
    }

    /// 只由真实指针输入调用；SwiftUI tracking area 重建产生的 entered/exited 不会让控制条自行复现。
    func handleMediaPointerActivity(at point: NSPoint, autoHideInterval: TimeInterval? = nil) {
        guard let window,
              appState.isExternalMediaDocument,
              point.x >= 0, point.y >= 0,
              point.x <= window.frame.width, point.y <= window.frame.height else { return }
        revealMediaPlaybackControls(autoHideInterval: autoHideInterval)
    }

    /// 离开窗口与窗口内静止采用同一延迟；重新进入前控制条仍平滑保留。
    /// 音频例外：显隐由播放状态与箔窗/目录 hover 区域推导，暂停或仍悬停在目录上时继续显示。
    func handleMediaPointerExit(autoHideInterval: TimeInterval? = nil, screenPoint: NSPoint? = nil) {
        guard appState.isExternalMediaDocument,
              appState.isMediaPlaybackControlsVisible else { return }
        if appState.isAudioDocument {
            updateAudioPlaybackControlsVisibility(screenPoint: screenPoint)
        } else {
            scheduleMediaPlaybackControlsHide(after: autoHideInterval)
        }
    }

    private func revealMediaPlaybackControlsIfPointerIsInside() {
        if appState.isAudioDocument {
            // 音频显隐与指针是否在箔窗内解耦（暂停时常显），统一交给状态推导。
            updateAudioPlaybackControlsVisibility()
            return
        }
        guard appState.isPointerInsideWindow else {
            hideMediaPlaybackControls()
            return
        }
        revealMediaPlaybackControls()
    }

    private func revealMediaPlaybackControls(autoHideInterval: TimeInterval? = nil) {
        guard appState.isExternalMediaDocument else {
            hideMediaPlaybackControls()
            return
        }
        appState.isMediaPlaybackControlsVisible = true
        if appState.isAudioDocument {
            // 音频：hover 期间持续显示，不做静止超时；显隐由播放状态与 hover 区域统一推导。
            pendingMediaPlaybackControlsHide?.cancel()
            pendingMediaPlaybackControlsHide = nil
        } else {
            scheduleMediaPlaybackControlsHide(after: autoHideInterval)
        }
    }

    private func scheduleMediaPlaybackControlsHide(after interval: TimeInterval? = nil) {
        pendingMediaPlaybackControlsHide?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appState.isMediaPlaybackControlsVisible = false
            self.pendingMediaPlaybackControlsHide = nil
        }
        pendingMediaPlaybackControlsHide = workItem
        let delay = interval ?? SettingsStore.shared.mediaPlaybackControlsAutoHideInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    private func hideMediaPlaybackControls() {
        pendingMediaPlaybackControlsHide?.cancel()
        pendingMediaPlaybackControlsHide = nil
        appState.isMediaPlaybackControlsVisible = false
    }

    /// 音频控制条显隐由状态推导：暂停时常显（无论指针在哪）；播放中仅当指针位于箔窗或目录面板上时显示，不做静止超时。
    private func updateAudioPlaybackControlsVisibility(screenPoint: NSPoint? = nil) {
        guard appState.isAudioDocument, appState.imageURL != nil else { return }
        pendingMediaPlaybackControlsHide?.cancel()
        pendingMediaPlaybackControlsHide = nil
        let shouldShow = !appState.isMediaPlaying || isPointerOverAudioHoverRegion(screenPoint: screenPoint)
        // 避免鼠标移动监听高频触发时对相同值重复发布导致内容整树重绘。
        if appState.isMediaPlaybackControlsVisible != shouldShow {
            appState.isMediaPlaybackControlsVisible = shouldShow
        }
    }

    /// 音频 hover 区域：箔窗与可见目录面板的屏幕并集。
    private func isPointerOverAudioHoverRegion(screenPoint: NSPoint? = nil) -> Bool {
        guard let window else { return false }
        var region = window.frame
        if navigatorPanelController.isVisible, let panel = navigatorPanelController.window {
            region = region.union(panel.frame)
        }
        return region.contains(screenPoint ?? NSEvent.mouseLocation)
    }

    private func updateNavigatorHoverMonitors() {
        // 音频播放时目录面板的进出不经过箔窗事件，需要全局监听维持控制条 hover 推导。
        let needsNavigatorHoverMonitor = !appState.navigatorContributions.isEmpty
            && appState.navigatorPanelVisibilityMode == .onHover
            && (navigatorPanelController.isVisible || appState.isFullScreen)
        let needsAudioHoverMonitor = appState.isAudioDocument && navigatorPanelController.isVisible
        let needsMonitor = !isTransitioningFullScreen && (needsNavigatorHoverMonitor || needsAudioHoverMonitor)
        if needsMonitor {
            if navigatorHoverLocalMonitor == nil {
                navigatorHoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                    self?.refreshNavigatorHoverFromPointer()
                    return event
                }
            }
            if navigatorHoverGlobalMonitor == nil {
                navigatorHoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                    self?.refreshNavigatorHoverFromPointer()
                }
            }
        } else {
            removeNavigatorHoverMonitors()
        }
    }

    private func removeNavigatorHoverMonitors() {
        if let navigatorHoverLocalMonitor {
            NSEvent.removeMonitor(navigatorHoverLocalMonitor)
            self.navigatorHoverLocalMonitor = nil
        }
        if let navigatorHoverGlobalMonitor {
            NSEvent.removeMonitor(navigatorHoverGlobalMonitor)
            self.navigatorHoverGlobalMonitor = nil
        }
    }

    func owns(_ candidate: NSWindow) -> Bool {
        window === candidate || navigatorPanelController.owns(candidate)
    }

    var isNavigatorPanelVisible: Bool {
        appState.isFullScreen ? shouldShowNavigatorPanel : navigatorPanelController.isVisible
    }

    /// 使用 AppKit 原生全屏 Space；每个箔片窗口独立切换，窗口态 frame 与边框偏好保持不变。
    public func toggleFullScreen() {
        guard let window, !isTransitioningFullScreen else { return }
        if !appState.isFullScreen {
            window.collectionBehavior = [.fullScreenPrimary]
            window.level = .normal
        }
        window.toggleFullScreen(nil)
    }

    public func zoomIn() {
        if appState.webURL != nil {
            appState.webZoom = AppState.clampWebZoom(appState.webZoom * zoomStep)
            return
        }
        zoomContent(by: zoomStep)
    }

    public func zoomOut() {
        if appState.webURL != nil {
            appState.webZoom = AppState.clampWebZoom(appState.webZoom / zoomStep)
            return
        }
        zoomContent(by: 1.0 / zoomStep)
    }

    public func zoomInWindow() {
        guard let window = window else { return }
        let factor: CGFloat = 1.1
        let currentSize = window.frame.size
        setWindowSize(
            NSSize(width: currentSize.width * factor, height: currentSize.height * factor),
            keepWidth: false,
            animated: true
        )
        scheduleWindowFrameSave()
    }

    public func zoomOutWindow() {
        guard let window = window else { return }
        let factor: CGFloat = 1.0 / 1.1
        let currentSize = window.frame.size
        setWindowSize(
            NSSize(width: currentSize.width * factor, height: currentSize.height * factor),
            keepWidth: false,
            animated: true
        )
        scheduleWindowFrameSave()
    }

    public func actualSize() {
        if isImageMode {
            appState.imageScale = 1.0
            if !appState.showBorder {
                fitWindowToCurrentImageSize(animated: true)
            }
        } else if appState.webURL != nil {
            appState.webZoom = 1.0
        } else {
            appState.textFontSize = AppState.defaultTextFontSize
        }
    }

    /// Cmd+滚轮缩放图片：过程中不写历史，停手后再落盘。
    func applyInteractiveImageZoom(factor: CGFloat) {
        pinchImageBaseScale = nil
        beginInteractiveZoom()
        appState.imageScale = AppState.clampImageScale(appState.imageScale * Double(factor))
        if !appState.showBorder {
            fitWindowToCurrentImageSize(animated: false)
        }
        scheduleInteractiveZoomCommit()
    }

    /// 触摸板捏合：magnification 相对手势起点，1 为开始时的大小。
    func applyInteractiveImageMagnification(_ magnification: CGFloat) {
        beginInteractiveZoom()
        if pinchImageBaseScale == nil {
            pinchImageBaseScale = appState.imageScale
        }
        appState.imageScale = AppState.clampImageScale((pinchImageBaseScale ?? 1) * Double(magnification))
        if !appState.showBorder {
            fitWindowToCurrentImageSize(animated: false)
        }
        scheduleInteractiveZoomCommit()
    }

    func finishInteractiveImageMagnification() {
        pinchImageBaseScale = nil
        commitInteractiveZoom()
    }

    private func beginInteractiveZoom() {
        appState.isInteractiveZooming = true
    }

    func commitInteractiveZoom() {
        pendingZoomCommit?.cancel()
        pendingZoomCommit = nil
        pinchImageBaseScale = nil
        appState.isInteractiveZooming = false
        if appState.isFullScreen || isTransitioningFullScreen {
            appState.windowFrame = windowedFrameDescriptorBeforeFullScreen ?? appState.windowFrame
        } else if let window = window {
            appState.windowFrame = window.frameDescriptor
        }
        appState.saveState()
    }

    func scheduleInteractiveZoomCommit() {
        pendingZoomCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.commitInteractiveZoom()
        }
        pendingZoomCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    public func fitWindowToCurrentImageSize(showBorderOverride: Bool? = nil, animated: Bool = true) {
        guard let contentSize = currentContentSize() else { return }
        let displaySize = displaySize(for: contentSize, scale: appState.imageScale)
        let showBorder = showBorderOverride ?? appState.showBorder
        let inset = showBorder ? borderedImageInset : 0
        setWindowSize(
            NSSize(width: displaySize.width + inset, height: displaySize.height + inset),
            keepWidth: false,
            animated: animated,
            showBorderOverride: showBorder
        )
    }

    public func fitImageToWindowWidth(animated: Bool = true) {
        guard let window = window, let contentSize = currentContentSize(), contentSize.width > 0 else { return }
        let inset = appState.showBorder ? borderedImageInset : 0
        let availableImageWidth = max(1, window.frame.width - inset)
        appState.imageScale = Double(availableImageWidth / contentSize.width)

        let displayHeight = contentSize.height * CGFloat(appState.imageScale)
        setWindowSize(
            NSSize(width: window.frame.width, height: displayHeight + inset),
            keepWidth: true,
            animated: animated
        )
    }

    private func zoomContent(by factor: Double) {
        if currentContentSize() != nil {
            appState.imageScale = AppState.clampImageScale(appState.imageScale * factor)
            if currentContentSize() != nil && !appState.showBorder {
                fitWindowToCurrentImageSize(animated: true)
            }
        } else if factor > 1.0 {
            appState.increaseTextFontSize()
        } else {
            appState.decreaseTextFontSize()
        }
    }

    private func currentImage() -> NSImage? {
        guard let url = appState.imageURL else { return nil }
        return appState.loadImage(from: url)
    }

    private func currentContentSize() -> NSSize? {
        if appState.isPDFDocument, let currentPDFPageSize {
            return currentPDFPageSize
        }
        if appState.isExternalMediaDocument {
            return currentMediaSize
        }
        if let cached = currentImageSize, cached.width > 0, cached.height > 0 {
            return cached
        }
        guard let image = currentImage() else { return nil }
        return AudioMetadataLoader.layoutSize(image)
    }

    private func imageContentSize(at url: URL) -> NSSize? {
        guard let image = appState.loadImage(from: url),
              let size = AudioMetadataLoader.layoutSize(image),
              size.width > 0, size.height > 0 else { return nil }
        currentImageSize = size
        return size
    }

    /// 异步读取媒体展示尺寸：视频用画面尺寸，音频用封面或默认卡片尺寸。
    private func fetchMediaPresentationSize(for url: URL, completion: @escaping (NSSize?) -> Void) {
        if appState.isAudioDocument {
            Task {
                let info = await AudioMetadataLoader.load(from: url)
                let size = AudioMetadataLoader.presentationSize(for: info)
                await MainActor.run { completion(size) }
            }
            return
        }

        let asset = AVURLAsset(url: url)
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize) else {
                await MainActor.run { completion(nil) }
                return
            }
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = naturalSize.applying(transform)
            let size = NSSize(width: abs(transformed.width), height: abs(transformed.height))
            await MainActor.run { completion(size) }
        }
    }

    private func displaySize(for imageSize: NSSize, scale: Double) -> NSSize {
        NSSize(
            width: imageSize.width * CGFloat(scale),
            height: imageSize.height * CGFloat(scale)
        )
    }

    private func initializeImageLayout(imageSize: NSSize, animated: Bool = true) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let inset = appState.showBorder ? borderedImageInset : 0
        let (targetWindowSize, imageScale) = initialImageWindowSize(imageSize: imageSize, inset: inset)
        appState.imageScale = Double(imageScale)
        setWindowSize(targetWindowSize, keepWidth: false, animated: animated)
    }

    private var shouldPreserveImageListDisplayArea: Bool {
        appState.fileList?.isPresentable == true
            && appState.fileList?.kind == .image
            && !appState.isExternalMediaDocument
            && !appState.isPDFDocument
    }

    /// 列表内切图：保持上一张的显示面积，并贴导航栏所在侧垂直居中。
    private func applyImageListSuccessorLayout(imageSize: NSSize, animated: Bool) {
        guard let window = window, imageSize.width > 0, imageSize.height > 0 else {
            initializeImageLayout(imageSize: imageSize, animated: animated)
            return
        }
        let inset = appState.showBorder ? borderedImageInset : 0
        let currentFrame = window.frame
        let previousDisplay = NSSize(
            width: max(1, currentFrame.width - inset),
            height: max(1, currentFrame.height - inset)
        )
        let nextDisplay = Self.sizeMatchingContentArea(previous: previousDisplay, content: imageSize)
        appState.imageScale = AppState.clampImageScale(Double(nextDisplay.width / imageSize.width))
        let displaySize = displaySize(for: imageSize, scale: appState.imageScale)
        let alignment: WindowSizeAlignment = appState.navigatorPanelSide == .left ? .leading : .trailing
        setWindowSize(
            NSSize(width: displaySize.width + inset, height: displaySize.height + inset),
            keepWidth: false,
            animated: animated,
            alignment: alignment,
            animationDuration: ImageListSlideshow.transitionDuration
        )
    }

    /// 下一张图按自身比例缩放，使显示面积与上一张相同。
    static func sizeMatchingContentArea(previous: NSSize, content: NSSize) -> NSSize {
        guard previous.width > 0, previous.height > 0, content.width > 0, content.height > 0 else {
            return previous
        }
        let area = previous.width * previous.height
        let ratio = content.width / content.height
        return NSSize(width: sqrt(area * ratio), height: sqrt(area / ratio))
    }

    private func initialImageWindowSize(imageSize: NSSize, inset: CGFloat) -> (size: NSSize, scale: CGFloat) {
        var maximumContentWidth = imageSize.width
        var maximumContentHeight = imageSize.height
        if let screenFrame = (window?.screen ?? NSScreen.main)?.visibleFrame {
            maximumContentWidth = max(1, screenFrame.width * initialImageScreenLimit - inset)
            maximumContentHeight = max(1, screenFrame.height * initialImageScreenLimit - inset)
        }
        if appState.isAudioDocument {
            let audioContentMax = max(1, AudioTrackInfo.initialWindowMaxLength - inset)
            maximumContentWidth = min(maximumContentWidth, audioContentMax)
            maximumContentHeight = min(maximumContentHeight, audioContentMax)
        }
        let scale = min(1, maximumContentWidth / imageSize.width, maximumContentHeight / imageSize.height)

        return (
            NSSize(width: imageSize.width * scale + inset, height: imageSize.height * scale + inset),
            scale
        )
    }

    enum WindowSizeAlignment {
        case center
        /// 保持左缘，垂直居中。
        case leading
        /// 保持右缘，垂直居中。
        case trailing
    }

    func setWindowSize(
        _ size: NSSize,
        keepWidth: Bool,
        animated: Bool,
        showBorderOverride: Bool? = nil,
        alignment: WindowSizeAlignment = .center,
        animationDuration: TimeInterval? = nil
    ) {
        guard let window = window else { return }
        guard !appState.isFullScreen, !isTransitioningFullScreen else { return }
        var newWidth = size.width
        var newHeight = size.height
        let minSize = minimumWindowSize(showBorderOverride: showBorderOverride)
        let maxSize: NSSize? = window.screen.map {
            NSSize(width: $0.visibleFrame.width * 0.85, height: $0.visibleFrame.height * 0.85)
        }
        let clamped = clampedSizePreservingAspect(
            NSSize(width: newWidth, height: newHeight),
            minSize: minSize,
            maxSize: maxSize
        )
        newWidth = clamped.width
        newHeight = clamped.height

        let currentFrame = window.frame
        if keepWidth {
            newWidth = currentFrame.width
        }

        let newFrame = Self.alignedFrame(
            current: currentFrame,
            size: NSSize(width: newWidth, height: newHeight),
            alignment: alignment
        )

        if animated, let animationDuration {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true, animate: animated)
        }
    }

    /// 按对齐方式计算新窗口框：列表切图时贴导航栏一侧，其余缩放仍绕中心。
    static func alignedFrame(current: NSRect, size: NSSize, alignment: WindowSizeAlignment) -> NSRect {
        let origin: NSPoint
        switch alignment {
        case .center:
            origin = NSPoint(
                x: current.midX - size.width / 2,
                y: current.midY - size.height / 2
            )
        case .leading:
            origin = NSPoint(
                x: current.minX,
                y: current.midY - size.height / 2
            )
        case .trailing:
            origin = NSPoint(
                x: current.maxX - size.width,
                y: current.midY - size.height / 2
            )
        }
        return NSRect(origin: origin, size: size)
    }

    func resizeWindowForPinch(magnification: CGFloat) {
        guard appState.imageURL == nil || appState.isExternalMediaDocument || appState.webURL != nil, let window = window else { return }

        if pinchResizeInitialSize == nil {
            pinchResizeInitialSize = window.frame.size
        }
        guard let initialSize = pinchResizeInitialSize else { return }

        setWindowSize(
            NSSize(width: initialSize.width * magnification, height: initialSize.height * magnification),
            keepWidth: false,
            animated: false
        )
    }

    /// 无边框 PDF 缩放时先改变窗口，避免 PDF 内容缩放与窗口尺寸调整互相竞争。
    func resizePDFWindowForMagnification(_ magnification: CGFloat) {
        guard let window = window else { return }
        if pdfResizeInitialSize == nil {
            pdfResizeInitialSize = window.frame.size
        }
        guard let initialSize = pdfResizeInitialSize else { return }
        setWindowSize(
            NSSize(width: initialSize.width * magnification, height: initialSize.height * magnification),
            keepWidth: false,
            animated: false
        )
    }

    func resizePDFWindowForScroll(factor: CGFloat) {
        guard let window = window else { return }
        let currentSize = window.frame.size
        setWindowSize(
            NSSize(width: currentSize.width * factor, height: currentSize.height * factor),
            keepWidth: false,
            animated: false
        )
        schedulePDFFitToWindow()
    }

    func finishPDFWindowResize() {
        pdfResizeInitialSize = nil
        schedulePDFFitToWindow()
    }

    private func schedulePDFFitToWindow() {
        pendingPDFFitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(
                name: .shouldFitPDFToWindow,
                object: nil,
                userInfo: ["id": self.appState.id]
            )
            self.scheduleWindowFrameSave()
        }
        pendingPDFFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func matchPDFWindowAspectRatio(to pageSize: NSSize) {
        guard let window = window,
              pageSize.width > 0,
              pageSize.height > 0 else { return }

        let pageAspectRatio = pageSize.width / pageSize.height
        let currentSize = window.frame.size
        let sizeKeepingWidth = NSSize(
            width: currentSize.width,
            height: currentSize.width / pageAspectRatio
        )
        let sizeKeepingHeight = NSSize(
            width: currentSize.height * pageAspectRatio,
            height: currentSize.height
        )
        let targetSize = abs(sizeKeepingWidth.height - currentSize.height)
            <= abs(sizeKeepingHeight.width - currentSize.width)
            ? sizeKeepingWidth
            : sizeKeepingHeight

        guard abs(currentSize.width / currentSize.height - pageAspectRatio) > 0.001 else { return }

        var fittedSize = targetSize
        if let screen = window.screen {
            let maximumSize = NSSize(width: screen.visibleFrame.width * 0.85, height: screen.visibleFrame.height * 0.85)
            let scale = min(1, maximumSize.width / fittedSize.width, maximumSize.height / fittedSize.height)
            fittedSize = NSSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
        }
        setWindowSize(fittedSize, keepWidth: false, animated: false)
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        let isCommandPressed = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        appState.isCommandKeyPressed = isCommandPressed
        updateNavigatorPanelVisibility()
    }

    public func windowDidResignKey(_ notification: Notification) {
        appState.isCommandKeyPressed = false
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window else { return }
        isTransitioningFullScreen = true
        pendingFrameSave?.cancel()
        windowedFrameDescriptorBeforeFullScreen = window.frameDescriptor
        appState.isFullScreen = true
        appState.isNavigatorPanelHovered = false
        appState.isNavigatorEdgeHovered = false
        navigatorPanelController.hide()
        removeNavigatorHoverMonitors()
        window.hasShadow = false
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = false
        appState.isFullScreen = true
        updateNavigatorPanelVisibility()
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = true
        pendingFrameSave?.cancel()
        appState.isNavigatorPanelHovered = false
        appState.isNavigatorEdgeHovered = false
        navigatorPanelController.hide()
        removeNavigatorHoverMonitors()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard let window else { return }
        isTransitioningFullScreen = false
        appState.isFullScreen = false
        window.hasShadow = true
        window.level = appState.isPinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let windowedFrameDescriptorBeforeFullScreen {
            appState.windowFrame = windowedFrameDescriptorBeforeFullScreen
        }
        self.windowedFrameDescriptorBeforeFullScreen = nil
        updateNavigatorPanelVisibility()
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isTransitioningFullScreen = false
        appState.isFullScreen = false
        window.hasShadow = true
        window.level = appState.isPinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        windowedFrameDescriptorBeforeFullScreen = nil
        updateNavigatorPanelVisibility()
    }

    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isTransitioningFullScreen = false
        appState.isFullScreen = true
        window.hasShadow = false
        navigatorPanelController.hide()
    }

    public func windowWillStartLiveResize(_ notification: Notification) {
        guard !appState.isFullScreen, !isTransitioningFullScreen else { return }
        isLiveResizing = true
        guard let window = window else { return }
        // 不要在 live resize 开始时把 aspectRatio 设为 .zero：无边框透明窗口自由拉伸会在
        // `_adjustNeedsDisplayRegionForNewFrame` 里因空脏区触发 AppKit 断言崩溃。
        if let ratioSize = constrainedContentAspectSize() {
            window.aspectRatio = ratioSize
        }
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !appState.isFullScreen, !isTransitioningFullScreen else { return frameSize }
        return constrainedLiveResizeSize(frameSize, sender: sender, referenceSize: sender.frame.size)
    }

    func beginManualLiveResize() {
        isLiveResizing = true
    }

    func constrainedManualResizeSize(_ frameSize: NSSize, from initialSize: NSSize) -> NSSize {
        guard let window else { return frameSize }
        return constrainedLiveResizeSize(frameSize, sender: window, referenceSize: initialSize)
    }

    func endManualLiveResize() {
        finishLiveResize()
    }

    private func constrainedLiveResizeSize(
        _ frameSize: NSSize,
        sender: NSWindow,
        referenceSize: NSSize
    ) -> NSSize {
        var size = sanitizedWindowSize(frameSize, fallback: sender.frame.size)
        let minSize = minimumWindowSize()
        let maxSize = sender.screen.map {
            NSSize(width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }

        // 用户拖拽且内容锁定比例时，按画面/封面改目标尺寸。
        if isLiveResizing, let ratioSize = constrainedContentAspectSize(), ratioSize.width > 0, ratioSize.height > 0 {
            let ratio = ratioSize.width / ratioSize.height
            let dw = abs(size.width - referenceSize.width)
            let dh = abs(size.height - referenceSize.height)
            if dw >= dh {
                size.height = size.width / ratio
            } else {
                size.width = size.height * ratio
            }
        }

        // 程序化 setFrame（恢复历史、按内容初始化）保持目标自身比例，避免分别夹紧宽高把图片拉扁。
        return clampedSizePreservingAspect(size, minSize: minSize, maxSize: maxSize)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        finishLiveResize()
    }

    private func finishLiveResize() {
        guard !appState.isFullScreen, !isTransitioningFullScreen else {
            isLiveResizing = false
            return
        }
        // 用户松开鼠标结束缩放时，通过重置 resizeIncrements 来解除宽高比锁定，为其余代码主动 setFrame 预留通路，根治死锁
        window?.resizeIncrements = NSSize(width: 1.0, height: 1.0)
        window?.aspectRatio = .zero
        if isImageMode, !appState.showBorder || appState.isAudioDocument, let window = window, let contentSize = currentContentSize(), contentSize.width > 0 {
            appState.imageScale = Double(window.frame.width / contentSize.width)
        }
        isLiveResizing = false
        scheduleWindowFrameSave()
    }

    public func windowDidMove(_ notification: Notification) {
        if !appState.isFullScreen, let window { navigatorPanelController.updateFrame(relativeTo: window) }
        autoSwapNavigatorSideIfNeeded()
        scheduleWindowFrameSave()
    }

    /// 一次超界自动换边是否已发生；面板重新完整可见后解除，允许下一次超界再换。
    private var hasAutoSwappedNavigatorSideForClip = false

    /// 拖动箔片把面板推出屏幕超过 1/3 且另一侧放得下时自动换边一次；
    /// 换边锁避免拖动过程中两侧来回跳。新侧经 navigatorPanelSide 的 didSet 持久化，
    /// 之后移回原位也不会自动切回。
    func autoSwapNavigatorSideIfNeeded() {
        guard !appState.isFullScreen,
              !isTransitioningFullScreen,
              navigatorPanelController.isVisible,
              let window,
              let panel = navigatorPanelController.window else { return }

        let panelFrame = panel.frame
        let screenVisibleFrames = NSScreen.screens.map(\.visibleFrame)
        let visibleWidth = screenVisibleFrames.reduce(CGFloat(0)) { $0 + panelFrame.intersection($1).width }
        if visibleWidth >= panelFrame.width {
            hasAutoSwappedNavigatorSideForClip = false
        }
        guard !hasAutoSwappedNavigatorSideForClip,
              let target = NavigatorPanelMetrics.autoSwapTargetSide(
                current: appState.navigatorPanelSide,
                panelFrame: panelFrame,
                windowFrame: window.frame,
                screenVisibleFrames: screenVisibleFrames
              ) else { return }

        hasAutoSwappedNavigatorSideForClip = true
        appState.navigatorPanelSide = target
        SettingsStore.shared.navigatorPanelSide = target
    }

    public func windowDidResize(_ notification: Notification) {
        if !appState.isFullScreen, let window { navigatorPanelController.updateFrame(relativeTo: window) }
        guard !isLiveResizing else { return }
        scheduleWindowFrameSave()
    }

    public func windowWillClose(_ notification: Notification) {
        pendingFrameSave?.cancel()
        pendingZoomCommit?.cancel()
        pendingNavigatorPanelHide?.cancel()
        pendingNavigatorWidthCommit?.cancel()
        pendingMediaPlaybackControlsHide?.cancel()
        removeNavigatorHoverMonitors()
        navigatorPanelController.detachAndClose()
        pinchImageBaseScale = nil
        if appState.isInteractiveZooming {
            appState.isInteractiveZooming = false
        }
        if appState.isFullScreen, let windowedFrameDescriptorBeforeFullScreen {
            appState.windowFrame = windowedFrameDescriptorBeforeFullScreen
        } else if let window = window {
            appState.windowFrame = window.frameDescriptor
        }
        appState.saveState()

        // 自动从 AppDelegate 的 windowControllers 列表中移除，避免内存泄漏
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func scheduleWindowFrameSave() {
        pendingFrameSave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.isLiveResizing,
                  !self.appState.isFullScreen,
                  !self.isTransitioningFullScreen,
                  let window = self.window else { return }
            self.appState.windowFrame = window.frameDescriptor
        }
        pendingFrameSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private var isImageMode: Bool {
        appState.imageURL != nil && appState.webURL == nil
    }

    /// 音频始终锁定封面/卡片比例；无边框图片与视频拖拽时同样整体等比缩放。
    private func constrainedContentAspectSize() -> NSSize? {
        if appState.isAudioDocument {
            if let contentSize = currentContentSize(), contentSize.width > 0, contentSize.height > 0 {
                return contentSize
            }
            // 封面尚未读到时，拖拽先按当前窗口比例锁住，避免再次自由拉扁。
            guard isLiveResizing else { return nil }
            let size = window?.frame.size ?? .zero
            return (size.width > 0 && size.height > 0) ? size : nil
        }
        guard isImageMode, !appState.showBorder, let contentSize = currentContentSize(),
              contentSize.width > 0, contentSize.height > 0 else {
            return nil
        }
        return contentSize
    }

    /// 把已读取的媒体尺寸套到当前窗口：恢复历史时保留已保存大小，新打开则按初始规则适配。
    private func applyMediaPresentationSize(_ size: NSSize, animated: Bool) {
        currentMediaSize = size
        guard !isLiveResizing else { return }
        if isRestoringFrame {
            return
        }
        if pendingSavedFrameRestore {
            pendingSavedFrameRestore = false
            restoreSavedMediaFrameIfNeeded(contentSize: size)
            return
        }
        initializeImageLayout(imageSize: size, animated: animated)
    }

    /// 历史窗口框已经 setFrame 之后，仅在比例明显不对时按已保存尺寸就近校正。
    private func correctRestoredContentWindowAspect() {
        if appState.isExternalMediaDocument {
            if let size = currentMediaSize {
                pendingSavedFrameRestore = false
                restoreSavedMediaFrameIfNeeded(contentSize: size)
            }
            return
        }
        guard isImageMode, !appState.isPDFDocument, let url = appState.imageURL,
              let size = imageContentSize(at: url) else { return }
        pendingSavedFrameRestore = false
        restoreSavedMediaFrameIfNeeded(contentSize: size)
    }

    /// 保留已保存窗口大小；仅当宽高比与画面/封面差得太多时，沿更接近的一边改比例。
    private func restoreSavedMediaFrameIfNeeded(contentSize: NSSize) {
        guard let window = window else { return }
        let currentSize = window.frame.size
        let targetSize = Self.sizeMatchingContentAspect(current: currentSize, content: contentSize)
        guard abs(targetSize.width - currentSize.width) > 0.5 || abs(targetSize.height - currentSize.height) > 0.5 else { return }
        setWindowSize(targetSize, keepWidth: false, animated: false)
    }

    /// 已保存尺寸比例足够接近内容时原样返回；否则改成内容比例，并选择偏离当前宽高更小的一侧。
    static func sizeMatchingContentAspect(current: NSSize, content: NSSize) -> NSSize {
        guard content.width > 0, content.height > 0, current.width > 0, current.height > 0 else {
            return current
        }
        let contentRatio = content.width / content.height
        let currentRatio = current.width / current.height
        if abs(currentRatio - contentRatio) / contentRatio <= 0.02 {
            return current
        }
        let keepWidth = NSSize(width: current.width, height: current.width / contentRatio)
        let keepHeight = NSSize(width: current.height * contentRatio, height: current.height)
        let widthDelta = abs(keepWidth.height - current.height)
        let heightDelta = abs(keepHeight.width - current.width)
        return widthDelta <= heightDelta ? keepWidth : keepHeight
    }

    /// 等比缩放，避免分别夹紧宽高把封面比例拉扁。
    private func clampedSizePreservingAspect(_ size: NSSize, minSize: NSSize, maxSize: NSSize?) -> NSSize {
        var width = size.width
        var height = size.height
        if !width.isFinite || width < 1 { width = minSize.width }
        if !height.isFinite || height < 1 { height = minSize.height }

        if let maxSize, maxSize.width > 0, maxSize.height > 0, width > 0, height > 0 {
            let scale = min(1, maxSize.width / width, maxSize.height / height)
            if scale < 1 {
                width *= scale
                height *= scale
            }
        }

        if width < minSize.width || height < minSize.height, width > 0, height > 0 {
            let scale = max(minSize.width / width, minSize.height / height)
            width *= scale
            height *= scale
        } else {
            width = max(minSize.width, width)
            height = max(minSize.height, height)
        }
        return sanitizedWindowSize(NSSize(width: width, height: height), fallback: minSize)
    }

    private func minimumWindowLength(showBorderOverride: Bool? = nil) -> CGFloat {
        let showBorder = showBorderOverride ?? appState.showBorder
        let usesCompactMinimum = (isImageMode && !showBorder) || appState.isAudioDocument
        return usesCompactMinimum ? 80 : 150
    }

    /// 音视频额外限制最小宽度，保证播放控件单行可完整显示。
    private func minimumWindowSize(showBorderOverride: Bool? = nil) -> NSSize {
        let length = minimumWindowLength(showBorderOverride: showBorderOverride)
        let width = appState.isExternalMediaDocument
            ? max(length, MediaPlaybackBarMetrics.minimumWindowWidth)
            : length
        return NSSize(width: width, height: length)
    }

    private func applyWindowSizeLimits() {
        guard let window = window else { return }
        let minSize = minimumWindowSize()
        window.minSize = minSize
        if window.frame.width + 0.5 < minSize.width || window.frame.height + 0.5 < minSize.height {
            setWindowSize(window.frame.size, keepWidth: false, animated: false)
        }
    }

    /// 滤掉 0 / NaN / Inf，避免无边框窗口在 AppKit 计算脏区时崩溃。
    private func sanitizedWindowSize(_ size: NSSize, fallback: NSSize) -> NSSize {
        var result = size
        if !result.width.isFinite || result.width < 1 {
            result.width = fallback.width.isFinite && fallback.width >= 1 ? fallback.width : 80
        }
        if !result.height.isFinite || result.height < 1 {
            result.height = fallback.height.isFinite && fallback.height >= 1 ? fallback.height : 80
        }
        return result
    }

    public func moveWindow(to position: WindowPosition) {
        guard let window = window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        var targetX: CGFloat = window.frame.origin.x
        var targetY: CGFloat = window.frame.origin.y

        switch position {
        case .topLeft:
            targetX = screenFrame.minX
            targetY = screenFrame.maxY - windowSize.height
        case .top:
            targetX = screenFrame.minX + (screenFrame.width - windowSize.width) / 2.0
            targetY = screenFrame.maxY - windowSize.height
        case .topRight:
            targetX = screenFrame.maxX - windowSize.width
            targetY = screenFrame.maxY - windowSize.height
        case .left:
            targetX = screenFrame.minX
            targetY = screenFrame.minY + (screenFrame.height - windowSize.height) / 2.0
        case .center:
            targetX = screenFrame.minX + (screenFrame.width - windowSize.width) / 2.0
            targetY = screenFrame.minY + (screenFrame.height - windowSize.height) / 2.0
        case .right:
            targetX = screenFrame.maxX - windowSize.width
            targetY = screenFrame.minY + (screenFrame.height - windowSize.height) / 2.0
        case .bottomLeft:
            targetX = screenFrame.minX
            targetY = screenFrame.minY
        case .bottom:
            targetX = screenFrame.minX + (screenFrame.width - windowSize.width) / 2.0
            targetY = screenFrame.minY
        case .bottomRight:
            targetX = screenFrame.maxX - windowSize.width
            targetY = screenFrame.minY
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: windowSize.width, height: windowSize.height)
        window.setFrame(targetFrame, display: true, animate: true)
        scheduleWindowFrameSave()
    }

    public func moveToNextScreen() {
        guard let window = window else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        let currentScreen = window.screen ?? NSScreen.main ?? screens[0]
        guard let currentIndex = screens.firstIndex(of: currentScreen) else { return }

        let nextIndex = (currentIndex + 1) % screens.count
        let targetScreen = screens[nextIndex]

        let currentVisible = currentScreen.visibleFrame
        let targetVisible = targetScreen.visibleFrame
        let windowFrame = window.frame

        let relX = (windowFrame.minX - currentVisible.minX) / max(1.0, currentVisible.width)
        let relY = (windowFrame.minY - currentVisible.minY) / max(1.0, currentVisible.height)

        let newWidth = min(windowFrame.width, targetVisible.width)
        let newHeight = min(windowFrame.height, targetVisible.height)

        var newX = targetVisible.minX + relX * targetVisible.width
        var newY = targetVisible.minY + relY * targetVisible.height

        newX = max(targetVisible.minX, min(newX, targetVisible.maxX - newWidth))
        newY = max(targetVisible.minY, min(newY, targetVisible.maxY - newHeight))

        let targetFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        window.setFrame(targetFrame, display: true, animate: true)
        scheduleWindowFrameSave()
    }
}

public enum WindowPosition {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight
}
