//  ExtensionHost.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

final class ExtensionHost: ExtensionRuntimeHost {
    static let shared = ExtensionHost()

    let resolver: ProviderResolver
    let stateStore: ExtensionStateStore
    let manager: ExtensionManager
    private var audioEnhancer: AudioEnhancerTestProvider?
    private var preferredProvidersByDomain: [String: String]
    private var sessionCounts: [String: Int] = [:]
    private var loadedInProcess: Set<String> = []
    private let sessionLock = NSLock()

    init(
        resolver: ProviderResolver = ProviderResolver(),
        stateStore: ExtensionStateStore = ExtensionStateStore(),
        manager: ExtensionManager? = nil
    ) {
        self.resolver = resolver
        self.stateStore = stateStore
        self.preferredProvidersByDomain = SettingsStore.shared.preferredProvidersByDomain
        resolver.register(BuiltInAudioProvider())
        let resolvedManager = manager ?? ExtensionManager()
        self.manager = resolvedManager
        resolvedManager.host = self
        resolvedManager.loadInstalledRuntimes()
    }

    func setPreferredProvider(_ providerID: String?, for domain: String) {
        preferredProvidersByDomain[domain] = providerID
        SettingsStore.shared.preferredProvidersByDomain = preferredProvidersByDomain
    }

    func preferredProvider(for domain: String) -> String? {
        preferredProvidersByDomain[domain]
    }

    func canOpen(url: URL) -> Bool {
        let request = ContentRequest.singleFile(.init(url: url))
        let candidates = resolver.candidates(for: request)
        if candidates.contains(where: { !$0.descriptor.isBuiltIn && $0.descriptor.role == .primary }) {
            return true
        }
        if let domain = candidates.compactMap(\.descriptor.enhancementDomain).first,
           let preferred = preferredProvidersByDomain[domain],
           candidates.contains(where: { $0.descriptor.id == preferred && !$0.descriptor.isBuiltIn }) {
            return true
        }
        return false
    }

    func open(url: URL) async throws -> SessionResolutionOutcome {
        let request = ContentRequest.singleFile(.sandboxed(url: url))
        let domain = resolver.candidates(for: request).compactMap(\.descriptor.enhancementDomain).first
        return try await resolver.makeSession(
            for: request,
            preferredProviderID: domain.flatMap { preferredProvidersByDomain[$0] }
        )
    }

    func perform(commandID: String, in session: ContentSession) async throws -> ContentSession {
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        let updated = try await provider.perform(commandID: commandID, session: session)
        try NavigatorContributionValidator.validate(updated)
        return updated
    }

    func perform(navigatorAction: NavigatorAction, in session: ContentSession) async throws -> ContentSession {
        guard let contribution = session.navigatorContributions.first(where: { $0.id == navigatorAction.contributionID }) else {
            throw NavigatorContributionError.invalidAction(navigatorAction.contributionID)
        }
        try NavigatorContributionValidator.validate(navigatorAction, in: contribution)
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        let updated = try await provider.perform(navigatorAction: navigatorAction, session: session)
        try NavigatorContributionValidator.validate(updated)
        return updated
    }

    func setTestAudioEnhancerFailure(_ shouldFail: Bool) {
        audioEnhancer?.failSessionCreation = shouldFail
    }

    func retainSession(extensionID: String) {
        sessionLock.lock()
        sessionCounts[extensionID, default: 0] += 1
        sessionLock.unlock()
    }

    func releaseSession(extensionID: String) {
        sessionLock.lock()
        let next = max(0, (sessionCounts[extensionID] ?? 0) - 1)
        if next == 0 {
            sessionCounts.removeValue(forKey: extensionID)
        } else {
            sessionCounts[extensionID] = next
        }
        sessionLock.unlock()
        try? manager.completePendingRemovals()
    }

    func activateRuntime(for loaded: LoadedExtension) {
        if loaded.manifest.id == LocalTestExtension.identifier {
            resolver.unregisterProviders(extensionID: loaded.manifest.id)
            audioEnhancer = LocalTestExtension.register(in: resolver)
        }
        markLoadedInProcess(loaded.manifest.id)
    }

    func deactivateRuntime(extensionID: String) {
        resolver.unregisterProviders(extensionID: extensionID)
        if extensionID == LocalTestExtension.identifier {
            audioEnhancer = nil
        }
    }

    func hasActiveSessions(for extensionID: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (sessionCounts[extensionID] ?? 0) > 0
    }

    func isLoadedInProcess(_ extensionID: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return loadedInProcess.contains(extensionID)
    }

    func markLoadedInProcess(_ extensionID: String) {
        sessionLock.lock()
        loadedInProcess.insert(extensionID)
        sessionLock.unlock()
    }
}
