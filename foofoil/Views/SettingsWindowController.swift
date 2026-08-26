//  SettingsWindowController.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import AppKit
import SwiftUI

enum SettingsWindowMetrics {
    static let width: CGFloat = 520
    static let maxHeight: CGFloat = 640
}

struct EmptySettingsPane: View {
    var body: some View {
        Form {}
            .formStyle(.grouped)
            .frame(width: SettingsWindowMetrics.width, alignment: .top)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabController = SettingsTabViewController()
    private var hasCentered = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowMetrics.width,
                height: 120
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.titleVisibility = .visible
        window.contentMinSize = NSSize(width: SettingsWindowMetrics.width, height: 1)
        window.contentMaxSize = NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.maxHeight)
        super.init(window: window)

        tabController.tabStyle = .toolbar
        tabController.canPropagateSelectedChildViewControllerTitle = true
        tabController.onSelectionChange = { [weak self] in
            self?.applySelectedTabAppearance(animated: true)
        }
        tabController.addTabViewItem(
            makeTab(
                identifier: "general",
                title: NSLocalizedString("General", comment: ""),
                symbolName: "gearshape",
                rootView: EmptySettingsPane()
            )
        )
        tabController.addTabViewItem(
            makeTab(
                identifier: "keyboardShortcuts",
                title: NSLocalizedString("Keyboard Shortcuts", comment: ""),
                symbolName: "keyboard",
                rootView: EmptySettingsPane()
            )
        )
        tabController.addTabViewItem(
            makeTab(
                identifier: "extensions",
                title: NSLocalizedString("Extensions", comment: ""),
                symbolName: "puzzlepiece.extension",
                rootView: ExtensionSettingsView(manager: ExtensionHost.shared.manager)
            )
        )
        window.contentViewController = tabController
        applySelectedTabAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !hasCentered {
            window.center()
            hasCentered = true
        }
        applySelectedTabAppearance(animated: false)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeTab<Content: View>(
        identifier: String,
        title: String,
        symbolName: String,
        rootView: Content
    ) -> NSTabViewItem {
        let pane = SettingsPaneViewController(rootView: rootView, title: title)
        pane.onIdealHeightChange = { [weak self] in
            self?.resizeToFitSelectedPane(animated: false)
        }
        let item = NSTabViewItem(identifier: identifier as NSString)
        item.label = title
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        item.viewController = pane
        item.toolTip = title
        return item
    }

    func applySelectedTabAppearance(animated: Bool) {
        updateWindowTitle()
        resizeToFitSelectedPane(animated: animated)
    }

    func updateWindowTitle() {
        guard let window else { return }
        window.titleVisibility = .visible
        let index = tabController.selectedTabViewItemIndex
        guard tabController.tabViewItems.indices.contains(index) else { return }
        window.title = tabController.tabViewItems[index].label
    }

    /// 窗口高度跟随当前 Tab 的内容高度；仅当内容超过最大高度时才截断并由面板内部滚动。
    func resizeToFitSelectedPane(animated: Bool) {
        guard let window else { return }
        let index = tabController.selectedTabViewItemIndex
        guard tabController.tabViewItems.indices.contains(index),
              let pane = tabController.tabViewItems[index].viewController as? any SettingsPaneHosting else {
            return
        }
        let contentHeight = pane.idealContentHeight(forWidth: SettingsWindowMetrics.width)
        let height = min(max(contentHeight.rounded(), 1), SettingsWindowMetrics.maxHeight)
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let newContentRect = NSRect(
            x: contentRect.minX,
            y: contentRect.maxY - height,
            width: SettingsWindowMetrics.width,
            height: height
        )
        let newFrame = window.frameRect(forContentRect: newContentRect)
        guard abs(window.frame.height - newFrame.height) > 1
                || abs(window.frame.width - newFrame.width) > 1 else { return }
        window.setFrame(newFrame, display: true, animate: animated && window.isVisible)
    }
}

final class SettingsTabViewController: NSTabViewController {
    var onSelectionChange: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.titleVisibility = .visible
        if let title = tabViewItem?.label {
            view.window?.title = title
        }
        onSelectionChange?()
    }
}

protocol SettingsPaneHosting: AnyObject {
    func idealContentHeight(forWidth width: CGFloat) -> CGFloat
}

/// 用 NSScrollView 承载 SwiftUI 面板：按内容固有高度排版，超出最大高度后再滚动。
final class SettingsPaneViewController<Content: View>: NSViewController, SettingsPaneHosting {
    var onIdealHeightChange: (() -> Void)?

    private let hostingController: NSHostingController<AnyView>
    private let scrollView = NSScrollView()
    private var lastReportedHeight: CGFloat = 0

    init(rootView: Content, title: String) {
        hostingController = NSHostingController(
            rootView: AnyView(
                rootView
                    .frame(width: SettingsWindowMetrics.width, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
            )
        )
        super.init(nibName: nil, bundle: nil)
        self.title = title
        hostingController.sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = true
        hostingController.view.autoresizingMask = [.width]
        scrollView.documentView = hostingController.view
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let height = fittedContentHeight()
        hostingController.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsWindowMetrics.width,
            height: height
        )
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onIdealHeightChange?()
    }

    func idealContentHeight(forWidth width: CGFloat) -> CGFloat {
        fittedContentHeight(forWidth: width)
    }

    private func fittedContentHeight(forWidth width: CGFloat = SettingsWindowMetrics.width) -> CGFloat {
        let fitting = hostingController.sizeThatFits(
            in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        if fitting > 1 { return fitting }
        if let documentHeight = scrollView.documentView?.fittingSize.height, documentHeight > 1 {
            return documentHeight
        }
        return hostingController.view.fittingSize.height
    }
}
