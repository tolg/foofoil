//  ProviderResolver.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import UniformTypeIdentifiers
import FoofoilExtensionKit

enum ProviderMatchStrength: Int, Codable, Comparable, Sendable {
    case conforms = 100
    case fileExtension = 200
    case sniff = 300

    static func < (lhs: ProviderMatchStrength, rhs: ProviderMatchStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProviderMatch: Codable, Equatable, Sendable {
    let strength: ProviderMatchStrength
    let explanation: String
}

struct ProviderDescriptor: Codable, Equatable, Sendable {
    let id: String
    let extensionID: String?
    let role: ExtensionProviderRole
    let fallbackProviderID: String?
    let enhancementDomain: String?
    var isEnabled: Bool
    var isRuntimeAvailable: Bool

    var isBuiltIn: Bool { extensionID == nil }
}

enum ProviderSelectionReason: String, Codable, Sendable {
    case userPreference
    case strongContentMatch
    case extensionEnhancement
    case builtIn
}

struct ProviderCandidate: Equatable, Sendable {
    let descriptor: ProviderDescriptor
    let match: ProviderMatch
}

struct ProviderResolution: Equatable, Sendable {
    let selectedProviderID: String
    let reason: ProviderSelectionReason
    let fallbackProviderIDs: [String]
    let candidates: [ProviderCandidate]
}

nonisolated struct ProviderFailure: Equatable, Sendable {
    let providerID: String
    let message: String
}

struct SessionResolutionOutcome: Sendable {
    let session: ContentSession
    let resolution: ProviderResolution
    let failures: [ProviderFailure]
}

enum ProviderResolverError: LocalizedError, Equatable {
    case noProvider
    case allProvidersFailed([ProviderFailure])

    var errorDescription: String? {
        switch self {
        case .noProvider:
            "No content provider is available for this request."
        case .allProvidersFailed(let failures):
            failures.map { "\($0.providerID): \($0.message)" }.joined(separator: "; ")
        }
    }
}

final class ProviderResolver {
    private var providers: [String: any ContentProvider] = [:]
    private var registrationOrder: [String] = []

    func register(_ provider: any ContentProvider) {
        let id = provider.descriptor.id
        if providers[id] == nil {
            registrationOrder.append(id)
        }
        providers[id] = provider
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        registrationOrder.removeAll { $0 == providerID }
    }

    func provider(id: String) -> (any ContentProvider)? {
        providers[id]
    }

    func allDescriptors() -> [ProviderDescriptor] {
        registrationOrder.compactMap { providers[$0]?.descriptor }
    }

    func unregisterProviders(extensionID: String) {
        let ids = registrationOrder.filter { providers[$0]?.descriptor.extensionID == extensionID }
        ids.forEach { unregister(providerID: $0) }
    }

    func candidates(for request: ContentRequest) -> [ProviderCandidate] {
        matchingCandidates(for: request)
    }

    func canResolve(_ request: ContentRequest) -> Bool {
        !matchingCandidates(for: request).isEmpty
    }

    func resolve(_ request: ContentRequest, preferredProviderID: String? = nil) throws -> ProviderResolution {
        let candidates = matchingCandidates(for: request)
        guard !candidates.isEmpty else { throw ProviderResolverError.noProvider }

        let preferredCandidate = preferredProviderID.flatMap { preferred in
            candidates.first { $0.descriptor.id == preferred }
        }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.match.strength != rhs.match.strength {
                return lhs.match.strength > rhs.match.strength
            }
            let lhsClass = providerClass(lhs.descriptor)
            let rhsClass = providerClass(rhs.descriptor)
            if lhsClass != rhsClass { return lhsClass > rhsClass }
            return order(of: lhs.descriptor.id) < order(of: rhs.descriptor.id)
        }
        let selected = preferredCandidate ?? sorted[0]
        let reason: ProviderSelectionReason
        if preferredCandidate != nil {
            reason = .userPreference
        } else if selected.match.strength == .sniff || selected.match.strength == .fileExtension {
            reason = .strongContentMatch
        } else if !selected.descriptor.isBuiltIn {
            reason = .extensionEnhancement
        } else {
            reason = .builtIn
        }

        var fallbackIDs: [String] = []
        if let declaredFallback = selected.descriptor.fallbackProviderID,
           candidates.contains(where: { $0.descriptor.id == declaredFallback }) {
            fallbackIDs.append(declaredFallback)
        }
        fallbackIDs.append(contentsOf: sorted.map(\.descriptor.id).filter {
            $0 != selected.descriptor.id && !fallbackIDs.contains($0)
        })

        return ProviderResolution(
            selectedProviderID: selected.descriptor.id,
            reason: reason,
            fallbackProviderIDs: fallbackIDs,
            candidates: sorted
        )
    }

    func makeSession(
        for request: ContentRequest,
        preferredProviderID: String? = nil,
        negotiatedAPI: UInt32 = 1
    ) async throws -> SessionResolutionOutcome {
        let resolution = try resolve(request, preferredProviderID: preferredProviderID)
        let providerIDs = [resolution.selectedProviderID] + resolution.fallbackProviderIDs
        var failures: [ProviderFailure] = []

        for providerID in providerIDs {
            guard let provider = providers[providerID] else { continue }
            do {
                let accessScope = ExtensionResourceAccessScope(request: request)
                defer { accessScope.stop() }
                let session = try await provider.makeSession(for: request, negotiatedAPI: negotiatedAPI)
                try NavigatorContributionValidator.validate(session)
                return SessionResolutionOutcome(session: session, resolution: resolution, failures: failures)
            } catch {
                failures.append(ProviderFailure(providerID: providerID, message: error.localizedDescription))
            }
        }
        throw ProviderResolverError.allProvidersFailed(failures)
    }

    private func matchingCandidates(for request: ContentRequest) -> [ProviderCandidate] {
        registrationOrder.compactMap { id in
            guard let provider = providers[id],
                  provider.descriptor.isEnabled,
                  provider.descriptor.isRuntimeAvailable,
                  let match = provider.match(request) else { return nil }
            return ProviderCandidate(descriptor: provider.descriptor, match: match)
        }
    }

    private func providerClass(_ descriptor: ProviderDescriptor) -> Int {
        if descriptor.isBuiltIn { return 0 }
        return descriptor.role == .override ? 2 : 1
    }

    private func order(of id: String) -> Int {
        registrationOrder.firstIndex(of: id) ?? .max
    }
}

enum ProviderContentMatcher {
    static func match(_ request: ContentRequest, declarations: [ContentTypeDeclaration], sniff: ((URL) -> Bool)? = nil) -> ProviderMatch? {
        guard let url = request.primaryFileURL else { return nil }
        let fileExtension = url.pathExtension.lowercased()

        for declaration in declarations where declaration.strategy == .sniff {
            let extensionMatches = declaration.extensions?.contains(fileExtension) == true
            let typeMatches = matchesUTType(url: url, identifiers: declaration.utTypes ?? [])
            if (extensionMatches || typeMatches), sniff?(url) == true {
                return ProviderMatch(strength: .sniff, explanation: "content-sniff")
            }
        }
        for declaration in declarations where declaration.strategy == .fileExtension {
            if declaration.extensions?.contains(fileExtension) == true {
                return ProviderMatch(strength: .fileExtension, explanation: "filename-extension:\(fileExtension)")
            }
        }
        for declaration in declarations where declaration.strategy == .conforms {
            if matchesUTType(url: url, identifiers: declaration.utTypes ?? []) {
                return ProviderMatch(strength: .conforms, explanation: "uttype-conformance")
            }
        }
        return nil
    }

    private static func matchesUTType(url: URL, identifiers: [String]) -> Bool {
        guard let sourceType = UTType(filenameExtension: url.pathExtension) else { return false }
        return identifiers.contains { identifier in
            guard let targetType = UTType(identifier) else { return false }
            return sourceType.conforms(to: targetType)
        }
    }
}
