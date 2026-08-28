//
//  CueSheet.swift
//  foofoil
//
//  Created by tolg on 2026/8/28.
//

import AppKit
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// CUE 索引时间：`MM:SS:FF`，1 秒 = 75 帧。切分与 seek 都用 timescale 75 的 CMTime，不经 Double 秒。
nonisolated enum CueTime {
    static let timescale: CMTimeScale = 75

    static func frames(minutes: Int, seconds: Int, frames: Int) -> Int64 {
        Int64((minutes * 60 + seconds) * 75 + frames)
    }

    static func time(_ cueFrames: Int64) -> CMTime {
        CMTime(value: cueFrames, timescale: timescale)
    }

    /// 仅用于界面展示。
    static func seconds(from cueFrames: Int64) -> Double {
        Double(cueFrames) / Double(timescale)
    }

    /// CUE 帧 → 采样点。`sampleRate` 能被 75 整除时（44.1/48/96/192 kHz）是整数精确。
    /// 这是 FLAC/CUE 播放该用的定位，而不是把时间交给 AVPlayer seek。
    static func sampleFrame(cueFrames: Int64, sampleRate: Double) -> Int64 {
        let rate = Int64(sampleRate.rounded())
        guard rate > 0 else { return 0 }
        if rate % Int64(timescale) == 0 {
            return cueFrames * (rate / Int64(timescale))
        }
        return (cueFrames * rate + Int64(timescale) / 2) / Int64(timescale)
    }

    /// 采样点 → CUE 帧，与 `sampleFrame` 在可整除采样率下互为逆运算。
    static func cueFrames(sampleFrame: Int64, sampleRate: Double) -> Int64 {
        let rate = Int64(sampleRate.rounded())
        guard rate > 0 else { return 0 }
        if rate % Int64(timescale) == 0 {
            let samplesPerFrame = rate / Int64(timescale)
            return samplesPerFrame > 0 ? sampleFrame / samplesPerFrame : 0
        }
        return (sampleFrame * Int64(timescale) + rate / 2) / rate
    }

    /// 解析 `MM:SS:FF` 为 CD 帧计数；分钟可超过两位。
    static func parse(_ text: String) -> Int64? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              let seconds = Int(parts[1]), seconds >= 0,
              let frames = Int(parts[2]), frames >= 0 else {
            return nil
        }
        return Self.frames(minutes: minutes, seconds: seconds, frames: frames)
    }
}

nonisolated struct CueTrack: Equatable, Sendable {
    var number: Int
    var title: String?
    var performer: String?
    var songwriter: String?
    var fileName: String
    var fileURL: URL?
    var startCueFrames: Int64
    var endCueFrames: Int64?
}

nonisolated struct CueSheet: Equatable, Sendable {
    var url: URL
    var title: String?
    var performer: String?
    var songwriter: String?
    var genre: String?
    var date: String?
    var tracks: [CueTrack]

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return url.deletingPathExtension().lastPathComponent
    }
}

nonisolated enum CueSheetParser {
    /// 将 CUE 文本解析为曲目列表；时间切分在同一 FILE 内按 INDEX 01 → 下一曲 INDEX 01。
    static func parse(text: String, cueURL: URL) -> CueSheet {
        var albumTitle: String?
        var albumPerformer: String?
        var albumSongwriter: String?
        var genre: String?
        var date: String?
        var currentFileName = ""
        var rawTracks: [RawTrack] = []
        var current: RawTrack?

        func flushTrack() {
            if let current {
                rawTracks.append(current)
            }
            current = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let parsed = parseLine(line) else { continue }
            let command = parsed.command
            let args = parsed.arguments

            switch command {
            case "REM":
                guard let key = args.first?.uppercased() else { continue }
                let value = joinedArguments(Array(args.dropFirst()))
                switch key {
                case "GENRE":
                    if genre == nil, !value.isEmpty { genre = value }
                case "DATE":
                    if date == nil, !value.isEmpty { date = year(from: value) }
                default:
                    break
                }
            case "TITLE":
                let value = joinedArguments(args)
                guard !value.isEmpty else { continue }
                if current != nil {
                    current?.title = value
                } else {
                    albumTitle = value
                }
            case "PERFORMER":
                let value = joinedArguments(args)
                guard !value.isEmpty else { continue }
                if current != nil {
                    current?.performer = value
                } else {
                    albumPerformer = value
                }
            case "SONGWRITER":
                let value = joinedArguments(args)
                guard !value.isEmpty else { continue }
                if current != nil {
                    current?.songwriter = value
                } else {
                    albumSongwriter = value
                }
            case "FILE":
                if let name = args.first, !name.isEmpty {
                    currentFileName = name
                    if current?.fileName.isEmpty == true {
                        current?.fileName = name
                    }
                }
            case "TRACK":
                flushTrack()
                let number = args.first.flatMap(Int.init) ?? (rawTracks.count + 1)
                let type = args.dropFirst().first?.uppercased() ?? "AUDIO"
                current = RawTrack(number: number, type: type, fileName: currentFileName)
            case "INDEX":
                guard let currentTrack = current,
                      let indexNumber = args.first.flatMap(Int.init),
                      let timeText = args.dropFirst().first,
                      let cueFrames = CueTime.parse(timeText) else { continue }
                if indexNumber == 0 {
                    current = currentTrack.settingIndex00(cueFrames)
                } else if indexNumber == 1 {
                    current = currentTrack.settingIndex01(cueFrames)
                } else if currentTrack.index01 == nil, currentTrack.index00 == nil {
                    current = currentTrack.settingIndex01(cueFrames)
                }
            default:
                break
            }
        }
        flushTrack()

        let audioTracks = rawTracks.filter(\.isAudio)
        let split = splitTimes(audioTracks)
        let tracks = split.map { track in
            CueTrack(
                number: track.number,
                title: track.title,
                performer: track.performer ?? albumPerformer,
                songwriter: track.songwriter ?? albumSongwriter,
                fileName: track.fileName,
                fileURL: nil,
                startCueFrames: track.startCueFrames,
                endCueFrames: track.endCueFrames
            )
        }

        return CueSheet(
            url: cueURL,
            title: albumTitle,
            performer: albumPerformer,
            songwriter: albumSongwriter,
            genre: genre,
            date: date,
            tracks: tracks
        )
    }

    /// 同一音频文件上的曲目：起点用 INDEX 01（缺省 INDEX 00），终点为下一曲 INDEX 01。
    static func splitTimes(_ tracks: [RawTrack]) -> [RawTrack] {
        var result = tracks
        var index = result.startIndex
        while index < result.endIndex {
            let fileName = result[index].fileName
            var end = index + 1
            while end < result.endIndex, result[end].fileName == fileName {
                end += 1
            }
            let group = index..<end
            for offset in group {
                let start = result[offset].index01 ?? result[offset].index00 ?? 0
                result[offset].startCueFrames = start
                let next = result.index(after: offset)
                if group.contains(next) {
                    let nextStart = result[next].index01 ?? result[next].index00 ?? start
                    result[offset].endCueFrames = nextStart > start ? nextStart : nil
                } else {
                    result[offset].endCueFrames = nil
                }
            }
            index = end
        }
        return result
    }

    static func parseLine(_ line: String) -> (command: String, arguments: [String])? {
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        func flush() {
            if !current.isEmpty {
                arguments.append(current)
                current = ""
            }
        }

        while index < line.endIndex {
            let character = line[index]
            let nextIndex = line.index(after: index)
            if character == "\"" {
                if inQuotes {
                    if nextIndex < line.endIndex, line[nextIndex] == "\"" {
                        current.append("\"")
                        index = line.index(after: nextIndex)
                        continue
                    }
                    inQuotes = false
                } else {
                    inQuotes = true
                }
                index = nextIndex
                continue
            }
            if character.isWhitespace, !inQuotes {
                flush()
                index = nextIndex
                continue
            }
            current.append(character)
            index = nextIndex
        }
        flush()
        guard let command = arguments.first, !command.isEmpty else { return nil }
        return (command.uppercased(), Array(arguments.dropFirst()))
    }

    static func joinedArguments(_ arguments: [String]) -> String {
        arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func year(from value: String) -> String {
        let digits = value.prefix(4)
        if digits.count == 4, digits.allSatisfy(\.isNumber) {
            return String(digits)
        }
        return value
    }

    struct RawTrack {
        var number: Int
        var type: String
        var title: String?
        var performer: String?
        var songwriter: String?
        var fileName: String
        var index00: Int64?
        var index01: Int64?
        var startCueFrames: Int64 = 0
        var endCueFrames: Int64?

        var isAudio: Bool {
            let type = type.uppercased()
            return type.isEmpty || type == "AUDIO"
        }

        func settingIndex00(_ cueFrames: Int64) -> RawTrack {
            var copy = self
            copy.index00 = cueFrames
            return copy
        }

        func settingIndex01(_ cueFrames: Int64) -> RawTrack {
            var copy = self
            copy.index01 = cueFrames
            return copy
        }
    }
}

nonisolated enum CueSheetLoader {
    static let audioExtensions = [
        "flac", "wav", "aiff", "aif", "aifc", "wv", "ape", "tak", "tta",
        "m4a", "aac", "mp3", "caf", "dsf", "dff", "ogg", "opus", "wma", "alac"
    ]

    static func load(from url: URL) -> CueSheet? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let text = readText(from: url) else { return nil }
        var sheet = CueSheetParser.parse(text: text, cueURL: url)
        sheet.tracks = sheet.tracks.compactMap { track in
            guard let audioURL = resolveAudioURL(named: track.fileName, cueURL: url) else { return nil }
            var resolved = track
            resolved.fileURL = audioURL
            return resolved
        }
        return sheet.tracks.isEmpty ? nil : sheet
    }

    static func readText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return decodeText(data)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    static func resolveAudioURL(named fileName: String, cueURL: URL) -> URL? {
        let candidates = audioCandidates(named: fileName, cueURL: cueURL)
        for candidate in candidates {
            if audioExists(primary: cueURL, related: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func audioCandidates(named fileName: String, cueURL: URL) -> [URL] {
        let directory = cueURL.deletingLastPathComponent()
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted {
                candidates.append(url)
            }
        }

        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        let asPath = URL(fileURLWithPath: normalized)
        if normalized.hasPrefix("/") {
            append(asPath)
        }
        if normalized.contains("/"), !normalized.hasPrefix("/") {
            append(directory.appendingPathComponent(normalized))
        }
        append(directory.appendingPathComponent(asPath.lastPathComponent))

        let stem = (asPath.lastPathComponent as NSString).deletingPathExtension
        guard !stem.isEmpty else { return candidates }
        for ext in audioExtensions {
            append(directory.appendingPathComponent("\(stem).\(ext)"))
        }
        return candidates
    }

    static func audioExists(primary: URL, related: URL) -> Bool {
        if FileManager.default.fileExists(atPath: related.path) {
            return true
        }
        return CueRelatedFilePresenter.exists(primary: primary, related: related)
    }

    /// 读取 CUE 关联音频的采样时钟；沙盒下先走直接打开，失败再用关联项协调读。
    static func playbackTiming(audioURL: URL, cueURL: URL) -> AudioPlaybackTiming? {
        let accessed = audioURL.startAccessingSecurityScopedResource()
        defer { if accessed { audioURL.stopAccessingSecurityScopedResource() } }
        if let timing = AudioMetadataLoader.playbackTiming(for: audioURL) {
            return timing
        }
        return CueRelatedFilePresenter.playbackTiming(primary: cueURL, related: audioURL)
    }

    private static var fallbackEncodings: [String.Encoding] {
        [
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )),
            .shiftJIS,
            .windowsCP1252,
            .isoLatin1
        ]
    }
}

/// 将同目录音频声明为用户所选 CUE 的关联项，以便沙盒允许读取。
final class CueRelatedFilePresenter: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(primary: URL, related: URL) {
        self.primaryPresentedItemURL = primary
        self.presentedItemURL = related
        self.presentedItemOperationQueue = CueRelatedFilePresenter.queue
    }

    static func exists(primary: URL, related: URL) -> Bool {
        coordinate(primary: primary, related: related) { url in
            FileManager.default.fileExists(atPath: url.path)
        } ?? false
    }

    static func playbackTiming(primary: URL, related: URL) -> AudioPlaybackTiming? {
        coordinate(primary: primary, related: related) { url in
            AudioMetadataLoader.playbackTiming(for: url)
        } ?? nil
    }

    private static func coordinate<T>(primary: URL, related: URL, read: (URL) -> T) -> T? {
        let presenter = CueRelatedFilePresenter(primary: primary, related: related)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var value: T?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: related, options: [], error: &coordinationError) { url in
            value = read(url)
        }
        return value
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.foofoil.cue-related-audio"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
}
