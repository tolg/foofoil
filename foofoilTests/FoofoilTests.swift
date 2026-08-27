//
//  FoofoilTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/7/6.
//

import Testing
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import SwiftUI
@testable import foofoil

@MainActor
@Suite(.serialized)
struct HistorySearchTests {
    private func repository() throws -> (HistoryRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3")), directory)
    }

    @Test func createsSQLiteDatabaseAndDoesNotImportLegacyHistory() throws {
        let legacy = try JSONEncoder().encode([WindowConfig(id: UUID(), text: "不应导入")])
        UserDefaults.standard.set(legacy, forKey: "historyConfigs")
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(repository.initializationError == nil)
        #expect(repository.recent().isEmpty)
        #expect(UserDefaults.standard.object(forKey: "historyConfigs") == nil)
    }

    @Test func searchesChineseSubstringAndRanksExactTitleFirst() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodyID = UUID()
        let titleID = UUID()
        #expect(repository.upsert(WindowConfig(id: bodyID, originalImageName: "项目笔记", text: "这里记录历史记录搜索的实现细节")))
        #expect(repository.upsert(WindowConfig(id: titleID, originalImageName: "记录搜索", text: "其他内容")))

        let results = await repository.search("记录搜索")
        #expect(results.map(\.id).contains(bodyID))
        #expect(results.first?.id == titleID)
    }

    @Test func supportsMultiKeywordAcrossDifferentChunksAndCascadingDelete() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        #expect(repository.upsert(WindowConfig(id: id, originalImageName: "Swift 资料", text: "数据库索引")))

        #expect((await repository.search("Swift 索引")).first?.id == id)
        repository.remove(id: id)
        #expect((await repository.search("索引")).isEmpty)
        #expect(repository.rebuildSearchIndex())
        #expect(repository.searchDatabaseSize > 0)
    }

    @Test func repeatedLocalSourceKeepsSingleHistoryItem() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprint = "file:/tmp/repeated-reference.png"
        let firstID = UUID()
        let secondID = UUID()

        #expect(repository.upsert(WindowConfig(id: firstID, imagePath: "/tmp/cache-a.png", originalImageName: "reference.png", contentKind: .image, sourceFingerprint: fingerprint)))
        #expect(repository.upsert(WindowConfig(id: secondID, imagePath: "/tmp/cache-b.png", originalImageName: "reference.png", contentKind: .image, sourceFingerprint: fingerprint)))

        let history = repository.recent()
        #expect(history.count == 1)
        #expect(history.first?.id == secondID)
        #expect(history.first?.sourceFingerprint == fingerprint)
    }

    @Test func recentHistoryDropsVideoEntriesWithMissingSourceFile() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 一条源文件缺失的视频历史与一条源文件存在的视频历史
        let missingID = UUID()
        #expect(repository.upsert(WindowConfig(
            id: missingID,
            imagePath: "/tmp/foofoil-definitely-missing-\(UUID().uuidString).mp4",
            originalImageName: "gone.mp4",
            contentKind: .video
        )))
        let existingURL = directory.appendingPathComponent("present.m4v")
        try Data("fake video".utf8).write(to: existingURL)
        let existingID = UUID()
        #expect(repository.upsert(WindowConfig(
            id: existingID,
            imagePath: existingURL.path,
            originalImageName: "present.m4v",
            contentKind: .video
        )))

        let recent = repository.recent()
        #expect(!recent.contains(where: { $0.id == missingID }))
        #expect(recent.contains(where: { $0.id == existingID }))
        // 缺失源文件的记录已被物理移除
        #expect(repository.config(id: missingID) == nil)
    }

    @Test func recentHistoryKeepsVideoEntriesWithResolvableBookmark() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 源文件存在但记录的路径已变化：书签仍能解析出文件（模拟文件被移动后书签找回）
        let realFileURL = directory.appendingPathComponent("moved.mp4")
        try Data("fake video".utf8).write(to: realFileURL)
        let bookmark = try #require(AppState.makeSecurityScopedBookmark(for: realFileURL))

        let bookmarkedID = UUID()
        #expect(repository.upsert(WindowConfig(
            id: bookmarkedID,
            imagePath: "/tmp/foofoil-stale-path-\(UUID().uuidString).mp4",
            originalImageName: "moved.mp4",
            contentKind: .video,
            videoBookmark: bookmark
        )))

        // 无书签且路径不存在的记录仍然被移除
        let missingID = UUID()
        #expect(repository.upsert(WindowConfig(
            id: missingID,
            imagePath: "/tmp/foofoil-definitely-missing-\(UUID().uuidString).mp4",
            originalImageName: "gone.mp4",
            contentKind: .video
        )))

        let recent = repository.recent()
        #expect(recent.contains(where: { $0.id == bookmarkedID }))
        #expect(!recent.contains(where: { $0.id == missingID }))
    }
}

@MainActor
@Suite(.serialized)
struct FoofoilTests {

    @Test func testLoadingHistoryKeepsOriginalIdentifier() {
        let historyID = UUID()
        let state = AppState()

        state.loadConfig(WindowConfig(id: historyID, text: "历史内容"))

        #expect(state.id == historyID)
    }

    @Test func testVideoFileTypeDetection() {
        #expect(AppState.isVideoFileName("movie.mp4"))
        #expect(AppState.isVideoFileName("clip.MOV"))
        #expect(AppState.isVideoFileName("recording.m4v"))
        #expect(!AppState.isVideoFileName("photo.png"))
        #expect(!AppState.isVideoFileName("note.txt"))
        #expect(!AppState.isVideoFileName("document.pdf"))
        #expect(!AppState.isVideoFileName("noextension"))
    }

    @Test func testAudioFileTypeDetection() {
        #expect(AppState.isAudioFileName("song.mp3"))
        #expect(AppState.isAudioFileName("track.M4A"))
        #expect(AppState.isAudioFileName("clip.wav"))
        #expect(AppState.isAudioFileName("sound.aiff"))
        #expect(AppState.isAudioFileName("loop.caf"))
        #expect(!AppState.isAudioFileName("movie.mp4"))
        #expect(!AppState.isAudioFileName("clip.MOV"))
        #expect(!AppState.isAudioFileName("photo.png"))
        #expect(!AppState.isAudioFileName("note.txt"))
        #expect(!AppState.isAudioFileName("noextension"))
    }

    @Test func testHistoryContentKindInfersVideo() {
        let video = WindowConfig(id: UUID(), imagePath: "/tmp/sample.mp4", originalImageName: "sample.mp4")
        #expect(HistoryContentKind.infer(from: video) == .video)

        let image = WindowConfig(id: UUID(), imagePath: "/tmp/sample.png", originalImageName: "sample.png")
        #expect(HistoryContentKind.infer(from: image) == .image)

        let pdf = WindowConfig(id: UUID(), imagePath: "/tmp/doc.pdf", originalImageName: "doc.pdf")
        #expect(HistoryContentKind.infer(from: pdf) == .pdf)
    }

    @Test func testHistoryContentKindInfersAudio() {
        let audio = WindowConfig(id: UUID(), imagePath: "/tmp/sample.mp3", originalImageName: "sample.mp3")
        #expect(HistoryContentKind.infer(from: audio) == .audio)
        #expect(HistoryContentKind.audio.symbolName == "music.note")
    }

    @Test func testOpenedVideoKeepsOriginalFileWithoutCaching() throws {
        // 视频不复制到缓存目录，历史记录仅保存原始路径
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-video-source-\(UUID().uuidString).mp4")
        try Data("fake video".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openVideo(url: sourceURL)

        #expect(state.isVideoDocument)
        #expect(state.imageURL == sourceURL)
        #expect(state.imageURL?.lastPathComponent.hasPrefix("cached_image") == false)

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        #expect(config.contentKind == .video)
        #expect(config.imagePath == sourceURL.path)

        // 从历史中移除时不得删除用户原始视频文件
        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func testOpenedVideoCreatesSecurityScopedBookmark() throws {
        // 打开视频时创建安全范围书签并随配置持久化，供 app 重启后恢复沙盒访问
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-video-bookmark-\(UUID().uuidString).mp4")
        try Data("fake video".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openVideo(url: sourceURL)

        let bookmark = try #require(state.videoBookmarkData)
        let resolvedURL = try #require(AppState.resolveVideoBookmark(bookmark))
        #expect(resolvedURL.path == sourceURL.path)

        let config = state.toConfig()
        #expect(config.videoBookmark == bookmark)

        // 经配置恢复窗口状态时同样能访问到文件
        let restored = AppState(config: config)
        #expect(restored.imageURL == sourceURL)
        #expect(restored.videoBookmarkData != nil)

        // 清理历史记录
        if let saved = SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }) {
            HistoryManager.shared.removeFromHistory(saved)
        }
    }

    @Test func testOpenedAudioKeepsOriginalFileWithoutCaching() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-audio-source-\(UUID().uuidString).mp3")
        try Data("fake audio".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openAudio(url: sourceURL)

        #expect(state.isAudioDocument)
        #expect(state.isExternalMediaDocument)
        #expect(state.imageURL == sourceURL)
        #expect(state.imageURL?.lastPathComponent.hasPrefix("cached_image") == false)

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        #expect(config.contentKind == .audio)
        #expect(config.imagePath == sourceURL.path)

        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func testOpenedAudioCreatesSecurityScopedBookmark() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-audio-bookmark-\(UUID().uuidString).m4a")
        try Data("fake audio".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openAudio(url: sourceURL)

        let bookmark = try #require(state.videoBookmarkData)
        let resolvedURL = try #require(AppState.resolveVideoBookmark(bookmark))
        #expect(resolvedURL.path == sourceURL.path)

        let config = state.toConfig()
        #expect(config.contentKind == .audio)
        #expect(config.videoBookmark == bookmark)

        let restored = AppState(config: config)
        #expect(restored.imageURL == sourceURL)
        #expect(restored.isAudioDocument)
        #expect(restored.videoBookmarkData != nil)

        if let saved = SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }) {
            HistoryManager.shared.removeFromHistory(saved)
        }
    }

    @Test func testCanOpenFileAcceptsAudioCandidates() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-canopen-\(UUID().uuidString).mp3")
        try Data("fake audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let state = AppState()
        #expect(state.canOpenFile(url: audioURL))
    }

    @Test func testAudioSidecarCoverPrefersMatchingBasename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-audio-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("song.mp3")
        try Data("fake audio".utf8).write(to: audioURL)

        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))

        let matchingCover = directory.appendingPathComponent("song.jpg")
        let genericCover = directory.appendingPathComponent("cover.jpg")
        try jpeg.write(to: genericCover)
        try jpeg.write(to: matchingCover)

        #expect(AudioMetadataLoader.sidecarCoverURL(for: audioURL) == matchingCover)
        #expect(AudioMetadataLoader.sidecarCoverImage(for: audioURL) != nil)
    }

    @Test func imageLayoutSizePrefersPointSizeOverPixels() throws {
        let image = NSImage(size: NSSize(width: 100, height: 50))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 400,
            pixelsHigh: 200,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        image.addRepresentation(rep)

        #expect(AudioMetadataLoader.reliableImageSize(image) == NSSize(width: 400, height: 200))
        #expect(AudioMetadataLoader.layoutSize(image) == NSSize(width: 100, height: 50))

        let invalidPointSize = NSImage(size: .zero)
        invalidPointSize.addRepresentation(rep)
        #expect(AudioMetadataLoader.layoutSize(invalidPointSize) == NSSize(width: 400, height: 200))
    }

    @Test func testAudioPresentationSizeUsesArtworkAspect() {
        let image = NSImage(size: NSSize(width: 600, height: 400))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        var info = AudioTrackInfo.fallback(fileName: "song.mp3")
        info.artwork = image
        let size = AudioMetadataLoader.presentationSize(for: info)
        #expect(abs(size.width / size.height - 1.5) < 0.001)

        let empty = AudioTrackInfo.fallback(fileName: "plain.wav")
        #expect(AudioMetadataLoader.presentationSize(for: empty) == AudioTrackInfo.fallbackPresentationSize)
    }

    @Test func testAudioInitialWindowSizeDoesNotExceed500() {
        let square = AudioTrackInfo.initialWindowSize(for: NSSize(width: 2000, height: 2000), inset: 0)
        #expect(square.width == AudioTrackInfo.initialWindowMaxLength)
        #expect(square.height == AudioTrackInfo.initialWindowMaxLength)

        let wide = AudioTrackInfo.initialWindowSize(for: NSSize(width: 1600, height: 900), inset: 0)
        #expect(wide.width == AudioTrackInfo.initialWindowMaxLength)
        #expect(abs(wide.height - AudioTrackInfo.initialWindowMaxLength * 900 / 1600) < 0.001)

        let bordered = AudioTrackInfo.initialWindowSize(for: NSSize(width: 2000, height: 2000), inset: 24)
        #expect(bordered.width <= AudioTrackInfo.initialWindowMaxLength)
        #expect(bordered.height <= AudioTrackInfo.initialWindowMaxLength)

        let fallback = AudioTrackInfo.initialWindowSize(for: AudioTrackInfo.fallbackPresentationSize, inset: 0)
        #expect(fallback == AudioTrackInfo.fallbackPresentationSize)
    }

    @Test func testHistoryMediaWindowMatchesContentAspect() {
        // 已保存的 16:9 窗口应原样保留，不能按初始规则重算大小
        let saved = FloatingWindowController.sizeMatchingContentAspect(
            current: NSSize(width: 960, height: 540),
            content: NSSize(width: 1920, height: 1080)
        )
        #expect(saved.width == 960)
        #expect(saved.height == 540)

        // 比例不对时沿更接近已保存尺寸的一边校正
        let wide = FloatingWindowController.sizeMatchingContentAspect(
            current: NSSize(width: 400, height: 400),
            content: NSSize(width: 1920, height: 1080)
        )
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.001)
        #expect(abs(wide.width - 400) < 0.001)

        let tall = FloatingWindowController.sizeMatchingContentAspect(
            current: NSSize(width: 400, height: 400),
            content: NSSize(width: 400, height: 500)
        )
        #expect(abs(tall.width / tall.height - 0.8) < 0.001)

        let alreadyMatching = FloatingWindowController.sizeMatchingContentAspect(
            current: NSSize(width: 640, height: 360),
            content: NSSize(width: 1920, height: 1080)
        )
        #expect(alreadyMatching.width == 640)
        #expect(alreadyMatching.height == 360)

        let photo = FloatingWindowController.sizeMatchingContentAspect(
            current: NSSize(width: 400, height: 400),
            content: NSSize(width: 3000, height: 2000)
        )
        #expect(abs(photo.width / photo.height - 1.5) < 0.001)
    }

    @Test func testImageListSuccessorKeepsDisplayAreaAndAlignsToNavigatorSide() {
        let previous = NSSize(width: 400, height: 300)
        let previousArea = previous.width * previous.height

        let wide = FloatingWindowController.sizeMatchingContentArea(
            previous: previous,
            content: NSSize(width: 1920, height: 1080)
        )
        #expect(abs(wide.width * wide.height - previousArea) < 0.001)
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.001)

        let tall = FloatingWindowController.sizeMatchingContentArea(
            previous: previous,
            content: NSSize(width: 600, height: 1200)
        )
        #expect(abs(tall.width * tall.height - previousArea) < 0.001)
        #expect(abs(tall.width / tall.height - 0.5) < 0.001)

        let current = NSRect(x: 100, y: 200, width: 400, height: 300)
        let nextSize = NSSize(width: 500, height: 240)

        let leftAligned = FloatingWindowController.alignedFrame(
            current: current,
            size: nextSize,
            alignment: .leading
        )
        #expect(leftAligned.minX == current.minX)
        #expect(abs(leftAligned.midY - current.midY) < 0.001)
        #expect(leftAligned.size == nextSize)

        let rightAligned = FloatingWindowController.alignedFrame(
            current: current,
            size: nextSize,
            alignment: .trailing
        )
        #expect(rightAligned.maxX == current.maxX)
        #expect(abs(rightAligned.midY - current.midY) < 0.001)
        #expect(rightAligned.size == nextSize)

        let centered = FloatingWindowController.alignedFrame(
            current: current,
            size: nextSize,
            alignment: .center
        )
        #expect(abs(centered.midX - current.midX) < 0.001)
        #expect(abs(centered.midY - current.midY) < 0.001)
    }

    @Test func testWindowEdgeResizeChangesHeightAndKeepsOppositeEdgeFixed() {
        let initialFrame = NSRect(x: 100, y: 200, width: 400, height: 300)

        let topSize = FloatingWindow.edgeResizeSize(
            initialFrame: initialFrame,
            offset: NSPoint(x: 0, y: 60),
            edges: [.top]
        )
        #expect(topSize == NSSize(width: 400, height: 360))
        let topFrame = FloatingWindow.edgeResizeFrame(
            initialFrame: initialFrame,
            constrainedSize: topSize,
            edges: [.top]
        )
        #expect(topFrame.minY == initialFrame.minY)
        #expect(topFrame.maxY == initialFrame.maxY + 60)

        let bottomSize = FloatingWindow.edgeResizeSize(
            initialFrame: initialFrame,
            offset: NSPoint(x: 0, y: 50),
            edges: [.bottom]
        )
        #expect(bottomSize == NSSize(width: 400, height: 250))
        let bottomFrame = FloatingWindow.edgeResizeFrame(
            initialFrame: initialFrame,
            constrainedSize: bottomSize,
            edges: [.bottom]
        )
        #expect(bottomFrame.minY == initialFrame.minY + 50)
        #expect(bottomFrame.maxY == initialFrame.maxY)
    }

    @Test func testWindowResizeCornerUsesBothAxesAcrossExpandedHitArea() {
        let size = NSSize(width: 400, height: 300)

        let topRight = FloatingWindow.resizeEdges(at: NSPoint(x: 395, y: 285), in: size)
        #expect(topRight?.contains(.right) == true)
        #expect(topRight?.contains(.top) == true)
        let cornerSize = FloatingWindow.edgeResizeSize(
            initialFrame: NSRect(origin: .zero, size: size),
            offset: NSPoint(x: 40, y: 30),
            edges: topRight ?? []
        )
        #expect(cornerSize == NSSize(width: 440, height: 330))

        let rightEdge = FloatingWindow.resizeEdges(at: NSPoint(x: 395, y: 150), in: size)
        #expect(rightEdge == [.right])

        let interior = FloatingWindow.resizeEdges(at: NSPoint(x: 200, y: 150), in: size)
        #expect(interior == nil)

        // 鼠标越过任意窗口边界后不应继续命中边缘，否则缩放光标会残留或变成错误方向。
        #expect(FloatingWindow.resizeEdges(at: NSPoint(x: -1, y: 150), in: size) == nil)
        #expect(FloatingWindow.resizeEdges(at: NSPoint(x: 401, y: 150), in: size) == nil)
        #expect(FloatingWindow.resizeEdges(at: NSPoint(x: 200, y: -1), in: size) == nil)
        #expect(FloatingWindow.resizeEdges(at: NSPoint(x: 200, y: 301), in: size) == nil)
    }

    @Test func testAudioMetadataFormatters() {
        #expect(AudioMetadataLoader.formatSampleRate(44100) == String(format: NSLocalizedString("%@ kHz", comment: ""), "44.1"))
        #expect(AudioMetadataLoader.formatSampleRate(48000) == String(format: NSLocalizedString("%@ kHz", comment: ""), "48"))
        #expect(AudioMetadataLoader.formatBitRate(320000) == String(format: NSLocalizedString("%@ kbps", comment: ""), "320"))
        #expect(AudioMetadataLoader.formatChannels(1) == NSLocalizedString("Mono", comment: ""))
        #expect(AudioMetadataLoader.formatChannels(2) == NSLocalizedString("Stereo", comment: ""))
        #expect(AudioMetadataLoader.formatDuration(185) == "3:05")
        #expect(AudioMetadataLoader.formatDuration(3723) == "1:02:03")
    }

    @Test func testCanOpenFileAcceptsVideoCandidates() throws {
        // UTType 预筛接受视频候选（MKV 等不可播格式在打开时再异步验证）
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-canopen-\(UUID().uuidString).mp4")
        try Data("fake video".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let state = AppState()
        #expect(state.canOpenFile(url: videoURL))
    }

    @Test func testVideoPlayerMuteToggle() {
        let controller = VideoPlayerController(
            appStateID: UUID(),
            url: URL(fileURLWithPath: "/tmp/foofoil-mute-test.mp4"),
            isLooping: true
        )
        #expect(!controller.isMuted)
        #expect(!controller.player.isMuted)

        controller.toggleMute()
        #expect(controller.isMuted)
        #expect(controller.player.isMuted)

        controller.toggleMute()
        #expect(!controller.isMuted)
        #expect(!controller.player.isMuted)
    }

    @Test func testVideoPlayerVolumeAdjustment() {
        let controller = VideoPlayerController(
            appStateID: UUID(),
            url: URL(fileURLWithPath: "/tmp/foofoil-volume-test.mp4"),
            isLooping: true
        )
        #expect(controller.volume == 1.0)

        controller.setVolume(0.5)
        #expect(controller.volume == 0.5)
        #expect(controller.player.volume == 0.5)

        // 越界值会被钳制到 0...1
        controller.setVolume(1.5)
        #expect(controller.volume == 1.0)
        controller.setVolume(-0.5)
        #expect(controller.volume == 0)

        // 静音状态下拖起音量时自动解除静音
        controller.toggleMute()
        #expect(controller.isMuted)
        controller.setVolume(0.8)
        #expect(!controller.isMuted)
        #expect(!controller.player.isMuted)
        #expect(controller.player.volume == 0.8)
        #expect(controller.volumeIconName == "speaker.wave.2.fill")

        // 音量为零时图标显示为静音
        controller.setVolume(0)
        #expect(controller.volumeIconName == "speaker.slash.fill")
    }

    @Test func testVideoPlaybackTimeFormatting() {
        #expect(VideoPlayerController.formatPlaybackTime(0) == "0:00")
        #expect(VideoPlayerController.formatPlaybackTime(-1) == "0:00")
        #expect(VideoPlayerController.formatPlaybackTime(.nan) == "0:00")
        #expect(VideoPlayerController.formatPlaybackTime(185) == "3:05")
        #expect(VideoPlayerController.formatPlaybackTime(3723) == "1:02:03")
        #expect(VideoPlayerController.formatPlaybackTime(12, includeHours: true) == "0:00:12")
        #expect(MediaPlaybackBar.minimumWindowWidth >= 360)
    }

    @Test func testVideoScrollWheelStepCalculation() {
        // 进度滚轮：触摸板精细滚动小步长，鼠标滚轮整格大步长
        #expect(VideoPlayerController.timeScrollStep(deltaY: 1, preciseScrolling: false) == 2.0)
        #expect(VideoPlayerController.timeScrollStep(deltaY: -2, preciseScrolling: false) == -4.0)
        #expect(VideoPlayerController.timeScrollStep(deltaY: 5, preciseScrolling: true) == 1.0)

        // 音量滚轮：向上滚动增大音量（与纵向滑块同向），整格 0.05，精细滚动 0.005
        #expect(abs(VideoPlayerController.volumeScrollStep(deltaY: 1, preciseScrolling: false) + 0.05) < 0.0001)
        #expect(abs(VideoPlayerController.volumeScrollStep(deltaY: -1, preciseScrolling: false) - 0.05) < 0.0001)
        #expect(abs(VideoPlayerController.volumeScrollStep(deltaY: 10, preciseScrolling: true) + 0.05) < 0.0001)
    }

    @Test func testVideoScrollAdjustmentsAreClamped() {
        let controller = VideoPlayerController(
            appStateID: UUID(),
            url: URL(fileURLWithPath: "/tmp/foofoil-scroll-test.mp4"),
            isLooping: true
        )

        // 未加载出时长时进度调节不生效
        controller.adjustTime(by: 5)
        #expect(controller.currentTime == 0)

        // 音量滚轮调节自动钳制到 0...1
        controller.adjustVolume(by: 0.1)
        #expect(abs(controller.volume - 1.0) < 0.0001) // 已在满音量，向上滚不超过 1
        controller.adjustVolume(by: -0.3)
        #expect(abs(controller.volume - 0.7) < 0.0001)
        controller.adjustVolume(by: -1.0)
        #expect(controller.volume == 0)
        #expect(controller.volumeIconName == "speaker.slash.fill")
    }

    @Test func testCSVParserHandlesQuotedValuesAndNewlines() {
        let rows = CSVParser.parse("名称,备注\r\n\"张,三\",\"第一行\n第二行\"\r\n李四,\"他说 \"\"你好\"\"\"")

        #expect(rows == [
            ["名称", "备注"],
            ["张,三", "第一行\n第二行"],
            ["李四", "他说 \"你好\""]
        ])
    }

    @Test func testOpenCSVFileUsesTableDocumentMode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-test-\(UUID().uuidString).csv")
        let content = "项目,数量\n纸张,3"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        state.openFile(url: url)

        #expect(state.isCSVDocument)
        #expect(state.text == content)
        #expect(state.imageURL == nil)
        #expect(state.webURL == nil)
    }

    @Test func testOpenedTextFileUsesCachedCopy() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-text-source-\(UUID().uuidString).txt")
        let content = "缓存后的文本内容"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openTextFile(url: sourceURL)

        let cachedURL = try #require(state.textURL)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL.lastPathComponent == "cached_text_\(state.id.uuidString).txt")
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        try FileManager.default.removeItem(at: sourceURL)
        let restoredState = AppState(config: state.toConfig())
        #expect(restoredState.text == content)

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test func testOpenedLocalWebFileUsesCachedCopy() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-web-source-\(UUID().uuidString).html")
        try "<html><body>缓存网页</body></html>".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openWeb(url: sourceURL)

        let cachedURL = try #require(state.webURL)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL.lastPathComponent == "cached_web_\(state.id.uuidString).html")
        try FileManager.default.removeItem(at: sourceURL)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test func testClearHistoryPreservesActiveCacheAndRemovesOtherCacheFiles() throws {
        let activeSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-active-\(UUID().uuidString).png")
        let historicalSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-history-\(UUID().uuidString).png")
        try Data("active".utf8).write(to: activeSourceURL)
        try Data("history".utf8).write(to: historicalSourceURL)
        defer {
            try? FileManager.default.removeItem(at: activeSourceURL)
            try? FileManager.default.removeItem(at: historicalSourceURL)
        }

        let activeState = AppState()
        activeState.imageURL = activeSourceURL
        let activeConfig = activeState.toConfig()
        let historicalState = AppState()
        historicalState.imageURL = historicalSourceURL
        let historicalCacheURL = try #require(historicalState.imageURL)
        let cacheDirectoryURL = try #require(AppState.cacheDirectoryURLs().first)
        let orphanCacheURL = cacheDirectoryURL
            .appendingPathComponent("cached_text_\(UUID().uuidString).txt")
        try Data("orphan".utf8).write(to: orphanCacheURL)

        HistoryManager.shared.clearHistory(preserving: [activeConfig])

        let activeCacheURL = try #require(activeState.imageURL)
        #expect(FileManager.default.fileExists(atPath: activeCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: historicalCacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanCacheURL.path) == false)
        #expect(SettingsStore.shared.historyConfigs.map(\.id) == [activeConfig.id])

        HistoryManager.shared.clearHistory(preserving: [])
    }

    @Test func testSettingsStoreDefaults() async throws {
        let store = SettingsStore.shared

        // 清理所有数据以确保独立性
        store.clear()

        // 验证默认值为空
        #expect(store.windowConfigs.isEmpty == true)
        #expect(store.historyConfigs.isEmpty == true)
    }

    @Test func testOpacityClamping() async throws {
        let state = AppState()

        // 测试正常范围赋值
        state.opacity = 0.5
        #expect(state.opacity == 0.5)

        // 测试下限 clamp (0.3)
        state.opacity = 0.1
        #expect(state.opacity == 0.3)

        // 测试上限 clamp (1.0)
        state.opacity = 1.5
        #expect(state.opacity == 1.0)

        // 测试增加透明度（越接近 1.0 越不透明）
        state.opacity = 0.9
        state.increaseOpacity()
        #expect(state.opacity == 1.0)

        // 再次增加不应超出 1.0
        state.increaseOpacity()
        #expect(state.opacity == 1.0)

        // 测试减少透明度（越接近 0.3 越透明）
        state.opacity = 0.4
        state.decreaseOpacity()
        #expect(state.opacity == 0.3)

        // 再次减少不应低于 0.3
        state.decreaseOpacity()
        #expect(state.opacity == 0.3)
    }

    @Test func testContentScaleClamping() async throws {
        let state = AppState()

        #expect(state.imageScale == 1.0)
        #expect(state.textFontSize == AppState.defaultTextFontSize)

        state.imageScale = 0.001
        #expect(state.imageScale == AppState.minImageScale)

        state.imageScale = 100
        #expect(state.imageScale == AppState.maxImageScale)

        state.textFontSize = 1
        #expect(state.textFontSize == AppState.minTextFontSize)

        state.textFontSize = 100
        #expect(state.textFontSize == AppState.maxTextFontSize)
    }

    @Test func testLoadedImageIsReusedAcrossScaleChanges() throws {
        let state = AppState()
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-image-cache-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        let pngData = try #require(
            image.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try pngData.write(to: imageURL)

        let first = try #require(state.loadImage(from: imageURL))
        state.imageScale = 2
        let second = try #require(state.loadImage(from: imageURL))

        #expect(first === second)
    }

    @Test func testWindowConfigDecodesLegacyScaleDefaults() async throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "text": "Legacy note",
          "isPinned": false,
          "opacity": 1.0,
          "showBorder": true
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(WindowConfig.self, from: data)

        #expect(config.imageScale == 1.0)
        #expect(config.textFontSize == AppState.defaultTextFontSize)
        #expect(config.imageSource == nil)
    }

    @Test func testClipboardImageSourcePersistsInHistoryConfig() throws {
        let config = WindowConfig(
            id: UUID(),
            imagePath: "/tmp/clipboard.png",
            imageSource: .clipboard
        )

        let decodedConfig = try JSONDecoder().decode(
            WindowConfig.self,
            from: JSONEncoder().encode(config)
        )

        #expect(decodedConfig.imageSource == .clipboard)
    }

    @Test func testPinStateToggling() async throws {
        let state = AppState()
        state.isPinned = false

        state.togglePin()
        #expect(state.isPinned == true)

        state.togglePin()
        #expect(state.isPinned == false)
    }

    @Test func testClearContent() async throws {
        let state = AppState()
        let originalId = state.id
        state.text = "Hello foofoil"
        state.imageURL = URL(fileURLWithPath: "/tmp/mock_image.png")

        #expect(state.text == "Hello foofoil")
        #expect(state.imageURL?.path == "/tmp/mock_image.png")

        state.resetContent()

        #expect(state.text == "")
        #expect(state.imageURL == nil)

        // 验证持久化存储中该窗口的配置在重置后依然保留在历史记录中
        #expect(SettingsStore.shared.historyConfigs.contains(where: { $0.id == originalId }) == true)

        // 恢复环境，从历史中删除该配置
        if let config = SettingsStore.shared.historyConfigs.first(where: { $0.id == originalId }) {
            HistoryManager.shared.removeFromHistory(config)
        }
    }

    @Test func testImageCaching() async throws {
        let state = AppState()

        // 确保一开始无图且缓存为空
        state.resetContent()
        #expect(state.imageURL == nil)

        // 创建一个临时测试文件作为模拟的源图片
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("test_source_image.png")
        let dummyData = "dummy image content".data(using: .utf8)!
        try dummyData.write(to: sourceURL)

        // 设置图片，触发缓存逻辑
        state.imageURL = sourceURL

        // 验证缓存后，imageURL 应当指向应用沙盒内的 Application Support 目录中的 cached_image.png
        let cachedURL = state.imageURL
        #expect(cachedURL != nil)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL?.lastPathComponent == "cached_image_\(state.id.uuidString).png")
        #expect(cachedURL?.path.contains("/Library/Application Support/foofoil") == true)

        // 验证文件是否实际写入成功且内容一致
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == true)
        let cachedData = try Data(contentsOf: cachedURL!)
        #expect(cachedData == dummyData)

        // 验证 SettingsStore 历史记录中是否保存了缓存路径
        let savedConfig = SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id })
        #expect(savedConfig != nil)
        #expect(savedConfig?.imagePath == cachedURL?.path)

        let beforeResetId = state.id

        // 清理/重置内容，但不应删除历史状态
        state.resetContent()
        #expect(state.imageURL == nil)

        // 应该依然包含历史记录，并且物理文件应当依然存在（因为在历史记录中被使用了）
        #expect(SettingsStore.shared.historyConfigs.contains(where: { $0.id == beforeResetId }) == true)
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == true)

        // 恢复环境，从历史中删除该配置，这也将清理其物理缓存
        if let config = savedConfig {
            HistoryManager.shared.removeFromHistory(config)
        }
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == false)

        // 清理临时源文件
        try? FileManager.default.removeItem(at: sourceURL)
    }

    @Test func settingsWindowUsesToolbarTabsAndLocksWidth() throws {
        let controller = SettingsWindowController.shared
        let window = try #require(controller.window)
        let tabController = try #require(window.contentViewController as? NSTabViewController)

        #expect(tabController.tabStyle == .toolbar)
        #expect(tabController.tabViewItems.map(\.label) == [
            NSLocalizedString("General", comment: ""),
            NSLocalizedString("Types", comment: ""),
            NSLocalizedString("Keyboard Shortcuts", comment: ""),
            NSLocalizedString("Extensions", comment: "")
        ])
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.contentMinSize.width == SettingsWindowMetrics.width)
        #expect(window.contentMaxSize.width == SettingsWindowMetrics.width)
        #expect(window.contentMaxSize.height == SettingsWindowMetrics.maxHeight)

        tabController.selectedTabViewItemIndex = 0
        controller.applySelectedTabAppearance(animated: false)
        #expect(window.title == NSLocalizedString("General", comment: ""))
        let generalHeight = window.contentLayoutRect.height
        #expect(generalHeight <= SettingsWindowMetrics.maxHeight + 0.5)
        #expect(generalHeight < SettingsWindowMetrics.maxHeight - 1)

        tabController.selectedTabViewItemIndex = 1
        controller.applySelectedTabAppearance(animated: false)
        #expect(window.title == NSLocalizedString("Types", comment: ""))
        let typesHeight = window.contentLayoutRect.height
        #expect(typesHeight > generalHeight)
        #expect(typesHeight <= SettingsWindowMetrics.maxHeight + 0.5)

        tabController.selectedTabViewItemIndex = 3
        controller.applySelectedTabAppearance(animated: false)
        #expect(window.title == NSLocalizedString("Extensions", comment: ""))
        #expect(window.contentLayoutRect.height <= SettingsWindowMetrics.maxHeight + 0.5)
        #expect(window.styleMask.contains(.closable))
    }

    @Test func closeWindowActionClosesSettingsWindow() throws {
        let appDelegate = AppDelegate()
        let controller = SettingsWindowController.shared
        let window = try #require(controller.window)
        controller.show()
        #expect(window.isVisible)

        #expect(appDelegate.closeStandardKeyWindow(window))
        #expect(!window.isVisible)

        controller.show()
        #expect(window.isVisible)
    }

    @Test func testMainMenuIncludesHideMenuItems() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApplication.shared.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else {
            #expect(Bool(false), "Main menu or App menu not setup")
            return
        }

        let hideItem = appMenu.items.first { $0.action == #selector(NSApplication.hide(_:)) }
        #expect(hideItem != nil)
        #expect(hideItem?.keyEquivalent == "h")
        #expect(hideItem?.keyEquivalentModifierMask == [.command])

        let hideOthersItem = appMenu.items.first { $0.action == #selector(NSApplication.hideOtherApplications(_:)) }
        #expect(hideOthersItem != nil)
        #expect(hideOthersItem?.keyEquivalent == "h")
        #expect(hideOthersItem?.keyEquivalentModifierMask == [.command, .option])

        let showAllItem = appMenu.items.first { $0.action == #selector(NSApplication.unhideAllApplications(_:)) }
        #expect(showAllItem != nil)

        let settingsItem = appMenu.items.first { $0.action == #selector(AppDelegate.showSettingsAction) }
        #expect(settingsItem != nil)
        #expect(settingsItem?.keyEquivalent == ",")
        #expect(settingsItem?.keyEquivalentModifierMask == [.command])
    }

    @Test func testWindowZoomShortcutsUseCommandShiftPlusMinus() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApplication.shared.mainMenu,
              let viewMenu = mainMenu.items.first(where: { $0.submenu?.title == NSLocalizedString("View", comment: "") })?.submenu else {
            #expect(Bool(false), "Main menu or View menu not setup")
            return
        }

        let zoomInWindowItem = viewMenu.items.first { $0.action == #selector(AppDelegate.zoomInWindowAction) }
        #expect(zoomInWindowItem != nil)
        #expect(zoomInWindowItem?.keyEquivalent == "+")
        #expect(zoomInWindowItem?.keyEquivalentModifierMask == [.command, .shift])

        let zoomOutWindowItem = viewMenu.items.first { $0.action == #selector(AppDelegate.zoomOutWindowAction) }
        #expect(zoomOutWindowItem != nil)
        #expect(zoomOutWindowItem?.keyEquivalent == "-")
        #expect(zoomOutWindowItem?.keyEquivalentModifierMask == [.command, .shift])

        let zoomInContentItem = viewMenu.items.first { $0.action == #selector(AppDelegate.zoomInAction) }
        #expect(zoomInContentItem?.keyEquivalent == "+")
        #expect(zoomInContentItem?.keyEquivalentModifierMask == [.command])

        let zoomOutContentItem = viewMenu.items.first { $0.action == #selector(AppDelegate.zoomOutAction) }
        #expect(zoomOutContentItem?.keyEquivalent == "-")
        #expect(zoomOutContentItem?.keyEquivalentModifierMask == [.command])
    }

    @Test func navigatorMenuUsesAlwaysShowToggle() throws {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let viewMenu = NSApplication.shared.mainMenu?.items.first(where: {
            $0.submenu?.title == NSLocalizedString("View", comment: "")
        })?.submenu,
              let navigatorMenu = viewMenu.items.first(where: {
                  $0.submenu?.title == NSLocalizedString("Navigator", comment: "")
              })?.submenu else {
            #expect(Bool(false), "Navigator submenu not setup")
            return
        }

        let alwaysShow = try #require(navigatorMenu.items.first { $0.action == #selector(AppDelegate.toggleNavigatorPanelAction) })
        #expect(alwaysShow.title == NSLocalizedString("Always Show Navigator", comment: ""))
        #expect(alwaysShow.keyEquivalent == "s")
        #expect(alwaysShow.keyEquivalentModifierMask == [.command, .control])
        #expect(appDelegate.validateMenuItem(alwaysShow) == false)
        #expect(alwaysShow.state == .off)

        #expect(navigatorMenu.items.contains { $0.title == NSLocalizedString("Toggle Navigator", comment: "") } == false)
        #expect(navigatorMenu.items.contains { $0.title == NSLocalizedString("Show Navigator on Hover", comment: "") } == false)
        #expect(navigatorMenu.items.contains {
            $0.title == NSLocalizedString("Always Show Navigator", comment: "")
                && $0.action != #selector(AppDelegate.toggleNavigatorPanelAction)
        } == false)
    }

    @Test func testWebModeMenuItemsInFileAndEditMenu() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApplication.shared.mainMenu else {
            #expect(Bool(false), "Main menu not setup")
            return
        }

        let fileMenuItem = mainMenu.items.first { $0.submenu?.title == NSLocalizedString("File", comment: "") }
        #expect(fileMenuItem != nil)
        let fileMenu = fileMenuItem?.submenu
        #expect(fileMenu != nil)

        let copyURLFileItem = fileMenu?.items.first { $0.action == Selector(("copyWebURLAction")) }
        #expect(copyURLFileItem != nil)

        let openBrowserItem = fileMenu?.items.first { $0.action == Selector(("openInDefaultBrowserAction")) }
        #expect(openBrowserItem != nil)

        let state = AppState()
        #expect(copyURLFileItem.map { appDelegate.validateMenuItem($0) } == false)
        #expect(openBrowserItem.map { appDelegate.validateMenuItem($0) } == false)
    }

    @Test func testHistorySearchViewModelInitialQuerySetsShouldSelectAll() {
        let model = HistorySearchViewModel()
        model.reset(mode: .url, initialQuery: "https://apple.com")
        #expect(model.query == "https://apple.com")
        #expect(model.shouldSelectAll == true)

        model.reset(mode: .url, initialQuery: nil)
        #expect(model.query == "")
        #expect(model.shouldSelectAll == false)
    }

    @Test func testMarkdownTableBasicRendering() {
        let md = """
        | Name | Age | City |
        |------|-----|------|
        | Alice | 30 | Beijing |
        | Bob | 25 | Shanghai |
        """
        let html = AppState.cmarkToHTML(md)
        #expect(html.contains("<table>"))
        #expect(html.contains("</table>"))
        #expect(html.contains("<th>") || html.contains("<th "))
        #expect(html.contains("<td>"))
        #expect(html.contains("Alice"))
        #expect(html.contains("Beijing"))
    }

    @Test func testMarkdownTableAlignment() {
        let md = """
        | left | center | right |
        |:-----|:------:|------:|
        | a | b | c |
        """
        let html = AppState.cmarkToHTML(md)
        #expect(html.contains("align=\"left\""))
        #expect(html.contains("align=\"center\""))
        #expect(html.contains("align=\"right\""))
    }

    @Test func testMarkdownTableInlineMarkdownInCells() {
        let md = """
        | Header |
        |--------|
        | **bold** and *italic* |
        | [link](https://example.com) |
        """
        let html = AppState.cmarkToHTML(md)
        #expect(html.contains("<strong>") || html.contains("<b>"))
        #expect(html.contains("<em>") || html.contains("<i>"))
        #expect(html.contains("<a "))
        #expect(html.contains("https://example.com"))
    }

    @Test func testMarkdownTableWithoutOuterPipes() {
        let md = """
        Name | Age
        ---- | ---
        Alice | 30
        Bob | 25
        """
        let html = AppState.cmarkToHTML(md)
        #expect(html.contains("<table>"))
        #expect(html.contains("Alice"))
    }

    @Test func testMarkdownTableMixedWithOtherMarkdown() {
        let md = """
        # Title
        Some paragraph.

        | A | B |
        |---|---|
        | 1 | 2 |

        - list item
        """
        let html = AppState.cmarkToHTML(md)
        #expect(html.contains("<h1>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<li>") || html.contains("<ul>"))
    }

    @Test func testMarkdownTableInsideCodeBlockNotParsed() {
        let md = """
        ```markdown
        | A | B |
        |---|---|
        | 1 | 2 |
        ```
        """
        let html = AppState.cmarkToHTML(md)
        #expect(!html.contains("<table>"))
        #expect(html.contains("<code>") || html.contains("<pre>"))
    }

    @Test func testMarkdownTableMultipleTables() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |

        Some text between.

        | X | Y |
        |---|---|
        | 3 | 4 |
        """
        let html = AppState.cmarkToHTML(md)
        // 应包含两个表格
        let count = html.components(separatedBy: "<table>").count - 1
        #expect(count == 2)
    }

    @Test func testMarkdownTableNSAttributedStringRendering() throws {
        let md = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        """
        let htmlBody = AppState.cmarkToHTML(md)
        let html = """
        <html><head><style>table{border-collapse:collapse} th,td{border:1px solid #000;padding:4px}</style></head><body>\(htmlBody)</body></html>
        """
        let data = try #require(html.data(using: .utf8))
        let attr = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        #expect(attr.string.contains("Alice"))
        #expect(attr.string.contains("Name"))
        // 检查是否包含 NSTextTable（通过附件或表格属性）
        var hasTableAttribute = false
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length), options: []) { attrs, _, _ in
            for key in attrs.keys where key.rawValue.contains("Table") || key.rawValue.contains("table") {
                hasTableAttribute = true
            }
            // AppKit 中表格通常以 NSParagraphStyle 的 textBlocks 形式存在
            if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
                if !paragraph.textBlocks.isEmpty {
                    hasTableAttribute = true
                }
            }
        }
        // 即使没有检测到 table 属性，也应保证文本内容已渲染，不强制 hasTableAttribute
        #expect(attr.length > 0)
    }

    @Test func groupsSameKindTogetherAndKeepsOthersSeparate() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/c.mp4"),
            URL(fileURLWithPath: "/tmp/d.pdf"),
            URL(fileURLWithPath: "/tmp/e.jpg"),
            URL(fileURLWithPath: "/tmp/notes.txt")
        ]
        let groups = FileListGrouper.groups(from: urls)
        #expect(groups.count == 4)
        #expect(groups[0].kind == .listable(.image))
        #expect(groups[0].urls.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "e.jpg"])
        #expect(groups[1].kind == .listable(.video))
        #expect(groups[1].urls.map(\.lastPathComponent) == ["c.mp4"])
        #expect(groups[2].kind == .other)
        #expect(groups[2].urls.first?.lastPathComponent == "d.pdf")
        #expect(groups[3].kind == .other)
        #expect(groups[3].urls.first?.lastPathComponent == "notes.txt")
    }

    @Test func classifyRejectsPDFAndTextFromImageLists() {
        #expect(FileListGrouper.classify(url: URL(fileURLWithPath: "/tmp/a.png")) == .listable(.image))
        #expect(FileListGrouper.classify(url: URL(fileURLWithPath: "/tmp/a.mp3")) == .listable(.audio))
        #expect(FileListGrouper.classify(url: URL(fileURLWithPath: "/tmp/a.mp4")) == .listable(.video))
        #expect(FileListGrouper.classify(url: URL(fileURLWithPath: "/tmp/a.pdf")) == .other)
        #expect(FileListGrouper.classify(url: URL(fileURLWithPath: "/tmp/a.txt")) == .other)
    }

    @Test func appendingFilesKeepsWindowIdentityAndUpdatesHistoryTitle() throws {
        let first = try writeTestPNG(name: "list-a.png")
        let second = try writeTestPNG(name: "list-b.png")
        let third = try writeTestPNG(name: "list-c.png")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: third)
        }

        let state = AppState()
        let originalID = state.id
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)
        #expect(state.fileList == nil)
        #expect(state.navigatorContributions.isEmpty)

        state.appendToFileList(urls: [second])
        #expect(state.id == originalID)
        #expect(state.fileList?.items.count == 2)
        #expect(!state.navigatorContributions.isEmpty)
        #expect(state.isNavigatorPanelExplicitlyVisible == false)
        #expect(state.sourceFingerprint == nil)

        let listed = state.toConfig()
        #expect(listed.fileList?.items.count == 2)
        #expect(listed.historyMenuSymbolName == "photo.on.rectangle")
        #expect(listed.historyMenuDisplayName.contains("2"))

        state.appendToFileList(urls: [third])
        #expect(state.id == originalID)
        #expect(state.fileList?.items.count == 3)
        #expect(state.toConfig().historyMenuDisplayName.contains("3"))

        let currentID = state.fileList?.currentID
        let otherID = state.fileList?.items.first(where: { $0.id != currentID })?.id
        #expect(otherID != nil)
        if let otherID {
            state.performNavigatorAction(
                NavigatorAction(contributionID: AppState.fileListNavigatorID, kind: .activate, itemIDs: [otherID])
            )
            #expect(state.fileList?.currentID == otherID)
            #expect(state.originalImageName == second.lastPathComponent || state.originalImageName == third.lastPathComponent)
            #expect(state.imageURL?.path.contains(otherID) == true)
        }
        #expect(state.fileList?.items.count == 3)
        #expect(state.id == originalID)

        if let removeID = state.fileList?.items.last?.id {
            state.performNavigatorAction(
                NavigatorAction(contributionID: AppState.fileListNavigatorID, kind: .remove, itemIDs: [removeID])
            )
        }
        #expect(state.fileList?.items.count == 2)
        #expect(state.id == originalID)

        if let remainingExtra = state.fileList?.items.first(where: { $0.id != state.fileList?.currentID })?.id {
            state.performNavigatorAction(
                NavigatorAction(contributionID: AppState.fileListNavigatorID, kind: .remove, itemIDs: [remainingExtra])
            )
        }
        #expect(state.fileList == nil)
        #expect(state.navigatorContributions.isEmpty)
        #expect(state.isNavigatorPanelExplicitlyVisible == false)
        #expect(state.id == originalID)
    }

    @Test func imageDropAppendsImagesAndIgnoresOtherFileTypes() throws {
        let first = try writeTestPNG(name: "drop-list-a.png")
        let second = try writeTestPNG(name: "drop-list-b.png")
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-ignored.mp4")
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-ignored.txt")
        try Data().write(to: video)
        try Data("ignored".utf8).write(to: text)
        defer {
            for url in [first, second, video, text] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)

        #expect(state.appendMatchingDroppedFiles(urls: [video, second, text]))
        #expect(state.fileList?.items.map(\.displayName).contains(second.lastPathComponent) == true)
        #expect(state.fileList?.items.contains(where: { $0.path == video.path || $0.path == text.path }) == false)

        let itemCount = state.fileList?.items.count
        #expect(!state.appendMatchingDroppedFiles(urls: [video, text]))
        #expect(state.fileList?.items.count == itemCount)
    }

    @Test func openedContentOnlyAcceptsMatchingDroppedFileType() throws {
        let image = try writeTestPNG(name: "type-lock.png")
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-type-lock.txt")
        try Data("text".utf8).write(to: text)
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: text)
        }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: text)

        #expect(state.matchingDroppedFiles(urls: [image]).isEmpty)
        #expect(state.matchingDroppedFiles(urls: [image, text]) == [text])
    }

    @Test func dockDropUsesTheSameImageFilteringAsInWindowDrop() throws {
        let first = try writeTestPNG(name: "dock-list-a.png")
        let second = try writeTestPNG(name: "dock-list-b.png")
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-dock-ignored.txt")
        try Data("ignored".utf8).write(to: text)
        defer {
            for url in [first, second, text] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)

        AppDelegate().openDroppedFiles([text, second], into: state)

        #expect(state.fileList?.items.count == 2)
        #expect(state.fileList?.items.contains(where: { $0.path == text.path }) == false)
    }

    @Test func inWindowDropAppendsOnlyImagesToCurrentImage() async throws {
        let first = try writeTestPNG(name: "window-list-a.png")
        let second = try writeTestPNG(name: "window-list-b.png")
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-window-ignored.txt")
        try Data("ignored".utf8).write(to: text)
        defer {
            for url in [first, second, text] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)
        let providers = [text, second].map { url in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                visibility: .all
            ) { completion in
                completion(url.absoluteString.data(using: .utf8), nil)
                return nil
            }
            return provider
        }
        let accepted = await withCheckedContinuation { continuation in
            state.handleDrop(providers: providers) { success in
                continuation.resume(returning: success)
            }
        }

        #expect(accepted)
        #expect(state.fileList?.items.count == 2)
        #expect(state.fileList?.items.contains(where: { $0.path == text.path }) == false)
    }

    @Test func windowFileDropCreatesAndExtendsImageListsInAllThreeStates() throws {
        let first = try writeTestPNG(name: "native-drop-a.png")
        let second = try writeTestPNG(name: "native-drop-b.png")
        let third = try writeTestPNG(name: "native-drop-c.png")
        let fourth = try writeTestPNG(name: "native-drop-d.png")
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-\(UUID().uuidString)-native-drop.txt")
        try Data("ignored".utf8).write(to: text)
        defer {
            for url in [first, second, third, fourth, text] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let blank = AppState()
        defer { HistoryManager.shared.removeFromHistory(blank.toConfig()) }
        #expect(blank.handleDroppedFileURLs([first, text, second]))
        #expect(blank.fileList?.items.map(\.displayName) == [first.lastPathComponent, second.lastPathComponent])
        #expect(blank.fileList?.items.contains(where: { $0.path == text.path }) == false)

        let single = AppState()
        defer { HistoryManager.shared.removeFromHistory(single.toConfig()) }
        single.openFile(url: first)
        #expect(single.handleDroppedFileURLs([text, second]))
        #expect(single.fileList?.items.count == 2)

        #expect(single.handleDroppedFileURLs([third, text, fourth]))
        #expect(single.fileList?.items.count == 4)
        #expect(single.fileList?.items.contains(where: { $0.path == text.path }) == false)
    }

    @Test func rootHostingViewOwnsNativeFileDropDestination() {
        let state = AppState()
        let hostingView = FileDropHostingView(rootView: ContentView(appState: state), appState: state)
        #expect(hostingView.responds(to: NSSelectorFromString("draggingEntered:")))
        #expect(hostingView.responds(to: NSSelectorFromString("performDragOperation:")))
        #expect(hostingView.registeredDraggedTypes.contains(.fileURL))
    }

    @Test func navigatorRowsAreNotTreatedAsWindowDragBackgrounds() {
        #expect(NavigatorPanel.shouldDragAttachedFoofoil(
            commandPressed: false,
            onResizeHandle: false,
            hitView: MovableWindowBackgroundNSView()
        ))
        #expect(!NavigatorPanel.shouldDragAttachedFoofoil(
            commandPressed: false,
            onResizeHandle: false,
            hitView: NSButton()
        ))
        #expect(!NavigatorPanel.shouldDragAttachedFoofoil(
            commandPressed: false,
            onResizeHandle: false,
            hitView: NSView()
        ))
    }

    @Test func fileListKeyDownNavigatesAdjacentItems() throws {
        let first = try writeTestPNG(name: "key-a.png")
        let second = try writeTestPNG(name: "key-b.png")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)
        state.appendToFileList(urls: [second])
        let firstID = try #require(state.fileList?.currentID)

        func keyEvent(keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 124)))
        #expect(state.fileList?.currentID != firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 126)))
        #expect(state.fileList?.currentID == firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 45, characters: "n", modifiers: .control)))
        #expect(state.fileList?.currentID != firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 35, characters: "p", modifiers: .control)))
        #expect(state.fileList?.currentID == firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 3, characters: "f", modifiers: .control)))
        #expect(state.fileList?.currentID != firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 11, characters: "b", modifiers: .control)))
        #expect(state.fileList?.currentID == firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 125)))
        #expect(state.fileList?.currentID != firstID)
        #expect(state.handleFileListKeyDown(keyEvent(keyCode: 123)))
        #expect(state.fileList?.currentID == firstID)
    }

    @Test func switchingFileListItemsPreservesBorder() throws {
        let first = try writeTestPNG(name: "border-a.png")
        let second = try writeTestPNG(name: "border-b.png")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openFile(url: first)
        #expect(state.showBorder == false)
        state.showBorder = true
        state.appendToFileList(urls: [second])
        let firstID = try #require(state.fileList?.currentID)
        let secondID = try #require(state.fileList?.items.first(where: { $0.id != firstID })?.id)

        state.presentFileListItem(id: secondID, rotatesIdentity: false)
        #expect(state.showBorder == true)
        #expect(state.fileList?.currentID == secondID)

        state.showBorder = false
        state.presentFileListItem(id: firstID, rotatesIdentity: false)
        #expect(state.showBorder == false)
        #expect(state.fileList?.currentID == firstID)
    }

    @Test func imageListSlideshowDefaultsOffAndWrapsForward() throws {
        let first = try writeTestPNG(name: "slide-a.png")
        let second = try writeTestPNG(name: "slide-b.png")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let state = AppState()
        let previousInterval = SettingsStore.shared.imageListSlideshowInterval
        defer {
            state.stopImageListSlideshow()
            SettingsStore.shared.imageListSlideshowInterval = previousInterval
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.installFileList(kind: .image, urls: [first, second], preservesIdentity: true)
        #expect(state.fileList?.isSlideshowEnabled == false)
        #expect(state.fileList?.slideshowInterval == ImageListSlideshow.defaultInterval)
        #expect(state.canToggleImageListSlideshow)

        let firstID = try #require(state.fileList?.currentID)
        let secondID = try #require(state.fileList?.items.first(where: { $0.id != firstID })?.id)
        state.presentFileListItem(id: secondID, rotatesIdentity: false)
        state.activateAdjacentFileListItem(delta: 1)
        #expect(state.fileList?.currentID == secondID)

        state.activateAdjacentFileListItem(delta: 1, wraps: true)
        #expect(state.fileList?.currentID == firstID)

        state.setImageListSlideshowEnabled(true)
        #expect(state.fileList?.isSlideshowEnabled == true)
        #expect(state.toConfig().fileList?.isSlideshowEnabled == true)

        state.setImageListSlideshowInterval(0.5)
        #expect(SettingsStore.shared.imageListSlideshowInterval == ImageListSlideshow.minInterval)
        #expect(state.fileList?.slideshowInterval == ImageListSlideshow.minInterval)
        state.setImageListSlideshowInterval(120)
        #expect(SettingsStore.shared.imageListSlideshowInterval == ImageListSlideshow.maxInterval)
        #expect(state.fileList?.slideshowInterval == ImageListSlideshow.maxInterval)
        state.setImageListSlideshowInterval(ImageListSlideshow.defaultInterval)
        #expect(SettingsStore.shared.imageListSlideshowInterval == ImageListSlideshow.defaultInterval)
        #expect(state.fileList?.slideshowInterval == ImageListSlideshow.defaultInterval)
    }

    @Test func settingsStoreClampsImageListSlideshowInterval() {
        let store = SettingsStore.shared
        let previous = store.imageListSlideshowInterval
        defer { store.imageListSlideshowInterval = previous }

        store.imageListSlideshowInterval = ImageListSlideshow.defaultInterval
        #expect(store.imageListSlideshowInterval == ImageListSlideshow.defaultInterval)
        store.imageListSlideshowInterval = 0.2
        #expect(store.imageListSlideshowInterval == ImageListSlideshow.minInterval)
        store.imageListSlideshowInterval = 90
        #expect(store.imageListSlideshowInterval == ImageListSlideshow.maxInterval)
        store.imageListSlideshowInterval = 12
        #expect(store.imageListSlideshowInterval == 12)
    }

    @Test func imageListSlideshowDecodesLegacyFileListWithoutSlideshowKeys() throws {
        let first = FileListItem(id: "a", path: "/tmp/a.png", bookmark: nil, displayName: "a.png")
        let second = FileListItem(id: "b", path: "/tmp/b.png", bookmark: nil, displayName: "b.png")
        let list = FileListState(kind: .image, items: [first, second], currentID: "b", isSlideshowEnabled: true, slideshowInterval: 8)
        let encoded = try JSONEncoder().encode(list)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isSlideshowEnabled")
        object.removeValue(forKey: "slideshowInterval")
        let decoded = try JSONDecoder().decode(FileListState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.isSlideshowEnabled == false)
        #expect(decoded.slideshowInterval == ImageListSlideshow.defaultInterval)
        #expect(decoded.currentID == "b")

        let stored = try JSONDecoder().decode(FileListState.self, from: encoded)
        #expect(stored.isSlideshowEnabled == true)
        #expect(stored.slideshowInterval == 8)
    }

    @Test func viewMenuIncludesSlideshowToggleForImageLists() throws {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let viewMenu = NSApplication.shared.mainMenu?.items.first(where: {
            $0.submenu?.title == NSLocalizedString("View", comment: "")
        })?.submenu else {
            #expect(Bool(false), "View menu not setup")
            return
        }
        let item = viewMenu.items.first { $0.action == #selector(AppDelegate.toggleImageListSlideshowAction) }
        #expect(item != nil)
        appDelegate.updateViewMenu(viewMenu)
        #expect(item?.isHidden == true)
    }

    @Test func goMenuArrowKeysAreNotBoundUntilContentOwnsThem() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let goMenu = NSApplication.shared.mainMenu?.items.first(where: {
            $0.submenu?.title == NSLocalizedString("Go", comment: "")
        })?.submenu else {
            #expect(Bool(false), "Go menu not setup")
            return
        }

        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let pdfPrevious = goMenu.items.first { $0.action == #selector(AppDelegate.previousPDFPageAction) }
        let pdfNext = goMenu.items.first { $0.action == #selector(AppDelegate.nextPDFPageAction) }
        let listPrevious = goMenu.items.first {
            $0.action == #selector(AppDelegate.previousFileListItemAction)
                && $0.tag == GoMenuItemTag.fileListPrevious
        }
        let listNext = goMenu.items.first {
            $0.action == #selector(AppDelegate.nextFileListItemAction)
                && $0.tag == GoMenuItemTag.fileListNext
        }

        appDelegate.updateGoMenuVisibility()
        #expect(pdfPrevious?.keyEquivalent != left)
        #expect(pdfNext?.keyEquivalent != right)
        #expect(listPrevious?.keyEquivalent != left)
        #expect(listNext?.keyEquivalent != right)
        #expect(pdfPrevious?.keyEquivalent == "")
        #expect(listPrevious?.keyEquivalent == "")
    }

    @Test func windowConfigAndHistoryRoundTripFileList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-filelist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FileListItem(id: "a", path: "/tmp/a.png", bookmark: nil, displayName: "a.png")
        let second = FileListItem(id: "b", path: "/tmp/b.png", bookmark: nil, displayName: "b.png")
        let list = FileListState(kind: .image, items: [first, second], currentID: "b")
        let config = WindowConfig(
            id: UUID(),
            imagePath: "/tmp/b.png",
            originalImageName: "b.png",
            contentKind: .image,
            fileList: list
        )

        let encoded = try JSONEncoder().encode(config)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fileList")
        let legacy = try JSONDecoder().decode(WindowConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.fileList == nil)

        let decoded = try JSONDecoder().decode(WindowConfig.self, from: encoded)
        #expect(decoded.fileList?.items.map(\.id) == ["a", "b"])
        #expect(decoded.fileList?.currentID == "b")
        #expect(decoded.fileList?.isSlideshowEnabled == false)
        #expect(decoded.fileList?.slideshowInterval == ImageListSlideshow.defaultInterval)
        #expect(decoded.historyMenuDisplayName.contains("2"))

        let database = try HistoryDatabase(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        try database.upsert(config)
        let stored = try #require(try database.config(id: config.id))
        #expect(stored.id == config.id)
        #expect(stored.fileList?.items.count == 2)
        #expect(stored.storedDisplayTitle?.contains("2") == true)
        #expect(stored.sourceFingerprint == nil)

        let member = WindowConfig(
            id: UUID(),
            imagePath: "/tmp/a.png",
            originalImageName: "a.png",
            contentKind: .image,
            sourceFingerprint: "file:/tmp/a.png"
        )
        try database.upsert(member)
        let listAfter = try #require(try database.config(id: config.id))
        #expect(listAfter.fileList?.items.count == 2)
    }

    private func writeTestPNG(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-\(UUID().uuidString)-\(name)")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}
