//  ExtensionCompatibilityResolver.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    static func parse(_ string: String) -> SemanticVersion? {
        let core = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? string
        let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numeric = parts[0].split(separator: ".")
        guard numeric.count == 3,
              let major = Int(numeric[0]),
              let minor = Int(numeric[1]),
              let patch = Int(numeric[2]) else { return nil }
        let prerelease = parts.count > 1
            ? parts[1].split(separator: ".").map(String.init)
            : []
        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    func isCompatibleMinorUpdate(from other: SemanticVersion) -> Bool {
        major == other.major && self > other && !isPrerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            if let leftNumber, let rightNumber { return leftNumber < rightNumber }
            if leftNumber != nil { return true }
            if rightNumber != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum ExtensionCompatibilityResolver {
    static func latestCompatible(
        in entry: ExtensionRegistryEntry,
        hostAPIs: Set<UInt32> = ExtensionAPI.supportedVersions,
        architecture: String = ExtensionSystemRequirements.currentArchitecture,
        macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        includeDeprecated: Bool = true,
        excludeRevoked: Bool = true
    ) -> ExtensionRegistryRelease? {
        compatibleReleases(
            in: entry,
            hostAPIs: hostAPIs,
            architecture: architecture,
            macOS: macOS,
            includeDeprecated: includeDeprecated,
            excludeRevoked: excludeRevoked
        ).first
    }

    static func compatibleReleases(
        in entry: ExtensionRegistryEntry,
        hostAPIs: Set<UInt32> = ExtensionAPI.supportedVersions,
        architecture: String = ExtensionSystemRequirements.currentArchitecture,
        macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        includeDeprecated: Bool = true,
        excludeRevoked: Bool = true
    ) -> [ExtensionRegistryRelease] {
        entry.releases
            .filter { release in
                if excludeRevoked, release.status == .revoked { return false }
                if !includeDeprecated, release.status == .deprecated { return false }
                guard ExtensionAPI.negotiate(with: release.api) != nil,
                      hostAPIs.contains(where: { release.api.contains($0) }),
                      release.system.isSatisfied(architecture: architecture, macOS: macOS),
                      SemanticVersion.parse(release.version) != nil else {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsStatus = statusRank(lhs.status)
                let rhsStatus = statusRank(rhs.status)
                if lhsStatus != rhsStatus { return lhsStatus > rhsStatus }
                let lhsVersion = SemanticVersion.parse(lhs.version)!
                let rhsVersion = SemanticVersion.parse(rhs.version)!
                return lhsVersion > rhsVersion
            }
    }

    static func matches(_ entry: ExtensionRegistryEntry, url: URL) -> Bool {
        ProviderContentMatcher.match(
            .singleFile(.init(url: url)),
            declarations: entry.contentTypes
        ) != nil
    }

    private static func statusRank(_ status: ExtensionReleaseStatus) -> Int {
        switch status {
        case .active: 2
        case .deprecated: 1
        case .revoked: 0
        }
    }
}
