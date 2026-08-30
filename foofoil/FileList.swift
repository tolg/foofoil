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

enum DroppedFileKind: Equatable {
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

    public init(
        kind: FileListKind,
        items: [FileListItem],
        currentID: String,
        isSlideshowEnabled: Bool = false,
        slideshowInterval: TimeInterval = ImageListSlideshow.defaultInterval,
        sections: [FileListSection] = []
    ) {
        self.kind = kind
        self.items = items
        self.currentID = currentID
        self.isSlideshowEnabled = isSlideshowEnabled
        self.slideshowInterval = ImageListSlideshow.clampInterval(slideshowInterval)
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case kind, items, currentID, isSlideshowEnabled, slideshowInterval, sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FileListKind.self, forKey: .kind)
        items = try container.decode([FileListItem].self, forKey: .items)
        currentID = try container.decode(String.self, forKey: .currentID)
        isSlideshowEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSlideshowEnabled) ?? false
        slideshowInterval = ImageListSlideshow.clampInterval(
            try container.decodeIfPresent(TimeInterval.self, forKey: .slideshowInterval) ?? ImageListSlideshow.defaultInterval
        )
        sections = try container.decodeIfPresent([FileListSection].self, forKey: .sections) ?? []
    }
}

public nonisolated struct FileListGroup: Equatable, Sendable {
    public let kind: FileOpenKind
    public let urls: [URL]
}

public nonisolated enum FileListGrouper {
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
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .text) { return .other }
            if type.conforms(to: .image) || type.conforms(to: .svg) { return .listable(.image) }
        }
        return .other
    }

    static func uniqued(_ urls: [URL]) -> [URL] {
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

    /// 可列表类型按首次出现顺序聚成一组（跨穿插的其它文件仍归入该类型）；其它类型各成单文件组。
    static func groups(from urls: [URL]) -> [FileListGroup] {
        let unique = preferredOpenableURLs(from: urls)
        let cues = unique.filter { isCueFile($0) }
        if !cues.isEmpty {
            return [FileListGroup(kind: .cueSheets, urls: cues)]
        }

        var listableURLs: [FileListKind: [URL]] = [:]
        enum Token {
            case listable(FileListKind)
            case other(URL)
        }
        var tokens: [Token] = []
        var seenKinds = Set<FileListKind>()

        for url in unique {
            switch classify(url: url) {
            case .listable(let kind):
                if seenKinds.insert(kind).inserted {
                    tokens.append(.listable(kind))
                }
                listableURLs[kind, default: []].append(url)
            case .cueSheets:
                break
            case .other:
                tokens.append(.other(url))
            }
        }

        return tokens.map { token in
            switch token {
            case .listable(let kind):
                FileListGroup(kind: .listable(kind), urls: listableURLs[kind] ?? [])
            case .other(let url):
                FileListGroup(kind: .other, urls: [url])
            }
        }
    }
}
