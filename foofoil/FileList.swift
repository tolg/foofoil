//
//  FileList.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.
//

import Foundation
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

public nonisolated struct FileListState: Codable, Equatable, Sendable {
    public var kind: FileListKind
    public var items: [FileListItem]
    public var currentID: String

    public var isPresentable: Bool { items.count >= 2 }

    public var currentItem: FileListItem? {
        items.first(where: { $0.id == currentID }) ?? items.first
    }

    public init(kind: FileListKind, items: [FileListItem], currentID: String) {
        self.kind = kind
        self.items = items
        self.currentID = currentID
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
