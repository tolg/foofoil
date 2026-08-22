//
//  FloatingWindowController.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//

import Cocoa
import SwiftUI
import Combine
import AVFoundation

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

    public init(appState: AppState) {
        self.appState = appState
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
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        applyWindowSizeLimits()

        // 预先缓存可能已有的图片/视频/音频展示尺寸
        if let url = appState.imageURL {
            if appState.isExternalMediaDocument {
                fetchMediaPresentationSize(for: url) { [weak self] size in
                    guard let self, self.appState.imageURL == url else { return }
                    self.currentMediaSize = size
                }
            } else if let nsImage = appState.loadImage(from: url) {
                self.currentImageSize = AudioMetadataLoader.reliableImageSize(nsImage) ?? nsImage.size
            }
        }

        // 绑定状态监听
        setupBindings()
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
                        self.currentImageSize = nil
                        self.currentMediaSize = nil
                        return
                    }
                    self.applyWindowSizeLimits()
                    if self.appState.isExternalMediaDocument {
                        self.currentImageSize = nil
                        self.fetchMediaPresentationSize(for: url) { size in
                            guard self.appState.imageURL == url else { return }
                            self.currentMediaSize = size
                        }
                    } else {
                        self.currentMediaSize = nil
                        if let image = self.appState.loadImage(from: url) {
                            self.currentImageSize = AudioMetadataLoader.reliableImageSize(image) ?? image.size
                        } else {
                            self.currentImageSize = nil
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 监听 Pin/Unpin 状态，更新窗口层级
        appState.$isPinned
            .sink { [weak window] isPinned in
                DispatchQueue.main.async {
                    window?.level = isPinned ? .floating : .normal
                }
            }
            .store(in: &cancellables)

        // 监听透明度变化，更新窗口透明度
        appState.$opacity
            .sink { [weak window] opacity in
                DispatchQueue.main.async {
                    window?.alphaValue = CGFloat(opacity)
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
                        self.initializeImageLayout(imageSize: size, animated: !isFirst)
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
                    if let window = self.window {
                        self.appState.windowFrame = window.frameDescriptor
                    }
                    self.appState.saveState()
                }
            }
            .store(in: &cancellables)
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
        if let window = window {
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
        return AudioMetadataLoader.reliableImageSize(image) ?? image.size
    }

    private func imageContentSize(at url: URL) -> NSSize? {
        guard let image = appState.loadImage(from: url) else { return nil }
        let size = AudioMetadataLoader.reliableImageSize(image) ?? image.size
        guard size.width > 0, size.height > 0 else { return nil }
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

    func setWindowSize(_ size: NSSize, keepWidth: Bool, animated: Bool, showBorderOverride: Bool? = nil) {
        guard let window = window else { return }
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

        // 保持当前窗口的中心点不变
        let currentCenter = NSPoint(
            x: currentFrame.minX + currentFrame.width / 2.0,
            y: currentFrame.minY + currentFrame.height / 2.0
        )

        let newFrame = NSRect(
            x: currentCenter.x - newWidth / 2.0,
            y: currentCenter.y - newHeight / 2.0,
            width: newWidth,
            height: newHeight
        )

        window.setFrame(newFrame, display: true, animate: animated)
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
    }

    public func windowDidResignKey(_ notification: Notification) {
        appState.isCommandKeyPressed = false
    }

    public func windowWillStartLiveResize(_ notification: Notification) {
        isLiveResizing = true
        guard let window = window else { return }
        // 不要在 live resize 开始时把 aspectRatio 设为 .zero：无边框透明窗口自由拉伸会在
        // `_adjustNeedsDisplayRegionForNewFrame` 里因空脏区触发 AppKit 断言崩溃。
        if let ratioSize = constrainedContentAspectSize() {
            window.aspectRatio = ratioSize
        }
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var size = sanitizedWindowSize(frameSize, fallback: sender.frame.size)
        let minSize = minimumWindowSize()
        let maxSize = sender.screen.map {
            NSSize(width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }

        // 用户拖拽且内容锁定比例时，按画面/封面改目标尺寸。
        if isLiveResizing, let ratioSize = constrainedContentAspectSize(), ratioSize.width > 0, ratioSize.height > 0 {
            let ratio = ratioSize.width / ratioSize.height
            let dw = abs(size.width - sender.frame.width)
            let dh = abs(size.height - sender.frame.height)
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
        scheduleWindowFrameSave()
    }

    public func windowDidResize(_ notification: Notification) {
        guard !isLiveResizing else { return }
        scheduleWindowFrameSave()
    }

    public func windowWillClose(_ notification: Notification) {
        pendingFrameSave?.cancel()
        pendingZoomCommit?.cancel()
        pinchImageBaseScale = nil
        if appState.isInteractiveZooming {
            appState.isInteractiveZooming = false
        }
        if let window = window {
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
            guard let self = self, !self.isLiveResizing, let window = self.window else { return }
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
            ? max(length, MediaPlaybackBar.minimumWindowWidth)
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
