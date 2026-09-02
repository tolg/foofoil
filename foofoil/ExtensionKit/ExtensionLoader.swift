//  ExtensionLoader.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Darwin
import Foundation
import Security
import FoofoilExtensionKit

enum ExtensionExecutionModel: String, Codable, Sendable {
    case inProcess
    case xpcService
}

struct LoadedExtension: Sendable {
    let manifest: ExtensionManifest
    let negotiatedAPI: UInt32
    let bundleURL: URL
    let executionModel: ExtensionExecutionModel
}

enum ExtensionLoaderError: LocalizedError {
    case missingManifest
    case unsupportedSystem
    case invalidBundle
    case invalidCodeSignature(OSStatus)
    case untrustedTeam
    case untrustedBundleID(String)
    case missingNotarization
    case missingExecutable
    case missingEntryPoint
    case invalidInterface

    var errorDescription: String? {
        switch self {
        case .missingManifest: "ExtensionManifest.json is missing."
        case .unsupportedSystem: "The extension is not compatible with this Mac."
        case .invalidBundle: "The extension bundle is invalid."
        case .invalidCodeSignature(let status): "Extension code signature validation failed (\(status))."
        case .untrustedTeam: "The extension is not signed by the foofoil team."
        case .untrustedBundleID(let value): "The extension bundle identifier is not allowed: \(value)."
        case .missingNotarization: "The extension is not notarized."
        case .missingExecutable: "The extension executable is missing."
        case .missingEntryPoint: "The Extension API entry point is missing."
        case .invalidInterface: "The extension returned an invalid Extension API interface."
        }
    }
}

final class ExtensionLoader {
    static let allowedBundleIDPrefix = "app.foofoil.extension."

    private let trustedTeamID: String?
    private let requireSignature: Bool
    private let requireNotarization: Bool
    private let allowedBundleIDPrefix: String

    init(
        trustedTeamID: String? = nil,
        requireSignature: Bool = true,
        requireNotarization: Bool = false,
        allowedBundleIDPrefix: String = ExtensionLoader.allowedBundleIDPrefix
    ) {
        self.trustedTeamID = trustedTeamID ?? Self.teamIdentifier(for: Bundle.main.bundleURL)
        self.requireSignature = requireSignature
        self.requireNotarization = requireNotarization
        self.allowedBundleIDPrefix = allowedBundleIDPrefix
    }

    func discover(in directory: URL) -> [(url: URL, result: Result<LoadedExtension, Error>)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "foofoilextension" || $0.pathExtension == "bundle" }
            .map { url in (url, Result { try loadBundle(at: url) }) }
    }

    func loadBundle(at bundleURL: URL) throws -> LoadedExtension {
        guard let bundle = Bundle(url: bundleURL) else { throw ExtensionLoaderError.invalidBundle }
        let manifestURL = bundle.url(forResource: "ExtensionManifest", withExtension: "json")
            ?? bundleURL.appendingPathComponent("ExtensionManifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionLoaderError.missingManifest
        }
        let manifest = try ExtensionManifestValidator.decodeAndValidate(Data(contentsOf: manifestURL))
        guard let api = ExtensionAPI.negotiate(with: manifest.extensionAPI),
              manifest.system.isSatisfied() else {
            throw ExtensionLoaderError.unsupportedSystem
        }
        let bundleID = (bundle.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleID == manifest.id,
              bundleID.hasPrefix(allowedBundleIDPrefix) else {
            throw ExtensionLoaderError.untrustedBundleID(bundleID.isEmpty ? manifest.id : bundleID)
        }
        if requireSignature {
            try validateCodeSignature(at: bundleURL, expectedBundleID: manifest.id)
        }
        let executionModel = (bundle.object(forInfoDictionaryKey: "FoofoilExtensionExecutionModel") as? String)
            .flatMap(ExtensionExecutionModel.init(rawValue:)) ?? .xpcService
        return LoadedExtension(
            manifest: manifest,
            negotiatedAPI: api,
            bundleURL: bundleURL,
            executionModel: executionModel
        )
    }

    func openInProcessInterface(_ loaded: LoadedExtension) throws -> InProcessExtensionInterface {
        guard loaded.executionModel == .inProcess,
              let bundle = Bundle(url: loaded.bundleURL),
              let executableURL = bundle.executableURL else {
            throw ExtensionLoaderError.missingExecutable
        }
        return try InProcessExtensionInterface(executableURL: executableURL, negotiatedAPI: loaded.negotiatedAPI)
    }

    /// 对静态代码做严格校验：全部 arch、nested code、sealed resources，以及固定 Team ID / Bundle ID。
    private func validateCodeSignature(at url: URL, expectedBundleID: String) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw ExtensionLoaderError.invalidCodeSignature(createStatus)
        }

        var requirement: SecRequirement?
        if let trustedTeamID {
            let requirementString = """
            identifier "\(expectedBundleID)" and anchor apple generic \
            and certificate leaf[subject.OU] = "\(trustedTeamID)"
            """ as CFString
            let requirementStatus = SecRequirementCreateWithString(requirementString, SecCSFlags(), &requirement)
            guard requirementStatus == errSecSuccess else {
                throw ExtensionLoaderError.invalidCodeSignature(requirementStatus)
            }
        }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let validationStatus = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard validationStatus == errSecSuccess else {
            throw ExtensionLoaderError.invalidCodeSignature(validationStatus)
        }
        if let trustedTeamID,
           Self.teamIdentifier(for: url) != trustedTeamID {
            throw ExtensionLoaderError.untrustedTeam
        }
        if Self.signingIdentifier(for: url) != expectedBundleID {
            throw ExtensionLoaderError.untrustedBundleID(Self.signingIdentifier(for: url) ?? "")
        }
        if requireNotarization, !Self.isNotarized(staticCode) {
            throw ExtensionLoaderError.missingNotarization
        }
    }

    private static func teamIdentifier(for url: URL) -> String? {
        signingInformation(for: url)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func signingIdentifier(for url: URL) -> String? {
        signingInformation(for: url)?[kSecCodeInfoIdentifier as String] as? String
    }

    private static func isNotarized(_ staticCode: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        if dictionary["notarization"] != nil { return true }
        var notarizedRequirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, SecCSFlags(), &notarizedRequirement) == errSecSuccess else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), notarizedRequirement) == errSecSuccess
    }

    private static func signingInformation(for url: URL) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}

/// 装载后保持映像到进程退出，不依赖 dlclose 做热升级或卸载。
final class InProcessExtensionInterface {
    typealias CreateFunction = @convention(c) (UInt32) -> UnsafePointer<FoofoilExtensionInterfaceV1>?

    private let imageHandle: UnsafeMutableRawPointer
    let interface: UnsafePointer<FoofoilExtensionInterfaceV1>

    init(executableURL: URL, negotiatedAPI: UInt32) throws {
        guard let imageHandle = dlopen(executableURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw ExtensionLoaderError.missingExecutable
        }
        guard let symbol = dlsym(imageHandle, FOOFOIL_EXTENSION_CREATE_SYMBOL) else {
            throw ExtensionLoaderError.missingEntryPoint
        }
        let create = unsafeBitCast(symbol, to: CreateFunction.self)
        guard let interface = create(negotiatedAPI),
              interface.pointee.api_version == negotiatedAPI,
              interface.pointee.struct_size >= MemoryLayout<FoofoilExtensionInterfaceV1>.size,
              interface.pointee.create_session != nil,
              interface.pointee.release_bytes != nil else {
            throw ExtensionLoaderError.invalidInterface
        }
        self.imageHandle = imageHandle
        self.interface = interface
    }

    deinit {
        interface.pointee.destroy?(interface.pointee.context)
        _ = imageHandle
    }
}
