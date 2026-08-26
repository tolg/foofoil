//
//  FloatingWindow.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import Cocoa
import PDFKit

public class FloatingWindow: NSWindow {
    struct ResizeEdges: OptionSet {
        let rawValue: UInt8

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private var isCommandDragCursorVisible = false
    private var isEdgeResizeCursorVisible = false
    private weak var resizeCursorTrackingView: NSView?
    private var resizeCursorTrackingArea: NSTrackingArea?
    private var currentAccumulatedMagnification: CGFloat = 1.0
    private static let resizeHitThickness: CGFloat = 8
    private static let resizeCornerExtent: CGFloat = 20

    public init(contentRect: NSRect, defer deferCreation: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: deferCreation
        )

        // 设置无边框透明窗口
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // 允许通过点击背景拖拽移动窗口
        self.isMovableByWindowBackground = true
        self.acceptsMouseMovedEvents = true

        // 确保在多个 Space (虚拟桌面) 中都可见，且支持全屏辅助模式
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 默认普通层级
        self.level = .normal
    }

    // 【重点说明】
    // 默认情况下，.borderless 窗口无法成为 key 窗口或 main 窗口，
    // 这会导致无法接受键盘事件（比如 TextEditor 无法打字，Cmd+W / Cmd+Q 快捷键失效）。
    // 因此必须重写以下两个属性并返回 true。

    public override var canBecomeKey: Bool {
        return true
    }

    public override var canBecomeMain: Bool {
        return true
    }

    func installResizeCursorTracking(in view: NSView) {
        if let resizeCursorTrackingArea, let resizeCursorTrackingView {
            resizeCursorTrackingView.removeTrackingArea(resizeCursorTrackingArea)
        }

        // acceptsMouseMovedEvents 不保证鼠标越界后还能收到最后一个 mouseMoved，显式跟踪整个内容区以可靠接收 mouseExited。
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea)
        resizeCursorTrackingView = view
        resizeCursorTrackingArea = trackingArea
    }

    public override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .flagsChanged {
            let isCommandPressed = modifiers.contains(.command)
            updateCommandDragCursor(isCommandPressed: isCommandPressed)
            if let controller = self.windowController as? FloatingWindowController {
                controller.appState.isCommandKeyPressed = isCommandPressed
            }
        }

        if event.type == .mouseMoved || event.type == .cursorUpdate {
            if let controller = self.windowController as? FloatingWindowController {
                controller.updateNavigatorEdgeHover(at: event.locationInWindow)
            }
            if !modifiers.contains(.command), updateEdgeResizeCursor(at: event.locationInWindow) {
                return
            }
        }

        if event.type == .mouseExited {
            if let controller = self.windowController as? FloatingWindowController {
                controller.updateNavigatorEdgeHover(at: nil)
            }
            resetEdgeResizeCursor()
        }

        // 透明全尺寸内容视图会让部分 macOS 版本的上下边缘命中落到内容层，窗口级处理可保证四边均可缩放。
        if event.type == .leftMouseDown,
           !modifiers.contains(.command),
           (windowController as? FloatingWindowController)?.appState.isFullScreen != true,
           let edges = resizeEdges(at: event.locationInWindow) {
            performEdgeResize(with: event, edges: edges)
            return
        }

        // Command + 拖拽始终交由 AppKit 移动整个窗口，并屏蔽内容视图的默认交互。
        if event.type == .leftMouseDown,
           modifiers.contains(.command),
           (windowController as? FloatingWindowController)?.appState.isFullScreen != true {
            updateCommandDragCursor(isCommandPressed: true)
            performDrag(with: event)
            return
        }

        // PDF 翻页使用窗口级键盘事件，避免焦点落在 PDFView 的子视图时快捷键失效。
        if event.type == .keyDown,
           modifiers.isEmpty,
           let controller = self.windowController as? FloatingWindowController,
           controller.appState.isPDFDocument {
            let notificationName: Notification.Name?
            switch event.keyCode {
            case 123: // 左方向键
                notificationName = .shouldGoToPreviousPDFPage
            case 124: // 右方向键
                notificationName = .shouldGoToNextPDFPage
            default:
                notificationName = nil
            }

            if let notificationName {
                NotificationCenter.default.post(
                    name: notificationName,
                    object: nil,
                    userInfo: ["id": controller.appState.id]
                )
                return
            }
        }

        // 音视频模式使用窗口级空格键切换播放/暂停；忽略按住空格产生的重复事件。
        if event.type == .keyDown,
           modifiers.isEmpty,
           event.keyCode == 49,
           !event.isARepeat,
           let controller = self.windowController as? FloatingWindowController,
           controller.appState.isExternalMediaDocument {
            NotificationCenter.default.post(
                name: .shouldToggleVideoPlayback,
                object: nil,
                userInfo: ["id": controller.appState.id]
            )
            return
        }

        // 无边框 PDF 的缩放只调整窗口；手势结束后再由 PDFKit 适配新的窗口尺寸。
        if let controller = self.windowController as? FloatingWindowController,
           controller.appState.isPDFDocument,
           !controller.appState.isFullScreen,
           !controller.appState.showBorder {
            if event.type == .scrollWheel {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers.contains(.command) else { return }

                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.003 : 0.03
                controller.resizePDFWindowForScroll(factor: 1.0 + delta * multiplier)
                return
            }

            if event.type == .magnify {
                if event.phase.contains(.began) {
                    currentAccumulatedMagnification = 1.0
                } else if event.phase.contains(.changed) || event.phase.isEmpty {
                    currentAccumulatedMagnification += event.magnification
                    controller.resizePDFWindowForMagnification(currentAccumulatedMagnification)
                } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    controller.finishPDFWindowResize()
                    currentAccumulatedMagnification = 1.0
                }
                return
            }
        }

        // 全屏时滚轮与捏合只交给内容视图；不能改变原窗口 frame。
        if let controller = windowController as? FloatingWindowController,
           controller.appState.isFullScreen,
           event.type == .scrollWheel || event.type == .magnify {
            super.sendEvent(event)
            return
        }

        // 处理 cmd + 鼠标滚轮
        if event.type == .scrollWheel, modifiers.contains(.command) {
            if let controller = self.windowController as? FloatingWindowController {
                let appState = controller.appState
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.003 : 0.03
                let factor = 1.0 + delta * multiplier

                if appState.imageURL != nil && appState.webURL == nil && !appState.isAudioDocument && !(appState.isVideoDocument && appState.showBorder) {
                    // 有边框 PDF 保留 PDFViewer 的原生缩放与滚动响应。
                    if appState.isPDFDocument && appState.showBorder {
                        super.sendEvent(event)
                        return
                    }
                    // 图片/无边框视频：只改缩放与窗口，结束后再写入历史（与音频窗口缩放一致）。
                    controller.applyInteractiveImageZoom(factor: factor)
                } else {
                    // 非图片模式（网页、文本、Markdown、音频、有边框视频）：缩放窗口
                    let currentSize = self.frame.size
                    let targetSize = NSSize(
                        width: currentSize.width * factor,
                        height: currentSize.height * factor
                    )
                    controller.setWindowSize(targetSize, keepWidth: false, animated: false)
                    controller.scheduleInteractiveZoomCommit()
                }
            }
            return
        }

        // 触摸板捏合：图片改内容缩放（无边框时同步窗口）；其余模式只改窗口大小。过程中不写历史。
        if event.type == .magnify, let controller = self.windowController as? FloatingWindowController {
            let appState = controller.appState
            let isImageMagnify = appState.imageURL != nil
                && appState.webURL == nil
                && !appState.isExternalMediaDocument
                && !appState.isPDFDocument
            let isWindowMagnify = appState.imageURL == nil
                || appState.isExternalMediaDocument
                || appState.webURL != nil
                || (appState.isPDFDocument && !appState.showBorder)

            if isImageMagnify || isWindowMagnify {
                let phase = event.phase
                if phase.contains(.began) {
                    currentAccumulatedMagnification = 1.0
                } else if phase.contains(.changed) || phase.isEmpty {
                    currentAccumulatedMagnification += event.magnification
                    if isImageMagnify {
                        controller.applyInteractiveImageMagnification(currentAccumulatedMagnification)
                    } else {
                        NotificationCenter.default.post(
                            name: .shouldResizeWindowWithPinch,
                            object: nil,
                            userInfo: ["id": appState.id, "magnification": currentAccumulatedMagnification]
                        )
                    }
                } else if phase.contains(.ended) || phase.contains(.cancelled) {
                    if isImageMagnify {
                        controller.finishInteractiveImageMagnification()
                    } else {
                        NotificationCenter.default.post(
                            name: .shouldEndWindowPinchResize,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }
                    currentAccumulatedMagnification = 1.0
                }
                return
            }
        }

        super.sendEvent(event)
    }

    static func resizeEdges(at point: NSPoint, in size: NSSize) -> ResizeEdges? {
        let bounds = NSRect(origin: .zero, size: size)
        // 窗口外坐标不能继续命中最近的边，否则离开窗口后会残留甚至切换成错误方向的缩放光标。
        guard point.x >= bounds.minX,
              point.x <= bounds.maxX,
              point.y >= bounds.minY,
              point.y <= bounds.maxY else {
            return nil
        }

        var edges: ResizeEdges = []
        let nearLeft = point.x <= resizeHitThickness
        let nearRight = point.x >= bounds.maxX - resizeHitThickness
        let nearBottom = point.y <= resizeHitThickness
        let nearTop = point.y >= bounds.maxY - resizeHitThickness

        if nearLeft { edges.insert(.left) }
        if nearRight { edges.insert(.right) }
        if nearBottom { edges.insert(.bottom) }
        if nearTop { edges.insert(.top) }

        // 四角沿两条相邻边扩大命中范围，确保角拖拽始终同时改变宽高。
        if nearLeft || nearRight {
            if point.y <= resizeCornerExtent { edges.insert(.bottom) }
            if point.y >= bounds.maxY - resizeCornerExtent { edges.insert(.top) }
        }
        if nearBottom || nearTop {
            if point.x <= resizeCornerExtent { edges.insert(.left) }
            if point.x >= bounds.maxX - resizeCornerExtent { edges.insert(.right) }
        }
        return edges.isEmpty ? nil : edges
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges? {
        Self.resizeEdges(at: point, in: frame.size)
    }

    private func updateEdgeResizeCursor(at point: NSPoint) -> Bool {
        guard let edges = resizeEdges(at: point) else {
            resetEdgeResizeCursor()
            return false
        }

        cursor(for: edges).set()
        isEdgeResizeCursorVisible = true
        return true
    }

    private func resetEdgeResizeCursor() {
        guard isEdgeResizeCursorVisible else { return }
        isEdgeResizeCursorVisible = false
        if !isCommandDragCursorVisible {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        resetEdgeResizeCursor()
        super.mouseExited(with: event)
    }

    private func cursor(for edges: ResizeEdges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (edges.contains(.left), edges.contains(.right), edges.contains(.bottom), edges.contains(.top)) {
        case (true, false, false, true): position = .topLeft
        case (false, true, false, true): position = .topRight
        case (true, false, true, false): position = .bottomLeft
        case (false, true, true, false): position = .bottomRight
        case (true, false, false, false): position = .left
        case (false, true, false, false): position = .right
        case (false, false, true, false): position = .bottom
        default: position = .top
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    private func performEdgeResize(with event: NSEvent, edges: ResizeEdges) {
        guard let controller = windowController as? FloatingWindowController else { return }

        let initialFrame = frame
        let initialMouseLocation = NSEvent.mouseLocation
        controller.beginManualLiveResize()
        defer {
            controller.endManualLiveResize()

            let mouseLocationInWindow = convertPoint(fromScreen: NSEvent.mouseLocation)
            _ = updateEdgeResizeCursor(at: mouseLocationInWindow)
        }

        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if nextEvent.type == .leftMouseUp { break }

            let mouseLocation = NSEvent.mouseLocation
            let offset = NSPoint(
                x: mouseLocation.x - initialMouseLocation.x,
                y: mouseLocation.y - initialMouseLocation.y
            )
            let rawSize = Self.edgeResizeSize(initialFrame: initialFrame, offset: offset, edges: edges)
            let constrainedSize = controller.constrainedManualResizeSize(rawSize, from: initialFrame.size)
            let resizedFrame = Self.edgeResizeFrame(
                initialFrame: initialFrame,
                constrainedSize: constrainedSize,
                edges: edges
            )
            setFrame(resizedFrame, display: true)
        }
    }

    static func edgeResizeSize(initialFrame: NSRect, offset: NSPoint, edges: ResizeEdges) -> NSSize {
        var width = initialFrame.width
        var height = initialFrame.height
        if edges.contains(.left) { width -= offset.x }
        if edges.contains(.right) { width += offset.x }
        if edges.contains(.bottom) { height -= offset.y }
        if edges.contains(.top) { height += offset.y }
        return NSSize(width: max(1, width), height: max(1, height))
    }

    static func edgeResizeFrame(initialFrame: NSRect, constrainedSize: NSSize, edges: ResizeEdges) -> NSRect {
        let originX = edges.contains(.left) ? initialFrame.maxX - constrainedSize.width : initialFrame.minX
        let originY = edges.contains(.bottom) ? initialFrame.maxY - constrainedSize.height : initialFrame.minY
        return NSRect(origin: NSPoint(x: originX, y: originY), size: constrainedSize)
    }

    private func updateCommandDragCursor(isCommandPressed: Bool) {
        guard isCommandDragCursorVisible != isCommandPressed else { return }

        isCommandDragCursorVisible = isCommandPressed
        (isCommandPressed ? NSCursor.openHand : NSCursor.arrow).set()
    }

    @objc public func copy(_ sender: Any?) {
        guard let controller = windowController as? FloatingWindowController else { return }
        if controller.appState.isPDFDocument,
           let pdfView = contentView?.findSubview(ofType: PDFView.self) {
            if let selection = pdfView.currentSelection,
               let text = selection.string,
               !text.isEmpty {
                pdfView.copy(sender)
            } else {
                pdfView.copyCurrentPageToPasteboard()
            }
        } else if !controller.appState.isExternalMediaDocument {
            controller.appState.copyCurrentImageToPasteboard()
        }
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(FloatingWindow.copy(_:)) {
            guard let controller = windowController as? FloatingWindowController else { return false }
            return controller.appState.imageURL != nil && controller.appState.webURL == nil && !controller.appState.isExternalMediaDocument
        }
        return super.validateMenuItem(menuItem)
    }

    // 重写 performKeyEquivalent(with:)：内容缩放仍响应不带 Shift 的 ⌘=；增大/缩小箔走 ⇧⌘+/-；⌘, 始终打开设置。
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let delegate = NSApplication.shared.delegate as? AppDelegate

        if modifiers == [.command, .control],
           event.charactersIgnoringModifiers?.lowercased() == "f",
           let controller = windowController as? FloatingWindowController {
            controller.toggleFullScreen()
            return true
        }

        // ⌘, 打开设置；内容视图（尤其是网页）不得吞掉该系统偏好快捷键。
        if modifiers == .command,
           event.charactersIgnoringModifiers == "," {
            delegate?.showSettingsAction()
            return true
        }

        // 快捷键 ⌃⌥ (Control + Option) 组合键（如 ⌃⌥q/w/e/a/s/d/z/x/c 窗口定位），优先交由主菜单处理。
        if modifiers == [.control, .option] {
            if let mainMenu = NSApplication.shared.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return true
            }
        }

        // ⇧⌘v 从剪贴板打开图片；⇧⌘+/- 增大/缩小箔，确保各内容模式窗口都可响应。
        if modifiers == [.command, .shift],
           let chars = event.charactersIgnoringModifiers {
            let key = chars.lowercased()
            if key == "v" {
                if delegate?.openClipboardImageInNewWindow() == true {
                    return true
                }
            } else if key == "=" || key == "+" {
                delegate?.zoomInWindowAction()
                return true
            } else if key == "-" {
                delegate?.zoomOutWindowAction()
                return true
            }
        }

        // 仅在修饰键恰好只有 Command 时进行拦截（不带 Shift）
        if modifiers == .command {
            if let chars = event.charactersIgnoringModifiers {
                if chars == "=" {
                    if let controller = self.windowController as? FloatingWindowController {
                        controller.zoomIn()
                        return true
                    }
                } else if chars == "[" {
                    if let controller = self.windowController as? FloatingWindowController {
                        let isImageMode = controller.appState.imageURL != nil && controller.appState.webURL == nil
                        if isImageMode && controller.appState.showBorder {
                            controller.fitWindowToCurrentImageSize()
                            return true
                        }
                    }
                } else if chars == "]" {
                    if let controller = self.windowController as? FloatingWindowController {
                        let isImageMode = controller.appState.imageURL != nil && controller.appState.webURL == nil
                        if isImageMode && controller.appState.showBorder {
                            controller.fitImageToWindowWidth()
                            return true
                        }
                    }
                }
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    // 【折中方案说明】
    // 如果在某些 macOS 版本下，.borderless 搭配 .resizable 边缘缩放手势难以触发（因为无可视边框），
    // 可以采用如下折中方案：
    // 使用 styleMask = [.titled, .resizable, .fullSizeContentView] 并设置：
    //   self.titleVisibility = .hidden
    //   self.titlebarAppearsTransparent = true
    // 这能在保留系统标准隐形边框缩放热区的同时，依然实现无标题栏的视觉效果。
    // 当前实现通过窗口级边缘拖拽保证四边缩放，因此继续保留纯 .borderless 外观。
}

extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let typed = self as? T {
            return typed
        }
        for subview in subviews {
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}
