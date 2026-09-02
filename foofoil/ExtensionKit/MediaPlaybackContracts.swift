import Foundation

enum ExtensionMediaPlaybackState: String, Codable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed
}

enum ExtensionMediaRepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

struct MediaPlaybackSnapshot: Codable, Equatable, Sendable {
    var state: ExtensionMediaPlaybackState
    var position: TimeInterval
    var duration: TimeInterval?
    var isSeekable: Bool
    var failureMessage: String?

    init(
        state: ExtensionMediaPlaybackState = .idle,
        position: TimeInterval = 0,
        duration: TimeInterval? = nil,
        isSeekable: Bool = false,
        failureMessage: String? = nil
    ) {
        self.state = state
        self.position = position
        self.duration = duration
        self.isSeekable = isSeekable
        self.failureMessage = failureMessage
    }
}

struct MediaPlaybackQueueItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var subtitle: String?
    var duration: TimeInterval?
    var symbolName: String?
    var isPlayable: Bool

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        duration: TimeInterval? = nil,
        symbolName: String? = nil,
        isPlayable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.symbolName = symbolName
        self.isPlayable = isPlayable
    }
}

struct MediaPlaybackQueueSnapshot: Codable, Equatable, Sendable {
    let contractVersion: UInt32
    var items: [MediaPlaybackQueueItem]
    var currentItemID: String?
    var repeatMode: ExtensionMediaRepeatMode
    var isShuffled: Bool
    var revision: UInt64

    init(
        contractVersion: UInt32 = 1,
        items: [MediaPlaybackQueueItem],
        currentItemID: String? = nil,
        repeatMode: ExtensionMediaRepeatMode = .off,
        isShuffled: Bool = false,
        revision: UInt64 = 0
    ) {
        self.contractVersion = contractVersion
        self.items = items
        self.currentItemID = currentItemID
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.revision = revision
    }
}

enum DSDOutputPolicy: String, Codable, Sendable {
    case automatic
    case preferDoP
    case convertToPCM
}

enum AudioOutputTransport: String, Codable, Sendable {
    case system
    case pcm
    case dop
}

struct AudioOutputDeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
    /// 使用 CoreAudio AudioDeviceUID；设备重连时不能依赖易变的 AudioObjectID。
    let id: String
    var displayName: String
    var isSystemDefault: Bool
    var isConnected: Bool
    var hasHardwareVolume: Bool
    var supportedDoPRates: [Int]

    init(
        id: String,
        displayName: String,
        isSystemDefault: Bool = false,
        isConnected: Bool = true,
        hasHardwareVolume: Bool = false,
        supportedDoPRates: [Int] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.isSystemDefault = isSystemDefault
        self.isConnected = isConnected
        self.hasHardwareVolume = hasHardwareVolume
        self.supportedDoPRates = supportedDoPRates
    }
}

struct AudioDeviceSelectionSnapshot: Codable, Equatable, Sendable {
    let contractVersion: UInt32
    var devices: [AudioOutputDeviceDescriptor]
    /// nil 表示跟随系统默认输出，避免持久化一次性的 AudioObjectID。
    var selectedDeviceID: String?
    var outputPolicy: DSDOutputPolicy
    var activeTransport: AudioOutputTransport?
    var statusDescription: String?
    var revision: UInt64

    init(
        contractVersion: UInt32 = 1,
        devices: [AudioOutputDeviceDescriptor],
        selectedDeviceID: String? = nil,
        outputPolicy: DSDOutputPolicy = .automatic,
        activeTransport: AudioOutputTransport? = nil,
        statusDescription: String? = nil,
        revision: UInt64 = 0
    ) {
        self.contractVersion = contractVersion
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.outputPolicy = outputPolicy
        self.activeTransport = activeTransport
        self.statusDescription = statusDescription
        self.revision = revision
    }
}

enum MediaSessionContractError: LocalizedError, Equatable {
    case unsupportedContractVersion(UInt32)
    case missingCapability(String)
    case duplicateQueueItem(String)
    case invalidCurrentItem(String)
    case invalidPlaybackPosition
    case duplicateDevice(String)
    case invalidSelectedDevice(String)
    case invalidDoPRate(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedContractVersion(let version):
            "Unsupported media contract version: \(version)"
        case .missingCapability(let identifier):
            "Media state is missing an active capability: \(identifier)"
        case .duplicateQueueItem(let identifier):
            "Duplicate playback queue item: \(identifier)"
        case .invalidCurrentItem(let identifier):
            "The current playback item does not exist: \(identifier)"
        case .invalidPlaybackPosition:
            "The playback position is invalid."
        case .duplicateDevice(let identifier):
            "Duplicate audio output device: \(identifier)"
        case .invalidSelectedDevice(let identifier):
            "The selected audio output device is unavailable: \(identifier)"
        case .invalidDoPRate(let identifier):
            "The audio output device has an invalid DoP rate: \(identifier)"
        }
    }
}

enum MediaSessionContractValidator {
    static let supportedContractVersion: UInt32 = 1

    static func validate(_ session: ContentSession) throws {
        if let playback = session.mediaPlayback {
            guard playback.position.isFinite, playback.position >= 0,
                  playback.duration.map({ $0.isFinite && $0 >= 0 && playback.position <= $0 }) ?? true else {
                throw MediaSessionContractError.invalidPlaybackPosition
            }
            if playback.isSeekable {
                try requireActiveCapability(ExtensionCapabilityIdentifier.seekable, in: session)
            }
        }

        if let queue = session.playbackQueue {
            try requireActiveCapability(ExtensionCapabilityIdentifier.mediaPlaybackQueue, in: session)
            guard queue.contractVersion > 0, queue.contractVersion <= supportedContractVersion else {
                throw MediaSessionContractError.unsupportedContractVersion(queue.contractVersion)
            }
            var identifiers = Set<String>()
            for item in queue.items {
                guard !item.id.isEmpty, !item.title.isEmpty else {
                    throw MediaSessionContractError.duplicateQueueItem(item.id)
                }
                guard identifiers.insert(item.id).inserted else {
                    throw MediaSessionContractError.duplicateQueueItem(item.id)
                }
                guard item.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw MediaSessionContractError.invalidPlaybackPosition
                }
            }
            if let currentItemID = queue.currentItemID, !identifiers.contains(currentItemID) {
                throw MediaSessionContractError.invalidCurrentItem(currentItemID)
            }
        }

        if let selection = session.audioDeviceSelection {
            try requireActiveCapability(ExtensionCapabilityIdentifier.deviceSelector, in: session)
            guard selection.contractVersion > 0,
                  selection.contractVersion <= supportedContractVersion else {
                throw MediaSessionContractError.unsupportedContractVersion(selection.contractVersion)
            }
            var identifiers = Set<String>()
            for device in selection.devices {
                guard !device.id.isEmpty, !device.displayName.isEmpty,
                      identifiers.insert(device.id).inserted else {
                    throw MediaSessionContractError.duplicateDevice(device.id)
                }
                guard device.supportedDoPRates.allSatisfy({ $0 > 0 }),
                      Set(device.supportedDoPRates).count == device.supportedDoPRates.count else {
                    throw MediaSessionContractError.invalidDoPRate(device.id)
                }
            }
            if let selectedDeviceID = selection.selectedDeviceID,
               !selection.devices.contains(where: { $0.id == selectedDeviceID }) {
                throw MediaSessionContractError.invalidSelectedDevice(selectedDeviceID)
            }
        }
    }

    private static func requireActiveCapability(_ identifier: String, in session: ContentSession) throws {
        guard session.extensionID == nil || session.capabilities.contains(where: {
            $0.declaration.id == identifier
                && $0.declaration.contractVersion <= supportedContractVersion
                && $0.state == .active
        }) else {
            throw MediaSessionContractError.missingCapability(identifier)
        }
    }
}

enum CommandContributionError: LocalizedError, Equatable {
    case missingCapability
    case malformedCommand(String)
    case duplicateCommand(String)
    case missingParent(commandID: String, parentID: String)
    case hierarchyCycle(String)

    var errorDescription: String? {
        switch self {
        case .missingCapability:
            "Commands require an active command-provider capability."
        case .malformedCommand(let identifier):
            "Invalid extension command: \(identifier)"
        case .duplicateCommand(let identifier):
            "Duplicate extension command: \(identifier)"
        case .missingParent(let commandID, let parentID):
            "Extension command \(commandID) has a missing parent: \(parentID)"
        case .hierarchyCycle(let identifier):
            "Extension command hierarchy contains a cycle at: \(identifier)"
        }
    }
}

enum CommandContributionValidator {
    static func validate(_ session: ContentSession) throws {
        guard session.extensionID == nil || session.commands.isEmpty || session.capabilities.contains(where: {
            $0.declaration.id == ExtensionCapabilityIdentifier.commandProvider && $0.state == .active
        }) else {
            throw CommandContributionError.missingCapability
        }

        var commandsByID: [String: CommandDescriptor] = [:]
        for command in session.commands {
            guard !command.id.isEmpty,
                  !command.titleLocalizationKey.isEmpty || command.displayTitle?.isEmpty == false,
                  command.parentID != command.id else {
                throw CommandContributionError.malformedCommand(command.id)
            }
            guard commandsByID.updateValue(command, forKey: command.id) == nil else {
                throw CommandContributionError.duplicateCommand(command.id)
            }
        }
        for command in session.commands {
            if let parentID = command.parentID, commandsByID[parentID] == nil {
                throw CommandContributionError.missingParent(commandID: command.id, parentID: parentID)
            }
            var ancestors = Set<String>()
            var current: CommandDescriptor? = command
            while let candidate = current, let parentID = candidate.parentID {
                guard ancestors.insert(candidate.id).inserted else {
                    throw CommandContributionError.hierarchyCycle(candidate.id)
                }
                current = commandsByID[parentID]
            }
        }
    }
}
