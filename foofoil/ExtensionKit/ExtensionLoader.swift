//  ExtensionLoader.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Darwin
import Foundation
import Security

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
        case .missingExecutable: "The extension executable is missing."
        case .missingEntryPoint: "The Extension API entry point is missing."
        case .invalidInterface: "The extension returned an invalid Extension API interface."
        }
    }
}

final class ExtensionLoader {
    private let trustedTeamID: String?
    private let requireSignature: Bool

    init(trustedTeamID: String? = nil, requireSignature: Bool = true) {
        self.trustedTeamID = trustedTeamID ?? Self.teamIdentifier(for: Bundle.main.bundleURL)
        self.requireSignature = requireSignature
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
              Self.supportsCurrentSystem(manifest.system) else {
            throw ExtensionLoaderError.unsupportedSystem
        }
        if requireSignature {
            try validateCodeSignature(at: bundleURL)
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

    private func validateCodeSignature(at url: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw ExtensionLoaderError.invalidCodeSignature(createStatus)
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let validationStatus = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard validationStatus == errSecSuccess else {
            throw ExtensionLoaderError.invalidCodeSignature(validationStatus)
        }
        if let trustedTeamID,
           Self.teamIdentifier(for: url) != trustedTeamID {
            throw ExtensionLoaderError.untrustedTeam
        }
    }

    private static func teamIdentifier(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func supportsCurrentSystem(_ requirements: ExtensionSystemRequirements) -> Bool {
        let architecture: String
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = "unknown"
#endif
        guard requirements.architectures.contains(architecture) else { return false }
        let parts = requirements.minMacOS.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        let required = OperatingSystemVersion(
            majorVersion: parts[0],
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
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
