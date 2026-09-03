//
//  FileList.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreMedia

public nonisolated enum FileListKind: String, Codable, Sendable {
    case image
    case video
    case audio

    var navigatorTitleKey: String {
        switch self {
        case .image: "Image List"
        case .video: "Video List"
        case .audio: "Audio List"
        }
    }

    var historyTitleFormatKey: String {
        switch self {
        case .image: "Image List History Format"
        case .video: "Video List History Format"
        case .audio: "Audio List History Format"
        }
    }

    var historySymbolName: String {
        switch self {
        case .image: "photo.on.rectangle"
        case .video: "film.stack"
        case .audio: "music.note.list"
        }
    }

    var itemSymbolName: String {
        switch self {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "music.note"
        }
    }

    var allowedContentTypes: [UTType] {
        switch self {
        case .image:
            return [.image]
        case .video:
            return [.movie]
        case .audio:
            var types: [UTType] = [.audio]
            if let cue = UTType(filenameExtension: "cue") {
                types.append(cue)
            }
            return types
        }
    }
}

public nonisolated enum FileOpenKind: Equatable, Sendable {
    case listable(FileListKind)
    case cueSheets
    case other
}

nonisolated enum DroppedFileKind: Equatable {
    case image
    case video
    case audio
    case pdf
    case web
    case text
    case other(String)
}

public nonisolated struct FileListItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var path: String
    public var bookmark: Data?
    public var displayName: String
    /// CUE 曲目分段信息；普通文件列表项为空。
    public var cue: FileListCueInfo?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(
        id: String,
        path: String,
        bookmark: Data? = nil,
        displayName: String,
        cue: FileListCueInfo? = nil
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.displayName = displayName
        self.cue = cue
    }
}

/// 侧边栏中一个 CUE 专辑分区。
public nonisolated struct FileListSection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var cueSheetPath: String?
    public var cueSheetBookmark: Data?

    public init(id: String, title: String, cueSheetPath: String? = nil, cueSheetBookmark: Data? = nil) {
        self.id = id
        self.title = title
        self.cueSheetPath = cueSheetPath
        self.cueSheetBookmark = cueSheetBookmark
    }
}

/// 播放区间：CUE 帧计数（1 秒 = 75 帧）。seek 时转成 CMTime(timescale: 75)。
public nonisolated struct MediaPlaybackRange: Equatable, Sendable {
    public var startCueFrames: Int64
    public var endCueFrames: Int64?

    public init(startCueFrames: Int64, endCueFrames: Int64? = nil) {
        self.startCueFrames = startCueFrames
        self.endCueFrames = endCueFrames
    }
}

public nonisolated struct FileListCueInfo: Codable, Equatable, Sendable {
    public var startCueFrames: Int64
    public var endCueFrames: Int64?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var composer: String?
    public var genre: String?
    public var year: String?
    public var trackNumber: String?
    public var sectionID: String?
    public var cueSheetPath: String?

    public var startSeconds: Double { CueTime.seconds(from: startCueFrames) }
    public var endSeconds: Double? { endCueFrames.map(CueTime.seconds(from:)) }

    public init(
        startCueFrames: Int64,
        endCueFrames: Int64? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        composer: String? = nil,
        genre: String? = nil,
        year: String? = nil,
        trackNumber: String? = nil,
        sectionID: String? = nil,
        cueSheetPath: String? = nil
    ) {
        self.startCueFrames = startCueFrames
        self.endCueFrames = endCueFrames
        self.title = title
        self.artist = artist
        self.album = album
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.sectionID = sectionID
        self.cueSheetPath = cueSheetPath
    }

    public var playbackRange: MediaPlaybackRange? {
        if startCueFrames <= 0, endCueFrames == nil { return nil }
        return MediaPlaybackRange(startCueFrames: max(0, startCueFrames), endCueFrames: endCueFrames)
    }

    private enum CodingKeys: String, CodingKey {
        case startCueFrames, endCueFrames, startSeconds, endSeconds
        case title, artist, album, composer, genre, year, trackNumber, sectionID, cueSheetPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let frames = try container.decodeIfPresent(Int64.self, forKey: .startCueFrames) {
            startCueFrames = frames
        } else {
            let seconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
            startCueFrames = Int64((seconds * Double(CueTime.timescale)).rounded())
        }
        if let frames = try container.decodeIfPresent(Int64.self, forKey: .endCueFrames) {
            endCueFrames = frames
        } else if let seconds = try container.decodeIfPresent(Double.self, forKey: .endSeconds) {
            endCueFrames = Int64((seconds * Double(CueTime.timescale)).rounded())
        } else {
            endCueFrames = nil
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        composer = try container.decodeIfPresent(String.self, forKey: .composer)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        trackNumber = try container.decodeIfPresent(String.self, forKey: .trackNumber)
        sectionID = try container.decodeIfPresent(String.self, forKey: .sectionID)
        cueSheetPath = try container.decodeIfPresent(String.self, forKey: .cueSheetPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startCueFrames, forKey: .startCueFrames)
        try container.encodeIfPresent(endCueFrames, forKey: .endCueFrames)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(composer, forKey: .composer)
        try container.encode(genre, forKey: .genre)
        try container.encode(year, forKey: .year)
        try container.encode(trackNumber, forKey: .trackNumber)
        try container.encode(sectionID, forKey: .sectionID)
        try container.encode(cueSheetPath, forKey: .cueSheetPath)
    }
}

/// 图片列表轮播：默认 5 秒，设置里可调，数值走 clamp。
public nonisolated enum ImageListSlideshow {
    public static let defaultInterval: TimeInterval = 5
    public static let minInterval: TimeInterval = 1
    public static let maxInterval: TimeInterval = 60
    public static let transitionDuration: TimeInterval = 0.45

    public static var transitionAnimation: Animation {
        .easeInOut(duration: transitionDuration)
    }

    public static func clampInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minInterval), maxInterval)
    }
}

public nonisolated struct FileListState: Codable, Equatable, Sendable {
    public var kind: FileListKind
    public var items: [FileListItem]
    public var currentID: String
    /// 用户设置的列表标题；为空时展示本地化的“类型 + 项数”回退标题。
    public var title: String?
    /// 仅图片列表使用；默认关闭，随列表一起持久化。
    public var isSlideshowEnabled: Bool
    /// 轮播间隔秒数快照；实际计时以 SettingsStore 全局偏好为准。
    public var slideshowInterval: TimeInterval
    /// 多个 CUE 时每个 CUE 一个分区；单 CUE 或普通目录为空或一项。
    public var sections: [FileListSection]

    public var isPresentable: Bool { items.count >= 2 }

    /// CUE 曲目顺序由谱表时间轴决定，不能像普通文件列表一样重排。
    public var isCueBased: Bool {
        !sections.isEmpty || items.contains(where: { $0.cue != nil })
    }

    public var isReorderable: Bool { isPresentable && !isCueBased }

    public var currentItem: FileListItem? {
        items.first(where: { $0.id == currentID }) ?? items.first
    }

    /// 与历史记录一致的列表展示标题：自定义（或 CUE 专辑）标题附项数，
    /// 无标题时回退为本地化的“类型（项数）”。
    public var historyDisplayTitle: String {
        if let title = Self.normalizedTitle(self.title) {
            return String(
                format: NSLocalizedString("File List Custom Title Format", comment: ""),
                title,
                items.count
            )
        }
        return String(
            format: NSLocalizedString(kind.historyTitleFormatKey, comment: ""),
            items.count
        )
    }

    public init(
        kind: FileListKind,
        items: [FileListItem],
        currentID: String,
        title: String? = nil,
        isSlideshowEnabled: Bool = false,
        slideshowInterval: TimeInterval = ImageListSlideshow.defaultInterval,
        sections: [FileListSection] = []
    ) {
        self.kind = kind
        self.items = items
        self.currentID = currentID
        self.title = Self.normalizedTitle(title)
        self.isSlideshowEnabled = isSlideshowEnabled
        self.slideshowInterval = ImageListSlideshow.clampInterval(slideshowInterval)
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case kind, items, currentID, title, isSlideshowEnabled, slideshowInterval, sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FileListKind.self, forKey: .kind)
        items = try container.decode([FileListItem].self, forKey: .items)
        currentID = try container.decode(String.self, forKey: .currentID)
        title = Self.normalizedTitle(try container.decodeIfPresent(String.self, forKey: .title))
        isSlideshowEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSlideshowEnabled) ?? false
        slideshowInterval = ImageListSlideshow.clampInterval(
            try container.decodeIfPresent(TimeInterval.self, forKey: .slideshowInterval) ?? ImageListSlideshow.defaultInterval
        )
        sections = try container.decodeIfPresent([FileListSection].self, forKey: .sections) ?? []
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public nonisolated struct FileListGroup: Equatable, Sendable {
    public let kind: FileOpenKind
    public let urls: [URL]
}

nonisolated final class DroppedFileScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

nonisolated struct DroppedFileScanResult: Sendable {
    let urls: [URL]
    let scannedFileCount: Int
    let didReachLimit: Bool
    let wasCancelled: Bool
}

public nonisolated enum DroppedFileResolver {
    static let scanLimit = 1_000

    /// 将拖入的目录递归展开为普通文件；隐藏项和包内容不参与后续类型选择。
    static func scan(
        urls: [URL],
        limit: Int = scanLimit,
        cancellation: DroppedFileScanCancellation? = nil,
        fileManager: FileManager = .default
    ) -> DroppedFileScanResult {
        let limit = max(1, limit)
        var result: [URL] = []
        var scannedFileCount = 0
        var didReachLimit = false

        for url in urls where url.isFileURL {
            if cancellation?.isCancelled == true {
                return DroppedFileScanResult(
                    urls: FileListGrouper.uniqued(result),
                    scannedFileCount: scannedFileCount,
                    didReachLimit: didReachLimit,
                    wasCancelled: true
                )
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard !isHidden(url) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                guard scannedFileCount < limit else {
                    didReachLimit = true
                    break
                }
                scannedFileCount += 1
                result.append(url)
                continue
            }
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { continue }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isPackageKey]
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var files: [URL] = []
            while let item = enumerator.nextObject() {
                if cancellation?.isCancelled == true {
                    enumerator.skipDescendants()
                    break
                }
                guard let child = item as? URL, !isHidden(child),
                      let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if values.isHidden == true || values.isPackage == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile != false else { continue }
                guard scannedFileCount < limit else {
                    didReachLimit = true
                    enumerator.skipDescendants()
                    break
                }
                scannedFileCount += 1
                files.append(child)
            }
            files.sort { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            result.append(contentsOf: files)
            if cancellation?.isCancelled == true || didReachLimit { break }
        }
        return DroppedFileScanResult(
            urls: FileListGrouper.uniqued(result),
            scannedFileCount: scannedFileCount,
            didReachLimit: didReachLimit,
            wasCancelled: cancellation?.isCancelled == true
        )
    }

    static func containsDirectory(in urls: [URL], fileManager: FileManager = .default) -> Bool {
        urls.contains { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private static func isHidden(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") { return true }
        return (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }
}

/// 内容分组会查询当前已加载的扩展声明，因此由宿主主 actor 串行访问。
public enum FileListGrouper {
    static func isCueFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "cue"
    }

    static func dropKind(url: URL) -> DroppedFileKind {
        switch classify(url: url) {
        case .listable(.image): return .image
        case .listable(.video): return .video
        case .listable(.audio), .cueSheets: return .audio
        case .other:
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return .pdf }
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) { return .web }
            if let type = UTType(filenameExtension: ext), type.conforms(to: .text) { return .text }
            return .other(ext)
        }
    }

    /// 按扩展名快速分类；PDF / 文本 / 网页不进列表。CUE 单独成组，优先于其它类型。
    static func classify(url: URL) -> FileOpenKind {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if isCueFile(url) { return .cueSheets }
        if ext == "pdf" { return .other }
        if ["html", "htm", "webarchive", "xhtml"].contains(ext) { return .other }
        if AppState.isVideoFileName(name) { return .listable(.video) }
        if AppState.isAudioFileName(name) { return .listable(.audio) }
        if ExtensionHost.shared.canOpenAsAudio(url: url) { return .listable(.audio) }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .text) { return .other }
            if type.conforms(to: .image) || type.conforms(to: .svg) { return .listable(.image) }
        }
        return .other
    }

    nonisolated static func uniqued(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)
        for url in urls {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    /// 批次中只要有 CUE，就只保留 CUE，其它类型忽略。
    static func preferredOpenableURLs(from urls: [URL]) -> [URL] {
        let unique = uniqued(urls)
        let cues = unique.filter { isCueFile($0) }
        return cues.isEmpty ? unique : cues
    }

    /// 一次批次只选择一种内容：CUE、音频、视频、图片依次优先；其它类型按数量最多者选择。
    static func groups(from urls: [URL]) -> [FileListGroup] {
        let unique = preferredOpenableURLs(from: urls)
        let cues = unique.filter { isCueFile($0) }
        if !cues.isEmpty {
            return [FileListGroup(kind: .cueSheets, urls: cues)]
        }

        for kind in [FileListKind.audio, .video, .image] {
            let matching = unique.filter { classify(url: $0) == .listable(kind) }
            if !matching.isEmpty {
                return [FileListGroup(kind: .listable(kind), urls: matching)]
            }
        }

        var otherGroups: [(kind: DroppedFileKind, urls: [URL])] = []
        for url in unique {
            let kind = dropKind(url: url)
            if let index = otherGroups.firstIndex(where: { $0.kind == kind }) {
                otherGroups[index].urls.append(url)
            } else {
                otherGroups.append((kind, [url]))
            }
        }
        guard var selected = otherGroups.first else { return [] }
        for candidate in otherGroups.dropFirst() where candidate.urls.count > selected.urls.count {
            selected = candidate
        }
        return selected.urls.map { FileListGroup(kind: .other, urls: [$0]) }
    }
}
