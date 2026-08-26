//  ExtensionManager.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Combine
import CryptoKit
import Foundation

protocol ExtensionRuntimeHost: AnyObject {
    func activateRuntime(for loaded: LoadedExtension)
    func deactivateRuntime(extensionID: String)
    func hasActiveSessions(for extensionID: String) -> Bool
    func isLoadedInProcess(_ extensionID: String) -> Bool
    func markLoadedInProcess(_ extensionID: String)
}

struct ExtensionManagerConfiguration: Sendable {
    var catalogURL: URL?
    var publicKey: Curve25519.Signing.PublicKey
    var requireSignature: Bool
    var requireNotarization: Bool
    var trustedTeamID: String?
    var allowsFileURLs: Bool
    var archiveLimits: ExtensionArchiveLimits
    var seedLocalCatalog: Bool
    var session: URLSession
    var now: @Sendable () -> Date

    static func testing(
        catalogURL: URL,
        publicKey: Curve25519.Signing.PublicKey
    ) -> ExtensionManagerConfiguration {
        ExtensionManagerConfiguration(
            catalogURL: catalogURL,
            publicKey: publicKey,
            requireSignature: false,
            requireNotarization: false,
            trustedTeamID: nil,
            allowsFileURLs: true,
            archiveLimits: .default,
            seedLocalCatalog: false,
            session: .shared,
            now: Date.init
        )
    }

    static var appDefault: ExtensionManagerConfiguration {
        ExtensionManagerConfiguration(
            catalogURL: nil,
            publicKey: ExtensionRegistryTrust.productionPublicKey,
            requireSignature: false,
            requireNotarization: false,
            trustedTeamID: nil,
            allowsFileURLs: true,
            archiveLimits: .default,
            seedLocalCatalog: true,
            session: .shared,
            now: Date.init
        )
    }
}

struct ExtensionSettingsItem: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let featuresSummary: String?
    let capabilitiesSummary: String?
    let enhancementDomain: String?
    let installedVersion: String?
    let availableVersion: String?
    let downloadSize: Int64?
    let status: ExtensionReleaseStatus?
    let enabled: Bool
    let pendingActivationVersion: String?
    let pendingRemoval: Bool
    let canRollback: Bool
    let hasUpdate: Bool
}

final class ExtensionManager: ObservableObject {
    weak var host: ExtensionRuntimeHost?

    @Published private(set) var catalog: ExtensionRegistryCatalog?
    @Published private(set) var records: [String: ExtensionInstallRecord] = [:]
    @Published private(set) var items: [ExtensionSettingsItem] = []
    @Published var lastErrorMessage: String?
    @Published var isRefreshing = false
    @Published var inProgressIDs: Set<String> = []

    let configuration: ExtensionManagerConfiguration
    let store: ExtensionInstallStore
    private let fileManager: FileManager

    init(
        configuration: ExtensionManagerConfiguration = .appDefault,
        store: ExtensionInstallStore? = nil,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.store = store ?? ExtensionInstallStore(fileManager: fileManager)
        records = (try? self.store.loadState().records) ?? [:]
        rebuildItems()
    }

    func loadInstalledRuntimes() {
        applyPendingActivationsIfPossible()
        let loader = makeLoader()
        for record in records.values where record.enabled && !record.pendingRemoval {
            guard let url = try? store.bundleURL(for: record),
                  let loaded = try? loader.loadBundle(at: url) else { continue }
            host?.activateRuntime(for: loaded)
            host?.markLoadedInProcess(record.extensionID)
            var updated = record
            updated.loadedVersion = loaded.manifest.version
            records[record.extensionID] = updated
        }
        try? persist()
        rebuildItems()
    }

    func refreshCatalog() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let url = try resolvedCatalogURL()
            let client = ExtensionRegistryClient(
                publicKey: catalogPublicKey(),
                allowsFileURLs: configuration.allowsFileURLs,
                session: configuration.session,
                now: configuration.now
            )
            let previous = try store.loadState().registrySequence
            let fetched = try await client.fetch(from: url, previousSequence: previous)
            catalog = fetched
            var state = try store.loadState()
            state.registrySequence = fetched.sequence
            try store.saveState(state)
            try await reconcileRevokedReleases()
            if SettingsStore.shared.extensionAutoInstallCompatibleMinorUpdates {
                try await installAvailableMinorUpdates()
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            if catalog == nil, configuration.seedLocalCatalog {
                catalog = try? loadSeededCatalog()
            }
        }
        rebuildItems()
    }

    func install(_ extensionID: String, version: String? = nil) async throws {
        inProgressIDs.insert(extensionID)
        defer { inProgressIDs.remove(extensionID) }
        let entry = try catalogEntry(extensionID)
        let release: ExtensionRegistryRelease
        if let version {
            guard let match = entry.releases.first(where: { $0.version == version }) else {
                throw ExtensionRegistryError.noCompatibleRelease(extensionID)
            }
            release = match
        } else if let latest = ExtensionCompatibilityResolver.latestCompatible(in: entry) {
            release = latest
        } else {
            throw ExtensionRegistryError.noCompatibleRelease(extensionID)
        }
        guard release.status != .revoked else {
            throw ExtensionRegistryError.noCompatibleRelease(extensionID)
        }
        try await install(entry: entry, release: release)
        rebuildItems()
    }

    func update(_ extensionID: String) async throws {
        try await install(extensionID)
    }

    func rollback(_ extensionID: String) async throws {
        guard var record = records[extensionID], let previous = record.previousVersion else {
            throw ExtensionInstallError.notInstalled(extensionID)
        }
        let previousURL = try store.bundleURL(for: record, version: previous)
        guard fileManager.fileExists(atPath: previousURL.path) else {
            throw ExtensionInstallError.missingInstalledVersion(previous)
        }
        if host?.isLoadedInProcess(extensionID) == true {
            record.pendingActivationVersion = previous
            records[extensionID] = record
            try persist()
            rebuildItems()
            return
        }
        host?.deactivateRuntime(extensionID: extensionID)
        let current = record.activeVersion
        record.activeVersion = previous
        record.previousVersion = current
        record.pendingActivationVersion = nil
        record.enabled = true
        records[extensionID] = record
        try persist()
        let loaded = try makeLoader().loadBundle(at: previousURL)
        host?.activateRuntime(for: loaded)
        host?.markLoadedInProcess(extensionID)
        rebuildItems()
    }

    func uninstall(_ extensionID: String) async throws {
        guard var record = records[extensionID] else {
            throw ExtensionInstallError.notInstalled(extensionID)
        }
        host?.deactivateRuntime(extensionID: extensionID)
        record.enabled = false
        if host?.hasActiveSessions(for: extensionID) == true {
            record.pendingRemoval = true
            records[extensionID] = record
            try persist()
            rebuildItems()
            return
        }
        try finishRemoval(record)
        rebuildItems()
    }

    func completePendingRemovals() throws {
        for record in records.values where record.pendingRemoval {
            if host?.hasActiveSessions(for: record.extensionID) == false {
                try finishRemoval(record)
            }
        }
        rebuildItems()
    }

    func setEnabled(_ enabled: Bool, extensionID: String) throws {
        guard var record = records[extensionID] else { throw ExtensionInstallError.notInstalled(extensionID) }
        record.enabled = enabled
        records[extensionID] = record
        if enabled {
            let loaded = try makeLoader().loadBundle(at: try store.bundleURL(for: record))
            host?.activateRuntime(for: loaded)
            host?.markLoadedInProcess(extensionID)
        } else {
            host?.deactivateRuntime(extensionID: extensionID)
        }
        try persist()
        rebuildItems()
    }

    func availableExtension(for url: URL) -> ExtensionRegistryEntry? {
        if catalog == nil, configuration.seedLocalCatalog {
            catalog = try? loadSeededCatalog()
            rebuildItems()
        }
        return catalog?.extensions.first { entry in
            let installed = records[entry.id]
            let isActive = installed?.enabled == true && installed?.pendingRemoval != true
            return !isActive
                && ExtensionCompatibilityResolver.matches(entry, url: url)
                && ExtensionCompatibilityResolver.latestCompatible(in: entry) != nil
        }
    }

    func isInstalledAndEnabled(_ extensionID: String) -> Bool {
        guard let record = records[extensionID] else { return false }
        return record.enabled && !record.pendingRemoval
    }

    private func install(entry: ExtensionRegistryEntry, release: ExtensionRegistryRelease) async throws {
        if let existing = records[entry.id],
           existing.activeVersion == release.version,
           existing.enabled,
           host?.isLoadedInProcess(entry.id) == true {
            return
        }

        let archive = try await download(release)
        let staging = try store.makeStagingDirectory()
        defer { store.removeItemIfExists(staging) }
        let extracted = try ExtensionArchive.extract(
            archive,
            to: staging.appendingPathComponent("extracted", isDirectory: true),
            limits: configuration.archiveLimits,
            fileManager: fileManager
        )
        let staged = try makeLoader().loadBundle(at: extracted)
        guard staged.manifest.id == entry.id,
              staged.manifest.bundleIdentifierMatchesInstall(entry: entry) else {
            throw ExtensionLoaderError.untrustedBundleID(staged.manifest.id)
        }

        let loadedInProcess = host?.isLoadedInProcess(entry.id) == true
        if loadedInProcess, records[entry.id]?.activeVersion == release.version {
            return
        }

        let committed = try store.commitVersion(
            directoryName: entry.directoryName,
            version: release.version,
            from: extracted
        )
        // 最终不可变目录再验证一次，避免 staging 到激活之间被替换。
        let verified = try makeLoader().loadBundle(at: committed)
        var record = records[entry.id] ?? ExtensionInstallRecord(
            extensionID: entry.id,
            directoryName: entry.directoryName,
            activeVersion: release.version,
            previousVersion: nil,
            enabled: true,
            pendingActivationVersion: nil,
            pendingRemoval: false,
            loadedVersion: nil
        )
        record.directoryName = entry.directoryName
        record.enabled = true
        record.pendingRemoval = false
        if loadedInProcess {
            record.pendingActivationVersion = release.version
            if record.activeVersion != release.version {
                record.previousVersion = record.activeVersion
            }
        } else {
            if record.activeVersion != release.version {
                record.previousVersion = record.activeVersion
            }
            record.activeVersion = release.version
            record.pendingActivationVersion = nil
            host?.deactivateRuntime(extensionID: entry.id)
            host?.activateRuntime(for: verified)
            host?.markLoadedInProcess(entry.id)
            record.loadedVersion = verified.manifest.version
        }
        records[entry.id] = record
        var kept = Set([record.activeVersion])
        if let previous = record.previousVersion { kept.insert(previous) }
        if let pending = record.pendingActivationVersion { kept.insert(pending) }
        try store.prune(directoryName: entry.directoryName, keeping: kept)
        try persist()
    }

    private func download(_ release: ExtensionRegistryRelease) async throws -> Data {
        let cacheURL = store.downloadsDirectory.appendingPathComponent("\(release.sha256).zip")
        if fileManager.fileExists(atPath: cacheURL.path),
           let cached = try? Data(contentsOf: cacheURL),
           ExtensionSHA256.matches(cached, expectedHex: release.sha256) {
            return cached
        }
        let url = release.downloadURL
        let data: Data
        if url.isFileURL {
            guard configuration.allowsFileURLs else { throw ExtensionInstallError.insecureDownload }
            data = try Data(contentsOf: url)
        } else {
            guard url.scheme?.lowercased() == "https" else { throw ExtensionInstallError.insecureDownload }
            let (downloaded, response) = try await configuration.session.data(from: url)
            if let http = response as? HTTPURLResponse,
               http.url?.scheme?.lowercased() != "https" {
                throw ExtensionRegistryError.redirectedToUntrustedURL
            }
            data = downloaded
        }
        guard ExtensionSHA256.matches(data, expectedHex: release.sha256),
              data.count == Int(release.downloadSize) else {
            throw ExtensionInstallError.downloadMismatch
        }
        try store.prepareDirectories()
        try data.write(to: cacheURL, options: .atomic)
        return data
    }

    private func finishRemoval(_ record: ExtensionInstallRecord) throws {
        host?.deactivateRuntime(extensionID: record.extensionID)
        try store.removeExtension(directoryName: record.directoryName)
        records.removeValue(forKey: record.extensionID)
        try persist()
    }

    private func applyPendingActivationsIfPossible() {
        for (id, record) in records {
            guard let pending = record.pendingActivationVersion else { continue }
            guard host?.isLoadedInProcess(id) != true else { continue }
            var updated = record
            if pending != record.activeVersion {
                updated.previousVersion = record.activeVersion
                updated.activeVersion = pending
            }
            updated.pendingActivationVersion = nil
            records[id] = updated
        }
        try? persist()
    }

    private func reconcileRevokedReleases() async throws {
        guard let catalog else { return }
        for entry in catalog.extensions {
            guard var record = records[entry.id] else { continue }
            let activeRelease = entry.releases.first(where: { $0.version == record.activeVersion })
            guard activeRelease?.status == .revoked else { continue }
            if let replacement = ExtensionCompatibilityResolver.latestCompatible(in: entry) {
                try await install(entry: entry, release: replacement)
            } else {
                record.enabled = false
                records[entry.id] = record
                host?.deactivateRuntime(extensionID: entry.id)
                try persist()
            }
        }
    }

    private func installAvailableMinorUpdates() async throws {
        guard let catalog else { return }
        for entry in catalog.extensions {
            guard let record = records[entry.id], record.enabled,
                  let current = SemanticVersion.parse(record.activeVersion),
                  let latest = ExtensionCompatibilityResolver.latestCompatible(in: entry),
                  let latestVersion = SemanticVersion.parse(latest.version),
                  latestVersion.isCompatibleMinorUpdate(from: current) else { continue }
            try await install(entry: entry, release: latest)
        }
    }

    private func persist() throws {
        var state = (try? store.loadState()) ?? .empty
        state.records = records
        try store.saveState(state)
    }

    private func catalogEntry(_ id: String) throws -> ExtensionRegistryEntry {
        guard let entry = catalog?.extensions.first(where: { $0.id == id }) else {
            throw ExtensionRegistryError.unknownExtension(id)
        }
        return entry
    }

    private func makeLoader() -> ExtensionLoader {
        ExtensionLoader(
            trustedTeamID: configuration.trustedTeamID,
            requireSignature: configuration.requireSignature,
            requireNotarization: configuration.requireNotarization
        )
    }

    private func resolvedCatalogURL() throws -> URL {
        if let catalogURL = configuration.catalogURL { return catalogURL }
        return try seedLocalCatalogIfNeeded()
    }

    private func catalogPublicKey() -> Curve25519.Signing.PublicKey {
        if configuration.catalogURL == nil, configuration.seedLocalCatalog,
           let key = try? localSeedPrivateKey().publicKey {
            return key
        }
        return configuration.publicKey
    }

    private func loadSeededCatalog() throws -> ExtensionRegistryCatalog {
        let url = try seedLocalCatalogIfNeeded()
        let data = try Data(contentsOf: url)
        let signed = try ExtensionRegistryCodec.decoder().decode(SignedExtensionRegistry.self, from: data)
        return try ExtensionRegistryCodec.verify(
            signed,
            publicKey: try localSeedPrivateKey().publicKey,
            previousSequence: nil,
            now: configuration.now()
        )
    }

    private func seedLocalCatalogIfNeeded() throws -> URL {
        let directory = store.rootDirectory.appendingPathComponent("ExtensionRegistry", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let archiveURL = directory.appendingPathComponent("Test-1.0.0.zip")
        let privateKey = try localSeedPrivateKey()
        if fileManager.fileExists(atPath: catalogURL.path),
           fileManager.fileExists(atPath: archiveURL.path),
           let data = try? Data(contentsOf: catalogURL),
           let signed = try? ExtensionRegistryCodec.decoder().decode(SignedExtensionRegistry.self, from: data),
           let catalog = try? ExtensionRegistryCodec.verify(
            signed,
            publicKey: privateKey.publicKey,
            previousSequence: nil,
            now: configuration.now()
           ) {
            _ = catalog
            return catalogURL
        }

        let archive = try ExtensionPackageBuilder.makeArchive(manifest: LocalTestExtension.manifest)
        try archive.write(to: archiveURL, options: .atomic)
        let entry = ExtensionRegistryEntry(
            id: LocalTestExtension.identifier,
            name: LocalTestExtension.manifest.name,
            summary: "Opens .foo files and can enhance MP3 playback.",
            featuresSummary: "FOO · MP3",
            capabilitiesSummary: "Commands · Navigator",
            bundleID: LocalTestExtension.identifier,
            directoryName: "Test",
            enhancementDomain: "audio",
            contentTypes: [
                ContentTypeDeclaration(extensions: ["foo"], strategy: .fileExtension),
                ContentTypeDeclaration(extensions: ["mp3"], strategy: .fileExtension),
                ContentTypeDeclaration(utTypes: ["public.audio"], strategy: .conforms)
            ],
            releases: [
                ExtensionRegistryRelease(
                    version: LocalTestExtension.manifest.version,
                    api: LocalTestExtension.manifest.extensionAPI,
                    minMacOS: LocalTestExtension.manifest.system.minMacOS,
                    architectures: LocalTestExtension.manifest.system.architectures,
                    downloadSize: Int64(archive.count),
                    sha256: ExtensionSHA256.hex(archive),
                    downloadURL: archiveURL,
                    status: .active
                )
            ]
        )
        let catalog = ExtensionRegistryCatalog(
            schemaVersion: ExtensionRegistryCatalog.currentSchemaVersion,
            sequence: 1,
            generatedAt: configuration.now(),
            expiresAt: configuration.now().addingTimeInterval(7 * 24 * 60 * 60),
            extensions: [entry]
        )
        let signed = try ExtensionRegistryCodec.sign(catalog, with: privateKey)
        try ExtensionRegistryCodec.encoder().encode(signed).write(to: catalogURL, options: .atomic)
        return catalogURL
    }

    private func localSeedPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let directory = store.rootDirectory.appendingPathComponent("ExtensionRegistry", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appendingPathComponent("dev-signing.key")
        if let data = try? Data(contentsOf: keyURL),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: keyURL, options: .atomic)
        return key
    }

    func rebuildItems() {
        let entries = catalog?.extensions ?? []
        items = entries.map { entry in
            let record = records[entry.id]
            let latest = ExtensionCompatibilityResolver.latestCompatible(in: entry)
            let installed = record?.activeVersion
            let hasUpdate: Bool
            if let installed, let latest,
               let installedVersion = SemanticVersion.parse(installed),
               let latestVersion = SemanticVersion.parse(latest.version) {
                hasUpdate = latestVersion > installedVersion
            } else {
                hasUpdate = false
            }
            return ExtensionSettingsItem(
                id: entry.id,
                name: entry.name,
                summary: entry.summary,
                featuresSummary: entry.featuresSummary,
                capabilitiesSummary: entry.capabilitiesSummary,
                enhancementDomain: entry.enhancementDomain,
                installedVersion: installed,
                availableVersion: latest?.version,
                downloadSize: latest?.downloadSize ?? entry.releases.first?.downloadSize,
                status: latest?.status ?? entry.releases.first?.status,
                enabled: record?.enabled ?? false,
                pendingActivationVersion: record?.pendingActivationVersion,
                pendingRemoval: record?.pendingRemoval ?? false,
                canRollback: record?.previousVersion != nil,
                hasUpdate: hasUpdate
            )
        }
    }
}

private extension ExtensionManifest {
    func bundleIdentifierMatchesInstall(entry: ExtensionRegistryEntry) -> Bool {
        id == entry.id && id == entry.bundleID
    }
}
