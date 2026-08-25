//  ExtensionHost.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

final class ExtensionHost {
    static let shared = ExtensionHost()

    let resolver: ProviderResolver
    let stateStore: ExtensionStateStore
    private let audioEnhancer: AudioEnhancerTestProvider
    private var preferredProvidersByDomain: [String: String] = [:]

    init(
        resolver: ProviderResolver = ProviderResolver(),
        stateStore: ExtensionStateStore = ExtensionStateStore()
    ) {
        self.resolver = resolver
        self.stateStore = stateStore
        resolver.register(BuiltInAudioProvider())
        audioEnhancer = LocalTestExtension.register(in: resolver)
    }

    func setPreferredProvider(_ providerID: String?, for domain: String) {
        preferredProvidersByDomain[domain] = providerID
    }

    func canOpen(url: URL) -> Bool {
        if url.pathExtension.lowercased() == "foo" { return true }
        return isAudio(url) && preferredProvidersByDomain["audio"] != nil
    }

    func open(url: URL) async throws -> SessionResolutionOutcome {
        let request = ContentRequest.singleFile(.sandboxed(url: url))
        let domain = isAudio(url) ? "audio" : nil
        return try await resolver.makeSession(
            for: request,
            preferredProviderID: domain.flatMap { preferredProvidersByDomain[$0] }
        )
    }

    func perform(commandID: String, in session: ContentSession) async throws -> ContentSession {
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        return try await provider.perform(commandID: commandID, session: session)
    }

    func setTestAudioEnhancerFailure(_ shouldFail: Bool) {
        audioEnhancer.failSessionCreation = shouldFail
    }

    private func isAudio(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mp3"
    }
}
