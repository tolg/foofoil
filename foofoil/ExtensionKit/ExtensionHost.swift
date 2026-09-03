//  ExtensionHost.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import FoofoilExtensionKit
import UniformTypeIdentifiers

final class ExtensionHost: ExtensionRuntimeHost {
    static let shared = ExtensionHost()

    let resolver: ProviderResolver
    let stateStore: ExtensionStateStore
    let manager: ExtensionManager
    private var audioEnhancer: AudioEnhancerTestProvider?
    private var preferredProvidersByDomain: [String: String]
    private var sessionCounts: [String: Int] = [:]
    private var loadedInProcess: Set<String> = []
    private var inProcessRuntimes: [String: InProcessExtensionInterface] = [:]
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
#if DEBUG
        loadBundledDevelopmentRuntimes()
#endif
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
        let domain = candidates.compactMap(\.descriptor.enhancementDomain).first
        let preferred = domain.flatMap { preferredProvidersByDomain[$0] }
        guard let resolution = try? resolver.resolve(request, preferredProviderID: preferred),
              let provider = resolver.provider(id: resolution.selectedProviderID) else { return false }
        return !provider.descriptor.isBuiltIn
    }

    /// 扩展只声明内容家族，宿主据此决定应复用哪一套列表与呈现；
    /// 是否真的由该扩展播放，仍在打开当前项目时重新执行 provider resolution。
    func canOpenAsAudio(url: URL) -> Bool {
        let request = ContentRequest.singleFile(.init(url: url))
        return resolver.candidates(for: request).contains {
            !$0.descriptor.isBuiltIn && $0.descriptor.contentFamily == .audio
        }
    }

    func additionalContentTypes(for family: ExtensionContentFamily) -> [UTType] {
        let extensions = resolver.allDescriptors()
            .filter { !$0.isBuiltIn && $0.contentFamily == family }
            .flatMap(\.filenameExtensions)
        var seen = Set<String>()
        return extensions.compactMap { UTType(filenameExtension: $0) }.filter {
            seen.insert($0.identifier).inserted
        }
    }

    func open(url: URL) async throws -> SessionResolutionOutcome {
        let request = ContentRequest.singleFile(.sandboxed(url: url))
        let domain = resolver.candidates(for: request).compactMap(\.descriptor.enhancementDomain).first
        return try await resolver.makeSession(
            for: request,
            preferredProviderID: domain.flatMap { preferredProvidersByDomain[$0] }
        )
    }

    func open(urls: [URL]) async throws -> SessionResolutionOutcome {
        let request = ContentRequest.fileCollection(urls.map(ExtensionResource.sandboxed(url:)))
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
        try CommandContributionValidator.validate(updated)
        try MediaSessionContractValidator.validate(updated)
        return updated
    }

    /// 通知扩展释放会话持有的文件访问与独占音频设备；普通扩展可忽略此命令。
    func closeSession(_ session: ContentSession) {
        Task { @MainActor in
            await closeSessionAndWait(session)
        }
    }

    /// 需要紧接着接管同一硬件资源时使用。返回前扩展已完成 stop、格式恢复与 hog mode 释放。
    func closeSessionAndWait(_ session: ContentSession) async {
        guard let provider = resolver.provider(id: session.providerID) else { return }
        _ = try? await provider.perform(commandID: "hifi.close", session: session)
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
        try CommandContributionValidator.validate(updated)
        try MediaSessionContractValidator.validate(updated)
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
        } else if loaded.executionModel == .inProcess {
            do {
                let runtime = try manager.makeLoader().openInProcessInterface(loaded)
                resolver.unregisterProviders(extensionID: loaded.manifest.id)
                for declaration in loaded.manifest.providers {
                    resolver.register(InProcessContentProvider(
                        extensionID: loaded.manifest.id,
                        declaration: declaration,
                        runtime: runtime
                    ))
                }
                inProcessRuntimes[loaded.manifest.id] = runtime
            } catch {
                NSLog("Extension runtime activation failed: \(error.localizedDescription)")
                return
            }
        }
        markLoadedInProcess(loaded.manifest.id)
    }

    func deactivateRuntime(extensionID: String) {
        resolver.unregisterProviders(extensionID: extensionID)
        inProcessRuntimes.removeValue(forKey: extensionID)
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

#if DEBUG
    /// `./run` 注入的开发插件不写安装状态；Release 只从正式安装目录加载。
    private func loadBundledDevelopmentRuntimes() {
        guard let directory = Bundle.main.builtInPlugInsURL else { return }
        let loader = manager.makeLoader()
        for discovered in loader.discover(in: directory) {
            guard case .success(let loaded) = discovered.result else {
                if case .failure(let error) = discovered.result {
                    NSLog("Development extension load failed: \(error.localizedDescription)")
                }
                continue
            }
            activateRuntime(for: loaded)
        }
    }
#endif
}
