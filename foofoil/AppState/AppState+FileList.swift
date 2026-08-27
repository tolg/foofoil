//
//  AppState+FileList.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    static let fileListNavigatorID = "builtin.file-list"

    var hasOpenedContent: Bool {
        imageURL != nil
            || webURL != nil
            || textURL != nil
            || extensionSession != nil
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前箔片能否作为同类型列表的宿主（含尚未形成列表的单个图片/视频/音频）。
    var listableKind: FileListKind? {
        if let fileList { return fileList.kind }
        if isPDFDocument { return nil }
        if isVideoDocument { return .video }
        if isAudioDocument { return .audio }
        if imageURL != nil, webURL == nil { return .image }
        return nil
    }

    /// 非空箔片锁定其文件类型，拖放不能用其它类型替换当前内容。
    var currentDroppedFileKind: DroppedFileKind? {
        if webURL != nil { return .web }
        if isPDFDocument { return .pdf }
        if isVideoDocument { return .video }
        if isAudioDocument { return .audio }
        if imageURL != nil { return .image }
        if textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text }
        if extensionSession != nil {
            return .other((originalImageName as NSString?)?.pathExtension.lowercased() ?? "")
        }
        return nil
    }

    func resetFileList() {
        fileList = nil
        fileListRevision = 0
        builtInNavigatorContributions = []
        builtInNavigatorActionHandler = nil
        isNavigatorPanelExplicitlyVisible = false
        activeNavigatorContributionID = nil
        expandedNavigatorItemIDs = []
    }

    func restoreFileList(from config: WindowConfig) {
        guard var list = config.fileList, list.isPresentable else {
            resetFileList()
            return
        }
        list.items = list.items.map { item in
            var resolved = item
            if let bookmark = item.bookmark, let url = Self.resolveVideoBookmark(bookmark) {
                resolved.path = url.path
                if url.path != item.path {
                    resolved.bookmark = Self.makeSecurityScopedBookmark(for: url) ?? bookmark
                }
            }
            return resolved
        }
        if list.currentItem == nil, let first = list.items.first {
            list.currentID = first.id
        }
        fileList = list
        sourceFingerprint = nil
        syncFileListNavigator()
    }

    func openFileGroup(_ group: FileListGroup, preservesIdentity: Bool) {
        switch group.kind {
        case .listable(let kind) where group.urls.count >= 2:
            installFileList(kind: kind, urls: group.urls, preservesIdentity: preservesIdentity)
        case .listable, .other:
            if let url = group.urls.first {
                openFile(url: url)
            }
        }
    }

    func installFileList(kind: FileListKind, urls: [URL], preservesIdentity: Bool) {
        let unique = uniqueExistingURLs(urls)
        guard unique.count >= 2 else {
            if let url = unique.first {
                openFile(url: url)
            }
            return
        }

        isBatchUpdating = true
        if !preservesIdentity, hasOpenedContent {
            id = UUID()
        }
        let items = unique.map(makeFileListItem)
        fileList = FileListState(kind: kind, items: items, currentID: items[0].id)
        sourceFingerprint = nil
        isVideoLooping = true
        isBatchUpdating = false
        presentFileListItem(id: items[0].id, rotatesIdentity: false)
    }

    /// 将同类型文件追加到当前列表；单文件箔片会就地升级为列表并保留窗口 id。
    @discardableResult
    func appendToFileList(urls: [URL]) -> [URL] {
        guard let kind = listableKind else { return urls }
        let incoming = uniqueExistingURLs(urls).filter { FileListGrouper.classify(url: $0) == .listable(kind) }
        let leftover = urls.filter { url in
            !incoming.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path })
        }

        guard !incoming.isEmpty else { return leftover }

        var list = fileList ?? FileListState(kind: kind, items: [], currentID: "")
        if list.items.isEmpty, let currentURL = currentListableFileURL() {
            let currentItem = makeFileListItem(url: currentURL)
            list.items = [currentItem]
            list.currentID = currentItem.id
        }

        let existingPaths = Set(list.items.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path })
        for url in incoming {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if existingPaths.contains(key) { continue }
            list.items.append(makeFileListItem(url: url))
        }

        guard list.items.count >= 2 else { return leftover }

        let previousID = id
        fileList = list
        sourceFingerprint = nil
        id = previousID
        syncFileListNavigator()
        saveState()
        return leftover
    }

    /// 已显示可列表内容时，拖放只接收当前类型；混入的其它文件直接忽略。
    @discardableResult
    func appendMatchingDroppedFiles(urls: [URL]) -> Bool {
        guard let kind = listableKind else { return false }
        let matching = urls.filter {
            canOpenFile(url: $0) && FileListGrouper.classify(url: $0) == .listable(kind)
        }
        guard !matching.isEmpty else { return false }
        appendToFileList(urls: matching)
        return true
    }

    func matchingDroppedFiles(urls: [URL]) -> [URL] {
        guard let kind = currentDroppedFileKind else {
            return urls.filter { canOpenFile(url: $0) }
        }
        return urls.filter {
            canOpenFile(url: $0) && FileListGrouper.dropKind(url: $0) == kind
        }
    }

    func presentFileListItem(id: String, rotatesIdentity: Bool) {
        guard var list = fileList, let item = list.items.first(where: { $0.id == id }) else { return }
        list.currentID = id
        fileList = list

        guard let url = resolvedURL(for: item) else {
            syncFileListNavigator()
            saveState()
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        switch list.kind {
        case .image:
            applyImage(
                url: url,
                originalName: item.displayName,
                rotatesIdentity: rotatesIdentity,
                clearsFileList: false,
                cacheToken: item.id
            )
        case .video, .audio:
            applyExternalMedia(url: url, holdsSecurityAccess: false, rotatesIdentity: rotatesIdentity, clearsFileList: false)
        }
        syncFileListNavigator()
    }

    func activateAdjacentFileListItem(delta: Int) {
        guard let list = fileList, list.isPresentable,
              let index = list.items.firstIndex(where: { $0.id == list.currentID }) else { return }
        let next = index + delta
        guard list.items.indices.contains(next) else { return }
        presentFileListItem(id: list.items[next].id, rotatesIdentity: false)
    }

    /// 右/下/⌃N/⌃F 下一项，左/上/⌃P/⌃B 上一项。
    @discardableResult
    func handleFileListKeyDown(_ event: NSEvent) -> Bool {
        guard fileList?.isPresentable == true, !isPDFDocument else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty {
            switch event.keyCode {
            case 123, 126:
                activateAdjacentFileListItem(delta: -1)
                return true
            case 124, 125:
                activateAdjacentFileListItem(delta: 1)
                return true
            default:
                return false
            }
        }
        guard modifiers == .control else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n", "f":
            activateAdjacentFileListItem(delta: 1)
            return true
        case "p", "b":
            activateAdjacentFileListItem(delta: -1)
            return true
        default:
            return false
        }
    }

    func advanceFileListAfterPlayback() {
        guard !isVideoLooping else { return }
        activateAdjacentFileListItem(delta: 1)
    }

    func handleFileListNavigatorAction(_ action: NavigatorAction) {
        switch action.kind {
        case .activate:
            if let id = action.itemIDs.first {
                presentFileListItem(id: id, rotatesIdentity: false)
            }
        case .remove:
            removeFileListItems(ids: action.itemIDs)
        case .move:
            break
        }
    }

    func removeFileListItems(ids: [String]) {
        guard var list = fileList else { return }
        let removing = Set(ids)
        let removedCurrent = removing.contains(list.currentID)
        list.items.removeAll { removing.contains($0.id) }

        if list.items.count < 2 {
            let remaining = list.items.first
            fileList = nil
            builtInNavigatorContributions = []
            builtInNavigatorActionHandler = nil
            isNavigatorPanelExplicitlyVisible = false
            activeNavigatorContributionID = nil
            if let remaining {
                sourceFingerprint = Self.localSourceFingerprint(for: remaining.url)
                if removedCurrent {
                    revealStandaloneFile(remaining)
                }
            }
            saveState()
            return
        }

        if removedCurrent, let first = list.items.first {
            list.currentID = first.id
            fileList = list
            presentFileListItem(id: first.id, rotatesIdentity: false)
            return
        }

        fileList = list
        syncFileListNavigator()
        saveState()
    }

    func currentListableFileURL() -> URL? {
        if let item = fileList?.currentItem {
            return resolvedURL(for: item) ?? item.url
        }
        if isExternalMediaDocument {
            return imageURL
        }
        if let fingerprint = sourceFingerprint, fingerprint.hasPrefix("file:") {
            let path = String(fingerprint.dropFirst("file:".count))
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return imageURL
    }

    func resolvedURL(for item: FileListItem) -> URL? {
        if let bookmark = item.bookmark, let url = Self.resolveVideoBookmark(bookmark) {
            return url
        }
        let url = item.url
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func syncFileListNavigator() {
        guard let list = fileList, list.isPresentable else {
            builtInNavigatorContributions = []
            builtInNavigatorActionHandler = nil
            return
        }

        fileListRevision &+= 1
        let items = list.items.map { item in
            let accessible = resolvedURL(for: item) != nil
            return NavigatorItem(
                id: item.id,
                title: item.displayName,
                subtitle: accessible ? nil : NSLocalizedString("File List Item Unavailable", comment: ""),
                symbolName: list.kind.itemSymbolName,
                isEnabled: accessible,
                isCurrent: item.id == list.currentID
            )
        }
        builtInNavigatorContributions = [
            NavigatorContribution(
                id: Self.fileListNavigatorID,
                titleLocalizationKey: list.kind.navigatorTitleKey,
                style: .flat,
                selectionMode: .single,
                items: items,
                selectedItemIDs: [list.currentID],
                allowedActions: [.activate, .remove],
                revision: fileListRevision
            )
        ]
        builtInNavigatorActionHandler = { [weak self] action in
            self?.handleFileListNavigatorAction(action)
        }
        if activeNavigatorContributionID == nil {
            activeNavigatorContributionID = Self.fileListNavigatorID
        }
    }

    func makeFileListItem(url: URL) -> FileListItem {
        let accessed = url.startAccessingSecurityScopedResource()
        let bookmark = Self.makeSecurityScopedBookmark(for: url)
        if accessed {
            url.stopAccessingSecurityScopedResource()
        }
        return FileListItem(
            id: UUID().uuidString.lowercased(),
            path: url.path,
            bookmark: bookmark,
            displayName: url.lastPathComponent
        )
    }

    private func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            let exists = FileManager.default.fileExists(atPath: url.path)
            if accessed { url.stopAccessingSecurityScopedResource() }
            guard exists else { continue }
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private func revealStandaloneFile(_ item: FileListItem) {
        guard let url = resolvedURL(for: item) ?? (FileManager.default.fileExists(atPath: item.path) ? item.url : nil) else {
            return
        }
        switch FileListGrouper.classify(url: url) {
        case .listable(.image):
            applyImage(url: url, originalName: item.displayName, rotatesIdentity: false, clearsFileList: false, cacheToken: item.id)
        case .listable(.video), .listable(.audio):
            applyExternalMedia(url: url, holdsSecurityAccess: false, rotatesIdentity: false, clearsFileList: false)
        case .other:
            openFile(url: url)
        }
    }
}
