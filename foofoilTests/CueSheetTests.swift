//
//  CueSheetTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/8/28.
//

import Testing
import Foundation
import AppKit
import AVFoundation
@testable import foofoil
import FoofoilExtensionKit

@MainActor
@Suite(.serialized)
struct CueSheetTests {
    @Test func cueTimeUsesSeventyFiveFramesPerSecond() {
        #expect(CueTime.parse("00:00:00") == Int64(0))
        #expect(CueTime.parse("00:00:01") == Int64(1))
        #expect(CueTime.parse("00:01:00") == Int64(75))
        #expect(CueTime.parse("01:00:00") == Int64(75 * 60))
        #expect(CueTime.parse("05:32:37") == CueTime.frames(minutes: 5, seconds: 32, frames: 37))
        #expect(CueTime.parse("05:32:37") == Int64(24937))
        let time = CueTime.time(24937)
        #expect(time.value == 24937)
        #expect(time.timescale == CueTime.timescale)
        #expect(CueTime.parse("123:00:00") == Int64(123 * 75 * 60))
        #expect(CueTime.sampleFrame(cueFrames: 1, sampleRate: 44100) == Int64(588))
        #expect(CueTime.sampleFrame(cueFrames: 75, sampleRate: 44100) == Int64(44100))
        #expect(CueTime.sampleFrame(cueFrames: 75, sampleRate: 96000) == Int64(96000))
        #expect(CueTime.sampleFrame(cueFrames: 24937, sampleRate: 44100) == Int64(24937) * Int64(588))
        #expect(CueTime.cueFrames(sampleFrame: 588, sampleRate: 44100) == Int64(1))
        #expect(CueTime.cueFrames(sampleFrame: 44100, sampleRate: 44100) == Int64(75))
        #expect(CueTime.cueFrames(sampleFrame: 96000, sampleRate: 96000) == Int64(75))
        #expect(CueTime.cueFrames(sampleFrame: 24937 * 588, sampleRate: 44100) == Int64(24937))
        #expect(CueTime.parse("00:00") == nil)
        #expect(CueTime.parse("abc") == nil)
    }

    @Test func parserSplitsSharedFileByIndex01AndIgnoresPregap() {
        let text = """
        REM GENRE Progressive Rock
        REM DATE 1973-03-01
        PERFORMER "Pink Floyd"
        TITLE "The Dark Side of the Moon"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Speak to Me"
            INDEX 00 00:00:00
            INDEX 01 00:00:32
          TRACK 02 AUDIO
            TITLE "Breathe"
            PERFORMER "Pink Floyd"
            INDEX 01 01:08:12
          TRACK 03 AUDIO
            TITLE "On the Run"
            INDEX 00 03:55:00
            INDEX 01 03:57:50
        """
        let sheet = CueSheetParser.parse(text: text, cueURL: URL(fileURLWithPath: "/tmp/album.cue"))
        #expect(sheet.title == "The Dark Side of the Moon")
        #expect(sheet.displayTitle == "The Dark Side of the Moon")
        #expect(sheet.performer == "Pink Floyd")
        #expect(sheet.genre == "Progressive Rock")
        #expect(sheet.date == "1973")
        #expect(sheet.tracks.count == 3)

        let first = sheet.tracks[0]
        #expect(first.title == "Speak to Me")
        #expect(first.performer == "Pink Floyd")
        #expect(first.startCueFrames == CueTime.parse("00:00:32"))
        #expect(first.endCueFrames == CueTime.parse("01:08:12"))

        let second = sheet.tracks[1]
        #expect(second.title == "Breathe")
        #expect(second.startCueFrames == CueTime.parse("01:08:12"))
        #expect(second.endCueFrames == CueTime.parse("03:57:50"))

        let third = sheet.tracks[2]
        #expect(third.title == "On the Run")
        #expect(third.startCueFrames == CueTime.parse("03:57:50"))
        #expect(third.endCueFrames == nil)
    }

    @Test func cueDisplayTitleFallsBackToFileName() {
        let sheet = CueSheetParser.parse(
            text: "FILE \"disc.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00",
            cueURL: URL(fileURLWithPath: "/tmp/Archive Disc.cue")
        )
        #expect(sheet.displayTitle == "Archive Disc")
    }

    @Test func parserKeepsSeparateFilesIndependent() {
        let text = """
        TITLE "Singles"
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
        FILE "02.wav" WAVE
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:00:00
        """
        let sheet = CueSheetParser.parse(text: text, cueURL: URL(fileURLWithPath: "/tmp/album.cue"))
        #expect(sheet.tracks.count == 2)
        #expect(sheet.tracks[0].fileName == "01.wav")
        #expect(sheet.tracks[0].startCueFrames == 0)
        #expect(sheet.tracks[0].endCueFrames == nil)
        #expect(sheet.tracks[1].fileName == "02.wav")
        #expect(sheet.tracks[1].startCueFrames == 0)
        #expect(sheet.tracks[1].endCueFrames == nil)
    }

    @Test func parserReadsQuotedNamesWindowsPathsAndSkipsDataTracks() {
        let text = [
            "FILE \"My Album.bin\" BINARY",
            "  TRACK 01 MODE1/2048",
            "    INDEX 01 00:00:00",
            "  TRACK 02 AUDIO",
            "    TITLE \"Hello \"\"World\"\"\"",
            "    INDEX 01 01:00:00",
            "FILE \"D:\\music\\disc two.wav\" WAVE",
            "  TRACK 03 AUDIO",
            "    TITLE \"Side B\"",
            "    INDEX 01 00:00:00"
        ].joined(separator: "\n")
        let sheet = CueSheetParser.parse(text: text, cueURL: URL(fileURLWithPath: "/tmp/album.cue"))
        #expect(sheet.tracks.map(\.title) == ["Hello \"World\"", "Side B"])
        #expect(sheet.tracks[0].fileName == "My Album.bin")
        #expect(sheet.tracks[0].startCueFrames == CueTime.parse("01:00:00"))
        #expect(sheet.tracks[1].fileName == "D:\\music\\disc two.wav")
    }

    @Test func loaderResolvesMissingExtensionToSiblingAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appendingPathComponent("album.flac")
        try Data("fake audio".utf8).write(to: audio)
        let cue = directory.appendingPathComponent("album.cue")
        try """
        TITLE "Album"
        FILE "album.bin" BINARY
          TRACK 01 AUDIO
            TITLE "Intro"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Outro"
            INDEX 01 01:00:00
        """.write(to: cue, atomically: true, encoding: .utf8)

        let sheet = try #require(CueSheetLoader.load(from: cue))
        #expect(sheet.tracks.count == 2)
        #expect(sheet.tracks[0].fileURL?.path == audio.path)
        #expect(sheet.tracks[1].fileURL?.path == audio.path)
        #expect(sheet.tracks[0].endCueFrames == CueTime.parse("01:00:00"))
    }

    @Test func decodePrefersUTF8ThenGB18030() throws {
        let utf8 = Data("TITLE \"Café\"\nFILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n".utf8)
        #expect(CueSheetLoader.decodeText(utf8)?.contains("Café") == true)

        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let chinese = "TITLE \"测试专辑\"\nFILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n"
        let gbData = try #require(chinese.data(using: gbEncoding))
        #expect(String(data: gbData, encoding: .utf8) == nil)
        #expect(CueSheetLoader.decodeText(gbData)?.contains("测试专辑") == true)
    }

    @Test func mixedDropKeepsOnlyCueSheets() {
        let urls = [
            URL(fileURLWithPath: "/tmp/cover.png"),
            URL(fileURLWithPath: "/tmp/album.cue"),
            URL(fileURLWithPath: "/tmp/song.mp3"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/extra.cue")
        ]
        let groups = FileListGrouper.groups(from: urls)
        #expect(groups.count == 1)
        #expect(groups[0].kind == .cueSheets)
        #expect(groups[0].urls.map(\.lastPathComponent) == ["album.cue", "extra.cue"])
        #expect(FileListGrouper.preferredOpenableURLs(from: urls).map(\.lastPathComponent) == ["album.cue", "extra.cue"])
    }

    @Test func cueSheetInstallsTracksAndMultipleCuesBecomeSections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstAudio = directory.appendingPathComponent("first.flac")
        let secondAudio = directory.appendingPathComponent("second.flac")
        try Data("a".utf8).write(to: firstAudio)
        try Data("b".utf8).write(to: secondAudio)
        let firstCue = directory.appendingPathComponent("first.cue")
        let secondCue = directory.appendingPathComponent("second.cue")
        try cueSheet(title: "First Album", performer: "Artist A", fileName: "first.flac", tracks: [
            ("Intro", "00:00:00"),
            ("Song", "01:00:00")
        ]).write(to: firstCue, atomically: true, encoding: .utf8)
        try cueSheet(title: "Second Album", performer: "Artist B", fileName: "second.flac", tracks: [
            ("Only", "00:00:32")
        ]).write(to: secondCue, atomically: true, encoding: .utf8)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.handleDroppedFileURLs([firstCue]))
        #expect(state.fileList?.kind == .audio)
        #expect(state.fileList?.items.count == 2)
        #expect(state.fileList?.sections.count == 1)
        #expect(state.fileList?.items.map(\.displayName) == ["Intro", "Song"])
        #expect(state.fileList?.items[0].cue?.startCueFrames == 0)
        #expect(state.fileList?.items[0].cue?.endCueFrames == CueTime.parse("01:00:00"))
        #expect(state.fileList?.items[0].cue?.endSeconds == 60.0)
        #expect(state.currentPlaybackRange?.startCueFrames == 0)
        #expect(state.currentPlaybackRange?.endCueFrames == CueTime.parse("01:00:00"))
        #expect(state.fileList?.items[0].cue?.album == "First Album")
        #expect(state.fileList?.items[0].cue?.artist == "Artist A")
        #expect(state.fileList?.items[0].cue?.trackNumber == "1")
        #expect(state.navigatorContributions.first?.style == .flat)
        #expect(state.navigatorContributions.first?.items.map(\.title) == ["Intro", "Song"])
        #expect(state.navigatorContributions.first?.items.map(\.badge) == ["1:00", nil])

        let image = try writeDummyPNG(in: directory)
        #expect(state.handleDroppedFileURLs([secondCue, image, firstAudio]))
        #expect(state.fileList?.sections.count == 2)
        #expect(state.fileList?.items.count == 3)
        #expect(state.fileList?.items.map(\.displayName) == ["Intro", "Song", "Only"])
        #expect(state.fileList?.items.contains(where: { $0.path == image.path }) == false)
        #expect(state.navigatorContributions.first?.style == .outline)
        #expect(state.navigatorContributions.first?.items.map(\.title) == ["First Album", "Intro", "Song", "Second Album", "Only"])
        #expect(state.navigatorContributions.first?.items.filter { $0.parentID == nil }.map(\.title) == ["First Album", "Second Album"])
        #expect(state.navigatorContributions.first?.allowedActions.contains(.move) == true)

        let firstSectionID = try #require(state.fileList?.sections.first?.id)
        let secondSectionID = try #require(state.fileList?.sections.last?.id)
        state.performNavigatorAction(
            NavigatorAction(
                contributionID: AppState.fileListNavigatorID,
                kind: .move,
                itemIDs: [secondSectionID],
                destinationItemID: firstSectionID,
                movePosition: .before
            )
        )
        #expect(state.fileList?.sections.map(\.title) == ["Second Album", "First Album"])
        #expect(state.fileList?.items.map(\.displayName) == ["Only", "Intro", "Song"])
        #expect(state.navigatorContributions.first?.items.map(\.title) == ["Second Album", "Only", "First Album", "Intro", "Song"])
    }

    @Test func blankMixedDropOpensCueAndIgnoresOtherTypes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appendingPathComponent("disc.wav")
        try Data("audio".utf8).write(to: audio)
        let cue = directory.appendingPathComponent("disc.cue")
        try cueSheet(title: "Disc", performer: "Solo", fileName: "disc.wav", tracks: [
            ("A", "00:00:00"),
            ("B", "00:30:00")
        ]).write(to: cue, atomically: true, encoding: .utf8)
        let image = try writeDummyPNG(in: directory)
        let text = directory.appendingPathComponent("readme.txt")
        try Data("ignore".utf8).write(to: text)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.handleDroppedFileURLs([image, cue, text, audio]))
        #expect(state.fileList?.items.map(\.displayName) == ["A", "B"])
        #expect(state.fileList?.items.contains(where: { $0.path == image.path || $0.path == text.path }) == false)
        #expect(state.originalImageName == "disc.wav")
        #expect(state.isAudioDocument)
        #expect(state.fileList?.currentItem?.displayName == "A")
    }

    @Test func singleCueBecomesLabeledSectionAfterAppendingAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let albumAudio = directory.appendingPathComponent("album.wav")
        let extraAudio = directory.appendingPathComponent("extra.mp3")
        let cue = directory.appendingPathComponent("album.cue")
        try Data().write(to: albumAudio)
        try Data().write(to: extraAudio)
        try cueSheet(title: "Album", performer: "Artist", fileName: "album.wav", tracks: [
            ("First", "00:00:00"),
            ("Second", "01:00:00")
        ]).write(to: cue, atomically: true, encoding: .utf8)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.installCueSheets(urls: [cue], preservesIdentity: true)
        #expect(state.fileList?.soleContainerFormat == .cue)
        #expect(state.navigatorContributions.first?.style == .flat)

        state.appendToFileList(urls: [extraAudio])

        #expect(state.fileList?.soleContainerFormat == nil)
        let contribution = try #require(state.navigatorContributions.first)
        #expect(contribution.style == .outline)
        #expect(contribution.items.map(\.title) == ["Album", "First", "Second", "extra.mp3"])
        #expect(contribution.items.first?.badge == "CUE")
    }

    @Test func navigatorShowsCueSegmentDurationInsteadOfTrackNumber() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-duration-badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appendingPathComponent("disc.wav")
        try writePCMWav(url: audio, sampleRate: 44100, seconds: 2)
        let cue = directory.appendingPathComponent("disc.cue")
        try cueSheet(title: "Disc", performer: "Solo", fileName: "disc.wav", tracks: [
            ("Intro", "00:00:00"),
            ("Song", "00:01:00")
        ]).write(to: cue, atomically: true, encoding: .utf8)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.handleDroppedFileURLs([cue]))
        #expect(state.fileList?.title == "Disc")
        // 自定义（专辑）标题同样展示项数；CUE 列表标题与历史记录保持一致。
        let displayTitle = state.toConfig().historyMenuDisplayName
        #expect(displayTitle.contains("Disc"))
        #expect(displayTitle.contains("2"))
        let items = try #require(state.navigatorContributions.first?.items)
        #expect(items.map(\.title) == ["Intro", "Song"])
        #expect(items.map(\.badge) == ["0:01", "0:01"])
        #expect(items.allSatisfy { $0.badge != $0.id && $0.badge != "1" && $0.badge != "2" })
    }

    @Test func cueFieldsRoundTripThroughWindowConfig() throws {
        let cue = FileListCueInfo(
            startCueFrames: CueTime.frames(minutes: 0, seconds: 12, frames: 37),
            endCueFrames: CueTime.frames(minutes: 0, seconds: 48, frames: 0),
            title: "Track",
            artist: "Artist",
            album: "Album",
            trackNumber: "2",
            sectionID: "section",
            cueSheetPath: "/tmp/album.cue"
        )
        let item = FileListItem(
            id: "t1",
            path: "/tmp/album.flac",
            displayName: "Track",
            cue: cue
        )
        let second = FileListItem(id: "t2", path: "/tmp/album.flac", displayName: "Next", cue: cue)
        let list = FileListState(
            kind: .audio,
            items: [item, second],
            currentID: "t1",
            title: "Album",
            sections: [FileListSection(id: "section", title: "Album", cueSheetPath: "/tmp/album.cue")]
        )
        let encoded = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(FileListState.self, from: encoded)
        #expect(decoded.items[0].cue?.startCueFrames == CueTime.frames(minutes: 0, seconds: 12, frames: 37))
        #expect(decoded.items[0].cue?.endCueFrames == CueTime.frames(minutes: 0, seconds: 48, frames: 0))
        #expect(decoded.items[0].cue?.title == "Track")
        #expect(decoded.title == "Album")
        #expect(decoded.sections.first?.title == "Album")

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "title")
        object.removeValue(forKey: "sections")
        if var items = object["items"] as? [[String: Any]] {
            items = items.map { item in
                var copy = item
                copy.removeValue(forKey: "cue")
                return copy
            }
            object["items"] = items
        }
        let legacy = try JSONDecoder().decode(FileListState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.sections.isEmpty)
        #expect(legacy.title == nil)
        #expect(legacy.items[0].cue == nil)
    }

    @Test func playbackTimingUsesSampleFramesAndCueTimesMapToCDSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-timing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePCMWav(url: url, sampleRate: 44100, seconds: 2)

        let timing = try #require(AudioMetadataLoader.playbackTiming(for: url))
        #expect(abs(timing.duration - 2.0) < 0.02)
        #expect(abs(timing.sampleRate - 44100) < 0.1)
        #expect(timing.sampleCount == Int64(88200))

        let cueTime = CueTime.time(CueTime.frames(minutes: 5, seconds: 32, frames: 37))
        #expect(cueTime.value == 24937)
        #expect(cueTime.timescale == CueTime.timescale)
    }

    @Test func navigatorMediaDurationLoaderReadsAudioDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-navigator-duration-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePCMWav(url: url, sampleRate: 44100, seconds: 2)

        let duration = try #require(await MediaDurationLoader.duration(for: url, kind: .audio))
        #expect(abs(duration - 2.0) < 0.02)
    }

    @Test func audioControllerPreparesCueSegmentWithoutStartingDuringViewConstruction() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-cue-prepare-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePCMWav(url: url, sampleRate: 44100, seconds: 2)

        let controller = AudioPlaybackController(
            appStateID: UUID(),
            url: url,
            isLooping: false,
            range: MediaPlaybackRange(startCueFrames: 0, endCueFrames: 75)
        )

        #expect(controller.duration == 1)
        #expect(controller.currentTime == 0)
        #expect(!controller.isPlaying)
    }

    @Test func sacdQueueInstallsCueLikeNavigator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-sacd-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.iso")
        try Data("iso".utf8).write(to: url)
        let queue = MediaPlaybackQueueSnapshot(
            items: [
                MediaPlaybackQueueItem(
                    id: "track:stereo:01",
                    title: "Allegro",
                    subtitle: "Beethoven",
                    duration: 60
                ),
                MediaPlaybackQueueItem(
                    id: "track:stereo:02",
                    title: "Andante",
                    subtitle: "Beethoven",
                    duration: 90
                )
            ],
            currentItemID: "track:stereo:01",
            title: "Symphony No. 5"
        )
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.installContainerAudioList(url: url, queue: queue, bookmark: nil)

        #expect(state.fileList?.kind == .audio)
        #expect(state.fileList?.isCueBased == true)
        #expect(state.fileList?.isReorderable == false)
        #expect(state.fileList?.soleContainerFormat == .sacd)
        #expect(state.fileList?.title == "Symphony No. 5")
        #expect(state.fileList?.items.map(\.displayName) == ["Allegro", "Andante"])
        #expect(state.fileList?.items.map(\.path) == [url.path, url.path])
        #expect(state.fileList?.items.map(\.id) == ["track:stereo:01", "track:stereo:02"])
        #expect(state.fileList?.items[0].cue?.artist == "Beethoven")
        #expect(state.fileList?.items[0].cue?.album == "Symphony No. 5")
        let contribution = try #require(state.navigatorContributions.first)
        #expect(contribution.id == AppState.fileListNavigatorID)
        #expect(contribution.style == .flat)
        #expect(contribution.items.map(\.title) == ["Allegro", "Andante"])
        #expect(contribution.items.map(\.subtitle) == ["Beethoven", "Beethoven"])
        #expect(contribution.items.map(\.badge) == ["1:00", "1:30"])
        #expect(!contribution.allowedActions.contains(.move))
    }

    @Test func sacdBecomesLabeledSectionWhenMixedWithAudioFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-sacd-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let iso = directory.appendingPathComponent("album.iso")
        let song = directory.appendingPathComponent("encore.mp3")
        try Data("iso".utf8).write(to: iso)
        try Data().write(to: song)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let isoItem = state.makeFileListItem(url: iso)
        let songItem = state.makeFileListItem(url: song)
        state.fileList = FileListState(
            kind: .audio,
            items: [isoItem, songItem],
            currentID: songItem.id
        )
        state.installContainerAudioList(
            url: iso,
            queue: MediaPlaybackQueueSnapshot(
                items: [
                    MediaPlaybackQueueItem(id: "track:1", title: "First", duration: 60),
                    MediaPlaybackQueueItem(id: "track:2", title: "Second", duration: 90)
                ],
                currentItemID: "track:1",
                title: "Album"
            ),
            bookmark: nil,
            selectsContainerTrack: false
        )

        let list = try #require(state.fileList)
        #expect(list.items.map(\.id) == ["track:1", "track:2", songItem.id])
        #expect(list.sections.count == 1)
        #expect(list.sections[0].resolvedFormat == .sacd)
        #expect(list.soleContainerFormat == nil)
        #expect(list.currentID == songItem.id)
        let contribution = try #require(state.navigatorContributions.first)
        #expect(contribution.style == .outline)
        #expect(contribution.items.map(\.title) == ["Album", "First", "Second", "encore.mp3"])
        #expect(contribution.items.first?.badge == "SACD")
        #expect(contribution.items.last?.parentID == nil)
    }

    @Test func sniffMatcherAcceptsSACDMagicAndIgnoresOrdinaryISO() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-iso-sniff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ordinary = directory.appendingPathComponent("disk.iso")
        try Data(repeating: 0, count: 32).write(to: ordinary)
        let sacd = directory.appendingPathComponent("album.iso")
        var payload = Data(repeating: 0, count: 511 * 2048)
        payload.replaceSubrange((510 * 2048)..<(510 * 2048 + 8), with: Data("SACDMTOC".utf8))
        try payload.write(to: sacd)

        let declarations = [ContentTypeDeclaration(extensions: ["iso"], strategy: .sniff)]
        let sniff: (URL) -> Bool = { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let offset = UInt64(510) * 2048
            guard let size = try? handle.seekToEnd(), size >= offset + 8 else { return false }
            try? handle.seek(toOffset: offset)
            return (try? handle.read(upToCount: 8)) == Data("SACDMTOC".utf8)
        }
        #expect(
            ProviderContentMatcher.match(
                .singleFile(.init(url: ordinary)),
                declarations: declarations,
                sniff: sniff
            ) == nil
        )
        let match = ProviderContentMatcher.match(
            .singleFile(.init(url: sacd)),
            declarations: declarations,
            sniff: sniff
        )
        #expect(match?.strength == .sniff)
        #expect(
            ProviderContentMatcher.match(
                .singleFile(.init(url: sacd)),
                declarations: declarations
            ) == nil
        )
    }

    private func writePCMWav(url: URL, sampleRate: Int, seconds: Double) throws {
        let frames = Int((Double(sampleRate) * seconds).rounded())
        let dataSize = frames * 2
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        u32(UInt32(36 + dataSize))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        try data.write(to: url)
    }

    private func cueSheet(
        title: String,
        performer: String,
        fileName: String,
        tracks: [(title: String, start: String)]
    ) -> String {
        var lines = [
            "PERFORMER \"\(performer)\"",
            "TITLE \"\(title)\"",
            "FILE \"\(fileName)\" WAVE"
        ]
        for (index, track) in tracks.enumerated() {
            lines.append("  TRACK \(String(format: "%02d", index + 1)) AUDIO")
            lines.append("    TITLE \"\(track.title)\"")
            lines.append("    INDEX 01 \(track.start)")
        }
        return lines.joined(separator: "\n")
    }

    private func writeDummyPNG(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("cover.png")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}
