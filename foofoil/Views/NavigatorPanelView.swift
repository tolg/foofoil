//  NavigatorPanelView.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import SwiftUI

struct NavigatorPanelView: View {
    @ObservedObject var appState: AppState
    @State private var dragStartWidth: Double?

    private struct VisibleRow: Identifiable {
        let item: NavigatorItem
        let depth: Int
        let hasChildren: Bool
        var id: String { item.id }
    }

    private var contributions: [NavigatorContribution] {
        appState.navigatorContributions
    }

    private var activeContribution: NavigatorContribution? {
        if let id = appState.activeNavigatorContributionID,
           let contribution = contributions.first(where: { $0.id == id }) {
            return contribution
        }
        return contributions.first
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color(NSColor.windowBackgroundColor).opacity(0.62)

            VStack(spacing: 0) {
                header
                Divider().opacity(0.7)
                if let contribution = activeContribution {
                    navigatorContent(contribution)
                } else {
                    ContentUnavailableView(
                        NSLocalizedString("Navigator Empty", comment: ""),
                        systemImage: "sidebar.left"
                    )
                }
            }

            resizeHandle
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
        .onHover { appState.isNavigatorPanelHovered = $0 }
        .onAppear { selectFirstContributionIfNeeded() }
        .onChange(of: contributions.map(\.id)) { _, _ in
            selectFirstContributionIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if contributions.count > 1 {
                Picker(
                    NSLocalizedString("Navigator", comment: ""),
                    selection: Binding(
                        get: { activeContribution?.id ?? contributions.first?.id ?? "" },
                        set: { appState.activeNavigatorContributionID = $0 }
                    )
                ) {
                    ForEach(contributions) { contribution in
                        Text(NSLocalizedString(contribution.titleLocalizationKey, comment: ""))
                            .tag(contribution.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } else if let contribution = activeContribution {
                Text(NSLocalizedString(contribution.titleLocalizationKey, comment: ""))
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                appState.navigatorPanelVisibilityMode = .onHover
                appState.isNavigatorPanelExplicitlyVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Hide Navigator", comment: ""))
            .accessibilityLabel(NSLocalizedString("Hide Navigator", comment: ""))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private func navigatorContent(_ contribution: NavigatorContribution) -> some View {
        if contribution.items.isEmpty {
            ContentUnavailableView(
                NSLocalizedString("Navigator Empty", comment: ""),
                systemImage: "list.bullet"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleRows(for: contribution)) { row in
                        navigatorRow(row, contribution: contribution)
                    }
                }
                .padding(6)
            }
        }
    }

    private func navigatorRow(_ row: VisibleRow, contribution: NavigatorContribution) -> some View {
        let isSelected = contribution.selectedItemIDs.contains(row.item.id)
        return HStack(spacing: 7) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)

            if row.hasChildren {
                Button {
                    if appState.expandedNavigatorItemIDs.contains(row.item.id) {
                        appState.expandedNavigatorItemIDs.remove(row.item.id)
                    } else {
                        appState.expandedNavigatorItemIDs.insert(row.item.id)
                    }
                } label: {
                    Image(systemName: appState.expandedNavigatorItemIDs.contains(row.item.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Toggle Navigator Group", comment: ""))
            } else if contribution.style == .outline {
                Color.clear.frame(width: 12, height: 1)
            }

            Button {
                appState.performNavigatorAction(
                    NavigatorAction(
                        contributionID: contribution.id,
                        kind: .activate,
                        itemIDs: [row.item.id]
                    )
                )
            } label: {
                HStack(spacing: 8) {
                    if let symbolName = row.item.symbolName {
                        Image(systemName: symbolName)
                            .frame(width: 16)
                            .foregroundStyle(row.item.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.item.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let subtitle = row.item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let badge = row.item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if row.item.isCurrent {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.item.isEnabled || !contribution.allowedActions.contains(.activate))
            .accessibilityLabel(row.item.title)
            .contextMenu {
                if contribution.allowedActions.contains(.remove) {
                    Button(role: .destructive) {
                        appState.performNavigatorAction(
                            NavigatorAction(
                                contributionID: contribution.id,
                                kind: .remove,
                                itemIDs: [row.item.id]
                            )
                        )
                    } label: {
                        Label(NSLocalizedString("Remove Navigator Item", comment: ""), systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.20) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var resizeHandle: some View {
        HStack(spacing: 0) {
            if appState.navigatorPanelSide == .right { Spacer() }
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = appState.navigatorPanelWidth
                                appState.isAdjustingNavigatorPanelWidth = true
                            }
                            let start = dragStartWidth ?? appState.navigatorPanelWidth
                            let delta = Double(value.translation.width)
                            appState.navigatorPanelWidth = NavigatorPanelMetrics.clampWidth(
                                appState.navigatorPanelSide == .left ? start - delta : start + delta
                            )
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            appState.isAdjustingNavigatorPanelWidth = false
                            SettingsStore.shared.navigatorPanelWidth = appState.navigatorPanelWidth
                            appState.saveState()
                        }
                )
            if appState.navigatorPanelSide == .left { Spacer() }
        }
    }

    private func visibleRows(for contribution: NavigatorContribution) -> [VisibleRow] {
        guard contribution.style == .outline else {
            return contribution.items.map { VisibleRow(item: $0, depth: 0, hasChildren: false) }
        }
        let children = Dictionary(grouping: contribution.items, by: \.parentID)
        var rows: [VisibleRow] = []

        func appendChildren(of parentID: String?, depth: Int) {
            for item in children[parentID] ?? [] {
                let hasChildren = children[item.id]?.isEmpty == false
                rows.append(VisibleRow(item: item, depth: depth, hasChildren: hasChildren))
                if hasChildren, appState.expandedNavigatorItemIDs.contains(item.id) {
                    appendChildren(of: item.id, depth: depth + 1)
                }
            }
        }

        appendChildren(of: nil, depth: 0)
        return rows
    }

    private func selectFirstContributionIfNeeded() {
        guard !contributions.isEmpty else {
            appState.activeNavigatorContributionID = nil
            return
        }
        if !contributions.contains(where: { $0.id == appState.activeNavigatorContributionID }) {
            appState.activeNavigatorContributionID = contributions[0].id
        }
    }
}
