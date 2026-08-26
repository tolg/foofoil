//  TestExtension.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import UniformTypeIdentifiers

final class BuiltInAudioProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "builtin.audio",
        extensionID: nil,
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: "audio",
        isEnabled: true,
        isRuntimeAvailable: true
    )

    func match(_ request: ContentRequest) -> ProviderMatch? {
        guard let url = request.primaryFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audio) else { return nil }
        return ProviderMatch(strength: .conforms, explanation: "builtin-audio")
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        guard let url = request.primaryFileURL else { throw ContentProviderError.unsupportedRequest }
        return ContentSession(
            extensionID: nil,
            providerID: descriptor.id,
            request: request,
            presentation: .text(
                titleKey: "Built-in Audio Provider",
                body: url.lastPathComponent
            )
        )
    }
}

final class TestContentProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.content",
        extensionID: LocalTestExtension.identifier,
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: nil,
        isEnabled: true,
        isRuntimeAvailable: true
    )

    func match(_ request: ContentRequest) -> ProviderMatch? {
        guard request.primaryFileURL?.pathExtension.lowercased() == "foo" else { return nil }
        return ProviderMatch(strength: .fileExtension, explanation: "filename-extension:foo")
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        guard negotiatedAPI == ExtensionAPI.v1,
              let url = request.primaryFileURL else { throw ContentProviderError.unsupportedRequest }
        let body = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? url.lastPathComponent
        }.value
        return ContentSession(
            extensionID: LocalTestExtension.identifier,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Test Extension", body: body),
            capabilities: [
                NegotiatedCapability(
                    declaration: ExtensionCapabilityDeclaration(
                        id: ExtensionCapabilityIdentifier.commandProvider,
                        scope: .presentation
                    ),
                    state: .active
                ),
                NegotiatedCapability(
                    declaration: ExtensionCapabilityDeclaration(
                        id: ExtensionCapabilityIdentifier.navigator,
                        scope: .presentation
                    ),
                    state: .active
                )
            ],
            commands: [
                CommandDescriptor(
                    id: "test.append-marker",
                    titleLocalizationKey: "Append Test Marker",
                    symbolName: "checkmark.seal"
                )
            ],
            navigatorContributions: [
                NavigatorContribution(
                    id: "test.items",
                    titleLocalizationKey: "Test Items",
                    style: .flat,
                    items: [
                        NavigatorItem(id: "first", title: "First item", symbolName: "1.circle", isCurrent: true),
                        NavigatorItem(id: "second", title: "Second item", symbolName: "2.circle")
                    ],
                    selectedItemIDs: ["first"]
                ),
                NavigatorContribution(
                    id: "test.outline",
                    titleLocalizationKey: "Test Outline",
                    style: .outline,
                    items: [
                        NavigatorItem(id: "chapter", title: "Chapter", symbolName: "book.closed"),
                        NavigatorItem(id: "section-a", parentID: "chapter", title: "Section A"),
                        NavigatorItem(id: "section-b", parentID: "chapter", title: "Section B")
                    ]
                )
            ]
        )
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        guard commandID == "test.append-marker" else { return session }
        var updated = session
        if case .text(let titleKey, let body) = updated.presentation {
            updated.presentation = .text(titleKey: titleKey, body: body + "\n✓ Extension command")
        }
        return updated
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        guard navigatorAction.kind == .activate,
              let itemID = navigatorAction.itemIDs.first,
              let contributionIndex = session.navigatorContributions.firstIndex(where: {
                  $0.id == navigatorAction.contributionID
              }) else { return session }
        var updated = session
        updated.navigatorContributions[contributionIndex].selectedItemIDs = [itemID]
        updated.navigatorContributions[contributionIndex].items = updated.navigatorContributions[contributionIndex].items.map {
            var item = $0
            item.isCurrent = item.id == itemID
            return item
        }
        updated.navigatorContributions[contributionIndex].revision += 1
        return updated
    }
}

final class AudioEnhancerTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.audio-enhancer",
        extensionID: LocalTestExtension.identifier,
        role: .override,
        fallbackProviderID: "builtin.audio",
        enhancementDomain: "audio",
        isEnabled: true,
        isRuntimeAvailable: true
    )
    var failSessionCreation = false

    func match(_ request: ContentRequest) -> ProviderMatch? {
        guard request.primaryFileURL?.pathExtension.lowercased() == "mp3" else { return nil }
        return ProviderMatch(strength: .conforms, explanation: "audio-enhancement")
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        if failSessionCreation {
            throw ContentProviderError.sessionCreationFailed("Test AudioEnhancer failure")
        }
        guard let url = request.primaryFileURL else { throw ContentProviderError.unsupportedRequest }
        return ContentSession(
            extensionID: LocalTestExtension.identifier,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Audio Enhancer", body: url.lastPathComponent),
            capabilities: [
                NegotiatedCapability(
                    declaration: ExtensionCapabilityDeclaration(
                        id: ExtensionCapabilityIdentifier.commandProvider,
                        scope: .presentation
                    ),
                    state: .active
                )
            ],
            commands: [
                CommandDescriptor(
                    id: "test.audio-enhancer.toggle",
                    titleLocalizationKey: "Toggle Audio Enhancement",
                    symbolName: "waveform"
                )
            ]
        )
    }
}

enum LocalTestExtension {
    static let identifier = "app.foofoil.extension.test"

    static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#else
        "x86_64"
#endif
    }

    static let manifest = ExtensionManifest(
        id: identifier,
        name: "Test Extension",
        version: "1.0.0",
        extensionAPI: ExtensionAPICompatibility(min: 1, max: 1),
        system: ExtensionSystemRequirements(
            minMacOS: "15.0",
            architectures: [currentArchitecture]
        ),
        providers: [
            ExtensionProviderDeclaration(
                id: "test.content",
                role: .primary,
                contentTypes: [
                    ContentTypeDeclaration(extensions: ["foo"], strategy: .fileExtension)
                ]
            ),
            ExtensionProviderDeclaration(
                id: "test.audio-enhancer",
                role: .override,
                fallbackProvider: "builtin.audio",
                contentTypes: [
                    ContentTypeDeclaration(extensions: ["mp3"], strategy: .fileExtension),
                    ContentTypeDeclaration(utTypes: ["public.audio"], strategy: .conforms)
                ]
            )
        ],
        capabilities: [
            ExtensionCapabilityDeclaration(
                id: ExtensionCapabilityIdentifier.commandProvider,
                scope: .presentation
            ),
            ExtensionCapabilityDeclaration(
                id: ExtensionCapabilityIdentifier.navigator,
                scope: .presentation
            )
        ]
    )

    static func register(in resolver: ProviderResolver) -> AudioEnhancerTestProvider {
        resolver.register(TestContentProvider())
        let enhancer = AudioEnhancerTestProvider()
        resolver.register(enhancer)
        return enhancer
    }
}
