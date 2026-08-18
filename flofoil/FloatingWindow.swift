//
//  FloatingWindow.swift
//  flofoil
//
//  Created by tolg on 2026/7/6.
//

import Cocoa
import PDFKit

public class FloatingWindow: NSWindow {
    private var isCommandDragCursorVisible = false
    private var currentAccumulatedMagnification: CGFloat = 1.0

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

    public override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .flagsChanged {
            let isCommandPressed = modifiers.contains(.command)
            updateCommandDragCursor(isCommandPressed: isCommandPressed)
            if let controller = self.windowController as? FloatingWindowController {
                controller.appState.isCommandKeyPressed = isCommandPressed
            }
        }

        // Command + 拖拽始终交由 AppKit 移动整个窗口，并屏蔽内容视图的默认交互。
        if event.type == .leftMouseDown, modifiers.contains(.command) {
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

        // 无边框 PDF 的缩放只调整窗口；手势结束后再由 PDFKit 适配新的窗口尺寸。
        if let controller = self.windowController as? FloatingWindowController,
           controller.appState.isPDFDocument,
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

        // 处理 cmd + 鼠标滚轮
        if event.type == .scrollWheel, modifiers.contains(.command) {
            if let controller = self.windowController as? FloatingWindowController {
                let appState = controller.appState
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.003 : 0.03
                let factor = 1.0 + delta * multiplier

                if appState.imageURL != nil && appState.webURL == nil {
                    // 有边框 PDF 保留 PDFViewer 的原生缩放与滚动响应。
                    if appState.isPDFDocument && appState.showBorder {
                        super.sendEvent(event)
                        return
                    }
                    // 图片模式：缩放内容大小
                    let newScale = appState.imageScale * Double(factor)
                    appState.imageScale = AppState.clampImageScale(newScale)

                    if !appState.showBorder {
                        NotificationCenter.default.post(
                            name: .shouldFitWindowToImage,
                            object: nil,
                            userInfo: ["id": appState.id, "animated": false]
                        )
                    }
                    appState.saveState()
                } else {
                    // 非图片模式（网页、文本、Markdown）：缩放窗口
                    let currentSize = self.frame.size
                    let targetSize = NSSize(
                        width: currentSize.width * factor,
                        height: currentSize.height * factor
                    )
                    controller.setWindowSize(targetSize, keepWidth: false, animated: false)
                    controller.scheduleWindowFrameSave()
                }
            }
            return
        }

        // 处理手势捏合（仅非图片模式拦截）
        if event.type == .magnify {
            if let controller = self.windowController as? FloatingWindowController,
               (controller.appState.imageURL == nil || controller.appState.webURL != nil) {

                let phase = event.phase
                if phase.contains(.began) {
                    currentAccumulatedMagnification = 1.0
                } else if phase.contains(.changed) {
                    currentAccumulatedMagnification += event.magnification
                    NotificationCenter.default.post(
                        name: .shouldResizeWindowWithPinch,
                        object: nil,
                        userInfo: ["id": controller.appState.id, "magnification": currentAccumulatedMagnification]
                    )
                } else if phase.contains(.ended) || phase.contains(.cancelled) {
                    NotificationCenter.default.post(
                        name: .shouldEndWindowPinchResize,
                        object: nil,
                        userInfo: ["id": controller.appState.id]
                    )
                    currentAccumulatedMagnification = 1.0
                }
                return
            }
        }

        super.sendEvent(event)
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
        } else {
            controller.appState.copyCurrentImageToPasteboard()
        }
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(FloatingWindow.copy(_:)) {
            guard let controller = windowController as? FloatingWindowController else { return false }
            return controller.appState.imageURL != nil && controller.appState.webURL == nil
        }
        return super.validateMenuItem(menuItem)
    }

    // 重写 performKeyEquivalent(with:) 拦截快捷键事件，支持不带 Shift 的 cmd + = / , / . 快捷键响应
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 快捷键 ⌃⌥ (Control + Option) 组合键（如 ⌃⌥q/w/e/a/s/d/z/x/c 窗口定位），优先交由主菜单处理。
        if modifiers == [.control, .option] {
            if let mainMenu = NSApplication.shared.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return true
            }
        }

        // 键盘快捷键 ⇧⌘v (Shift + Command + V) 用于从剪贴板打开图片，确保所有模式窗口都可响应。
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let delegate = NSApplication.shared.delegate as? AppDelegate,
               delegate.openClipboardImageInNewWindow() {
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
                } else if chars == "," {
                    if let controller = self.windowController as? FloatingWindowController {
                        let isImageMode = controller.appState.imageURL != nil && controller.appState.webURL == nil
                        if isImageMode {
                            if controller.appState.showBorder {
                                controller.zoomOutWindow()
                            } else {
                                controller.zoomOut()
                            }
                        } else {
                            controller.zoomOutWindow()
                        }
                        return true
                    }
                } else if chars == "." {
                    if let controller = self.windowController as? FloatingWindowController {
                        let isImageMode = controller.appState.imageURL != nil && controller.appState.webURL == nil
                        if isImageMode {
                            if controller.appState.showBorder {
                                controller.zoomInWindow()
                            } else {
                                controller.zoomIn()
                            }
                        } else {
                            controller.zoomInWindow()
                        }
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
    // 当前 MVP 先采用纯 .borderless + .resizable 以满足完全无边框设计要求。
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
