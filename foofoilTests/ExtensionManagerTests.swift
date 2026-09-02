//  ExtensionManagerTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/8/26.

import CryptoKit
import Foundation
import Testing
@testable import foofoil
import FoofoilExtensionKit

@MainActor
@Suite(.serialized)
struct ExtensionManagerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-extension-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func registryRejectsInvalidSignatureExpiryAndRollback() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalog = try makeCatalog(
            directory: temporaryDirectory(),
            privateKey: privateKey,
            sequence: 4,
            expiresAt: Date().addingTimeInterval(3_600)
        ).catalog

        let signed = try ExtensionRegistryCodec.sign(catalog, with: privateKey)
        _ = try ExtensionRegistryCodec.verify(signed, publicKey: privateKey.publicKey, previousSequence: 3)

        let tampered = SignedExtensionRegistry(payload: signed.payload + Data([0x00]), signature: signed.signature)
        #expect(throws: ExtensionRegistryError.invalidSignature) {
            try ExtensionRegistryCodec.verify(tampered, publicKey: privateKey.publicKey)
        }

        #expect(throws: ExtensionRegistryError.rolledBack) {
            try ExtensionRegistryCodec.verify(signed, publicKey: privateKey.publicKey, previousSequence: 5)
        }

        let expired = ExtensionRegistryCatalog(
            schemaVersion: catalog.schemaVersion,
            sequence: catalog.sequence,
            generatedAt: catalog.generatedAt,
            expiresAt: Date().addingTimeInterval(-60),
            extensions: catalog.extensions
        )
        let expiredSigned = try ExtensionRegistryCodec.sign(expired, with: privateKey)
        #expect(throws: ExtensionRegistryError.expired) {
            try ExtensionRegistryCodec.verify(expiredSigned, publicKey: privateKey.publicKey)
        }
    }

    @Test func compatibilityResolverSelectsNewestCompatibleNotLatestIncompatible() throws {
        let entry = ExtensionRegistryEntry(
            id: LocalTestExtension.identifier,
            name: "Test Extension",
            summary: "fixture",
            bundleID: LocalTestExtension.identifier,
            directoryName: "Test",
            contentTypes: [ContentTypeDeclaration(extensions: ["foo"], strategy: .fileExtension)],
            releases: [
                makeRelease(version: "1.4.2", api: .init(min: 1, max: 1), status: .active, url: URL(fileURLWithPath: "/tmp/a.zip")),
                makeRelease(version: "1.8.1", api: .init(min: 1, max: 2), status: .active, url: URL(fileURLWithPath: "/tmp/b.zip")),
                makeRelease(version: "2.0.0", api: .init(min: 2, max: 2), status: .active, url: URL(fileURLWithPath: "/tmp/c.zip"))
            ]
        )

        let selected = try #require(ExtensionCompatibilityResolver.latestCompatible(
            in: entry,
            hostAPIs: [1],
            architecture: ExtensionSystemRequirements.currentArchitecture,
            macOS: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ))
        #expect(selected.version == "1.8.1")
    }

    @Test func archiveExtractorRejectsPathEscapeAndKeepsRegularFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = try ExtensionArchive.pack(files: [
            "Test.foofoilextension/Contents/Info.plist": Data("<plist></plist>".utf8),
            "Test.foofoilextension/Contents/Resources/ExtensionManifest.json": Data("{}".utf8)
        ])
        let extracted = try ExtensionArchive.extract(valid, to: directory.appendingPathComponent("ok"))
        #expect(extracted.lastPathComponent == "Test.foofoilextension")

        let zipSlip = try ExtensionArchive.pack(
            files: ["../escape.txt": Data("nope".utf8)],
            validatePaths: false
        )
        #expect(throws: ExtensionArchiveError.pathEscape("../escape.txt")) {
            try ExtensionArchive.extract(zipSlip, to: directory.appendingPathComponent("slip"))
        }
    }

    @Test func managerInstallsTestExtensionThenOpensAndPreservesStateOnUninstall() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalogInfo = try makeCatalog(directory: directory, privateKey: privateKey)

        let store = ExtensionInstallStore(rootDirectory: directory.appendingPathComponent("support", isDirectory: true))
        let manager = ExtensionManager(
            configuration: .testing(catalogURL: catalogInfo.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        let host = ExtensionHost(
            resolver: ProviderResolver(),
            stateStore: ExtensionStateStore(rootDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            manager: manager
        )
        await manager.refreshCatalog()

        let fileURL = directory.appendingPathComponent("Test.foo")
        try Data("manager-install".utf8).write(to: fileURL)
        #expect(!host.canOpen(url: fileURL))

        try await manager.install(LocalTestExtension.identifier)
        #expect(host.canOpen(url: fileURL))
        #expect(manager.records[LocalTestExtension.identifier]?.activeVersion == "1.0.0")

        let outcome = try await host.open(url: fileURL)
        #expect(outcome.session.providerID == "test.content")
        guard case .text(_, let body) = outcome.session.presentation else {
            Issue.record("Expected installed test extension presentation")
            return
        }
        #expect(body == "manager-install")

        let reference = try host.stateStore.save(
            extensionID: LocalTestExtension.identifier,
            schemaVersion: 1,
            payload: try JSONEncoder().encode(outcome.session)
        )
        host.retainSession(extensionID: LocalTestExtension.identifier)
        try await manager.uninstall(LocalTestExtension.identifier)
        #expect(manager.records[LocalTestExtension.identifier]?.pendingRemoval == true)
        #expect(try host.stateStore.load(extensionID: LocalTestExtension.identifier, reference: reference) != nil)

        host.releaseSession(extensionID: LocalTestExtension.identifier)
        #expect(manager.records[LocalTestExtension.identifier] == nil)
        #expect(try host.stateStore.load(extensionID: LocalTestExtension.identifier, reference: reference) != nil)
        #expect(!host.canOpen(url: fileURL))
    }

    @Test func upgradeWhileLoadedDefersActivationAndRollbackRestoresPrevious() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalogV1 = try makeCatalog(directory: directory, privateKey: privateKey, version: "1.0.0")
        let store = ExtensionInstallStore(rootDirectory: directory.appendingPathComponent("support", isDirectory: true))
        let manager = ExtensionManager(
            configuration: .testing(catalogURL: catalogV1.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        let host = ExtensionHost(
            resolver: ProviderResolver(),
            stateStore: ExtensionStateStore(rootDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            manager: manager
        )
        await manager.refreshCatalog()
        try await manager.install(LocalTestExtension.identifier)
        #expect(host.isLoadedInProcess(LocalTestExtension.identifier))

        let catalogV2 = try makeCatalog(
            directory: directory,
            privateKey: privateKey,
            version: "1.1.0",
            sequence: 2,
            includePrevious: catalogV1
        )
        let updater = ExtensionManager(
            configuration: .testing(catalogURL: catalogV2.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        updater.host = host
        await updater.refreshCatalog()
        try await updater.install(LocalTestExtension.identifier)
        #expect(updater.records[LocalTestExtension.identifier]?.activeVersion == "1.0.0")
        #expect(updater.records[LocalTestExtension.identifier]?.pendingActivationVersion == "1.1.0")

        let relaunched = ExtensionManager(
            configuration: .testing(catalogURL: catalogV2.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        let relaunchedHost = ExtensionHost(
            resolver: ProviderResolver(),
            stateStore: ExtensionStateStore(rootDirectory: directory.appendingPathComponent("state-2", isDirectory: true)),
            manager: relaunched
        )
        #expect(relaunched.records[LocalTestExtension.identifier]?.activeVersion == "1.1.0")
        #expect(relaunchedHost.isLoadedInProcess(LocalTestExtension.identifier))

        try await relaunched.rollback(LocalTestExtension.identifier)
        #expect(relaunched.records[LocalTestExtension.identifier]?.pendingActivationVersion == "1.0.0")
    }

    @Test func revokedReleaseDisablesWhenNoCompatibleReplacementExists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalogV1 = try makeCatalog(directory: directory, privateKey: privateKey)
        let store = ExtensionInstallStore(rootDirectory: directory.appendingPathComponent("support", isDirectory: true))
        let manager = ExtensionManager(
            configuration: .testing(catalogURL: catalogV1.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        let host = ExtensionHost(
            resolver: ProviderResolver(),
            stateStore: ExtensionStateStore(rootDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            manager: manager
        )
        await manager.refreshCatalog()
        try await manager.install(LocalTestExtension.identifier)

        let revoked = try makeCatalog(
            directory: directory,
            privateKey: privateKey,
            sequence: 2,
            status: .revoked
        )
        let revokedManager = ExtensionManager(
            configuration: .testing(catalogURL: revoked.catalogURL, publicKey: privateKey.publicKey),
            store: store
        )
        revokedManager.host = host
        await revokedManager.refreshCatalog()
        #expect(revokedManager.records[LocalTestExtension.identifier]?.enabled == false)
    }

    @Test func downloadRejectsSHA256Mismatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalogInfo = try makeCatalog(directory: directory, privateKey: privateKey)
        let mismatched = ExtensionRegistryRelease(
            version: catalogInfo.catalog.extensions[0].releases[0].version,
            api: catalogInfo.catalog.extensions[0].releases[0].api,
            minMacOS: catalogInfo.catalog.extensions[0].releases[0].minMacOS,
            architectures: catalogInfo.catalog.extensions[0].releases[0].architectures,
            downloadSize: catalogInfo.catalog.extensions[0].releases[0].downloadSize,
            sha256: String(repeating: "ab", count: 32),
            downloadURL: catalogInfo.catalog.extensions[0].releases[0].downloadURL,
            status: .active
        )
        let entry = catalogInfo.catalog.extensions[0]
        let tamperedCatalog = ExtensionRegistryCatalog(
            schemaVersion: catalogInfo.catalog.schemaVersion,
            sequence: catalogInfo.catalog.sequence,
            generatedAt: catalogInfo.catalog.generatedAt,
            expiresAt: catalogInfo.catalog.expiresAt,
            extensions: [
                ExtensionRegistryEntry(
                    id: entry.id,
                    name: entry.name,
                    summary: entry.summary,
                    featuresSummary: entry.featuresSummary,
                    capabilitiesSummary: entry.capabilitiesSummary,
                    bundleID: entry.bundleID,
                    directoryName: entry.directoryName,
                    enhancementDomain: entry.enhancementDomain,
                    contentTypes: entry.contentTypes,
                    releases: [mismatched]
                )
            ]
        )
        let signed = try ExtensionRegistryCodec.sign(tamperedCatalog, with: privateKey)
        try ExtensionRegistryCodec.encoder().encode(signed).write(to: catalogInfo.catalogURL, options: .atomic)

        let manager = ExtensionManager(
            configuration: .testing(catalogURL: catalogInfo.catalogURL, publicKey: privateKey.publicKey),
            store: ExtensionInstallStore(rootDirectory: directory.appendingPathComponent("support", isDirectory: true))
        )
        await manager.refreshCatalog()
        await #expect(throws: ExtensionInstallError.downloadMismatch) {
            try await manager.install(LocalTestExtension.identifier)
        }
    }

    private struct CatalogInfo {
        let catalog: ExtensionRegistryCatalog
        let catalogURL: URL
        let archiveURL: URL
        let archive: Data
    }

    private func makeCatalog(
        directory: URL,
        privateKey: Curve25519.Signing.PrivateKey,
        version: String = "1.0.0",
        sequence: UInt64 = 1,
        expiresAt: Date = Date().addingTimeInterval(86_400),
        status: ExtensionReleaseStatus = .active,
        includePrevious: CatalogInfo? = nil
    ) throws -> CatalogInfo {
        var manifest = LocalTestExtension.manifest
        manifest = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            version: version,
            extensionAPI: manifest.extensionAPI,
            system: manifest.system,
            providers: manifest.providers,
            capabilities: manifest.capabilities
        )
        let archive = try ExtensionPackageBuilder.makeArchive(manifest: manifest)
        let archiveURL = directory.appendingPathComponent("Test-\(version).zip")
        try archive.write(to: archiveURL, options: .atomic)
        var releases = [
            makeRelease(
                version: version,
                api: manifest.extensionAPI,
                status: status,
                url: archiveURL,
                size: Int64(archive.count),
                sha256: ExtensionSHA256.hex(archive)
            )
        ]
        if let includePrevious {
            releases.append(contentsOf: includePrevious.catalog.extensions[0].releases)
        }
        let entry = ExtensionRegistryEntry(
            id: manifest.id,
            name: manifest.name,
            summary: "Opens .foo files and can enhance MP3 playback.",
            featuresSummary: "FOO · MP3",
            capabilitiesSummary: "Commands · Navigator",
            bundleID: manifest.id,
            directoryName: "Test",
            enhancementDomain: "audio",
            contentTypes: [
                ContentTypeDeclaration(extensions: ["foo"], strategy: .fileExtension)
            ],
            releases: releases
        )
        let catalog = ExtensionRegistryCatalog(
            schemaVersion: 1,
            sequence: sequence,
            generatedAt: Date(),
            expiresAt: expiresAt,
            extensions: [entry]
        )
        let catalogURL = directory.appendingPathComponent("catalog-\(sequence).json")
        try ExtensionRegistryCodec.encoder().encode(
            ExtensionRegistryCodec.sign(catalog, with: privateKey)
        ).write(to: catalogURL, options: .atomic)
        return CatalogInfo(catalog: catalog, catalogURL: catalogURL, archiveURL: archiveURL, archive: archive)
    }

    private func makeRelease(
        version: String,
        api: ExtensionAPICompatibility,
        status: ExtensionReleaseStatus,
        url: URL,
        size: Int64 = 16,
        sha256: String = String(repeating: "ab", count: 32)
    ) -> ExtensionRegistryRelease {
        ExtensionRegistryRelease(
            version: version,
            api: api,
            minMacOS: "15.0",
            architectures: [ExtensionSystemRequirements.currentArchitecture],
            downloadSize: size,
            sha256: sha256,
            downloadURL: url,
            status: status
        )
    }
}
