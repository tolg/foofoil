//
//  MovableBackgrounds.swift
//  flamina
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

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
        MovableNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MovableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            true
        }
    }
}
