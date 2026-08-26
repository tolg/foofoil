//  NavigatorPanelPreferences.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation
import Combine

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
