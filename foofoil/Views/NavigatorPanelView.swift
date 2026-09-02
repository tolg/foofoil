//  NavigatorPanelView.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FoofoilExtensionKit

struct NavigatorPanelView: View {
    @ObservedObject var appState: AppState
    var isFullScreenOverlay = false
    @State private var dragStartWidth: Double?
    @State private var dragStartMouseX: CGFloat?
    @State private var draggedNavigatorContributionID: String?
    @State private var draggedNavigatorItemID: String?
    /// 当前鼠标悬停所在行的 ID，用于触发行内标题滚动。
    @State private var hoveringNavigatorRowID: String?
    /// 鼠标是否悬停在固定标题上，触发标题跑马灯。
    @State private var isHoveringNavigatorHeader = false

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
                if let contribution = activeContribution {
                    // 标题区位于滚动区域之外，列表滚动时保持固定；
                    // 多个贡献时由选择器兼任标题与切换，避免重复展示同一名称。
                    if contributions.count > 1 {
                        contributionPicker
                    } else {
                        contributionTitleHeader(contribution)
                    }
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
        // 空白处默认右键菜单；行与标题各自提供更具体的菜单覆盖此处。
        .contextMenu {
            if !contributions.isEmpty {
                alwaysShowNavigatorMenuItem
            }
            moveToOppositeSideMenuItem
        }
        .onAppear { selectFirstContributionIfNeeded() }
        .onChange(of: contributions.map(\.id)) { _, _ in
            selectFirstContributionIfNeeded()
        }
    }

    private func localizedTitle(for contribution: NavigatorContribution) -> String {
        NSLocalizedString(contribution.titleLocalizationKey, comment: "")
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
                Text(localizedTitle(for: contribution))
                    .tag(contribution.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(NonMovableBackground())
    }

    /// 单一贡献时的固定小标题：显示列表自定义/专辑标题（不附数量），过长时悬停滚动，
    /// CUE 列表在尾部追加格式标记；高度与选择器一致，贡献数量变化时顶部区域不跳动。
    private func contributionTitleHeader(_ contribution: NavigatorContribution) -> some View {
        HStack(spacing: 6) {
            NavigatorScrollingTitle(
                title: headerTitle(for: contribution),
                font: .caption.weight(.semibold),
                isRowHovering: isHoveringNavigatorHeader
            )
            if showsCUEBadge(for: contribution) {
                Text(NSLocalizedString("Navigator CUE Badge", comment: ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        // 可移动背景盖在最上层：按住标题任意处（含文字与徽标）都走“拖父窗口、面板跟随”的
        // 贴附拖动路径；若只作背景，命中文字时会走仅拖面板的原生路径。
        .overlay(MovableBackground())
        // 整条标题区命中悬停，与列表行的整行命中保持一致。
        .onHover { isHoveringNavigatorHeader = $0 }
        .contextMenu {
            alwaysShowNavigatorMenuItem
            moveToOppositeSideMenuItem
            if contribution.id == AppState.fileListNavigatorID {
                Button {
                    beginListTitleRename()
                } label: {
                    Label(NSLocalizedString("Change Title", comment: ""), systemImage: "pencil")
                }
            }
        }
    }

    /// “始终显示”开关项：勾选状态即当前显示模式，切换写法与菜单栏同名命令一致。
    private var alwaysShowNavigatorMenuItem: some View {
        Toggle(
            isOn: Binding(
                get: { appState.navigatorPanelVisibilityMode == .always },
                set: { enabled in
                    let next: NavigatorPanelVisibilityMode = enabled ? .always : .onHover
                    appState.navigatorPanelVisibilityMode = next
                    SettingsStore.shared.navigatorPanelVisibilityMode = next
                    if next != .always {
                        appState.isNavigatorPanelExplicitlyVisible = false
                    }
                }
            )
        ) {
            Label(
                NSLocalizedString("Always Show", comment: ""),
                systemImage: "sidebar.squares.leading"
            )
        }
    }

    /// 面板空白处与标题共用的右键菜单项：把面板挂到另一侧。
    private var moveToOppositeSideMenuItem: some View {
        Button {
            moveNavigatorPanelToOppositeSide()
        } label: {
            Label(
                NSLocalizedString(
                    appState.navigatorPanelSide == .left
                        ? "Move Navigator to Right Side"
                        : "Move Navigator to Left Side",
                    comment: ""
                ),
                systemImage: appState.navigatorPanelSide == .left ? "sidebar.right" : "sidebar.left"
            )
        }
    }

    /// 与菜单栏“挂在左侧/右侧”动作一致：AppState 驱动重排，偏好同步持久化。
    private func moveNavigatorPanelToOppositeSide() {
        let next: NavigatorPanelSide = appState.navigatorPanelSide == .left ? .right : .left
        appState.navigatorPanelSide = next
        SettingsStore.shared.navigatorPanelSide = next
    }

    /// 用原生 NSAlert 改标题：面板是 canBecomeMain = false 的边框面板，SwiftUI 警告框
    /// 在其中文本框无法聚焦且绑定只在首次展示生效；原生 accessory 输入框没有这两个问题。
    /// 确认后走箔片上历史记录改名的同一流程，预填原始列表标题（不带数量）。
    private func beginListTitleRename() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Change Title", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = FileListState.normalizedTitle(appState.fileList?.title) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryManager.shared.updateHistoryTitle(configId: appState.id, newTitle: field.stringValue)
    }

    /// 内置文件列表显示自定义/专辑标题（不附数量）；无自定义标题时回退到类型名称。
    private func headerTitle(for contribution: NavigatorContribution) -> String {
        if contribution.id == AppState.fileListNavigatorID,
           let list = appState.fileList, list.isPresentable,
           let title = FileListState.normalizedTitle(list.title) {
            return title
        }
        return localizedTitle(for: contribution)
    }

    /// CUE 标记放在尾部独立徽标中，标题过长被截断时仍然可见。
    private func showsCUEBadge(for contribution: NavigatorContribution) -> Bool {
        contribution.id == AppState.fileListNavigatorID && appState.fileList?.isCueBased == true
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
                        if showsPlaybackIndicator(for: contribution), row.item.isCurrent {
                            // 内置音视频列表的当前项用频率柱状图指示：播放时底部对齐的
                            // 柱高持续起伏；暂停时时间轴停走、冻结在最后变化时刻。
                            NavigatorPlaybackBars(isPlaying: appState.isMediaPlaying)
                                .frame(width: 16)
                        } else {
                            Image(systemName: symbolName)
                                .frame(width: 16)
                                .foregroundStyle(row.item.isCurrent ? Color.accentColor : Color.secondary)
                        }
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

    /// 仅内置音视频列表的当前项使用“正在播放”波形图标；图片列表与扩展贡献保持原样。
    private func showsPlaybackIndicator(for contribution: NavigatorContribution) -> Bool {
        guard contribution.id == AppState.fileListNavigatorID,
              let kind = appState.fileList?.kind else { return false }
        return kind == .video || kind == .audio
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

/// 标题超出可用宽度时，鼠标悬停所在行（或固定标题区）即触发标题单向循环滚动（跑马灯），
/// 避免常态下分散注意力。
private struct NavigatorScrollingTitle: View {
    let title: String
    var font: Font = .body
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
                    .font(font)
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
                        .font(font)
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

/// “正在播放”频率柱状图：底部对齐的数根竖线按固定步进随机起伏。
/// 时间轴在暂停时停走，柱形冻结在最后变化时刻；高度由（步数, 柱序号）
/// 确定性生成，父视图重渲染也不会让冻结画面跳动。
private struct NavigatorPlaybackBars: View {
    let isPlaying: Bool

    private static let barCount = 4
    private static let stepInterval: Double = 0.24
    private static let maxHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.stepInterval, paused: !isPlaying)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / Self.stepInterval)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: Self.maxHeight * Self.level(step: step, bar: index))
                }
            }
            .animation(.linear(duration: Self.stepInterval), value: step)
        }
        .frame(width: 13, height: Self.maxHeight, alignment: .bottom)
    }

    /// 简单整数散列映射到 0.25...1 的高度比例，保证同一步内结果稳定。
    private static func level(step: Int, bar: Int) -> CGFloat {
        var hash = UInt(bitPattern: step) &* 2_654_435_761 &+ UInt(bar) &* 4_073_552_689
        hash ^= hash >> 13
        hash = hash &* 1_274_126_177
        hash ^= hash >> 16
        return 0.25 + 0.75 * CGFloat(hash % 1_000) / 1_000
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
