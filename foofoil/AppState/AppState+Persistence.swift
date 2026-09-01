//  AppState+Persistence.swift
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
        public func saveState() {
            guard !isBatchUpdating else { return }
            let config = toConfig()
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if imageURL != nil || webURL != nil || textURL != nil || extensionSession != nil || !trimmedText.isEmpty {
                HistoryManager.shared.addToHistory(config)
            }
        }

        public func loadConfig(_ config: WindowConfig) {
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
                updateRenderedMarkdown()
            }

            // 载入历史项必须沿用原 UUID，否则随后的自动保存会创建一条重复历史。
            self.id = config.id
            self.sourceFingerprint = config.sourceFingerprint
            self.isPinned = config.isPinned
            self.opacity = config.opacity
            self.originalImageName = config.originalImageName
            self.imageSource = config.imageSource
            self.showBorder = config.showBorder
            self.imageScale = Self.clampImageScale(config.imageScale)
            self.textFontSize = Self.clampTextFontSize(config.textFontSize)
            self.webZoom = Self.clampWebZoom(config.webZoom)
            self.isMarkdownPreview = config.isMarkdownPreview
            self.windowFrame = config.windowFrame
            self.createdAt = config.createdAt
            self.svgColor = config.svgColor
            self.backgroundColorHex = config.backgroundColorHex
            self.mediaPlaybackMode = config.mediaPlaybackMode
            self.extensionStateReference = config.extensionStateReference
            self.navigatorPanelSide = config.navigatorPanelSide
            self.navigatorPanelVisibilityMode = config.navigatorPanelVisibilityMode
            self.navigatorPanelWidth = NavigatorPanelMetrics.clampWidth(config.navigatorPanelWidth)
            self.fileList = nil
            self.fileListRevision = 0
            self.stopImageListSlideshow()
            self.builtInNavigatorContributions = []
            self.builtInNavigatorActionHandler = nil
            self.isNavigatorPanelExplicitlyVisible = false
            self.activeNavigatorContributionID = nil
            self.expandedNavigatorItemIDs = []
            restoreExtensionSession(from: config)
            restoreFileList(from: config)

            // 载入历史记录时，一律尝试通知窗口控制器恢复当初保存的窗口位置与尺寸
            if let frameString = config.windowFrame {
                NotificationCenter.default.post(
                    name: .shouldRestoreFrame,
                    object: nil,
                    userInfo: ["frame": frameString, "id": id]
                )
            }

            if let path = config.imagePath {
                let url = URL(fileURLWithPath: path)
                // 视频/音频经安全范围书签恢复沙盒访问（重启后路径直接不可达）
                if Self.isExternalMediaFileName(config.originalImageName ?? path) {
                    // 加载新配置前先释放旧的媒体授权
                    stopVideoAccess()
                    if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                        self.accessingVideoURL = restored.accessedURL
                        self.videoBookmarkData = restored.bookmark
                        self.imageURL = restored.url
                        // 音频再恢复同目录封面文件夹的访问，保证封面在重启后仍可读取
                        if Self.isAudioFileName(config.originalImageName ?? path),
                           let sidecarBookmark = config.mediaSidecarBookmark,
                           let sidecar = Self.restoreSidecarCoverAccess(bookmark: sidecarBookmark) {
                            if sidecar.accessed { accessingSidecarDirectoryURL = sidecar.directory }
                            mediaSidecarBookmarkData = sidecar.refreshedBookmark ?? sidecarBookmark
                        }
                    } else {
                        self.videoBookmarkData = nil
                        self.mediaSidecarBookmarkData = nil
                        self.imageURL = nil
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    self.imageURL = url
                } else {
                    self.imageURL = nil
                }
            } else {
                self.imageURL = nil
            }

            if let webStr = config.webURLString, let url = URL(string: webStr) {
                self.webURL = url
            } else {
                self.webURL = nil
            }

            if let actualWebStr = config.actualWebURLString, let url = URL(string: actualWebStr) {
                self.actualWebURL = url
            } else {
                self.actualWebURL = nil
            }
            if let path = config.textPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    self.textURL = url
                    do {
                        self.text = try Self.readTextContent(from: url)
                    } catch {
                        self.text = config.text
                    }
                } else {
                    self.textURL = nil
                    self.text = config.text
                }
            } else {
                self.textURL = nil
                self.text = config.text
            }
        }

        public func toConfig() -> WindowConfig {
            return WindowConfig(
                id: id,
                imagePath: imageURL?.path,
                webURLString: webURL?.absoluteString,
                actualWebURLString: actualWebURL?.absoluteString,
                originalImageName: originalImageName,
                imageSource: imageSource,
                text: text,
                isPinned: isPinned,
                opacity: opacity,
                windowFrame: windowFrame,
                showBorder: showBorder,
                imageScale: imageScale,
                textFontSize: textFontSize,
                isMarkdownPreview: isMarkdownPreview,
                createdAt: createdAt,
                svgColor: svgColor,
                backgroundColorHex: backgroundColorHex,
                textPath: textURL?.path,
                contentKind: HistoryContentKind.infer(from: WindowConfig(
                    id: id,
                    imagePath: imageURL?.path,
                    webURLString: webURL?.absoluteString,
                    originalImageName: originalImageName,
                    text: text,
                    isMarkdownPreview: isMarkdownPreview,
                    textPath: textURL?.path
                )),
                sourceFingerprint: sourceFingerprint,
                webZoom: webZoom,
                mediaPlaybackMode: mediaPlaybackMode,
                videoBookmark: videoBookmarkData,
                mediaSidecarBookmark: mediaSidecarBookmarkData,
                extensionID: extensionSession?.extensionID,
                extensionStateReference: extensionStateReference,
                navigatorPanelSide: navigatorPanelSide,
                navigatorPanelVisibilityMode: navigatorPanelVisibilityMode,
                navigatorPanelWidth: navigatorPanelWidth,
                fileList: fileList?.isPresentable == true ? fileList : nil
            )
        }

        /// 由 Core 保存完整的值类型 Session 快照；扩展缺失或状态损坏时保留可解释的占位展示。
        func restoreExtensionSession(from config: WindowConfig) {
            guard let extensionID = config.extensionID,
                  let reference = config.extensionStateReference else {
                extensionSession = nil
                return
            }
            do {
                if let envelope = try ExtensionHost.shared.stateStore.load(extensionID: extensionID, reference: reference),
                   let session = try? JSONDecoder().decode(ContentSession.self, from: envelope.payload),
                   (try? NavigatorContributionValidator.validate(session)) != nil,
                   ExtensionHost.shared.manager.isInstalledAndEnabled(extensionID) {
                    extensionSession = session
                } else {
                    extensionSession = ContentSession(
                        extensionID: extensionID,
                        providerID: "unavailable",
                        request: .restoredSession(extensionID: extensionID, stateReference: reference),
                        presentation: .unavailable(
                            titleKey: "Extension Session Unavailable",
                            messageKey: "Extension Session Restore Failed"
                        ),
                        stateReference: reference
                    )
                }
            } catch {
                extensionSession = ContentSession(
                    extensionID: extensionID,
                    providerID: "unavailable",
                    request: .restoredSession(extensionID: extensionID, stateReference: reference),
                    presentation: .unavailable(
                        titleKey: "Extension Session Unavailable",
                        messageKey: "Extension Session Restore Failed"
                    ),
                    stateReference: reference
                )
            }
        }

}
