//  main.swift
//  foofoilTestExtensionService
//
//  Created by tolg on 2026/8/25.

import Foundation

@objc(FoofoilExtensionServiceProtocol)
protocol TestExtensionServiceProtocol {
    func handshake(apiVersionsJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func createSession(requestJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func performCommand(commandJSON: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

private struct Handshake: Codable {
    let hostAPIVersions: [UInt32]
}

private struct HandshakeResponse: Codable {
    let extensionID: String
    let negotiatedAPI: UInt32
}

private final class TestExtensionService: NSObject, TestExtensionServiceProtocol {
    func handshake(apiVersionsJSON: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let handshake = try? JSONDecoder().decode(Handshake.self, from: apiVersionsJSON),
              handshake.hostAPIVersions.contains(1),
              let response = try? JSONEncoder().encode(
                HandshakeResponse(extensionID: "app.foofoil.extension.test", negotiatedAPI: 1)
              ) else {
            reply(nil, "No compatible Extension API version")
            return
        }
        reply(response, nil)
    }

    func createSession(requestJSON: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        // 样机原样回传值消息，验证跨进程 JSON 与 security-scoped bookmark Data 不依赖进程内对象。
        reply(requestJSON, nil)
    }

    func performCommand(commandJSON: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        reply(commandJSON, nil)
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = TestExtensionService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TestExtensionServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
