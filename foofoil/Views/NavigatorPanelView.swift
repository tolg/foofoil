//  NavigatorPanelView.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NavigatorPanelView: View {
    @ObservedObject var appState: AppState
    var isFullScreenOverlay = false
    @State private var dragStartWidth: Double?
    @State private var dragStartMouseX: CGFloat?
    @State private var draggedNavigatorContributionID: String?
    @State private var draggedNavigatorItemID: String?
    /// 当前鼠标悬停所在行的 ID，用于触发行内标题滚动。
    @State private var hoveringNavigatorRowID: String?

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
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .behindWindow,
                cornerRadius: isFullScreenOverlay ? 0 : 12
            )
            Color(NSColor.windowBackgroundColor).opacity(0.62)
            MovableBackground()

            VStack(spacing: 0) {
                if contributions.count > 1 {
                    contributionPicker
                }
                if let contribution = activeContribution {
                    navigatorContent(contribution)
                } else {
                    ContentUnavailableView(
                        NSLocalizedString("Navigator Empty", comment: ""),
                        systemImage: "sidebar.left"
                    )
                    .allowsHitTesting(false)
                }
            }

            resizeHandle
        }
        .clipShape(RoundedRectangle(cornerRadius: isFullScreenOverlay ? 0 : 12, style: .continuous))
        .shadow(
            color: .black.opacity(isFullScreenOverlay ? 0.34 : 0.24),
            radius: isFullScreenOverlay ? 18 : 12,
            x: isFullScreenOverlay ? (appState.navigatorPanelSide == .left ? 7 : -7) : 0,
            y: isFullScreenOverlay ? 0 : 4
        )
        .onHover { appState.isNavigatorPanelHovered = $0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            appState.handleNavigatorDrop(providers: providers)
            return true
        }
        .onAppear { selectFirstContributionIfNeeded() }
        .onChange(of: contributions.map(\.id)) { _, _ in
            selectFirstContributionIfNeeded()
        }
    }

    private var contributionPicker: some View {
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
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(NonMovableBackground())
    }

    @ViewBuilder
    private func navigatorContent(_ contribution: NavigatorContribution) -> some View {
        if contribution.items.isEmpty {
            ContentUnavailableView(
                NSLocalizedString("Navigator Empty", comment: ""),
                systemImage: "list.bullet"
            )
            .allowsHitTesting(false)
        } else {
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleRows(for: contribution)) { row in
                            navigatorRow(row, contribution: contribution)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .background(MovableBackground())
                    .onDrop(
                        of: [.utf8PlainText],
                        delegate: navigatorEndDropDelegate(for: contribution)
                    )
                }
            }
        }
    }

    private func navigatorRow(_ row: VisibleRow, contribution: NavigatorContribution) -> some View {
        let isSelected = contribution.selectedItemIDs.contains(row.item.id)
        let thumbnailPath = imageThumbnailPath(for: row.item.id, contribution: contribution)
        let rowContent = HStack(spacing: 7) {
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
                    if let thumbnailPath {
                        NavigatorImageThumbnail(
                            path: thumbnailPath,
                            fallbackSymbolName: row.item.symbolName ?? "photo",
                            isCurrent: row.item.isCurrent
                        )
                    } else if let symbolName = row.item.symbolName {
                        Image(systemName: symbolName)
                            .frame(width: 16)
                            .foregroundStyle(row.item.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        NavigatorScrollingTitle(
                            title: row.item.title,
                            isRowHovering: hoveringNavigatorRowID == row.item.id
                        )
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
        .background(NonMovableBackground())
        return reorderableRow(
            rowContent,
            row: row,
            contribution: contribution,
            hasThumbnail: thumbnailPath != nil
        )
        // 整行命中悬停：离开旧行时仅在仍是记录行的情况下清空，避免事件顺序抖动。
        .onHover { hovering in
            if hovering {
                hoveringNavigatorRowID = row.item.id
            } else if hoveringNavigatorRowID == row.item.id {
                hoveringNavigatorRowID = nil
            }
        }
    }

    /// 只有扩展明确开放 move 的平面列表才能拖动；层级列表（包括 CUE）保持来源顺序。
    @ViewBuilder
    private func reorderableRow<Content: View>(
        _ content: Content,
        row: VisibleRow,
        contribution: NavigatorContribution,
        hasThumbnail: Bool
    ) -> some View {
        if contribution.style == .flat, contribution.allowedActions.contains(.move) {
            content
                .onDrag {
                    draggedNavigatorContributionID = contribution.id
                    draggedNavigatorItemID = row.item.id
                    return NSItemProvider(object: row.item.id as NSString)
                }
                .onDrop(
                    of: [.utf8PlainText],
                    delegate: NavigatorMoveDropDelegate(
                        canDrop: {
                            draggedNavigatorContributionID == contribution.id
                                && draggedNavigatorItemID != nil
                                && draggedNavigatorItemID != row.item.id
                        },
                        perform: { location in
                            guard let movingID = draggedNavigatorItemID else { return false }
                            appState.performNavigatorAction(
                                NavigatorAction(
                                    contributionID: contribution.id,
                                    kind: .move,
                                    itemIDs: [movingID],
                                    destinationItemID: row.item.id,
                                    movePosition: location.y < (hasThumbnail ? 24 : 18) ? .before : .after
                                )
                            )
                            clearNavigatorDrag()
                            return true
                        }
                    )
                )
        } else {
            content
        }
    }

    /// 列表项以下的剩余区域作为末尾投放区。
    private func navigatorEndDropDelegate(for contribution: NavigatorContribution) -> NavigatorMoveDropDelegate {
        NavigatorMoveDropDelegate(
            canDrop: {
                contribution.style == .flat
                    && contribution.allowedActions.contains(.move)
                    && draggedNavigatorContributionID == contribution.id
                    && draggedNavigatorItemID != nil
            },
            perform: { _ in
                guard let movingID = draggedNavigatorItemID else { return false }
                appState.performNavigatorAction(
                    NavigatorAction(
                        contributionID: contribution.id,
                        kind: .move,
                        itemIDs: [movingID],
                        movePosition: .end
                    )
                )
                clearNavigatorDrag()
                return true
            }
        )
    }

    private func clearNavigatorDrag() {
        draggedNavigatorContributionID = nil
        draggedNavigatorItemID = nil
    }

    private func imageThumbnailPath(for itemID: String, contribution: NavigatorContribution) -> String? {
        guard contribution.id == AppState.fileListNavigatorID,
              let list = appState.fileList,
              list.kind == .image else { return nil }
        return list.items.first(where: { $0.id == itemID })?.path
    }

    /// 桌面伴随窗口拖外侧（左挂左缘、右挂右缘）；全屏覆盖层只能拖贴着箔片的内侧。
    private var isDraggingLeftEdge: Bool {
        if isFullScreenOverlay {
            return appState.navigatorPanelSide == .right
        }
        return appState.navigatorPanelSide == .left
    }

    private var resizeHandle: some View {
        HStack(spacing: 0) {
            if !isDraggingLeftEdge { Spacer() }
            Color.clear
                .frame(width: NavigatorPanelMetrics.widthResizeHandleThickness)
                .background(NonMovableBackground())
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            let mouseX = NSEvent.mouseLocation.x
                            if dragStartWidth == nil {
                                dragStartWidth = appState.navigatorPanelWidth
                                dragStartMouseX = mouseX
                                appState.isAdjustingNavigatorPanelWidth = true
                            }
                            let start = dragStartWidth ?? appState.navigatorPanelWidth
                            let translation = Double(mouseX - (dragStartMouseX ?? mouseX))
                            appState.navigatorPanelWidth = NavigatorPanelMetrics.width(
                                afterDrag: start,
                                translation: translation,
                                draggingLeftEdge: isDraggingLeftEdge
                            )
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            dragStartMouseX = nil
                            appState.isAdjustingNavigatorPanelWidth = false
                            SettingsStore.shared.navigatorPanelWidth = appState.navigatorPanelWidth
                            appState.saveState()
                        }
                )
            if isDraggingLeftEdge { Spacer() }
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

/// 标题超出可用宽度时，鼠标悬停所在行即触发标题单向循环滚动（跑马灯），避免常态下分散注意力。
private struct NavigatorScrollingTitle: View {
    let title: String
    let isRowHovering: Bool

    /// 循环衔接处两份文本之间的间隔。
    private static let loopGap: CGFloat = 24
    /// 滚动速度（点/秒），保证长短标题观感一致。
    private static let scrollPointsPerSecond: CGFloat = 28

    @State private var availableWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, titleWidth - availableWidth) }
    private var isScrolling: Bool { isRowHovering && overflow > 0 }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: Self.loopGap) {
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(key: NavigatorTitleWidthKey.self, value: textProxy.size.width)
                        }
                    }
                // 第二份文本用于无缝循环：偏移走到 -(titleWidth + gap) 时它与首份起点重合。
                // 在静止（未滚动）时就提前创建，避免滚动期间插入触发带动画的透明度过渡。
                if overflow > 0 {
                    Text(title)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.identity)
                }
            }
            .offset(x: isScrolling ? -(titleWidth + Self.loopGap) : 0)
            .animation(
                isScrolling
                    ? .linear(
                        duration: max(1.4, Double(titleWidth + Self.loopGap) / Double(Self.scrollPointsPerSecond))
                    )
                    .repeatForever(autoreverses: false)
                    : .default,
                value: isScrolling
            )
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .frame(height: 17)
        .clipped()
        .onPreferenceChange(NavigatorTitleWidthKey.self) { titleWidth = $0 }
        .accessibilityLabel(title)
    }
}

private struct NavigatorTitleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 显式返回 move 提案，避免 macOS 将应用内重排显示成带加号的复制操作。
private struct NavigatorMoveDropDelegate: DropDelegate {
    let canDrop: () -> Bool
    let perform: (CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        canDrop()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        canDrop() ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard canDrop() else { return false }
        return perform(info.location)
    }
}

private struct NavigatorImageThumbnail: View {
    let path: String
    let fallbackSymbolName: String
    let isCurrent: Bool
    @StateObject private var thumbnail = HistorySearchThumbnailLoader()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image = thumbnail.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbolName)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: path) { await thumbnail.load(path: path) }
    }
}
