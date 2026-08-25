//  ExtensionStateStore.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

struct ExtensionStateEnvelope: Codable, Equatable, Sendable {
    let extensionID: String
    let schemaVersion: UInt32
    let updatedAt: Date
    let payload: Data
}

enum ExtensionStateStoreError: LocalizedError, Equatable {
    case invalidNamespace
    case invalidSchemaVersion
    case payloadTooLarge(limit: Int)
    case namespaceMismatch

    var errorDescription: String? {
        switch self {
        case .invalidNamespace: "The extension state namespace is invalid."
        case .invalidSchemaVersion: "The extension state schema version must be greater than zero."
        case .payloadTooLarge(let limit): "The extension state exceeds the \(limit)-byte limit."
        case .namespaceMismatch: "The extension state namespace does not match its storage location."
        }
    }
}

final class ExtensionStateStore {
    static let defaultPayloadLimit = 1_048_576

    private let rootDirectory: URL
    private let payloadLimit: Int
    private let fileManager: FileManager

    init(
        rootDirectory: URL? = nil,
        payloadLimit: Int = defaultPayloadLimit,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.payloadLimit = payloadLimit
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootDirectory = applicationSupport
                .appendingPathComponent("foofoil", isDirectory: true)
                .appendingPathComponent("ExtensionState", isDirectory: true)
        }
    }

    @discardableResult
    func save(extensionID: String, schemaVersion: UInt32, payload: Data, reference: String? = nil) throws -> String {
        try validateNamespace(extensionID)
        guard schemaVersion > 0 else { throw ExtensionStateStoreError.invalidSchemaVersion }
        guard payload.count <= payloadLimit else {
            throw ExtensionStateStoreError.payloadTooLarge(limit: payloadLimit)
        }
        let reference = reference ?? UUID().uuidString.lowercased()
        guard isSafePathComponent(reference) else { throw ExtensionStateStoreError.invalidNamespace }

        let directory = rootDirectory.appendingPathComponent(extensionID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = ExtensionStateEnvelope(
            extensionID: extensionID,
            schemaVersion: schemaVersion,
            updatedAt: Date(),
            payload: payload
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: directory.appendingPathComponent(reference).appendingPathExtension("json"), options: .atomic)
        return reference
    }

    func load(extensionID: String, reference: String) throws -> ExtensionStateEnvelope? {
        try validateNamespace(extensionID)
        guard isSafePathComponent(reference) else { throw ExtensionStateStoreError.invalidNamespace }
        let url = rootDirectory
            .appendingPathComponent(extensionID, isDirectory: true)
            .appendingPathComponent(reference)
            .appendingPathExtension("json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(ExtensionStateEnvelope.self, from: data) else {
            // 损坏状态不覆盖也不删除，Host 可展示恢复占位并保留人工诊断材料。
            return nil
        }
        guard envelope.extensionID == extensionID else { throw ExtensionStateStoreError.namespaceMismatch }
        guard envelope.payload.count <= payloadLimit else {
            throw ExtensionStateStoreError.payloadTooLarge(limit: payloadLimit)
        }
        return envelope
    }

    private func validateNamespace(_ value: String) throws {
        guard isSafePathComponent(value), value.contains(".") else {
            throw ExtensionStateStoreError.invalidNamespace
        }
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains(":")
    }
}
