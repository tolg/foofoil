//  ExtensionProcessConnection.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

@objc(FoofoilExtensionServiceProtocol)
protocol FoofoilExtensionServiceProtocol {
    func handshake(apiVersionsJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func createSession(requestJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func performCommand(commandJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

struct ExtensionProcessHandshake: Codable, Equatable, Sendable {
    let hostAPIVersions: [UInt32]
}

struct ExtensionProcessHandshakeResponse: Codable, Equatable, Sendable {
    let extensionID: String
    let negotiatedAPI: UInt32
}

enum ExtensionProcessError: LocalizedError {
    case unavailable
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The extension process is unavailable."
        case .invalidResponse: "The extension process returned an invalid response."
        case .remote(let message): message
        }
    }
}

final class ExtensionProcessConnection {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FoofoilExtensionServiceProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    func handshake() async throws -> ExtensionProcessHandshakeResponse {
        let request = ExtensionProcessHandshake(hostAPIVersions: ExtensionAPI.supportedVersions.sorted())
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? FoofoilExtensionServiceProtocol else {
                continuation.resume(throwing: ExtensionProcessError.unavailable)
                return
            }
            proxy.handshake(apiVersionsJSON: data) { response, errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: ExtensionProcessError.remote(errorMessage))
                } else if let response,
                          let decoded = try? JSONDecoder().decode(ExtensionProcessHandshakeResponse.self, from: response) {
                    continuation.resume(returning: decoded)
                } else {
                    continuation.resume(throwing: ExtensionProcessError.invalidResponse)
                }
            }
        }
    }

    func createSession(for request: ContentRequest) async throws -> ContentRequest {
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? FoofoilExtensionServiceProtocol else {
                continuation.resume(throwing: ExtensionProcessError.unavailable)
                return
            }
            proxy.createSession(requestJSON: data) { response, errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: ExtensionProcessError.remote(errorMessage))
                } else if let response,
                          let decoded = try? JSONDecoder().decode(ContentRequest.self, from: response) {
                    continuation.resume(returning: decoded)
                } else {
                    continuation.resume(throwing: ExtensionProcessError.invalidResponse)
                }
            }
        }
    }
}
