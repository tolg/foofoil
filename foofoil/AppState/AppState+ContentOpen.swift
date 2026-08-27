//  AppState+ContentOpen.swift
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
        public func openImage(url: URL) {
            applyImage(url: url, originalName: url.lastPathComponent, rotatesIdentity: true, clearsFileList: true)
        }

        func applyImage(
            url: URL,
            originalName: String,
            rotatesIdentity: Bool,
            clearsFileList: Bool,
            cacheToken: String? = nil
        ) {
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            if rotatesIdentity, hasOpenedContent {
                self.id = UUID()
            }
            if clearsFileList {
                resetFileList()
            }
            self.originalImageName = originalName
            self.sourceFingerprint = fileList == nil ? Self.localSourceFingerprint(for: url) : nil
            self.imageSource = nil
            // 列表内切项保留边框；新打开图片仍默认无边框。
            if clearsFileList || imageURL == nil {
                self.showBorder = false
            }
            self.createdAt = Date()
            self.webURL = nil
            self.actualWebURL = nil
            if let cachedURL = cacheImage(from: url, itemToken: cacheToken) {
                self.imageURL = cachedURL
            } else {
                self.imageURL = url
            }
        }

        /// 打开本地视频；与图片不同，视频不复制到缓存目录，仅记录原始路径。
        public func openVideo(url: URL) {
            openExternalMedia(url: url, holdsSecurityAccess: false)
        }

        /// 打开本地音频；与视频相同，不复制到缓存目录，仅记录原始路径。
        public func openAudio(url: URL) {
            openExternalMedia(url: url, holdsSecurityAccess: false)
        }

        /// 打开本地音视频：引用原始文件并创建安全范围书签。
        /// - Parameter holdsSecurityAccess: 调用方已对 `url` 调用过 `startAccessingSecurityScopedResource` 且交由本窗口持有。
        func openExternalMedia(url: URL, holdsSecurityAccess: Bool) {
            applyExternalMedia(url: url, holdsSecurityAccess: holdsSecurityAccess, rotatesIdentity: true, clearsFileList: true)
        }

        func applyExternalMedia(url: URL, holdsSecurityAccess: Bool, rotatesIdentity: Bool, clearsFileList: Bool) {
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            if rotatesIdentity, hasOpenedContent {
                self.id = UUID()
            }
            if clearsFileList {
                resetFileList()
            }
            stopVideoAccess()
            self.originalImageName = url.lastPathComponent
            self.sourceFingerprint = fileList == nil ? Self.localSourceFingerprint(for: url) : nil
            self.imageSource = nil
            if clearsFileList || imageURL == nil {
                self.showBorder = false
            }
            self.imageScale = 1.0
            if clearsFileList {
                // 新打开的媒体恢复默认顺序循环；列表内切项保留用户选择
                self.mediaPlaybackMode = .sequentialLoop
            }
            self.createdAt = Date()
            self.webURL = nil
            self.actualWebURL = nil
            // 窗口打开期间保持沙盒访问，同目录封面才能作为关联项读取
            if holdsSecurityAccess {
                accessingVideoURL = url
            } else if url.startAccessingSecurityScopedResource() {
                accessingVideoURL = url
            }
            // 创建安全范围书签，保证 app 重启后仍能访问原始文件
            self.videoBookmarkData = Self.makeSecurityScopedBookmark(for: url)
            if var list = fileList, let index = list.items.firstIndex(where: { $0.id == list.currentID }) {
                list.items[index].path = url.path
                list.items[index].bookmark = videoBookmarkData
                fileList = list
            }
            self.imageURL = url
        }

        /// 停止当前媒体文件的安全范围访问授权。
        func stopVideoAccess() {
            accessingVideoURL?.stopAccessingSecurityScopedResource()
            accessingVideoURL = nil
        }

        /// 从历史配置恢复视频文件的沙盒访问：优先解析安全范围书签重新授权；
        /// 书签缺失或失效时，进程内仍有授权（如拖入后未重启）则直接使用原始路径。
        /// 返回 (播放 URL, 应持久化的书签, 已持有授权的 URL)；无法访问时返回 nil。
        static func restoreVideoAccess(config: WindowConfig, fallbackURL: URL) -> (url: URL, bookmark: Data?, accessedURL: URL?)? {
            if let bookmark = config.videoBookmark {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &isStale
                ) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    if FileManager.default.fileExists(atPath: url.path) {
                        // 书签过期（如文件被移动）时按解析出的新位置重建并持久化
                        let newBookmark = isStale ? Self.makeSecurityScopedBookmark(for: url) : bookmark
                        return (url, newBookmark, accessed ? url : nil)
                    }
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }
            guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
            return (fallbackURL, Self.makeSecurityScopedBookmark(for: fallbackURL), nil)
        }

        /// UTType 对音视频的声明较宽（MKV/AVI 等也归为 movie），需再确认 macOS 原生可播放后才打开。
        /// - Parameter holdsSecurityAccess: 已对 `url` 取得安全范围访问；不可播放时由本方法释放，可播放时转交窗口持有。
        func openExternalMediaIfPlayable(url: URL, holdsSecurityAccess: Bool = false) {
            let asset = AVURLAsset(url: url)
            Task { @MainActor [weak self] in
                let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                guard isPlayable, let self else {
                    if holdsSecurityAccess { url.stopAccessingSecurityScopedResource() }
                    return
                }
                self.openExternalMedia(url: url, holdsSecurityAccess: holdsSecurityAccess)
            }
        }

        public func openWeb(url: URL) {
            resetFileList()
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            let cachedURL: URL
            if url.isFileURL {
                guard let copiedURL = cacheImportedFile(from: url, kind: "web", for: targetID) else { return }
                cachedURL = copiedURL
            } else {
                // 远程网页以 URL 为内容来源，不属于本地文件缓存。
                cachedURL = url
            }

            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            self.id = targetID
            self.sourceFingerprint = Self.localSourceFingerprint(for: url)
            self.originalImageName = url.lastPathComponent
            self.imageSource = nil
            self.showBorder = true
            self.imageScale = 1.0
            self.createdAt = Date()
            self.imageURL = nil
            self.webURL = cachedURL
            self.actualWebURL = nil
        }

        static func readTextContent(from url: URL) throws -> String {
            // 1. 尝试以系统的自动编码探测读取
            var usedEncoding: String.Encoding = .utf8
            if let content = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
                return content
            }

            // 2. 尝试显式以 UTF-8 读取
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }

            // 3. 尝试以 GBK / GB18030 读取
            let gbkEncodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            let gbkEncoding = String.Encoding(rawValue: gbkEncodingValue)
            if let content = try? String(contentsOf: url, encoding: gbkEncoding) {
                return content
            }

            // 4. 尝试以 UTF-16 读取
            if let content = try? String(contentsOf: url, encoding: .utf16) {
                return content
            }

            // 5. 尝试以 Windows CP1252 / ASCII 读取
            if let content = try? String(contentsOf: url, encoding: .ascii) {
                return content
            }
            if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
                return content
            }

            // 兜底：如果都失败，抛出最后的异常（用 utf8 读取抛出的错误，这样至少有报错堆栈）
            return try String(contentsOf: url, encoding: .utf8)
        }

        public func openTextFile(url: URL) {
            resetFileList()
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            guard let cachedURL = cacheImportedFile(from: url, kind: "text", for: targetID) else { return }

            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }

            do {
                let content = try Self.readTextContent(from: cachedURL)
                self.id = targetID
                self.sourceFingerprint = Self.localSourceFingerprint(for: url)
                self.text = content
                self.textURL = cachedURL
                self.originalImageName = url.lastPathComponent
                self.imageSource = nil
                self.imageURL = nil
                self.webURL = nil
                self.actualWebURL = nil
                self.showBorder = true
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" {
                    self.isMarkdownPreview = true
                } else {
                    self.isMarkdownPreview = false
                }
                self.createdAt = Date()
            } catch {
                print("Failed to read text file: \(error)")
            }
        }

        func isTextFile(url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            let webExtensions = ["html", "htm", "webarchive", "xhtml"]
            if webExtensions.contains(ext) {
                return false
            }

            let textExtensions = ["txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "ini", "conf", "plist", "log", "swift", "py", "js", "ts", "sh", "css", "php", "c", "cpp", "h", "java", "go", "rs", "sql", "rb"]
            if textExtensions.contains(ext) {
                return true
            }

            if let type = UTType(filenameExtension: ext) {
                if ext == "svg" || type.conforms(to: .svg) {
                    return false
                }
                return type.conforms(to: .text)
            }
            return false
        }

        /// 判断本应用能否按内容打开本地文件，避免将未知文件的 Finder 图标当成图片。
        public func canOpenFile(url: URL) -> Bool {
            guard url.isFileURL else { return false }

            if ExtensionHost.shared.canOpen(url: url) { return true }

            let ext = url.pathExtension.lowercased()
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) || isTextFile(url: url) {
                return true
            }
            if Self.isExternalMediaFile(url: url) {
                return true
            }
            if NSImage(contentsOf: url) != nil {
                return true
            }
            return ExtensionHost.shared.manager.availableExtension(for: url) != nil
        }

        public func openFile(url: URL) {
            guard canOpenFile(url: url) else { return }

            resetFileList()

            if ExtensionHost.shared.canOpen(url: url) {
                openUsingExtension(url: url)
                return
            }

            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil

            let ext = url.pathExtension.lowercased()
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) {
                openWeb(url: url)
            } else if isTextFile(url: url) {
                openTextFile(url: url)
            } else if Self.isExternalMediaFile(url: url) {
                let accessed = url.startAccessingSecurityScopedResource()
                openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
            } else if NSImage(contentsOf: url) != nil {
                openImage(url: url)
            } else if let available = ExtensionHost.shared.manager.availableExtension(for: url) {
                promptToInstall(available, opening: url)
            }
        }

        func openUsingExtension(url: URL) {
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || extensionSession != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            isLoading = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isLoading = false }
                do {
                    let outcome = try await ExtensionHost.shared.open(url: url)
                    self.isBatchUpdating = true
                    self.id = targetID
                    self.stopVideoAccess()
                    self.imageURL = nil
                    self.webURL = nil
                    self.actualWebURL = nil
                    self.textURL = nil
                    self.text = ""
                    self.originalImageName = url.lastPathComponent
                    self.sourceFingerprint = Self.localSourceFingerprint(for: url)
                    self.extensionSession = outcome.session
                    self.extensionFallbackProviderID = outcome.failures.first?.providerID
                    self.extensionStateReference = nil
                    if let extensionID = outcome.session.extensionID {
                        let payload = try JSONEncoder().encode(outcome.session)
                        self.extensionStateReference = try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: outcome.session.id.uuidString.lowercased()
                        )
                    }
                    self.isBatchUpdating = false
                    self.saveState()
                } catch {
                    self.isBatchUpdating = false
                    NSLog("Extension session failed: \(error.localizedDescription)")
                }
            }
        }

        func promptToInstall(_ entry: ExtensionRegistryEntry, opening url: URL) {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Install Extension Title Format", comment: ""), entry.name)
            alert.informativeText = String(
                format: NSLocalizedString("Install Extension Message Format", comment: ""),
                entry.name
            )
            alert.addButton(withTitle: NSLocalizedString("Install and Open", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            isLoading = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await ExtensionHost.shared.manager.install(entry.id)
                    self.openUsingExtension(url: url)
                } catch {
                    self.isLoading = false
                    let failed = NSAlert()
                    failed.messageText = NSLocalizedString("Extension Install Failed Title", comment: "")
                    failed.informativeText = error.localizedDescription
                    failed.runModal()
                }
            }
        }

        func performExtensionCommand(_ commandID: String) {
            guard let session = extensionSession else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let updated = try await ExtensionHost.shared.perform(commandID: commandID, in: session)
                    self.extensionSession = updated
                    if let extensionID = updated.extensionID,
                       let reference = self.extensionStateReference {
                        let payload = try JSONEncoder().encode(updated)
                        try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: reference
                        )
                    }
                    self.saveState()
                } catch {
                    NSLog("Extension command failed: \(error.localizedDescription)")
                }
            }
        }

        func performNavigatorAction(_ action: NavigatorAction) {
            if let session = extensionSession {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let updated = try await ExtensionHost.shared.perform(
                            navigatorAction: action,
                            in: session
                        )
                        self.extensionSession = updated
                        if let extensionID = updated.extensionID,
                           let reference = self.extensionStateReference {
                            let payload = try JSONEncoder().encode(updated)
                            try ExtensionHost.shared.stateStore.save(
                                extensionID: extensionID,
                                schemaVersion: 1,
                                payload: payload,
                                reference: reference
                            )
                        }
                        self.saveState()
                    } catch {
                        NSLog("Navigator action failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            guard let contribution = builtInNavigatorContributions.first(where: {
                $0.id == action.contributionID
            }) else { return }
            do {
                try NavigatorContributionValidator.validate(action, in: contribution)
                builtInNavigatorActionHandler?(action)
            } catch {
                NSLog("Built-in navigator action failed validation: \(error.localizedDescription)")
            }
        }

        @discardableResult
        public func copyCurrentImageToPasteboard() -> Bool {
            guard webURL == nil,
                  let imageURL,
                  let image = NSImage(contentsOf: imageURL) else {
                return false
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        }

        public func saveWebScreenshot(_ image: NSImage, triggerSavePanel: Bool = false) {
            guard webURL != nil else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                guard let tiffData = image.tiffRepresentation,
                      let bitmapImage = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                    return
                }

                guard let destURL = self.getCachedImageURL(extension: "png") else { return }

                do {
                    try pngData.write(to: destURL)
                    DispatchQueue.main.async {
                        guard self.webURL != nil else { return }
                        self.imageURL = destURL

                        if triggerSavePanel {
                            NotificationCenter.default.post(
                                name: .webSnapshotReadyForSave,
                                object: nil,
                                userInfo: ["id": self.id]
                            )
                        }
                    }
                } catch {
                    print("Failed to save web screenshot: \(error)")
                }
            }
        }

        public func openImage(image: NSImage, originalName: String? = nil, imageSource: ImageSource? = nil) {
            if hasOpenedContent {
                self.id = UUID()
            }
            resetFileList()
            self.isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                guard let tiffData = image.tiffRepresentation,
                      let bitmapImage = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return
                }

                self.clearCachedImages()
                guard let destURL = self.getCachedImageURL(extension: "png") else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return
                }

                do {
                    try pngData.write(to: destURL)
                    DispatchQueue.main.async {
                        self.isBatchUpdating = true
                        self.sourceFingerprint = nil
                        self.originalImageName = originalName ?? "dropped_image.png"
                        self.imageSource = imageSource
                        self.showBorder = false
                        self.createdAt = Date()
                        self.webURL = nil
                        self.actualWebURL = nil
                        self.imageURL = destURL
                        self.isBatchUpdating = false
                        self.isLoading = false
                        self.saveState()
                    }
                } catch {
                    print("Failed to save dropped image to cache: \(error)")
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
            }
        }
}
