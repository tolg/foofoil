//  ExtensionRegistry.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import CryptoKit
import Foundation

enum ExtensionReleaseStatus: String, Codable, Sendable {
    case active
    case deprecated
    case revoked
}

struct ExtensionRegistryRelease: Codable, Equatable, Sendable {
    let version: String
    let api: ExtensionAPICompatibility
    let minMacOS: String
    let architectures: [String]
    let downloadSize: Int64
    let sha256: String
    let downloadURL: URL
    let status: ExtensionReleaseStatus

    var system: ExtensionSystemRequirements {
        ExtensionSystemRequirements(minMacOS: minMacOS, architectures: architectures)
    }
}

struct ExtensionRegistryEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let summary: String
    var featuresSummary: String? = nil
    var capabilitiesSummary: String? = nil
    let bundleID: String
    let directoryName: String
    var enhancementDomain: String? = nil
    var contentTypes: [ContentTypeDeclaration]
    let releases: [ExtensionRegistryRelease]
}

struct ExtensionRegistryCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let sequence: UInt64
    let generatedAt: Date
    let expiresAt: Date
    let extensions: [ExtensionRegistryEntry]
}

struct SignedExtensionRegistry: Codable, Equatable, Sendable {
    let payload: Data
    let signature: Data
}

enum ExtensionRegistryError: LocalizedError, Equatable {
    case invalidSchema
    case expired
    case rolledBack
    case invalidSignature
    case malformedCatalog
    case insecureURL
    case redirectedToUntrustedURL
    case unknownExtension(String)
    case noCompatibleRelease(String)

    var errorDescription: String? {
        switch self {
        case .invalidSchema: "The extension registry schema is unsupported."
        case .expired: "The extension registry metadata has expired."
        case .rolledBack: "The extension registry metadata is older than the last accepted catalog."
        case .invalidSignature: "The extension registry signature is invalid."
        case .malformedCatalog: "The extension registry catalog is malformed."
        case .insecureURL: "The extension registry must be fetched over HTTPS."
        case .redirectedToUntrustedURL: "The extension registry redirected to an untrusted location."
        case .unknownExtension(let id): "Unknown extension: \(id)."
        case .noCompatibleRelease(let id): "No compatible release is available for \(id)."
        }
    }
}

enum ExtensionRegistryTrust {
    /// 官网 Registry 的固定 Ed25519 公钥；私钥不进入客户端。
    static let productionPublicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(hexadecimal: "13e8ac5199fdc13a16d91ab2cfc119b4ec9c6c4da48a0cee95ea4b16e888538a")
    )

    static func makeSigningKey() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }
}

enum ExtensionRegistryCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func sign(_ catalog: ExtensionRegistryCatalog, with privateKey: Curve25519.Signing.PrivateKey) throws -> SignedExtensionRegistry {
        let payload = try encoder().encode(catalog)
        let signature = try privateKey.signature(for: payload)
        return SignedExtensionRegistry(payload: payload, signature: Data(signature))
    }

    static func verify(
        _ signed: SignedExtensionRegistry,
        publicKey: Curve25519.Signing.PublicKey,
        previousSequence: UInt64? = nil,
        now: Date = Date()
    ) throws -> ExtensionRegistryCatalog {
        guard publicKey.isValidSignature(signed.signature, for: signed.payload) else {
            throw ExtensionRegistryError.invalidSignature
        }
        let catalog: ExtensionRegistryCatalog
        do {
            catalog = try decoder().decode(ExtensionRegistryCatalog.self, from: signed.payload)
        } catch {
            throw ExtensionRegistryError.malformedCatalog
        }
        try validate(catalog, previousSequence: previousSequence, now: now)
        return catalog
    }

    static func validate(
        _ catalog: ExtensionRegistryCatalog,
        previousSequence: UInt64? = nil,
        now: Date = Date()
    ) throws {
        guard catalog.schemaVersion == ExtensionRegistryCatalog.currentSchemaVersion else {
            throw ExtensionRegistryError.invalidSchema
        }
        guard catalog.expiresAt >= now else {
            throw ExtensionRegistryError.expired
        }
        if let previousSequence, catalog.sequence < previousSequence {
            throw ExtensionRegistryError.rolledBack
        }
        var identifiers = Set<String>()
        for entry in catalog.extensions {
            guard identifiers.insert(entry.id).inserted,
                  entry.bundleID == entry.id,
                  entry.bundleID.hasPrefix(ExtensionLoader.allowedBundleIDPrefix),
                  ExtensionInstallPaths.isSafeComponent(entry.directoryName),
                  !entry.releases.isEmpty else {
                throw ExtensionRegistryError.malformedCatalog
            }
            for release in entry.releases {
                guard SemanticVersion.parse(release.version) != nil,
                      ExtensionSHA256.isValidHex(release.sha256),
                      release.downloadSize > 0,
                      release.api.min > 0,
                      release.api.min <= release.api.max,
                      !release.architectures.isEmpty else {
                    throw ExtensionRegistryError.malformedCatalog
                }
            }
        }
    }
}

struct ExtensionRegistryClient {
    var publicKey: Curve25519.Signing.PublicKey
    var allowsFileURLs: Bool
    var session: URLSession
    var now: @Sendable () -> Date

    init(
        publicKey: Curve25519.Signing.PublicKey = ExtensionRegistryTrust.productionPublicKey,
        allowsFileURLs: Bool = false,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.publicKey = publicKey
        self.allowsFileURLs = allowsFileURLs
        self.session = session
        self.now = now
    }

    func fetch(from url: URL, previousSequence: UInt64? = nil) async throws -> ExtensionRegistryCatalog {
        let data = try await downloadSignedCatalog(from: url)
        let signed = try ExtensionRegistryCodec.decoder().decode(SignedExtensionRegistry.self, from: data)
        return try ExtensionRegistryCodec.verify(
            signed,
            publicKey: publicKey,
            previousSequence: previousSequence,
            now: now()
        )
    }

    private func downloadSignedCatalog(from url: URL) async throws -> Data {
        if url.isFileURL {
            guard allowsFileURLs else { throw ExtensionRegistryError.insecureURL }
            return try Data(contentsOf: url)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ExtensionRegistryError.insecureURL
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           let finalURL = http.url,
           finalURL.scheme?.lowercased() != "https" {
            throw ExtensionRegistryError.redirectedToUntrustedURL
        }
        return data
    }
}

enum ExtensionSHA256 {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidHex(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    static func matches(_ data: Data, expectedHex: String) -> Bool {
        hex(data) == expectedHex.lowercased()
    }
}

private extension Data {
    init(hexadecimal hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
