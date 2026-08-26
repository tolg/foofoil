//  NavigatorContribution.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import Foundation

enum NavigatorPresentationStyle: String, Codable, Sendable {
    case flat
    case outline
}

enum NavigatorSelectionMode: String, Codable, Sendable {
    case single
    case multiple
}

enum NavigatorActionKind: String, Codable, Sendable {
    case activate
    case remove
    case move
}

enum NavigatorMovePosition: String, Codable, Sendable {
    case before
    case after
    case end
}

struct NavigatorItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var parentID: String?
    let title: String
    var subtitle: String?
    var symbolName: String?
    var badge: String?
    var isEnabled: Bool
    var isCurrent: Bool

    init(
        id: String,
        parentID: String? = nil,
        title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        badge: String? = nil,
        isEnabled: Bool = true,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.badge = badge
        self.isEnabled = isEnabled
        self.isCurrent = isCurrent
    }
}

struct NavigatorContribution: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let contractVersion: UInt32
    let titleLocalizationKey: String
    let style: NavigatorPresentationStyle
    let selectionMode: NavigatorSelectionMode
    var items: [NavigatorItem]
    var selectedItemIDs: [String]
    var allowedActions: [NavigatorActionKind]
    var revision: UInt64

    init(
        id: String,
        contractVersion: UInt32 = 1,
        titleLocalizationKey: String,
        style: NavigatorPresentationStyle,
        selectionMode: NavigatorSelectionMode = .single,
        items: [NavigatorItem],
        selectedItemIDs: [String] = [],
        allowedActions: [NavigatorActionKind] = [.activate],
        revision: UInt64 = 0
    ) {
        self.id = id
        self.contractVersion = contractVersion
        self.titleLocalizationKey = titleLocalizationKey
        self.style = style
        self.selectionMode = selectionMode
        self.items = items
        self.selectedItemIDs = selectedItemIDs
        self.allowedActions = allowedActions
        self.revision = revision
    }
}

/// 用户动作只携带稳定标识，保持 ABI/XPC 边界不依赖进程内对象。
struct NavigatorAction: Codable, Equatable, Sendable {
    let contributionID: String
    let kind: NavigatorActionKind
    let itemIDs: [String]
    var destinationItemID: String?
    var movePosition: NavigatorMovePosition?

    init(
        contributionID: String,
        kind: NavigatorActionKind,
        itemIDs: [String],
        destinationItemID: String? = nil,
        movePosition: NavigatorMovePosition? = nil
    ) {
        self.contributionID = contributionID
        self.kind = kind
        self.itemIDs = itemIDs
        self.destinationItemID = destinationItemID
        self.movePosition = movePosition
    }
}

enum NavigatorContributionError: LocalizedError, Equatable {
    case unsupportedContractVersion(UInt32)
    case malformedContribution(String)
    case duplicateContribution(String)
    case missingCapability(String)
    case malformedItem(String)
    case duplicateItem(String)
    case missingParent(itemID: String, parentID: String)
    case hierarchyCycle(String)
    case invalidSelection(String)
    case duplicateAction(String)
    case unsupportedAction(String)
    case invalidAction(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedContractVersion(let version):
            "Unsupported navigator contract version: \(version)"
        case .malformedContribution(let id):
            "Invalid navigator contribution: \(id)"
        case .duplicateContribution(let id):
            "Duplicate navigator contribution: \(id)"
        case .missingCapability(let id):
            "Navigator contribution is missing an active capability: \(id)"
        case .malformedItem(let id):
            "Invalid navigator item: \(id)"
        case .duplicateItem(let id):
            "Duplicate navigator item: \(id)"
        case .missingParent(let itemID, let parentID):
            "Navigator item \(itemID) has a missing parent: \(parentID)"
        case .hierarchyCycle(let id):
            "Navigator hierarchy contains a cycle at: \(id)"
        case .invalidSelection(let id):
            "Navigator selection is invalid: \(id)"
        case .duplicateAction(let id):
            "Navigator action is duplicated: \(id)"
        case .unsupportedAction(let id):
            "Navigator action is not supported: \(id)"
        case .invalidAction(let id):
            "Navigator action is invalid: \(id)"
        }
    }
}

enum NavigatorContributionValidator {
    static let supportedContractVersion: UInt32 = 1

    static func validate(_ contributions: [NavigatorContribution]) throws {
        var contributionIDs = Set<String>()
        for contribution in contributions {
            guard contributionIDs.insert(contribution.id).inserted else {
                throw NavigatorContributionError.duplicateContribution(contribution.id)
            }
            try validate(contribution)
        }
    }

    static func validate(_ session: ContentSession) throws {
        try validate(session.navigatorContributions)
        guard session.extensionID == nil || session.navigatorContributions.isEmpty || session.capabilities.contains(where: {
            $0.declaration.id == ExtensionCapabilityIdentifier.navigator
                && $0.declaration.contractVersion <= supportedContractVersion
                && $0.state == .active
        }) else {
            throw NavigatorContributionError.missingCapability(session.providerID)
        }
    }

    static func validate(_ contribution: NavigatorContribution) throws {
        guard contribution.contractVersion > 0,
              contribution.contractVersion <= supportedContractVersion else {
            throw NavigatorContributionError.unsupportedContractVersion(contribution.contractVersion)
        }
        guard !contribution.id.isEmpty, !contribution.titleLocalizationKey.isEmpty else {
            throw NavigatorContributionError.malformedContribution(contribution.id)
        }

        var itemsByID: [String: NavigatorItem] = [:]
        for item in contribution.items {
            guard !item.id.isEmpty, !item.title.isEmpty, item.parentID != item.id else {
                throw NavigatorContributionError.malformedItem(item.id)
            }
            guard itemsByID.updateValue(item, forKey: item.id) == nil else {
                throw NavigatorContributionError.duplicateItem(item.id)
            }
            if contribution.style == .flat, item.parentID != nil {
                throw NavigatorContributionError.malformedItem(item.id)
            }
        }

        for item in contribution.items {
            if let parentID = item.parentID, itemsByID[parentID] == nil {
                throw NavigatorContributionError.missingParent(itemID: item.id, parentID: parentID)
            }
            // 沿父链检测环，避免不可信扩展数据让宿主递归渲染失控。
            var ancestors = Set<String>()
            var current: NavigatorItem? = item
            while let candidate = current, let parentID = candidate.parentID {
                guard ancestors.insert(candidate.id).inserted else {
                    throw NavigatorContributionError.hierarchyCycle(candidate.id)
                }
                current = itemsByID[parentID]
            }
        }

        let selectedIDs = Set(contribution.selectedItemIDs)
        guard selectedIDs.count == contribution.selectedItemIDs.count,
              selectedIDs.allSatisfy({ itemsByID[$0] != nil }),
              contribution.selectionMode == .multiple || selectedIDs.count <= 1 else {
            throw NavigatorContributionError.invalidSelection(contribution.id)
        }

        let actions = Set(contribution.allowedActions.map(\.rawValue))
        guard actions.count == contribution.allowedActions.count else {
            throw NavigatorContributionError.duplicateAction(contribution.id)
        }
    }

    static func validate(_ action: NavigatorAction, in contribution: NavigatorContribution) throws {
        guard contribution.allowedActions.contains(action.kind) else {
            throw NavigatorContributionError.unsupportedAction(action.contributionID)
        }
        let itemIDs = Set(contribution.items.map(\.id))
        guard !action.itemIDs.isEmpty,
              Set(action.itemIDs).count == action.itemIDs.count,
              action.itemIDs.allSatisfy(itemIDs.contains) else {
            throw NavigatorContributionError.invalidAction(action.contributionID)
        }
        switch action.kind {
        case .activate:
            guard action.itemIDs.count == 1,
                  action.destinationItemID == nil,
                  action.movePosition == nil else {
                throw NavigatorContributionError.invalidAction(action.contributionID)
            }
        case .remove:
            guard action.destinationItemID == nil,
                  action.movePosition == nil else {
                throw NavigatorContributionError.invalidAction(action.contributionID)
            }
        case .move:
            guard let position = action.movePosition else {
                throw NavigatorContributionError.invalidAction(action.contributionID)
            }
            if position == .end {
                guard action.destinationItemID == nil else {
                    throw NavigatorContributionError.invalidAction(action.contributionID)
                }
            } else {
                guard let destinationItemID = action.destinationItemID,
                      itemIDs.contains(destinationItemID),
                      !action.itemIDs.contains(destinationItemID) else {
                    throw NavigatorContributionError.invalidAction(action.contributionID)
                }
            }
        }
    }
}
