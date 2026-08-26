//  NavigatorPanelPreferences.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation

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

    static func clampWidth(_ width: Double) -> Double {
        max(minimumWidth, min(maximumWidth, width))
    }
}
