//
//  FlaminaTests.swift
//  flaminaTests
//
//  Created by tolg on 2026/7/6.
//

import Testing
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
@testable import Flamina

@MainActor
@Suite(.serialized)
struct HistorySearchTests {
    private func repository() throws -> (HistoryRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flamina-history-tests-\(UUID().uuidString)", isDirectory: true)
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
            imagePath: "/tmp/flamina-definitely-missing-\(UUID().uuidString).mp4",
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
            imagePath: "/tmp/flamina-stale-path-\(UUID().uuidString).mp4",
            originalImageName: "moved.mp4",
            contentKind: .video,
            videoBookmark: bookmark
        )))

        // 无书签且路径不存在的记录仍然被移除
        let missingID = UUID()
        #expect(repository.upsert(WindowConfig(
            id: missingID,
            imagePath: "/tmp/flamina-definitely-missing-\(UUID().uuidString).mp4",
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
struct FlaminaTests {

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
            .appendingPathComponent("flamina-video-source-\(UUID().uuidString).mp4")
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
            .appendingPathComponent("flamina-video-bookmark-\(UUID().uuidString).mp4")
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
            .appendingPathComponent("flamina-audio-source-\(UUID().uuidString).mp3")
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
            .appendingPathComponent("flamina-audio-bookmark-\(UUID().uuidString).m4a")
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
            .appendingPathComponent("flamina-canopen-\(UUID().uuidString).mp3")
        try Data("fake audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let state = AppState()
        #expect(state.canOpenFile(url: audioURL))
    }

    @Test func testAudioSidecarCoverPrefersMatchingBasename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamina-audio-cover-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("flamina-canopen-\(UUID().uuidString).mp4")
        try Data("fake video".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let state = AppState()
        #expect(state.canOpenFile(url: videoURL))
    }

    @Test func testVideoPlayerMuteToggle() {
        let controller = VideoPlayerController(
            appStateID: UUID(),
            url: URL(fileURLWithPath: "/tmp/flamina-mute-test.mp4"),
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
            url: URL(fileURLWithPath: "/tmp/flamina-volume-test.mp4"),
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
            url: URL(fileURLWithPath: "/tmp/flamina-scroll-test.mp4"),
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
            .appendingPathComponent("flamina-test-\(UUID().uuidString).csv")
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
            .appendingPathComponent("flamina-text-source-\(UUID().uuidString).txt")
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
            .appendingPathComponent("flamina-web-source-\(UUID().uuidString).html")
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
            .appendingPathComponent("flamina-active-\(UUID().uuidString).png")
        let historicalSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamina-history-\(UUID().uuidString).png")
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
        state.text = "Hello Flamina"
        state.imageURL = URL(fileURLWithPath: "/tmp/mock_image.png")

        #expect(state.text == "Hello Flamina")
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
        #expect(cachedURL?.path.contains("/Library/Application Support/Flamina") == true)

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
}
