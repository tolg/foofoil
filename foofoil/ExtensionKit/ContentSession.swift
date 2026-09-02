//  ContentSession.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

enum SessionPresentation: Codable, Equatable, Sendable {
    case text(titleKey: String, body: String)
    case unavailable(titleKey: String, messageKey: String)

    private enum CodingKeys: String, CodingKey { case kind, titleKey, body, messageKey }
    private enum Kind: String, Codable { case text, unavailable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(
                titleKey: try container.decode(String.self, forKey: .titleKey),
                body: try container.decode(String.self, forKey: .body)
            )
        case .unavailable:
            self = .unavailable(
                titleKey: try container.decode(String.self, forKey: .titleKey),
                messageKey: try container.decode(String.self, forKey: .messageKey)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let titleKey, let body):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(titleKey, forKey: .titleKey)
            try container.encode(body, forKey: .body)
        case .unavailable(let titleKey, let messageKey):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(titleKey, forKey: .titleKey)
            try container.encode(messageKey, forKey: .messageKey)
        }
    }
}

struct CommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let titleLocalizationKey: String
    /// 设备名等外部动态值不走本地化；普通宿主 chrome 继续使用 localization key。
    var displayTitle: String?
    /// 指向同一命令集合中的父命令；宿主据此构造原生子菜单。
    var parentID: String?
    var symbolName: String?
    var keyEquivalent: String?
    var modifierFlags: UInt
    var isEnabled: Bool
    var isChecked: Bool

    init(
        id: String,
        titleLocalizationKey: String,
        displayTitle: String? = nil,
        parentID: String? = nil,
        symbolName: String? = nil,
        keyEquivalent: String? = nil,
        modifierFlags: UInt = 0,
        isEnabled: Bool = true,
        isChecked: Bool = false
    ) {
        self.id = id
        self.titleLocalizationKey = titleLocalizationKey
        self.displayTitle = displayTitle
        self.parentID = parentID
        self.symbolName = symbolName
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }
}

struct NegotiatedCapability: Codable, Equatable, Sendable {
    let declaration: ExtensionCapabilityDeclaration
    var state: ExtensionCapabilityState
    var failureMessage: String?
}

struct ContentSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let extensionID: String?
    let providerID: String
    let request: ContentRequest
    var presentation: SessionPresentation
    var capabilities: [NegotiatedCapability]
    var commands: [CommandDescriptor]
    var navigatorContributions: [NavigatorContribution]
    var mediaPlayback: MediaPlaybackSnapshot?
    var playbackQueue: MediaPlaybackQueueSnapshot?
    var audioDeviceSelection: AudioDeviceSelectionSnapshot?
    var stateReference: String?

    init(
        id: UUID = UUID(),
        extensionID: String?,
        providerID: String,
        request: ContentRequest,
        presentation: SessionPresentation,
        capabilities: [NegotiatedCapability] = [],
        commands: [CommandDescriptor] = [],
        navigatorContributions: [NavigatorContribution] = [],
        mediaPlayback: MediaPlaybackSnapshot? = nil,
        playbackQueue: MediaPlaybackQueueSnapshot? = nil,
        audioDeviceSelection: AudioDeviceSelectionSnapshot? = nil,
        stateReference: String? = nil
    ) {
        self.id = id
        self.extensionID = extensionID
        self.providerID = providerID
        self.request = request
        self.presentation = presentation
        self.capabilities = capabilities
        self.commands = commands
        self.navigatorContributions = navigatorContributions
        self.mediaPlayback = mediaPlayback
        self.playbackQueue = playbackQueue
        self.audioDeviceSelection = audioDeviceSelection
        self.stateReference = stateReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, extensionID, providerID, request, presentation, capabilities, commands
        case navigatorContributions, mediaPlayback, playbackQueue, audioDeviceSelection, stateReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        extensionID = try container.decodeIfPresent(String.self, forKey: .extensionID)
        providerID = try container.decode(String.self, forKey: .providerID)
        request = try container.decode(ContentRequest.self, forKey: .request)
        presentation = try container.decode(SessionPresentation.self, forKey: .presentation)
        capabilities = try container.decodeIfPresent([NegotiatedCapability].self, forKey: .capabilities) ?? []
        commands = try container.decodeIfPresent([CommandDescriptor].self, forKey: .commands) ?? []
        // Phase 0 早期 Session 没有导航贡献；缺失字段必须保持可恢复。
        navigatorContributions = try container.decodeIfPresent(
            [NavigatorContribution].self,
            forKey: .navigatorContributions
        ) ?? []
        mediaPlayback = try container.decodeIfPresent(MediaPlaybackSnapshot.self, forKey: .mediaPlayback)
        playbackQueue = try container.decodeIfPresent(MediaPlaybackQueueSnapshot.self, forKey: .playbackQueue)
        audioDeviceSelection = try container.decodeIfPresent(
            AudioDeviceSelectionSnapshot.self,
            forKey: .audioDeviceSelection
        )
        stateReference = try container.decodeIfPresent(String.self, forKey: .stateReference)
    }
}

enum ContentProviderError: LocalizedError, Equatable {
    case unavailable(String)
    case unsupportedRequest
    case sessionCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let provider): "Provider unavailable: \(provider)"
        case .unsupportedRequest: "The provider does not support this request."
        case .sessionCreationFailed(let message): message
        }
    }
}

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
