//
//  MovableBackgrounds.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

/// 仅显式标记的背景视图允许伴随窗口拖动箔片，避免吞掉 SwiftUI 控件点击。
protocol ExplicitlyMovableWindowBackground {}

final class MovableWindowBackgroundNSView: NSView, ExplicitlyMovableWindowBackground {
    override var mouseDownCanMoveWindow: Bool { true }
}

// 用于让 SwiftUI View 区域阻止 macOS 窗口通过背景进行拖动的辅助容器背景
struct NonMovableBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return NonMovableNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class NonMovableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            return false
        }
    }
}

// 用于将文字模式中露出的边距标记为可移动窗口的原生背景。
struct MovableBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MovableWindowBackgroundNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
