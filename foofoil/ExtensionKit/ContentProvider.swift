//  ContentProvider.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import FoofoilExtensionKit
import Foundation

/// 仅供 Host 内部和经过验证的进程内样机使用；跨 Release 的边界是 C ABI 或 XPC Data 消息。
protocol ContentProvider: AnyObject {
    var descriptor: ProviderDescriptor { get }
    func match(_ request: ContentRequest) -> ProviderMatch?
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession
    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession
}

extension ContentProvider {
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        session
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        session
    }
}
