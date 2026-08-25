//  AppState+Lifecycle.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        public func resetContent() {
            NotificationCenter.default.post(
                name: .willResetContent,
                object: self
            )

            isBatchUpdating = true
            self.originalImageName = nil
            self.imageSource = nil
            self.imageURL = nil
            self.webURL = nil
            self.actualWebURL = nil
            self.textURL = nil
            self.text = ""
            self.sourceFingerprint = nil
            self.imageScale = 1.0
            self.id = UUID()
            self.createdAt = Date()
            self.svgColor = nil
            self.isVideoLooping = true
            self.videoBookmarkData = nil
            self.extensionSession = nil
            self.extensionFallbackProviderID = nil
            self.extensionStateReference = nil
            isBatchUpdating = false

            NotificationCenter.default.post(
                name: .shouldResetWindowFrame,
                object: self
            )
        }

        public func togglePin() {
            self.isPinned.toggle()
        }

        public func increaseOpacity() {
            self.opacity = opacity + 0.1
        }

        public func decreaseOpacity() {
            self.opacity = opacity - 0.1
        }

        public func increaseTextFontSize() {
            textFontSize += 1.0
        }

        public func decreaseTextFontSize() {
            textFontSize -= 1.0
        }

        public static func clampImageScale(_ value: Double) -> Double {
            max(minImageScale, min(maxImageScale, value))
        }

        public static func clampTextFontSize(_ value: Double) -> Double {
            max(minTextFontSize, min(maxTextFontSize, value))
        }

        public static func clampWebZoom(_ value: Double) -> Double {
            max(0.25, min(5.0, value))
        }
}
