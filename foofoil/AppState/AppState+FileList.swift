//
//  AppState+FileList.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import FoofoilExtensionKit

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
        navigatorMediaDurationBadges = [:]
        navigatorMediaDurationLoadingIDs = []
        stopImageListSlideshow()
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
        list.sections = list.sections.map { section in
            var resolved = section
            if let bookmark = section.cueSheetBookmark, let url = Self.resolveVideoBookmark(bookmark) {
                resolved.cueSheetPath = url.path
                if url.path != section.cueSheetPath {
                    resolved.cueSheetBookmark = Self.makeSecurityScopedBookmark(for: url) ?? bookmark
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
        scheduleImageListSlideshowAdvance()
    }

    func openFileGroup(_ group: FileListGroup, preservesIdentity: Bool, title: String? = nil) {
        switch group.kind {
        case .cueSheets:
            installCueSheets(urls: group.urls, preservesIdentity: preservesIdentity)
        case .listable(let kind) where group.urls.count >= 2:
            if kind == .audio {
                let sacd = group.urls.filter { FileListGrouper.isSACDISOFile($0) }
                if sacd.count == group.urls.count, let url = sacd.first {
                    openFile(url: url)
                    return
                }
            }
            installFileList(kind: kind, urls: group.urls, preservesIdentity: preservesIdentity, title: title)
        case .listable, .other:
            if let url = group.urls.first {
                openFile(url: url)
            }
        }
    }

    /// 当前 CUE 曲目的播放区间；普通音频为空。
    var currentPlaybackRange: MediaPlaybackRange? {
        fileList?.currentItem?.cue?.playbackRange
    }

    func installFileList(kind: FileListKind, urls: [URL], preservesIdentity: Bool, title: String? = nil) {
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
        fileList = FileListState(kind: kind, items: items, currentID: items[0].id, title: title)
        sourceFingerprint = nil
        mediaPlaybackMode = .sequentialLoop
        isBatchUpdating = false
        presentFileListItem(id: items[0].id, rotatesIdentity: false)
    }

    /// 将同类型文件追加到当前列表；单文件箔片会就地升级为列表并保留窗口 id。
    @discardableResult
    func appendToFileList(urls: [URL]) -> [URL] {
        guard let kind = listableKind else { return urls }
        if kind == .audio {
            let cueURLs = uniqueExistingURLs(urls).filter { FileListGrouper.isCueFile($0) }
            if !cueURLs.isEmpty {
                appendCueSheets(urls: cueURLs)
                return urls.filter { url in
                    !cueURLs.contains(where: {
                        $0.resolvingSymlinksInPath().standardizedFileURL.path
                            == url.resolvingSymlinksInPath().standardizedFileURL.path
                    })
                }
            }
        }
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
        var appendedSACDURLs: [URL] = []
        for url in incoming {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if existingPaths.contains(key) { continue }
            list.items.append(makeFileListItem(url: url))
            if kind == .audio, FileListGrouper.isSACDISOFile(url) {
                appendedSACDURLs.append(url)
            }
        }

        guard list.items.count >= 2 else { return leftover }

        let previousID = id
        fileList = list
        sourceFingerprint = nil
        id = previousID
        syncFileListNavigator()
        saveState()
        expandAppendedSACDContainers(urls: appendedSACDURLs)
        return leftover
    }

    /// 已有列表接收 SACD ISO 后，用一个不启动播放的临时 Hi-Fi 会话解析曲目，再原位展开为子目录。
    func expandAppendedSACDContainers(urls: [URL]) {
        for url in urls {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await ExtensionHost.shared.open(url: url)
                    let session = outcome.session
                    let queue = session.providerID == "audio.hifi" ? session.playbackQueue : nil
                    let bookmark = session.request.resources.first?.securityScopedBookmark
                        ?? Self.makeSecurityScopedBookmark(for: url)
                    await ExtensionHost.shared.closeSessionAndWait(session)
                    guard let queue, queue.items.count >= 2,
                          self.fileList?.items.contains(where: { item in
                              item.cue == nil
                                  && item.url.resolvingSymlinksInPath().standardizedFileURL.path
                                      == url.resolvingSymlinksInPath().standardizedFileURL.path
                          }) == true else { return }
                    self.installContainerAudioList(
                        url: url,
                        queue: queue,
                        bookmark: bookmark,
                        selectsContainerTrack: false
                    )
                    self.saveState()
                } catch {
                    NSLog("Failed to expand appended SACD ISO: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 已显示可列表内容时，拖放只接收当前类型；混入的其它文件直接忽略。批次含 CUE 时只收 CUE。
    @discardableResult
    func appendMatchingDroppedFiles(urls: [URL]) -> Bool {
        guard let kind = listableKind else { return false }
        let preferred = FileListGrouper.preferredOpenableURLs(from: urls.filter { canOpenFile(url: $0) })
        let matching = preferred.filter { url in
            if kind == .audio, FileListGrouper.isCueFile(url) { return true }
            return FileListGrouper.classify(url: url) == .listable(kind)
        }
        guard !matching.isEmpty else { return false }
        appendToFileList(urls: matching)
        return true
    }

    func matchingDroppedFiles(urls: [URL]) -> [URL] {
        let openable = urls.filter { canOpenFile(url: $0) }
        let preferred = FileListGrouper.preferredOpenableURLs(from: openable)
        guard let kind = currentDroppedFileKind else {
            return preferred
        }
        return preferred.filter { FileListGrouper.dropKind(url: $0) == kind }
    }

    func presentFileListItem(id: String, rotatesIdentity: Bool) {
        guard var list = fileList, let item = list.items.first(where: { $0.id == id }) else { return }
        list.currentID = id
        fileList = list

        guard let url = resolvedURL(for: item) else {
            syncFileListNavigator()
            saveState()
            scheduleImageListSlideshowAdvance()
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
        case .audio where ExtensionHost.shared.canOpen(url: url):
            if activateExistingHiFiContainerTrack(item) {
                syncFileListNavigator()
                saveState()
                return
            }
            openFileListAudioUsingExtension(url: url, itemID: item.id)
        case .video, .audio:
            currentMediaRouteGeneration &+= 1
            let routeGeneration = currentMediaRouteGeneration
            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil
            if let closeTask = extensionSessionCloseTask {
                isLoading = true
                Task { @MainActor [weak self] in
                    await closeTask.value
                    guard let self,
                          self.currentMediaRouteGeneration == routeGeneration,
                          self.fileList?.currentID == item.id else { return }
                    self.isLoading = false
                    self.applyExternalMedia(
                        url: url,
                        holdsSecurityAccess: false,
                        rotatesIdentity: rotatesIdentity,
                        clearsFileList: false
                    )
                }
            } else {
                isLoading = false
                applyExternalMedia(
                    url: url,
                    holdsSecurityAccess: false,
                    rotatesIdentity: rotatesIdentity,
                    clearsFileList: false
                )
            }
        }
        syncFileListNavigator()
        scheduleImageListSlideshowAdvance()
    }

    func activateAdjacentFileListItem(delta: Int, wraps: Bool = false) {
        guard let list = fileList, list.isPresentable,
              let index = list.items.firstIndex(where: { $0.id == list.currentID }) else { return }
        let count = list.items.count
        let next: Int
        if wraps {
            next = ((index + delta) % count + count) % count
        } else {
            next = index + delta
            guard list.items.indices.contains(next) else { return }
        }
        presentFileListItem(id: list.items[next].id, rotatesIdentity: false)
    }

    var canToggleImageListSlideshow: Bool {
        fileList?.isPresentable == true && fileList?.kind == .image
    }

    func setImageListSlideshowEnabled(_ enabled: Bool) {
        guard var list = fileList, list.kind == .image, list.isPresentable else { return }
        list.isSlideshowEnabled = enabled
        list.slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
        fileList = list
        saveState()
        scheduleImageListSlideshowAdvance()
    }

    func toggleImageListSlideshow() {
        setImageListSlideshowEnabled(!(fileList?.isSlideshowEnabled ?? false))
    }

    func setImageListSlideshowInterval(_ interval: TimeInterval) {
        SettingsStore.shared.imageListSlideshowInterval = interval
        guard var list = fileList, list.kind == .image else { return }
        list.slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
        fileList = list
        saveState()
    }

    func stopImageListSlideshow() {
        imageListSlideshowWorkItem?.cancel()
        imageListSlideshowWorkItem = nil
    }

    /// 到点后循环切到下一项；手动切图或开关变化会重置计时。
    func scheduleImageListSlideshowAdvance() {
        stopImageListSlideshow()
        guard canToggleImageListSlideshow, fileList?.isSlideshowEnabled == true else { return }
        let interval = SettingsStore.shared.imageListSlideshowInterval
        let workItem = DispatchWorkItem { [weak self] in
            self?.activateAdjacentFileListItem(delta: 1, wraps: true)
        }
        imageListSlideshowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
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
        guard fileList?.isPresentable == true else { return }
        switch mediaPlaybackMode {
        case .singleLoop:
            return
        case .sequential:
            activateAdjacentFileListItem(delta: 1, wraps: false)
        case .sequentialLoop:
            activateAdjacentFileListItem(delta: 1, wraps: true)
        case .shuffle:
            activateShuffledFileListItem()
        }
    }

    /// 系统上一首/下一首媒体键仅切换当前音视频列表；单文件时报告命令不可用。
    @discardableResult
    func activateMediaListItem(delta: Int) -> Bool {
        guard isExternalMediaDocument, fileList?.isPresentable == true else { return false }
        activateAdjacentFileListItem(delta: delta, wraps: true)
        return true
    }

    /// 随机切到另一项；仅一项时保持当前项。
    func activateShuffledFileListItem() {
        guard let list = fileList, list.isPresentable else { return }
        let candidates = list.items.filter { $0.id != list.currentID }
        guard let next = candidates.randomElement() else { return }
        presentFileListItem(id: next.id, rotatesIdentity: false)
    }

    func handleFileListNavigatorAction(_ action: NavigatorAction) {
        switch action.kind {
        case .activate:
            if let id = action.itemIDs.first {
                if let first = fileList?.items.first(where: { $0.cue?.sectionID == id }) {
                    presentFileListItem(id: first.id, rotatesIdentity: false)
                } else {
                    presentFileListItem(id: id, rotatesIdentity: false)
                }
            }
        case .remove:
            var ids = action.itemIDs
            if let list = fileList {
                for id in action.itemIDs where list.sections.contains(where: { $0.id == id }) {
                    ids.append(contentsOf: list.items.compactMap { $0.cue?.sectionID == id ? $0.id : nil })
                }
            }
            removeFileListItems(ids: ids)
        case .move:
            if let list = fileList,
               action.itemIDs.allSatisfy({ id in list.sections.contains(where: { $0.id == id }) }) {
                moveFileListSections(
                    ids: action.itemIDs,
                    destinationID: action.destinationItemID,
                    position: action.movePosition
                )
            } else {
                moveFileListItems(
                    ids: action.itemIDs,
                    destinationID: action.destinationItemID,
                    position: action.movePosition
                )
            }
        }
    }

    /// 只重排顶层容器；每个 CUE / SACD 内部曲目保持原始顺序，并同步改变连续播放顺序。
    func moveFileListSections(
        ids: [String],
        destinationID: String?,
        position: NavigatorMovePosition?
    ) {
        guard var list = fileList, list.sections.count >= 2, let position else { return }
        let movingIDs = Set(ids)
        let movingSections = list.sections.filter { movingIDs.contains($0.id) }
        guard movingSections.count == movingIDs.count else { return }

        var remainingSections = list.sections.filter { !movingIDs.contains($0.id) }
        let insertionIndex: Int
        switch position {
        case .end:
            guard destinationID == nil else { return }
            insertionIndex = remainingSections.endIndex
        case .before, .after:
            guard let destinationID,
                  let destinationIndex = remainingSections.firstIndex(where: { $0.id == destinationID }) else { return }
            insertionIndex = position == .before ? destinationIndex : remainingSections.index(after: destinationIndex)
        }
        remainingSections.insert(contentsOf: movingSections, at: insertionIndex)
        guard remainingSections != list.sections else { return }

        list.sections = remainingSections
        let sectionIDs = Set(remainingSections.map(\.id))
        let groupedItems = remainingSections.flatMap { section in
            list.items.filter { $0.cue?.sectionID == section.id }
        }
        let ungroupedItems = list.items.filter { item in
            guard let sectionID = item.cue?.sectionID else { return true }
            return !sectionIDs.contains(sectionID)
        }
        list.items = groupedItems + ungroupedItems
        fileList = list
        syncFileListNavigator()
        saveState()
    }

    /// 普通文件列表按稳定 ID 重排；CUE 曲目必须保持谱表定义的时间顺序。
    func moveFileListItems(
        ids: [String],
        destinationID: String?,
        position: NavigatorMovePosition?
    ) {
        guard var list = fileList,
              list.isReorderable,
              let position else { return }
        let movingIDs = Set(ids)
        let movingItems = list.items.filter { movingIDs.contains($0.id) }
        guard movingItems.count == movingIDs.count else { return }

        var remainingItems = list.items.filter { !movingIDs.contains($0.id) }
        let insertionIndex: Int
        switch position {
        case .end:
            guard destinationID == nil else { return }
            insertionIndex = remainingItems.endIndex
        case .before, .after:
            guard let destinationID,
                  let destinationIndex = remainingItems.firstIndex(where: { $0.id == destinationID }) else { return }
            insertionIndex = position == .before ? destinationIndex : remainingItems.index(after: destinationIndex)
        }
        remainingItems.insert(contentsOf: movingItems, at: insertionIndex)
        guard remainingItems != list.items else { return }

        list.items = remainingItems
        fileList = list
        syncFileListNavigator()
        saveState()
    }

    func removeFileListItems(ids: [String]) {
        guard var list = fileList else { return }
        let removing = Set(ids)
        let removedCurrent = removing.contains(list.currentID)
        list.items.removeAll { removing.contains($0.id) }
        let remainingSectionIDs = Set(list.items.compactMap(\.cue?.sectionID))
        list.sections.removeAll { !remainingSectionIDs.contains($0.id) }

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
            scheduleImageListSlideshowAdvance()
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
        scheduleImageListSlideshowAdvance()
    }

    func currentListableFileURL() -> URL? {
        if let item = fileList?.currentItem {
            return resolvedURL(for: item) ?? item.url
        }
        if isAudioDocument, let url = currentAudioPresentationURL {
            return url
        }
        if isVideoDocument {
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
        let useOutline = !list.sections.isEmpty && list.soleContainerFormat == nil
        if useOutline {
            expandedNavigatorItemIDs.formUnion(list.sections.map(\.id))
        }
        let items: [NavigatorItem]
        if useOutline {
            var rows: [NavigatorItem] = []
            for section in list.sections {
                rows.append(
                    NavigatorItem(
                        id: section.id,
                        title: section.title,
                        symbolName: "opticaldisc",
                        badge: NSLocalizedString(section.resolvedFormat.badgeLocalizationKey, comment: ""),
                        isEnabled: true,
                        isCurrent: false
                    )
                )
                for item in list.items where item.cue?.sectionID == section.id {
                    rows.append(makeNavigatorItem(for: item, in: list, parentID: section.id))
                }
            }
            for item in list.items where item.cue?.sectionID == nil {
                rows.append(makeNavigatorItem(for: item, in: list, parentID: nil))
            }
            items = rows
        } else {
            items = list.items.map { makeNavigatorItem(for: $0, in: list, parentID: nil) }
        }
        let canMove = list.isReorderable || list.sections.count >= 2
        builtInNavigatorContributions = [
            NavigatorContribution(
                id: Self.fileListNavigatorID,
                titleLocalizationKey: list.kind.navigatorTitleKey,
                style: useOutline ? .outline : .flat,
                selectionMode: .single,
                items: items,
                selectedItemIDs: [list.currentID],
                allowedActions: canMove ? [.activate, .remove, .move] : [.activate, .remove],
                revision: fileListRevision
            )
        ]
        builtInNavigatorActionHandler = { [weak self] action in
            self?.handleFileListNavigatorAction(action)
        }
        if activeNavigatorContributionID == nil {
            activeNavigatorContributionID = Self.fileListNavigatorID
        }
        loadNavigatorMediaDurationsIfNeeded(for: list)
    }

    func makeNavigatorItem(for item: FileListItem, in list: FileListState, parentID: String?) -> NavigatorItem {
        let accessible = resolvedURL(for: item) != nil
        return NavigatorItem(
            id: item.id,
            parentID: parentID,
            title: item.displayName,
            subtitle: accessible ? item.cue?.artist : NSLocalizedString("File List Item Unavailable", comment: ""),
            symbolName: list.kind.itemSymbolName,
            badge: cueSegmentDurationBadge(for: item) ?? navigatorMediaDurationBadges[item.id],
            isEnabled: accessible,
            isCurrent: item.id == list.currentID
        )
    }

    /// CUE / SACD 曲目在列表末尾显示分段时长；序号由导航行单独绘制。
    func cueSegmentDurationBadge(for item: FileListItem) -> String? {
        guard let seconds = cueSegmentDurationSeconds(for: item) else { return nil }
        return AudioMetadataLoader.formatDuration(seconds)
    }

    func cueSegmentDurationSeconds(for item: FileListItem) -> Double? {
        guard let cue = item.cue else { return nil }
        if let endFrames = cue.endCueFrames, endFrames > cue.startCueFrames {
            return CueTime.seconds(from: endFrames - cue.startCueFrames)
        }
        let audioURL = resolvedURL(for: item) ?? item.url
        let timing: AudioPlaybackTiming?
        if let path = cue.cueSheetPath {
            timing = CueSheetLoader.playbackTiming(
                audioURL: audioURL,
                cueURL: URL(fileURLWithPath: path)
            )
        } else {
            let accessed = audioURL.startAccessingSecurityScopedResource()
            defer { if accessed { audioURL.stopAccessingSecurityScopedResource() } }
            timing = AudioMetadataLoader.playbackTiming(for: audioURL)
        }
        guard let timing, timing.sampleRate > 0 else { return nil }
        let startSamples = CueTime.sampleFrame(cueFrames: cue.startCueFrames, sampleRate: timing.sampleRate)
        return Double(max(0, timing.sampleCount - startSamples)) / timing.sampleRate
    }

    /// 音视频时长可能触发文件 I/O，因此在后台完成后再仅刷新导航投影。
    func loadNavigatorMediaDurationsIfNeeded(for list: FileListState) {
        guard list.kind == .audio || list.kind == .video else { return }
        for item in list.items where item.cue == nil && navigatorMediaDurationBadges[item.id] == nil && !navigatorMediaDurationLoadingIDs.contains(item.id) {
            guard let url = resolvedURL(for: item) else { continue }
            let itemID = item.id
            let kind = list.kind
            navigatorMediaDurationLoadingIDs.insert(itemID)
            Task { [weak self] in
                let duration = await MediaDurationLoader.duration(for: url, kind: kind)
                await MainActor.run {
                    guard let self else { return }
                    self.navigatorMediaDurationLoadingIDs.remove(itemID)
                    guard self.fileList?.items.contains(where: { $0.id == itemID }) == true else { return }
                    if let duration, let badge = AudioMetadataLoader.formatDuration(duration) {
                        self.navigatorMediaDurationBadges[itemID] = badge
                        self.syncFileListNavigator()
                    }
                }
            }
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
            applyExternalMedia(
                url: url,
                holdsSecurityAccess: false,
                rotatesIdentity: false,
                clearsFileList: false
            )
        case .cueSheets:
            installCueSheets(urls: [url], preservesIdentity: true)
        case .other:
            openFile(url: url)
        }
    }

    /// 同一 SACD ISO 会话内切歌，不重建 Session、不重配 HAL。
    /// 自然播完后由 Hi-Fi Runtime 在 activate 时继续播放下一曲；此处只切换队列项。
    @discardableResult
    func activateExistingHiFiContainerTrack(_ item: FileListItem) -> Bool {
        guard let session = extensionSession,
              session.providerID == "audio.hifi",
              let queue = session.playbackQueue,
              let containerTrackID = containerTrackID(for: item, in: queue) else {
            return false
        }
        let sessionURL = session.request.primaryFileURL
        let itemURL = resolvedURL(for: item) ?? item.url
        if let sessionURL {
            let same = sessionURL.resolvingSymlinksInPath().standardizedFileURL.path
                == itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard same else { return false }
        }
        if queue.currentItemID != containerTrackID {
            performNavigatorAction(
                NavigatorAction(
                    contributionID: "hifi.playback-queue",
                    kind: .activate,
                    itemIDs: [containerTrackID]
                )
            )
        }
        return true
    }

    /// 新列表显式保存容器内部 ID；旧版持久化数据则按原 ID 或曲目序号兼容恢复。
    func containerTrackID(for item: FileListItem, in queue: MediaPlaybackQueueSnapshot) -> String? {
        if let id = item.cue?.containerTrackID,
           queue.items.contains(where: { $0.id == id }) {
            return id
        }
        if queue.items.contains(where: { $0.id == item.id }) {
            return item.id
        }
        if let number = item.cue?.trackNumber.flatMap(Int.init) {
            let index = number - 1
            if queue.items.indices.contains(index) {
                return queue.items[index].id
            }
        }
        return nil
    }

    func installContainerAudioList(
        url: URL,
        queue: MediaPlaybackQueueSnapshot,
        bookmark: Data?,
        selectsContainerTrack: Bool = true
    ) {
        guard queue.items.count >= 2 else { return }
        let sectionID = UUID().uuidString.lowercased()
        let album = FileListState.normalizedTitle(queue.title)
            ?? url.deletingPathExtension().lastPathComponent
        let section = FileListSection(
            id: sectionID,
            title: album,
            cueSheetPath: url.path,
            cueSheetBookmark: bookmark,
            format: .sacd
        )
        var start: Int64 = 0
        let items: [FileListItem] = queue.items.enumerated().map { index, item in
            let frames = Int64(((item.duration ?? 0) * Double(CueTime.timescale)).rounded())
            let cue = FileListCueInfo(
                startCueFrames: start,
                endCueFrames: start + max(0, frames),
                title: item.title,
                artist: item.subtitle,
                album: album,
                trackNumber: "\(index + 1)",
                sectionID: sectionID,
                cueSheetPath: url.path,
                containerTrackID: item.id
            )
            start += max(0, frames)
            return FileListItem(
                id: "sacd:\(sectionID):\(index):\(item.id)",
                path: url.path,
                bookmark: bookmark,
                displayName: item.title,
                cue: cue
            )
        }
        let currentID = queue.currentItemID.flatMap { id in
            items.first(where: { $0.cue?.containerTrackID == id })?.id
        }
            ?? items[0].id
        if var list = fileList,
           list.kind == .audio,
           let containerIndex = list.items.firstIndex(where: {
               $0.cue == nil && $0.url.resolvingSymlinksInPath().standardizedFileURL.path
                   == url.resolvingSymlinksInPath().standardizedFileURL.path
           }) {
            // 混合列表首次打开 ISO 时，将占位文件原位展开为 SACD 子目录并保留其它音频。
            list.items.replaceSubrange(containerIndex...containerIndex, with: items)
            list.sections.append(section)
            if selectsContainerTrack {
                list.currentID = currentID
            }
            fileList = list
        } else {
            fileList = FileListState(
                kind: .audio,
                items: items,
                currentID: currentID,
                title: album,
                sections: [section]
            )
        }
        mediaPlaybackMode = .sequentialLoop
        syncFileListNavigator()
    }

    func installCueSheets(urls: [URL], preservesIdentity: Bool) {
        let sheets = loadedCueSheets(from: urls)
        let items = sheets.flatMap(\.items)
        guard !items.isEmpty else { return }

        isBatchUpdating = true
        if !preservesIdentity, hasOpenedContent {
            id = UUID()
        }
        fileList = FileListState(
            kind: .audio,
            items: items,
            currentID: items[0].id,
            title: sheets.first?.section.title,
            sections: sheets.map(\.section)
        )
        sourceFingerprint = nil
        mediaPlaybackMode = .sequentialLoop
        isBatchUpdating = false
        presentFileListItem(id: items[0].id, rotatesIdentity: false)
    }

    func appendCueSheets(urls: [URL]) {
        let sheets = loadedCueSheets(from: urls)
        guard !sheets.isEmpty else { return }

        var list = fileList ?? FileListState(kind: .audio, items: [], currentID: "")
        if list.items.isEmpty, let currentURL = currentListableFileURL() {
            let currentItem = makeFileListItem(url: currentURL)
            list.items = [currentItem]
            list.currentID = currentItem.id
        }

        var existingCuePaths = Set(
            list.sections.compactMap { $0.cueSheetPath }.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
        for sheet in sheets {
            let key = sheet.section.cueSheetPath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
            if let key, existingCuePaths.contains(key) { continue }
            list.sections.append(sheet.section)
            list.items.append(contentsOf: sheet.items)
            if let key { existingCuePaths.insert(key) }
        }

        guard list.items.count >= 2 || list.items.contains(where: { $0.cue != nil }) else { return }

        let previousID = id
        if list.currentID.isEmpty, let first = list.items.first {
            list.currentID = first.id
        }
        fileList = list
        sourceFingerprint = nil
        id = previousID
        syncFileListNavigator()
        saveState()
    }

    func loadedCueSheets(from urls: [URL]) -> [(section: FileListSection, items: [FileListItem])] {
        uniqueExistingURLs(urls).compactMap { url in
            guard let sheet = CueSheetLoader.load(from: url) else { return nil }
            let section = makeCueSection(from: sheet)
            let items = makeCueItems(from: sheet, sectionID: section.id)
            guard !items.isEmpty else { return nil }
            return (section, items)
        }
    }

    func makeCueSection(from sheet: CueSheet) -> FileListSection {
        let accessed = sheet.url.startAccessingSecurityScopedResource()
        let bookmark = Self.makeSecurityScopedBookmark(for: sheet.url)
        if accessed { sheet.url.stopAccessingSecurityScopedResource() }
        return FileListSection(
            id: UUID().uuidString.lowercased(),
            title: sheet.displayTitle,
            cueSheetPath: sheet.url.path,
            cueSheetBookmark: bookmark,
            format: .cue
        )
    }

    func makeCueItems(from sheet: CueSheet, sectionID: String) -> [FileListItem] {
        sheet.tracks.compactMap { track in
            guard let audioURL = track.fileURL else { return nil }
            let accessed = audioURL.startAccessingSecurityScopedResource()
            let bookmark = Self.makeSecurityScopedBookmark(for: audioURL)
            if accessed { audioURL.stopAccessingSecurityScopedResource() }
            let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (title?.isEmpty == false ? title : nil)
                ?? audioURL.deletingPathExtension().lastPathComponent
            return FileListItem(
                id: UUID().uuidString.lowercased(),
                path: audioURL.path,
                bookmark: bookmark,
                displayName: displayName,
                cue: FileListCueInfo(
                    startCueFrames: track.startCueFrames,
                    endCueFrames: track.endCueFrames,
                    title: title,
                    artist: track.performer,
                    album: sheet.title,
                    composer: track.songwriter ?? sheet.songwriter,
                    genre: sheet.genre,
                    year: sheet.date,
                    trackNumber: "\(track.number)",
                    sectionID: sectionID,
                    cueSheetPath: sheet.url.path
                )
            )
        }
    }

    func beginCueRelatedAccess(for item: FileListItem) {
        guard let cuePath = item.cue?.cueSheetPath else { return }
        let cueURL: URL
        if let section = fileList?.sections.first(where: { $0.id == item.cue?.sectionID }),
           let bookmark = section.cueSheetBookmark,
           let resolved = Self.resolveVideoBookmark(bookmark) {
            cueURL = resolved
        } else {
            cueURL = URL(fileURLWithPath: cuePath)
        }
        let audioURL = resolvedURL(for: item) ?? item.url
        if cueURL.startAccessingSecurityScopedResource() {
            accessingCueURL = cueURL
        }
        let presenter = CueRelatedFilePresenter(primary: cueURL, related: audioURL)
        NSFileCoordinator.addFilePresenter(presenter)
        cueRelatedPresenter = presenter
    }
}
