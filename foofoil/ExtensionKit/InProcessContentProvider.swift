//  InProcessContentProvider.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import FoofoilExtensionKit

/// 把稳定 C ABI 的 JSON 值消息适配为宿主内部 Provider；插件对象不会跨越 ABI 边界。
final class InProcessContentProvider: ContentProvider {
    let descriptor: ProviderDescriptor

    private let declaration: ExtensionProviderDeclaration
    private let runtime: InProcessExtensionInterface

    init(
        extensionID: String,
        declaration: ExtensionProviderDeclaration,
        runtime: InProcessExtensionInterface
    ) {
        self.declaration = declaration
        self.runtime = runtime
        descriptor = ProviderDescriptor(
            id: declaration.id,
            extensionID: extensionID,
            role: declaration.role,
            fallbackProviderID: declaration.fallbackProvider,
            enhancementDomain: declaration.enhancementDomain,
            contentFamily: declaration.contentFamily,
            filenameExtensions: declaration.contentTypes.flatMap { $0.extensions ?? [] },
            isEnabled: true,
            isRuntimeAvailable: true
        )
    }

    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(request, declarations: declaration.contentTypes)
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.createSession(for: request)
        }.value
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(commandID: commandID, session: session)
        }.value
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        guard let index = session.navigatorContributions.firstIndex(where: {
            $0.id == navigatorAction.contributionID
        }) else {
            return session
        }
        var requested = session
        let commandID: String
        switch navigatorAction.kind {
        case .activate:
            guard let selectedID = navigatorAction.itemIDs.first else { return session }
            requested.navigatorContributions[index].selectedItemIDs = [selectedID]
            commandID = "hifi.navigator.activate"
        case .move:
            requested.navigatorContributions[index].items = Self.movingItems(
                requested.navigatorContributions[index].items,
                action: navigatorAction
            )
            commandID = "hifi.navigator.move"
        case .remove:
            return session
        }
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(commandID: commandID, session: requested)
        }.value
    }

    private static func movingItems(
        _ items: [NavigatorItem],
        action: NavigatorAction
    ) -> [NavigatorItem] {
        guard let position = action.movePosition else { return items }
        let movingIDs = Set(action.itemIDs)
        let moving = items.filter { movingIDs.contains($0.id) }
        guard moving.count == movingIDs.count else { return items }
        var remaining = items.filter { !movingIDs.contains($0.id) }
        let insertionIndex: Int
        switch position {
        case .end:
            insertionIndex = remaining.endIndex
        case .before, .after:
            guard let destinationID = action.destinationItemID,
                  let destinationIndex = remaining.firstIndex(where: { $0.id == destinationID }) else {
                return items
            }
            insertionIndex = position == .before
                ? destinationIndex
                : remaining.index(after: destinationIndex)
        }
        remaining.insert(contentsOf: moving, at: insertionIndex)
        return remaining
    }
}
