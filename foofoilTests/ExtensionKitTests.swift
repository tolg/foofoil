//  ExtensionKitTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/8/25.

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import foofoil
import FoofoilExtensionKit

@MainActor
@Suite(.serialized)
struct ExtensionKitTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-extension-kit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func validatesManifestFixtureAndNegotiatesHighestCommonAPI() throws {
        let url = try #require(ExtensionKitResources.fixture(named: "TestExtensionManifest"))
        let manifest = try ExtensionManifestValidator.decodeAndValidate(Data(contentsOf: url))

        #expect(manifest.id == LocalTestExtension.identifier)
        #expect(manifest.providers.map(\.id) == ["test.content", "test.audio-enhancer"])
        #expect(manifest.providers.last?.contentFamily == .audio)
        #expect(manifest.capabilities.map(\.id).contains(ExtensionCapabilityIdentifier.navigator))
        #expect(ExtensionAPI.negotiate(with: manifest.extensionAPI) == 1)

        let incompatibleURL = try #require(ExtensionKitResources.fixture(named: "IncompatibleExtensionManifest"))
        #expect(throws: ExtensionManifestError.incompatibleAPI) {
            try ExtensionManifestValidator.decodeAndValidate(Data(contentsOf: incompatibleURL))
        }
    }

    @Test func extensionAudioFormatsJoinTheBuiltInAudioList() throws {
        let provider = ExtensionAudioListTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm = directory.appendingPathComponent("one.mp3")
        let dsd = directory.appendingPathComponent("two.dsf")
        try Data().write(to: pcm)
        try Data().write(to: dsd)

        #expect(FileListGrouper.classify(url: pcm) == .listable(.audio))
        #expect(FileListGrouper.classify(url: dsd) == .listable(.audio))
        let group = try #require(FileListGrouper.groups(from: [pcm, dsd]).first)
        #expect(group.kind == .listable(.audio))
        #expect(group.urls == [pcm, dsd])

        let state = AppState()
        let current = state.makeFileListItem(url: pcm)
        state.fileList = FileListState(kind: .audio, items: [current], currentID: current.id)
        #expect(state.appendToFileList(urls: [dsd]).isEmpty)
        #expect(state.fileList?.items.map(\.url) == [pcm, dsd])
        #expect(state.navigatorContributions.first?.id == AppState.fileListNavigatorID)
    }

    @Test func builtInAudioListActionsWinWhileAnExtensionTrackIsActive() {
        let state = AppState()
        let contribution = NavigatorContribution(
            id: AppState.fileListNavigatorID,
            titleLocalizationKey: "Audio List",
            style: .flat,
            items: [NavigatorItem(id: "one", title: "One", isCurrent: true)],
            selectedItemIDs: ["one"],
            allowedActions: [.activate]
        )
        state.builtInNavigatorContributions = [contribution]
        var handled = false
        state.builtInNavigatorActionHandler = { _ in handled = true }
        state.extensionSession = ContentSession(
            extensionID: nil,
            providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/one.dsf"))),
            presentation: .text(titleKey: "Hi-Fi", body: "one.dsf")
        )

        state.performNavigatorAction(NavigatorAction(
            contributionID: AppState.fileListNavigatorID,
            kind: .activate,
            itemIDs: ["one"]
        ))
        #expect(handled)
    }

    @Test func clearingExtensionSessionProvidesACompletedReleaseBarrier() async throws {
        let provider = DelayedCloseTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }

        let state = AppState()
        state.extensionSession = ContentSession(
            extensionID: provider.descriptor.extensionID,
            providerID: provider.descriptor.id,
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/release.dsf"))),
            presentation: .text(titleKey: "Test", body: "DSD")
        )

        state.extensionSession = nil
        #expect(provider.didClose == false)
        await state.extensionSessionCloseTask?.value
        #expect(provider.didClose)
    }

    @Test func abiV1HeaderAndLoaderKeepVersionedBoundary() throws {
        #expect(FOOFOIL_EXTENSION_API_V1 == ExtensionAPI.v1)
        #expect(MemoryLayout<FoofoilExtensionInterfaceV1>.size > MemoryLayout<UInt32>.size)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("Test.foofoilextension", isDirectory: true)
        let resourcesURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": LocalTestExtension.identifier,
            "CFBundleName": "Test Extension",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
            "FoofoilExtensionExecutionModel": "xpcService"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(LocalTestExtension.manifest)
            .write(to: resourcesURL.appendingPathComponent("ExtensionManifest.json"))

        let loader = ExtensionLoader(requireSignature: false)
        let loaded = try loader.loadBundle(at: bundleURL)
        #expect(loaded.manifest.id == LocalTestExtension.identifier)
        #expect(loaded.negotiatedAPI == ExtensionAPI.v1)
        #expect(loaded.executionModel == .xpcService)
        #expect(loader.discover(in: directory).count == 1)
    }

    @Test func rejectsOverrideWithoutFallbackAndDuplicateCapability() {
        let invalidOverride = ExtensionManifest(
            id: "app.foofoil.extension.invalid",
            name: "Invalid",
            version: "1.0.0",
            extensionAPI: .init(min: 1, max: 1),
            system: .init(minMacOS: "15.0", architectures: [LocalTestExtension.currentArchitecture]),
            providers: [
                .init(
                    id: "invalid.override",
                    role: .override,
                    contentTypes: [.init(extensions: ["mp3"], strategy: .fileExtension)]
                )
            ],
            capabilities: []
        )
        #expect(throws: ExtensionManifestError.invalidProvider("invalid.override")) {
            try ExtensionManifestValidator.validate(invalidOverride)
        }

        let duplicateCapability = ExtensionManifest(
            id: "app.foofoil.extension.invalid",
            name: "Invalid",
            version: "1.0.0",
            extensionAPI: .init(min: 1, max: 1),
            system: .init(minMacOS: "15.0", architectures: [LocalTestExtension.currentArchitecture]),
            providers: [],
            capabilities: [
                .init(id: "ui.commands", scope: .presentation),
                .init(id: "ui.commands", scope: .presentation)
            ]
        )
        #expect(throws: ExtensionManifestError.duplicateCapability("ui.commands")) {
            try ExtensionManifestValidator.validate(duplicateCapability)
        }
    }

    @Test func contentRequestRoundTripsAllV1KindsAndBookmarks() throws {
        let bookmark = Data([1, 2, 3, 4])
        let first = ExtensionResource(url: URL(fileURLWithPath: "/tmp/one.foo"), securityScopedBookmark: bookmark)
        let second = ExtensionResource(url: URL(fileURLWithPath: "/tmp/two.foo"))
        let requests: [ContentRequest] = [
            .singleFile(first),
            .fileCollection([first, second]),
            .restoredSession(extensionID: LocalTestExtension.identifier, stateReference: "state-1")
        ]

        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ContentRequest.self, from: encoded) == request)
        }
    }

    @Test func capabilityNegotiationChecksContractScopeVersionAndDependencies() {
        let declarations: [ExtensionCapabilityDeclaration] = [
            .init(id: ExtensionCapabilityIdentifier.commandProvider, scope: .presentation),
            .init(id: ExtensionCapabilityIdentifier.navigator, scope: .presentation),
            .init(
                id: ExtensionCapabilityIdentifier.visualization,
                scope: .session,
                dependencies: [ExtensionCapabilityIdentifier.commandProvider]
            ),
            .init(id: ExtensionCapabilityIdentifier.audioEffects, contractVersion: 2, scope: .session),
            .init(id: "future.unknown", scope: .session)
        ]
        let result = CapabilityNegotiator.negotiate(declarations)

        #expect(result.accepted.map(\.declaration.id) == [
            ExtensionCapabilityIdentifier.commandProvider,
            ExtensionCapabilityIdentifier.navigator,
            ExtensionCapabilityIdentifier.visualization
        ])
        #expect(result.rejected.map(\.reason).contains(.unsupportedContractVersion))
        #expect(result.rejected.map(\.reason).contains(.unsupportedIdentifier))
    }

    @Test func testFileCreatesSessionAndRunsHostCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Test.foo")
        try Data("Phase 0 presentation".utf8).write(to: fileURL)

        let resolver = ProviderResolver()
        _ = LocalTestExtension.register(in: resolver)
        let outcome = try await resolver.makeSession(
            for: .singleFile(.init(url: fileURL))
        )

        #expect(outcome.session.providerID == "test.content")
        #expect(outcome.session.commands.map(\.id) == ["test.append-marker"])
        #expect(outcome.session.navigatorContributions.map(\.style) == [.flat, .outline])
        guard case .text(_, let body) = outcome.session.presentation else {
            Issue.record("Expected a host text presentation")
            return
        }
        #expect(body == "Phase 0 presentation")

        let provider = try #require(resolver.provider(id: outcome.session.providerID))
        let updated = try await provider.perform(commandID: "test.append-marker", session: outcome.session)
        guard case .text(_, let updatedBody) = updated.presentation else {
            Issue.record("Expected an updated host text presentation")
            return
        }
        #expect(updatedBody.hasSuffix("✓ Extension command"))

        let action = NavigatorAction(
            contributionID: "test.outline",
            kind: .activate,
            itemIDs: ["section-b"]
        )
        let navigated = try await provider.perform(navigatorAction: action, session: outcome.session)
        #expect(navigated.navigatorContributions[1].selectedItemIDs == ["section-b"])
        #expect(navigated.navigatorContributions[1].revision == 1)
    }

    @Test func navigatorContractRoundTripsAndRejectsInvalidHierarchyAndActions() throws {
        let contribution = NavigatorContribution(
            id: "document.outline",
            titleLocalizationKey: "Outline",
            style: .outline,
            items: [
                NavigatorItem(id: "chapter", title: "Chapter"),
                NavigatorItem(id: "section", parentID: "chapter", title: "Section")
            ],
            selectedItemIDs: ["section"],
            allowedActions: [.activate, .move],
            revision: 4
        )
        try NavigatorContributionValidator.validate(contribution)
        let decoded = try JSONDecoder().decode(
            NavigatorContribution.self,
            from: JSONEncoder().encode(contribution)
        )
        #expect(decoded == contribution)

        let action = NavigatorAction(
            contributionID: contribution.id,
            kind: .move,
            itemIDs: ["section"],
            movePosition: .end
        )
        try NavigatorContributionValidator.validate(action, in: contribution)
        #expect(try JSONDecoder().decode(NavigatorAction.self, from: JSONEncoder().encode(action)) == action)

        let missingParent = NavigatorContribution(
            id: "missing-parent",
            titleLocalizationKey: "Outline",
            style: .outline,
            items: [NavigatorItem(id: "child", parentID: "missing", title: "Child")]
        )
        #expect(throws: NavigatorContributionError.missingParent(itemID: "child", parentID: "missing")) {
            try NavigatorContributionValidator.validate(missingParent)
        }

        let cycle = NavigatorContribution(
            id: "cycle",
            titleLocalizationKey: "Outline",
            style: .outline,
            items: [
                NavigatorItem(id: "a", parentID: "b", title: "A"),
                NavigatorItem(id: "b", parentID: "a", title: "B")
            ]
        )
        #expect(throws: NavigatorContributionError.hierarchyCycle("a")) {
            try NavigatorContributionValidator.validate(cycle)
        }
    }

    @Test func contentSessionDecodesPreNavigatorPhaseZeroState() throws {
        let session = ContentSession(
            extensionID: LocalTestExtension.identifier,
            providerID: "test.content",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/Test.foo"))),
            presentation: .text(titleKey: "Test Extension", body: "legacy")
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "navigatorContributions")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ContentSession.self, from: legacyData)
        #expect(decoded.navigatorContributions.isEmpty)
        #expect(decoded.mediaPlayback == nil)
        #expect(decoded.playbackQueue == nil)
        #expect(decoded.audioDeviceSelection == nil)
        #expect(decoded.providerID == session.providerID)
    }

    @Test func mediaAndDeviceContractsRoundTripAndValidateCapabilities() throws {
        let capabilities = [
            NegotiatedCapability(
                declaration: .init(id: ExtensionCapabilityIdentifier.seekable, scope: .session),
                state: .active
            ),
            NegotiatedCapability(
                declaration: .init(id: ExtensionCapabilityIdentifier.mediaPlaybackQueue, scope: .session),
                state: .active
            ),
            NegotiatedCapability(
                declaration: .init(id: ExtensionCapabilityIdentifier.deviceSelector, scope: .application),
                state: .active
            )
        ]
        let session = ContentSession(
            extensionID: "app.foofoil.extension.hifi",
            providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/album.dsf"))),
            presentation: .text(titleKey: "Hi-Fi", body: "album.dsf"),
            capabilities: capabilities,
            mediaPlayback: .init(state: .paused, position: 12, duration: 120, isSeekable: true),
            playbackQueue: .init(
                items: [.init(id: "track-1", title: "Track 1", duration: 120)],
                currentItemID: "track-1"
            ),
            audioDeviceSelection: .init(
                devices: [
                    .init(
                        id: "device-uid",
                        displayName: "USB DAC",
                        supportedDoPRates: [2_822_400, 5_644_800]
                    )
                ],
                selectedDeviceID: "device-uid",
                activeTransport: .dop,
                statusDescription: "DSD64 · DoP · USB DAC"
            )
        )

        try MediaSessionContractValidator.validate(session)
        let decoded = try JSONDecoder().decode(ContentSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.playbackQueue?.currentItemID == "track-1")
        #expect(decoded.audioDeviceSelection?.selectedDeviceID == "device-uid")
        #expect(decoded.audioDeviceSelection?.activeTransport == .dop)

        var missingCapability = session
        missingCapability.capabilities = []
        #expect(throws: MediaSessionContractError.missingCapability(ExtensionCapabilityIdentifier.seekable)) {
            try MediaSessionContractValidator.validate(missingCapability)
        }
    }

    @Test func hiFiSessionUsesCurrentQueueResourceForAudioPresentation() throws {
        let first = URL(fileURLWithPath: "/tmp/first.dsf")
        let second = URL(fileURLWithPath: "/tmp/second.dsf")
        let state = AppState()
        defer { state.extensionSession = nil }

        state.extensionSession = ContentSession(
            extensionID: nil,
            providerID: "audio.hifi",
            request: .fileCollection([
                .init(url: first),
                .init(url: second)
            ]),
            presentation: .text(titleKey: "Hi-Fi", body: "second.dsf"),
            mediaPlayback: .init(state: .playing, position: 1, duration: 10, isSeekable: true),
            playbackQueue: .init(
                items: [
                    .init(id: "file:0", title: "first"),
                    .init(id: "file:1", title: "second")
                ],
                currentItemID: "file:1"
            )
        )

        #expect(state.isAudioDocument)
        #expect(state.isExternalMediaDocument)
        #expect(state.currentAudioPresentationURL == second)

        var reordered = try #require(state.extensionSession)
        reordered.playbackQueue?.items.swapAt(0, 1)
        state.extensionSession = reordered
        #expect(state.currentAudioPresentationURL == second)
    }

    @Test func hierarchicalCommandsAcceptDynamicDeviceNamesAndRejectCycles() throws {
        let session = ContentSession(
            extensionID: "app.foofoil.extension.hifi",
            providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/album.dsf"))),
            presentation: .text(titleKey: "Hi-Fi", body: "album.dsf"),
            capabilities: [
                NegotiatedCapability(
                    declaration: .init(id: ExtensionCapabilityIdentifier.commandProvider, scope: .presentation),
                    state: .active
                )
            ],
            commands: [
                .init(id: "output", titleLocalizationKey: "Output Device"),
                .init(
                    id: "output.usb-dac",
                    titleLocalizationKey: "",
                    displayTitle: "USB DAC",
                    parentID: "output",
                    isChecked: true
                )
            ]
        )
        try CommandContributionValidator.validate(session)

        var cycle = session
        cycle.commands[0].parentID = "output.usb-dac"
        #expect(throws: CommandContributionError.hierarchyCycle("output")) {
            try CommandContributionValidator.validate(cycle)
        }

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        var legacyCommands = try #require(legacyObject["commands"] as? [[String: Any]])
        legacyCommands[0].removeValue(forKey: "displayTitle")
        legacyCommands[0].removeValue(forKey: "parentID")
        legacyObject["commands"] = legacyCommands
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(ContentSession.self, from: legacyData)
        #expect(decoded.commands[0].displayTitle == nil)
        #expect(decoded.commands[0].parentID == nil)
    }

    @Test func navigatorWidthDragFollowsOuterEdge() {
        let start = 260.0
        #expect(NavigatorPanelMetrics.width(afterDrag: start, translation: -40, draggingLeftEdge: true) == 300)
        #expect(NavigatorPanelMetrics.width(afterDrag: start, translation: 40, draggingLeftEdge: true) == 220)
        #expect(NavigatorPanelMetrics.width(afterDrag: start, translation: 40, draggingLeftEdge: false) == 300)
        #expect(NavigatorPanelMetrics.width(afterDrag: start, translation: -40, draggingLeftEdge: false) == 220)
    }

    @Test func navigatorWidthScrollGrowsOnPositiveDelta() {
        let start = 260.0
        #expect(NavigatorPanelMetrics.width(afterScroll: start, delta: 1, precise: false) > start)
        #expect(NavigatorPanelMetrics.width(afterScroll: start, delta: -1, precise: false) < start)
        #expect(NavigatorPanelMetrics.width(afterScroll: start, delta: 1000, precise: false) == NavigatorPanelMetrics.maximumWidth)
        #expect(NavigatorPanelMetrics.width(afterScroll: start, delta: -1000, precise: false) == NavigatorPanelMetrics.minimumWidth)
        let precise = NavigatorPanelMetrics.width(afterScroll: start, delta: 10, precise: true)
        let coarse = NavigatorPanelMetrics.width(afterScroll: start, delta: 10, precise: false)
        #expect(precise < coarse)
    }

    @Test func navigatorWidthResizeHandleSitsOnOuterEdge() {
        let width: CGFloat = 260
        #expect(NavigatorPanelMetrics.containsWidthResizeHandle(x: 2, width: width, draggingLeftEdge: true))
        #expect(!NavigatorPanelMetrics.containsWidthResizeHandle(x: 40, width: width, draggingLeftEdge: true))
        #expect(NavigatorPanelMetrics.containsWidthResizeHandle(x: 258, width: width, draggingLeftEdge: false))
        #expect(!NavigatorPanelMetrics.containsWidthResizeHandle(x: 40, width: width, draggingLeftEdge: false))
    }

    @Test func navigatorPanelUsesCompanionWindowWithoutChangingFoilFrame() throws {
        let state = AppState()
        state.builtInNavigatorContributions = [
            NavigatorContribution(
                id: "builtin.test",
                titleLocalizationKey: "Navigator",
                style: .flat,
                items: [NavigatorItem(id: "one", title: "One")]
            )
        ]
        state.navigatorPanelVisibilityMode = .always
        state.navigatorPanelSide = .right
        state.navigatorPanelWidth = 300

        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        let originalFrame = foilWindow.frame
        let panel = try #require(foilWindow.childWindows?.first)

        #expect(controller.isNavigatorPanelVisible)
        #expect(controller.owns(panel))
        #expect(abs(panel.frame.width - 300) < 0.5)
        #expect(abs(panel.frame.minX - foilWindow.frame.maxX - NavigatorPanelMetrics.attachmentGap) < 0.5)
        #expect(foilWindow.frame == originalFrame)

        controller.close()
    }

    @Test func navigatorPanelAppearsWhenPointerIsInsideWindowOnHover() throws {
        let state = AppState()
        state.builtInNavigatorContributions = [
            NavigatorContribution(
                id: "builtin.hover-test",
                titleLocalizationKey: "Navigator",
                style: .flat,
                items: [NavigatorItem(id: "one", title: "One")]
            )
        ]
        state.navigatorPanelVisibilityMode = .onHover
        state.navigatorPanelSide = .right

        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        #expect(controller.isNavigatorPanelVisible == false)

        let interior = NSPoint(x: foilWindow.frame.width / 2, y: foilWindow.frame.height / 2)
        controller.updateNavigatorEdgeHover(at: interior)
        #expect(state.isNavigatorEdgeHovered)
        #expect(controller.isNavigatorPanelVisible)

        let away = NSPoint(x: foilWindow.frame.maxX + 2400, y: foilWindow.frame.minY - 2400)
        controller.refreshNavigatorHoverFromPointer(screenPoint: away)
        #expect(state.isNavigatorEdgeHovered == false)
        #expect(state.isNavigatorPanelHovered == false)

        controller.close()
    }

    @Test func windowHoverRemainsAvailableWithoutNavigatorContent() throws {
        let state = AppState()
        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)

        let interior = NSPoint(x: foilWindow.frame.width / 2, y: foilWindow.frame.height / 2)
        controller.updateNavigatorEdgeHover(at: interior)
        #expect(state.isPointerInsideWindow)

        let away = NSPoint(x: foilWindow.frame.maxX + 2400, y: foilWindow.frame.minY - 2400)
        controller.refreshNavigatorHoverFromPointer(screenPoint: away)
        #expect(state.isPointerInsideWindow == false)

        controller.close()
    }

    @Test func videoControlsAppearOnPointerActivityAndHideAfterInactivity() async throws {
        let state = AppState()
        state.originalImageName = "foofoil-hover-test.mp4"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-hover-test.mp4")
        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        // 先让 imageURL 订阅回调跑完初次显隐推导，避免其异步块重排隐藏计时造成竞态。
        try await Task.sleep(for: .milliseconds(50))
        let interior = NSPoint(x: foilWindow.frame.width / 2, y: foilWindow.frame.height / 2)

        controller.updateNavigatorEdgeHover(at: interior)
        controller.handleMediaPointerActivity(at: interior, autoHideInterval: 0.01)
        #expect(state.isMediaPlaybackControlsVisible)

        try await Task.sleep(for: .milliseconds(50))
        #expect(state.isPointerInsideWindow)
        #expect(state.isMediaPlaybackControlsVisible == false)

        controller.handleMediaPointerActivity(at: interior, autoHideInterval: 1)
        #expect(state.isMediaPlaybackControlsVisible)

        let away = NSPoint(x: foilWindow.frame.maxX + 2400, y: foilWindow.frame.minY - 2400)
        controller.refreshNavigatorHoverFromPointer(screenPoint: away)
        #expect(state.isPointerInsideWindow == false)
        #expect(state.isMediaPlaybackControlsVisible)

        controller.handleMediaPointerExit(autoHideInterval: 0.01)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.isMediaPlaybackControlsVisible == false)
        controller.close()
    }

    @Test func audioControlsStayVisibleWhileHoveringWithoutIdleTimeout() async throws {
        let state = AppState()
        state.originalImageName = "foofoil-audio-hover-test.mp3"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-audio-hover-test.mp3")
        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        // 移到远处的屏幕外坐标，保证真实鼠标位置不会落在窗口上，推导结果确定。
        foilWindow.setFrameOrigin(NSPoint(x: 30000, y: 30000))
        try await Task.sleep(for: .milliseconds(50))

        let interior = NSPoint(x: foilWindow.frame.width / 2, y: foilWindow.frame.height / 2)
        controller.updateNavigatorEdgeHover(at: interior)
        controller.handleMediaPointerActivity(at: interior, autoHideInterval: 0.01)
        #expect(state.isMediaPlaybackControlsVisible)

        try await Task.sleep(for: .milliseconds(50))
        // 音频 hover 不做鼠标静止超时隐藏（暂停态同样常显）。
        #expect(state.isMediaPlaybackControlsVisible)

        controller.close()
    }

    @Test func audioControlsStayVisibleWhilePausedRegardlessOfPointer() async throws {
        let state = AppState()
        state.originalImageName = "foofoil-audio-pause-test.mp3"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-audio-pause-test.mp3")
        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        foilWindow.setFrameOrigin(NSPoint(x: 30000, y: 30000))
        try await Task.sleep(for: .milliseconds(50))

        let away = NSPoint(x: 40000, y: 20000)
        controller.refreshNavigatorHoverFromPointer(screenPoint: away)
        #expect(state.isPointerInsideWindow == false)
        // 未播放（暂停态）时常显，与指针位置无关。
        #expect(state.isMediaPlaybackControlsVisible)

        controller.handleMediaPointerExit(autoHideInterval: 0.01)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.isMediaPlaybackControlsVisible)

        controller.close()
    }

    @Test func audioControlsFollowHoverRegionWhilePlaying() async throws {
        let state = AppState()
        state.originalImageName = "foofoil-audio-play-test.mp3"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-audio-play-test.mp3")
        let controller = FloatingWindowController(appState: state)
        let foilWindow = try #require(controller.window)
        foilWindow.setFrameOrigin(NSPoint(x: 30000, y: 30000))
        try await Task.sleep(for: .milliseconds(50))

        state.isMediaPlaying = true
        try await Task.sleep(for: .milliseconds(50))
        // 播放中且指针不在箔窗/目录上 → 隐藏。
        #expect(state.isMediaPlaybackControlsVisible == false)

        let interior = NSPoint(x: foilWindow.frame.width / 2, y: foilWindow.frame.height / 2)
        controller.updateNavigatorEdgeHover(at: interior)
        controller.handleMediaPointerActivity(at: interior, autoHideInterval: 0.01)
        #expect(state.isMediaPlaybackControlsVisible)

        let away = NSPoint(x: 40000, y: 20000)
        controller.refreshNavigatorHoverFromPointer(screenPoint: away)
        // 播放中指针离开箔窗且未悬停目录 → 隐藏。
        #expect(state.isMediaPlaybackControlsVisible == false)

        state.isMediaPlaying = false
        try await Task.sleep(for: .milliseconds(50))
        // 暂停后无论指针在哪都常显。
        #expect(state.isMediaPlaybackControlsVisible)

        controller.close()
    }

    @Test func mediaControlsAutoHideIntervalIsClamped() {
        #expect(MediaPlaybackControlsAutoHide.clampInterval(0) == MediaPlaybackControlsAutoHide.minInterval)
        #expect(MediaPlaybackControlsAutoHide.clampInterval(99) == MediaPlaybackControlsAutoHide.maxInterval)
    }

    @Test func showsMediaBottomProgressBarDefaultsOnAndNotifies() {
        let original = SettingsStore.shared.showsMediaBottomProgressBar
        defer { SettingsStore.shared.showsMediaBottomProgressBar = original }

        // 未写入用户偏好时走注册默认值：开启。
        UserDefaults.standard.removeObject(forKey: "showsMediaBottomProgressBar")
        #expect(SettingsStore.shared.showsMediaBottomProgressBar == true)

        var changeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .showsMediaBottomProgressBarDidChange, object: nil, queue: .main
        ) { _ in changeCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        SettingsStore.shared.showsMediaBottomProgressBar = false
        #expect(SettingsStore.shared.showsMediaBottomProgressBar == false)
        #expect(changeCount == 1)

        // 相同值写入不重复发布通知。
        SettingsStore.shared.showsMediaBottomProgressBar = false
        #expect(changeCount == 1)

        SettingsStore.shared.showsMediaBottomProgressBar = true
        #expect(SettingsStore.shared.showsMediaBottomProgressBar == true)
        #expect(changeCount == 2)
    }

    @Test func fullScreenLifecycleKeepsWindowedBorderAndFramePreferences() throws {
        let state = AppState()
        state.showBorder = true
        state.isPinned = true
        state.builtInNavigatorContributions = [
            NavigatorContribution(
                id: "builtin.fullscreen-test",
                titleLocalizationKey: "Navigator",
                style: .flat,
                items: [NavigatorItem(id: "one", title: "One")]
            )
        ]
        state.navigatorPanelVisibilityMode = .always

        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        let originalFrame = window.frame
        let windowedFrame = window.frameDescriptor
        let companionPanel = try #require(window.childWindows?.first)
        #expect(controller.isNavigatorPanelVisible)
        #expect(state.effectiveShowBorder)

        controller.windowWillEnterFullScreen(
            Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
        )
        #expect(state.isFullScreen)
        #expect(state.showBorder)
        #expect(!state.effectiveShowBorder)
        #expect(controller.isNavigatorPanelVisible)
        #expect(!companionPanel.isVisible)
        #expect(!window.hasShadow)

        window.setFrame(NSRect(x: 0, y: 0, width: 1600, height: 900), display: false)
        controller.windowDidEnterFullScreen(
            Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
        )
        #expect(controller.isNavigatorPanelVisible)

        controller.windowWillExitFullScreen(
            Notification(name: NSWindow.willExitFullScreenNotification, object: window)
        )
        controller.windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )
        #expect(!state.isFullScreen)
        #expect(state.showBorder)
        #expect(state.effectiveShowBorder)
        #expect(state.windowFrame == windowedFrame)
        #expect(window.hasShadow)
        #expect(window.level == .floating)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))

        state.showBorder = false
        state.isFullScreen = true
        #expect(!state.effectiveShowBorder)
        state.isFullScreen = false
        #expect(!state.effectiveShowBorder)

        window.setFrame(originalFrame, display: false)
        controller.close()
    }

    @Test func audioOverrideIsSelectedAndFallsBackToBuiltInAfterFailure() async throws {
        let resolver = ProviderResolver()
        resolver.register(BuiltInAudioProvider())
        let enhancer = LocalTestExtension.register(in: resolver)
        let request = ContentRequest.singleFile(.init(url: URL(fileURLWithPath: "/tmp/Test.mp3")))

        let resolution = try resolver.resolve(request, preferredProviderID: "test.audio-enhancer")
        #expect(resolution.selectedProviderID == "test.audio-enhancer")
        #expect(resolution.reason == .userPreference)
        #expect(resolution.fallbackProviderIDs.first == "builtin.audio")

        let enhanced = try await resolver.makeSession(
            for: request,
            preferredProviderID: "test.audio-enhancer"
        )
        #expect(enhanced.session.providerID == "test.audio-enhancer")
        #expect(enhanced.session.commands.map(\.id) == ["test.audio-enhancer.toggle"])

        enhancer.failSessionCreation = true
        let fallback = try await resolver.makeSession(
            for: request,
            preferredProviderID: "test.audio-enhancer"
        )
        #expect(fallback.session.providerID == "builtin.audio")
        #expect(fallback.failures.map(\.providerID) == ["test.audio-enhancer"])
    }

    @Test func stateStoreNamespacesVersionsLimitsAndPreservesCorruptState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExtensionStateStore(rootDirectory: directory, payloadLimit: 16)
        let payload = Data("session".utf8)
        let reference = try store.save(
            extensionID: LocalTestExtension.identifier,
            schemaVersion: 2,
            payload: payload
        )
        let loadedEnvelope = try store.load(extensionID: LocalTestExtension.identifier, reference: reference)
        let loaded = try #require(loadedEnvelope)
        #expect(loaded.schemaVersion == 2)
        #expect(loaded.payload == payload)

        #expect(throws: ExtensionStateStoreError.payloadTooLarge(limit: 16)) {
            try store.save(
                extensionID: LocalTestExtension.identifier,
                schemaVersion: 1,
                payload: Data(repeating: 0, count: 17)
            )
        }

        let stateURL = directory
            .appendingPathComponent(LocalTestExtension.identifier)
            .appendingPathComponent(reference)
            .appendingPathExtension("json")
        try Data("corrupt".utf8).write(to: stateURL)
        #expect(try store.load(extensionID: LocalTestExtension.identifier, reference: reference) == nil)
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test func windowConfigDecodingKeepsBackwardCompatibility() throws {
        let legacy = WindowConfig(id: UUID(), text: "legacy")
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "navigatorPanelSide")
        object.removeValue(forKey: "navigatorPanelVisibilityMode")
        object.removeValue(forKey: "navigatorPanelWidth")
        object.removeValue(forKey: "fileList")
        object.removeValue(forKey: "mediaPlaybackMode")
        object.removeValue(forKey: "isVideoLooping")
        let decoded = try JSONDecoder().decode(
            WindowConfig.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.extensionID == nil)
        #expect(decoded.extensionStateReference == nil)
        #expect(decoded.navigatorPanelSide == .right)
        #expect(decoded.navigatorPanelVisibilityMode == .onHover)
        #expect(decoded.navigatorPanelWidth == NavigatorPanelMetrics.defaultWidth)
        #expect(decoded.fileList == nil)
        #expect(decoded.mediaPlaybackMode == .singleLoop)
        #expect(decoded.text == "legacy")
    }

    @Test func historyDatabaseRoundTripsExtensionStateReference() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let config = WindowConfig(
            id: UUID(),
            originalImageName: "Test.foo",
            extensionID: LocalTestExtension.identifier,
            extensionStateReference: "session-state",
            navigatorPanelSide: .left,
            navigatorPanelVisibilityMode: .always,
            navigatorPanelWidth: 312
        )

        try database.upsert(config)
        let storedConfig = try database.config(id: config.id)
        let restored = try #require(storedConfig)

        #expect(restored.contentKind == .extensionContent)
        #expect(restored.extensionID == LocalTestExtension.identifier)
        #expect(restored.extensionStateReference == "session-state")
        #expect(restored.navigatorPanelSide == .left)
        #expect(restored.navigatorPanelVisibilityMode == .always)
        #expect(restored.navigatorPanelWidth == 312)
    }

    @Test func sandboxedXPCServiceNegotiatesAPIAndTransfersBookmarkMessage() async throws {
        let connection = ExtensionProcessConnection(
            serviceName: "com.markonce.foofoil.TestExtensionService"
        )
        let handshake = try await connection.handshake()
        #expect(handshake.extensionID == LocalTestExtension.identifier)
        #expect(handshake.negotiatedAPI == ExtensionAPI.v1)

        let request = ContentRequest.fileCollection([
            ExtensionResource(
                url: URL(fileURLWithPath: "/tmp/one.foo"),
                securityScopedBookmark: Data([0xF0, 0x0F])
            ),
            ExtensionResource(url: URL(fileURLWithPath: "/tmp/two.foo"))
        ])
        #expect(try await connection.createSession(for: request) == request)
    }
}

private final class ExtensionAudioListTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.extension-audio-list",
        extensionID: "app.foofoil.extension.audio-list-test",
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: "audio",
        contentFamily: .audio,
        filenameExtensions: ["dsf"],
        isEnabled: true,
        isRuntimeAvailable: true
    )

    func match(_ request: ContentRequest) -> ProviderMatch? {
        guard request.primaryFileURL?.pathExtension.lowercased() == "dsf" else { return nil }
        return ProviderMatch(strength: .fileExtension, explanation: "filename-extension:dsf")
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Test", body: "DSD")
        )
    }
}

private final class DelayedCloseTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.delayed-close",
        extensionID: "app.foofoil.extension.delayed-close-test",
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: "audio",
        contentFamily: .audio,
        filenameExtensions: ["dsf"],
        isEnabled: true,
        isRuntimeAvailable: true
    )
    var didClose = false

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Test", body: "DSD")
        )
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        if commandID == "hifi.close" {
            try await Task.sleep(for: .milliseconds(20))
            didClose = true
        }
        return session
    }
}
