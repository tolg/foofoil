//  ExtensionKitTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/8/25.

import Foundation
import Testing
@testable import foofoil

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
        let url = try #require(Bundle.main.url(forResource: "TestExtensionManifest", withExtension: "json"))
        let manifest = try ExtensionManifestValidator.decodeAndValidate(Data(contentsOf: url))

        #expect(manifest.id == LocalTestExtension.identifier)
        #expect(manifest.providers.map(\.id) == ["test.content", "test.audio-enhancer"])
        #expect(ExtensionAPI.negotiate(with: manifest.extensionAPI) == 1)

        let incompatibleURL = try #require(Bundle.main.url(forResource: "IncompatibleExtensionManifest", withExtension: "json"))
        #expect(throws: ExtensionManifestError.incompatibleAPI) {
            try ExtensionManifestValidator.decodeAndValidate(Data(contentsOf: incompatibleURL))
        }
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
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: encoded)

        #expect(decoded.extensionID == nil)
        #expect(decoded.extensionStateReference == nil)
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
            extensionStateReference: "session-state"
        )

        try database.upsert(config)
        let storedConfig = try database.config(id: config.id)
        let restored = try #require(storedConfig)

        #expect(restored.contentKind == .extensionContent)
        #expect(restored.extensionID == LocalTestExtension.identifier)
        #expect(restored.extensionStateReference == "session-state")
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
