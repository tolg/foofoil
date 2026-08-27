//
//  FileList.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
        case .image: [.image]
        case .video: [.movie]
        case .audio: [.audio]
        }
    }
}

public nonisolated enum FileOpenKind: Equatable, Sendable {
    case listable(FileListKind)
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

    public var url: URL { URL(fileURLWithPath: path) }

    public init(id: String, path: String, bookmark: Data? = nil, displayName: String) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.displayName = displayName
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

    public var isPresentable: Bool { items.count >= 2 }

    public var currentItem: FileListItem? {
        items.first(where: { $0.id == currentID }) ?? items.first
    }

    public init(
        kind: FileListKind,
        items: [FileListItem],
        currentID: String,
        isSlideshowEnabled: Bool = false,
        slideshowInterval: TimeInterval = ImageListSlideshow.defaultInterval
    ) {
        self.kind = kind
        self.items = items
        self.currentID = currentID
        self.isSlideshowEnabled = isSlideshowEnabled
        self.slideshowInterval = ImageListSlideshow.clampInterval(slideshowInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, items, currentID, isSlideshowEnabled, slideshowInterval
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
    }
}

public nonisolated struct FileListGroup: Equatable, Sendable {
    public let kind: FileOpenKind
    public let urls: [URL]
}

public enum FileListGrouper {
    static func dropKind(url: URL) -> DroppedFileKind {
        switch classify(url: url) {
        case .listable(.image): return .image
        case .listable(.video): return .video
        case .listable(.audio): return .audio
        case .other:
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return .pdf }
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) { return .web }
            if let type = UTType(filenameExtension: ext), type.conforms(to: .text) { return .text }
            return .other(ext)
        }
    }

    /// 按扩展名快速分类；PDF / 文本 / 网页不进列表。
    static func classify(url: URL) -> FileOpenKind {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
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

    /// 可列表类型按首次出现顺序聚成一组（跨穿插的其它文件仍归入该类型）；其它类型各成单文件组。
    static func groups(from urls: [URL]) -> [FileListGroup] {
        var seenPaths = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)
        for url in urls {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                unique.append(url)
            }
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
