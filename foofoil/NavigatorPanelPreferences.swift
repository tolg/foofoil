//  NavigatorPanelPreferences.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation
import Combine
import AppKit

/// 指针悬停状态单独观察，避免写入 AppState 的 @Published 导致箔片内容整树重绘闪一下。
final class NavigatorHoverState: ObservableObject {
    @Published var isPointerInside = false
    @Published var isPanelHovered = false
}

nonisolated public enum NavigatorPanelSide: String, Codable, Sendable {
    case left
    case right
}

nonisolated public enum NavigatorPanelVisibilityMode: String, Codable, Sendable {
    case onHover
    case always
}

nonisolated enum NavigatorPanelMetrics {
    static let defaultWidth = 260.0
    static let minimumWidth = 180.0
    static let maximumWidth = 480.0
    static let attachmentGap = 8.0
    static let edgeTriggerWidth = 12.0
    static let widthResizeHandleThickness = 8.0
    static let hoverHideDelay = 0.08
    /// 面板横向可见宽度低于此比例（即被推出屏幕超过 1/3）时视为超界，可自动换边。
    static let autoSwapMinVisibleRatio: CGFloat = 2.0 / 3.0

    /// 面板被推出屏幕超过 1/3、且挂到另一侧后能完整放进某块屏幕可见区域时，
    /// 返回换边目标；否则返回 nil。纯几何判定，供窗口移动时调用与单元测试。
    static func autoSwapTargetSide(
        current: NavigatorPanelSide,
        panelFrame: NSRect,
        windowFrame: NSRect,
        screenVisibleFrames: [NSRect]
    ) -> NavigatorPanelSide? {
        let visibleWidth = screenVisibleFrames.reduce(CGFloat(0)) { $0 + panelFrame.intersection($1).width }
        guard visibleWidth < panelFrame.width * autoSwapMinVisibleRatio else { return nil }

        let gap = CGFloat(attachmentGap)
        let candidateFrame: NSRect
        switch current {
        case .left:
            candidateFrame = NSRect(
                x: windowFrame.maxX + gap,
                y: panelFrame.minY,
                width: panelFrame.width,
                height: panelFrame.height
            )
        case .right:
            candidateFrame = NSRect(
                x: windowFrame.minX - gap - panelFrame.width,
                y: panelFrame.minY,
                width: panelFrame.width,
                height: panelFrame.height
            )
        }
        guard screenVisibleFrames.contains(where: { $0.contains(candidateFrame) }) else { return nil }
        return current == .left ? .right : .left
    }

    static func containsWidthResizeHandle(x: CGFloat, width: CGFloat, draggingLeftEdge: Bool) -> Bool {
        if draggingLeftEdge {
            return x <= widthResizeHandleThickness
        }
        return x >= width - widthResizeHandleThickness
    }

    static func clampWidth(_ width: Double) -> Double {
        max(minimumWidth, min(maximumWidth, width))
    }

    /// `translation` 为指针相对起点的水平位移（右为正）。拖左缘时向左加宽，拖右缘时向右加宽。
    static func width(afterDrag start: Double, translation: Double, draggingLeftEdge: Bool) -> Double {
        let next = draggingLeftEdge ? start - translation : start + translation
        return clampWidth(next)
    }

    /// ⌘+滚轮：上滚加宽，下滚收窄；精细滚动用较小倍率。
    static func width(afterScroll start: Double, delta: Double, precise: Bool) -> Double {
        let multiplier = precise ? 0.003 : 0.04
        return clampWidth(start * (1.0 + delta * multiplier))
    }
}
