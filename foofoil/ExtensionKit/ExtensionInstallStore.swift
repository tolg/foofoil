//  ExtensionInstallStore.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation
import FoofoilExtensionKit

struct ExtensionInstallRecord: Codable, Equatable, Sendable {
    let extensionID: String
    var directoryName: String
    var activeVersion: String
    var previousVersion: String?
    var enabled: Bool
    var pendingActivationVersion: String?
    var pendingRemoval: Bool
    var loadedVersion: String?

    var versionToLoad: String {
        pendingActivationVersion ?? activeVersion
    }
}

struct ExtensionInstallState: Codable, Equatable, Sendable {
    var records: [String: ExtensionInstallRecord]
    var registrySequence: UInt64?

    static var empty: ExtensionInstallState {
        ExtensionInstallState(records: [:], registrySequence: nil)
    }
}

enum ExtensionInstallPaths {
    static func root(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("foofoil", isDirectory: true)
    }

    static func isSafeComponent(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return !value.isEmpty
            && value != "."
            && value != ".."
            && !value.hasPrefix(".")
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

enum ExtensionInstallError: LocalizedError, Equatable {
    case invalidPath
    case downloadMismatch
    case insecureDownload
    case alreadyLoaded(String)
    case hasActiveSessions(String)
    case missingInstalledVersion(String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "The extension install path is invalid."
        case .downloadMismatch: "The downloaded extension does not match the registry checksum."
        case .insecureDownload: "Extension downloads must use HTTPS."
        case .alreadyLoaded(let id): "\(id) is already loaded in this process and will activate on the next launch."
        case .hasActiveSessions(let id): "\(id) still has an open session."
        case .missingInstalledVersion(let version): "Installed extension version \(version) is missing."
        case .notInstalled(let id): "\(id) is not installed."
        }
    }
}

final class ExtensionInstallStore {
    let rootDirectory: URL
    let extensionsDirectory: URL
    let downloadsDirectory: URL
    private let stateURL: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = rootDirectory ?? ExtensionInstallPaths.root(fileManager: fileManager)
        self.rootDirectory = root
        self.extensionsDirectory = root.appendingPathComponent("Extensions", isDirectory: true)
        self.downloadsDirectory = root.appendingPathComponent("ExtensionDownloads", isDirectory: true)
        self.stateURL = root
            .appendingPathComponent("ExtensionState", isDirectory: true)
            .appendingPathComponent("install.json")
    }

    func prepareDirectories() throws {
        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func loadState() throws -> ExtensionInstallState {
        guard fileManager.fileExists(atPath: stateURL.path) else { return .empty }
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(ExtensionInstallState.self, from: data)
    }

    func saveState(_ state: ExtensionInstallState) throws {
        try prepareDirectories()
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func versionDirectory(directoryName: String, version: String) throws -> URL {
        guard ExtensionInstallPaths.isSafeComponent(directoryName),
              ExtensionInstallPaths.isSafeComponent(version) else {
            throw ExtensionInstallError.invalidPath
        }
        return extensionsDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    func bundleURL(for record: ExtensionInstallRecord, version: String? = nil) throws -> URL {
        let version = version ?? record.versionToLoad
        return try versionDirectory(directoryName: record.directoryName, version: version)
    }

    func installedVersions(directoryName: String) throws -> [String] {
        let directory = extensionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { ExtensionInstallPaths.isSafeComponent($0) }
            .sorted()
    }

    /// 将已验证的 staging 目录原子切换到版本目录，不覆盖正在使用的 active 版本。
    func commitVersion(
        directoryName: String,
        version: String,
        from stagingBundle: URL
    ) throws -> URL {
        let destination = try versionDirectory(directoryName: directoryName, version: version)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let temporary = destination.appendingPathExtension("new-\(UUID().uuidString)")
        try fileManager.copyItem(at: stagingBundle, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    func prune(directoryName: String, keeping versions: Set<String>) throws {
        for installed in try installedVersions(directoryName: directoryName) where !versions.contains(installed) {
            try fileManager.removeItem(at: try versionDirectory(directoryName: directoryName, version: installed))
        }
    }

    func removeExtension(directoryName: String) throws {
        let directory = extensionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func makeStagingDirectory() throws -> URL {
        try prepareDirectories()
        let url = downloadsDirectory
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func removeItemIfExists(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

struct ExtensionPackageBuilder {
    static func makeBundle(
        manifest: ExtensionManifest,
        directory: URL,
        bundleID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(manifest.name).foofoilextension", isDirectory: true)
        let resources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID ?? manifest.id,
            "CFBundleName": manifest.name,
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": manifest.version,
            "FoofoilExtensionExecutionModel": ExtensionExecutionModel.xpcService.rawValue
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("ExtensionManifest.json"))
        return bundleURL
    }

    static func makeArchive(manifest: ExtensionManifest, fileManager: FileManager = .default) throws -> Data {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let bundle = try makeBundle(manifest: manifest, directory: directory, fileManager: fileManager)
        var files: [String: Data] = [:]
        let enumerator = fileManager.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: bundle.deletingLastPathComponent().path + "/", with: "")
            files[relative] = try Data(contentsOf: fileURL)
        }
        return try ExtensionArchive.pack(files: files)
    }
}
