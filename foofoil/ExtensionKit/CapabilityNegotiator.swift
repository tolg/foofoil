//  CapabilityNegotiator.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

struct HostCapabilityContract: Equatable, Sendable {
    let id: String
    let maximumContractVersion: UInt32
    let scope: ExtensionCapabilityScope
}

enum CapabilityRejectionReason: String, Equatable, Sendable {
    case unsupportedIdentifier
    case unsupportedContractVersion
    case scopeMismatch
    case missingDependency
}

struct RejectedCapability: Equatable, Sendable {
    let declaration: ExtensionCapabilityDeclaration
    let reason: CapabilityRejectionReason
}

struct CapabilityNegotiationResult: Equatable, Sendable {
    let accepted: [NegotiatedCapability]
    let rejected: [RejectedCapability]
}

enum CapabilityNegotiator {
    static let v1HostContracts: [HostCapabilityContract] = [
        .init(id: ExtensionCapabilityIdentifier.seekable, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.mediaPlaybackQueue, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.audioEffects, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.visualization, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.subtitle, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.controllerInput, maximumContractVersion: 1, scope: .session),
        .init(id: ExtensionCapabilityIdentifier.deviceSelector, maximumContractVersion: 1, scope: .application),
        .init(id: ExtensionCapabilityIdentifier.settingsProvider, maximumContractVersion: 1, scope: .application),
        .init(id: ExtensionCapabilityIdentifier.commandProvider, maximumContractVersion: 1, scope: .presentation),
        .init(id: ExtensionCapabilityIdentifier.navigator, maximumContractVersion: 1, scope: .presentation),
        .init(id: ExtensionCapabilityIdentifier.presentationAdapter, maximumContractVersion: 1, scope: .presentation)
    ]

    static func negotiate(
        _ declarations: [ExtensionCapabilityDeclaration],
        hostContracts: [HostCapabilityContract] = v1HostContracts
    ) -> CapabilityNegotiationResult {
        let contracts = Dictionary(uniqueKeysWithValues: hostContracts.map { ($0.id, $0) })
        let declaredIDs = Set(declarations.map(\.id))
        var acceptedIDs = Set<String>()
        var accepted: [NegotiatedCapability] = []
        var rejected: [RejectedCapability] = []

        // 依赖必须先被接受；重复扫描允许 manifest 不按依赖顺序书写。
        var pending = declarations
        var madeProgress = true
        while madeProgress, !pending.isEmpty {
            madeProgress = false
            pending.removeAll { declaration in
                guard let contract = contracts[declaration.id] else {
                    rejected.append(.init(declaration: declaration, reason: .unsupportedIdentifier))
                    madeProgress = true
                    return true
                }
                guard contract.scope == declaration.scope else {
                    rejected.append(.init(declaration: declaration, reason: .scopeMismatch))
                    madeProgress = true
                    return true
                }
                guard declaration.contractVersion <= contract.maximumContractVersion else {
                    rejected.append(.init(declaration: declaration, reason: .unsupportedContractVersion))
                    madeProgress = true
                    return true
                }
                let unresolved = declaration.dependencies.filter { !acceptedIDs.contains($0) }
                guard unresolved.isEmpty else {
                    if unresolved.contains(where: { !declaredIDs.contains($0) }) {
                        rejected.append(.init(declaration: declaration, reason: .missingDependency))
                        madeProgress = true
                        return true
                    }
                    return false
                }
                acceptedIDs.insert(declaration.id)
                accepted.append(.init(declaration: declaration, state: .available))
                madeProgress = true
                return true
            }
        }
        rejected.append(contentsOf: pending.map {
            RejectedCapability(declaration: $0, reason: .missingDependency)
        })
        return CapabilityNegotiationResult(accepted: accepted, rejected: rejected)
    }
}
