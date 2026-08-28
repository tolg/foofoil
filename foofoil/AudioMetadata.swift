//
//  AudioMetadata.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import AppKit
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

/// 从音频文件提取的展示信息；封面优先使用内嵌 artwork，其次同目录匹配的封面图。
nonisolated struct AudioTrackInfo {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var year: String?
    var trackNumber: String?
    var formatName: String?
    var sampleRate: Double?
    var bitRate: Double?
    var channelCount: Int?
    var artwork: NSImage?

    static func fallback(fileName: String) -> AudioTrackInfo {
        AudioTrackInfo(title: (fileName as NSString).deletingPathExtension)
    }

    /// 无封面时的默认窗口内容尺寸，接近竖版专辑卡片。
    static let fallbackPresentationSize = NSSize(width: 400, height: 500)
    /// 初次打开音频时，窗口宽、高均不超过该值。
    static let initialWindowMaxLength: CGFloat = 500

    /// 按封面比例缩放，使窗口（含边框留白）宽高都不超过 `initialWindowMaxLength`。
    static func initialWindowSize(for contentSize: NSSize, inset: CGFloat) -> NSSize {
        guard contentSize.width > 0, contentSize.height > 0 else { return fallbackPresentationSize }
        let maxContent = max(1, initialWindowMaxLength - inset)
        let scale = min(1, maxContent / contentSize.width, maxContent / contentSize.height)
        return NSSize(
            width: contentSize.width * scale + inset,
            height: contentSize.height * scale + inset
        )
    }
}

/// 以文件头采样数为准的播放时钟。AVAsset.duration 对 FLAC 常偏短，导致 CUE 后几段起点漂移、末段进度条提前走满。
nonisolated struct AudioPlaybackTiming: Equatable, Sendable {
    var duration: Double
    var sampleRate: Double
    var sampleCount: Int64
    var timescale: CMTimeScale

    func time(from seconds: Double) -> CMTime {
        let scale = max(1, timescale)
        let value = Int64((max(0, seconds) * Double(scale)).rounded())
        return CMTime(value: value, timescale: scale)
    }
}

nonisolated enum AudioMetadataLoader {
    /// 与音频文件同名或同目录常用封面文件名，按优先级尝试。
    static let sidecarImageExtensions = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "gif"]
    static let conventionalCoverNames = [
        "cover", "folder", "artwork", "albumart", "front", "AlbumArt", "AlbumArtSmall", "封面"
    ]

    static func load(from url: URL) async -> AudioTrackInfo {
        var info = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        info.formatName = formatName(for: url)
        let asset = AVURLAsset(url: url)
        let metadata = ((try? await asset.load(.commonMetadata)) ?? [])
            + ((try? await asset.load(.metadata)) ?? [])
        await applyMetadata(metadata, to: &info)

        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                info.bitRate = Double(rate)
            }
            if let descriptions = try? await track.load(.formatDescriptions) {
                applyFormatDescriptions(descriptions, to: &info)
            }
        }

        if info.artwork == nil {
            info.artwork = sidecarCoverImage(for: url)
        }
        return info
    }

    /// 供历史索引等后台队列同步读取；请勿在主线程调用。
    static func loadSynchronously(from url: URL) -> AudioTrackInfo {
        let semaphore = DispatchSemaphore(value: 0)
        var result = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        Task {
            result = await load(from: url)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func presentationSize(for info: AudioTrackInfo) -> NSSize {
        if let artwork = info.artwork, let size = reliableImageSize(artwork) {
            return size
        }
        return AudioTrackInfo.fallbackPresentationSize
    }

    /// 用 AudioFile 的采样帧数计算真实时长；FLAC 不要用 AVAsset.duration。
    static func playbackTiming(for url: URL) -> AudioPlaybackTiming? {
        if let timing = timingFromAVAudioFile(url) { return timing }
        return timingFromAudioFile(url)
    }

    private static func timingFromAVAudioFile(_ url: URL) -> AudioPlaybackTiming? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate > 0
            ? file.processingFormat.sampleRate
            : file.fileFormat.sampleRate
        let frames = file.length
        guard sampleRate > 0, frames > 0 else { return nil }
        return makeTiming(duration: Double(frames) / sampleRate, sampleRate: sampleRate, sampleCount: frames)
    }

    private static func timingFromAudioFile(_ url: URL) -> AudioPlaybackTiming? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            return nil
        }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd) == noErr,
              asbd.mSampleRate > 0 else {
            return nil
        }

        var duration: TimeInterval = 0
        var durationSize = UInt32(MemoryLayout<TimeInterval>.size)
        if AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &durationSize, &duration) == noErr,
           duration > 0 {
            return makeTiming(
                duration: duration,
                sampleRate: asbd.mSampleRate,
                sampleCount: Int64((duration * asbd.mSampleRate).rounded())
            )
        }

        var packetCount: UInt64 = 0
        var packetSize = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataPacketCount, &packetSize, &packetCount) == noErr,
              packetCount > 0 else {
            return nil
        }
        let framesPerPacket = max(1, asbd.mFramesPerPacket)
        let sampleCount = Int64(packetCount * UInt64(framesPerPacket))
        return makeTiming(
            duration: Double(sampleCount) / asbd.mSampleRate,
            sampleRate: asbd.mSampleRate,
            sampleCount: sampleCount
        )
    }

    private static func makeTiming(duration: Double, sampleRate: Double, sampleCount: Int64) -> AudioPlaybackTiming {
        let timescale = CMTimeScale(clamping: max(1, Int(sampleRate.rounded())))
        return AudioPlaybackTiming(
            duration: duration,
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            timescale: timescale
        )
    }

    /// 优先用像素尺寸，避免内嵌封面 NSImage.size 尚未就绪或被 DPI 压成 0/1。
    static func reliableImageSize(_ image: NSImage) -> NSSize? {
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return nil
    }

    /// 图片箔布局用点尺寸，与 SwiftUI 按 `NSImage.size` 绘制一致；仅在 size 无效时退回像素。
    static func layoutSize(_ image: NSImage) -> NSSize? {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return reliableImageSize(image)
    }

    static func sidecarCoverCandidates(for audioURL: URL) -> [URL] {
        let directory = audioURL.deletingLastPathComponent()
        let base = audioURL.deletingPathExtension().lastPathComponent
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.path
            if seen.insert(key).inserted {
                candidates.append(url)
            }
        }

        for ext in sidecarImageExtensions {
            append(directory.appendingPathComponent("\(base).\(ext)"))
        }
        for name in conventionalCoverNames {
            for ext in sidecarImageExtensions {
                append(directory.appendingPathComponent("\(name).\(ext)"))
            }
        }
        return candidates
    }

    static func sidecarCoverURL(for audioURL: URL) -> URL? {
        sidecarCoverCandidates(for: audioURL).first { candidate in
            loadSidecarImage(primary: audioURL, related: candidate) != nil
        }
    }

    static func sidecarCoverImage(for audioURL: URL) -> NSImage? {
        for candidate in sidecarCoverCandidates(for: audioURL) {
            if let image = loadSidecarImage(primary: audioURL, related: candidate) {
                return image
            }
        }
        return nil
    }

    /// 沙盒只授权用户选中的音频文件；同目录封面需以 NSFilePresenter 关联项方式读取。
    private static func loadSidecarImage(primary: URL, related: URL) -> NSImage? {
        if let image = NSImage(contentsOf: related), image.size.width > 0, image.size.height > 0 {
            return image
        }
        return readRelatedItemImage(primary: primary, related: related)
    }

    private static func readRelatedItemImage(primary: URL, related: URL) -> NSImage? {
        let presenter = SidecarFilePresenter(primary: primary, related: related)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        var image: NSImage?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: related, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url), let loaded = NSImage(data: data),
                  loaded.size.width > 0, loaded.size.height > 0 else { return }
            image = loaded
        }
        return image
    }

    static func formatSampleRate(_ sampleRate: Double) -> String {
        let kilohertz = sampleRate / 1000
        let text: String
        if abs(kilohertz.rounded() - kilohertz) < 0.05 {
            text = String(Int(kilohertz.rounded()))
        } else {
            text = String(format: "%g", (kilohertz * 10).rounded() / 10)
        }
        return String(format: NSLocalizedString("%@ kHz", comment: ""), text)
    }

    static func formatBitRate(_ bitRate: Double) -> String {
        let kbps = max(1, Int((bitRate / 1000).rounded()))
        return String(format: NSLocalizedString("%@ kbps", comment: ""), "\(kbps)")
    }

    static func formatChannels(_ count: Int) -> String {
        switch count {
        case 1: return NSLocalizedString("Mono", comment: "")
        case 2: return NSLocalizedString("Stereo", comment: "")
        default: return String(format: NSLocalizedString("%d Channels", comment: ""), count)
        }
    }

    static func formatDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func formatTrackNumber(_ value: String) -> String {
        String(format: NSLocalizedString("Track %@", comment: ""), value)
    }

    private static func applyMetadata(_ items: [AVMetadataItem], to info: inout AudioTrackInfo) async {
        if let title = await stringValue(items, identifiers: [.commonIdentifierTitle]), !title.isEmpty {
            info.title = title
        }
        info.artist = await stringValue(items, identifiers: [.commonIdentifierArtist])
        info.album = await stringValue(items, identifiers: [.commonIdentifierAlbumName])
        info.genre = await stringValue(items, identifiers: [
            .iTunesMetadataUserGenre,
            .commonIdentifierType,
            AVMetadataIdentifier(rawValue: "org.id3/TCON")
        ])
        info.composer = await stringValue(items, identifiers: [.commonIdentifierCreator, .iTunesMetadataComposer])
        info.albumArtist = await stringValue(items, identifiers: [.iTunesMetadataAlbumArtist])

        if let dateString = await stringValue(items, identifiers: [
            .commonIdentifierCreationDate,
            .iTunesMetadataReleaseDate
        ]) {
            info.year = year(from: dateString)
        }

        if let track = await stringValue(items, identifiers: [
            .id3MetadataTrackNumber,
            .iTunesMetadataTrackNumber
        ]) {
            info.trackNumber = normalizedTrackNumber(track)
        } else if let trackData = await dataValue(items, identifiers: [.iTunesMetadataTrackNumber]) {
            info.trackNumber = trackNumber(from: trackData)
        }

        if info.artwork == nil, let artworkData = await dataValue(items, identifiers: [.commonIdentifierArtwork]) {
            info.artwork = NSImage(data: artworkData)
        }
    }

    private static func applyFormatDescriptions(_ descriptions: [CMFormatDescription], to info: inout AudioTrackInfo) {
        for description in descriptions {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
            if asbd.mSampleRate > 0 {
                info.sampleRate = asbd.mSampleRate
            }
            if asbd.mChannelsPerFrame > 0 {
                info.channelCount = Int(asbd.mChannelsPerFrame)
            }
            let codec = fourCC(asbd.mFormatID)
            if info.formatName == nil || info.formatName?.isEmpty == true {
                info.formatName = displayName(forCodec: codec) ?? codec
            } else if let codecName = displayName(forCodec: codec) {
                info.formatName = codecName
            }
            break
        }
    }

    private static func stringValue(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let string = try? await item.load(.stringValue), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let data = try? await item.load(.dataValue),
                   let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private static func dataValue(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> Data? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
                if let value = try? await item.load(.value) {
                    if let data = value as? Data, !data.isEmpty { return data }
                    if let image = value as? NSImage, let tiff = image.tiffRepresentation { return tiff }
                }
            }
        }
        return nil
    }

    private static func year(from string: String) -> String {
        let digits = string.prefix(4)
        if digits.count == 4, digits.allSatisfy(\.isNumber) {
            return String(digits)
        }
        return string
    }

    private static func normalizedTrackNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let number = trimmed[..<slash].trimmingCharacters(in: .whitespaces)
            return number.isEmpty ? trimmed : number
        }
        return trimmed
    }

    private static func trackNumber(from data: Data) -> String? {
        // iTunes trkn 原子：4 字节保留 + 2 字节曲目 + 2 字节总数
        guard data.count >= 8 else { return nil }
        let number = Int(data[4]) << 8 | Int(data[5])
        return number > 0 ? "\(number)" : nil
    }

    private static func formatName(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let type = UTType(filenameExtension: ext), let name = type.localizedDescription, !name.isEmpty {
            return preferredShortFormatName(extension: ext) ?? name
        }
        return preferredShortFormatName(extension: ext) ?? ext.uppercased()
    }

    private static func preferredShortFormatName(extension ext: String) -> String? {
        switch ext {
        case "mp3": return "MP3"
        case "m4a", "aac": return "AAC"
        case "m4b": return "M4B"
        case "wav": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "caf": return "CAF"
        case "flac": return "FLAC"
        case "au", "snd": return "AU"
        default: return nil
        }
    }

    private static func displayName(forCodec codec: String) -> String? {
        switch codec.lowercased() {
        case "aac", "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case ".mp3", "mp3 ": return "MP3"
        case "lpcm", "twos", "sowt": return "PCM"
        case "ima4": return "IMA"
        default: return nil
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes.map { $0 == 0 ? " " : Character(UnicodeScalar($0)) })
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 将同目录封面声明为用户所选音频的关联项，以便沙盒允许读取。
nonisolated private final class SidecarFilePresenter: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(primary: URL, related: URL) {
        self.primaryPresentedItemURL = primary
        self.presentedItemURL = related
        self.presentedItemOperationQueue = SidecarFilePresenter.queue
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.foofoil.audio-sidecar"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
}
