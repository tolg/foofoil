//  NavigatorPanelController.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import AppKit
import SwiftUI

final class NavigatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 桌面态使用独立伴随窗口，避免导航面板宽度进入箔片内容 frame 和比例缩放计算。
final class NavigatorPanelController: NSWindowController {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let panel = NavigatorPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: appState.navigatorPanelWidth,
                height: 400
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NavigatorPanelView(appState: appState))
        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool { window?.isVisible == true }

    func owns(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    func show(attachedTo parent: NSWindow) {
        guard let panel = window else { return }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        synchronizeAppearance(with: parent)
        updateFrame(relativeTo: parent)
        panel.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func detachAndClose() {
        guard let panel = window else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
    }

    func synchronizeAppearance(with parent: NSWindow) {
        guard let panel = window else { return }
        panel.level = parent.level
        panel.alphaValue = parent.alphaValue
    }

    func updateFrame(relativeTo parent: NSWindow) {
        guard let panel = window else { return }
        let width = CGFloat(NavigatorPanelMetrics.clampWidth(appState.navigatorPanelWidth))
        let gap = CGFloat(NavigatorPanelMetrics.attachmentGap)
        let x: CGFloat
        switch appState.navigatorPanelSide {
        case .left:
            x = parent.frame.minX - width - gap
        case .right:
            x = parent.frame.maxX + gap
        }
        let frame = NSRect(x: x, y: parent.frame.minY, width: width, height: parent.frame.height)
        panel.setFrame(frame, display: true)
    }
}
