//
//  PDFModeView.swift
//  foofoil
//

import SwiftUI
import PDFKit

/// 采用系统 PDFKit 渲染 PDF，以保留多页文档的翻页能力。
struct PDFModeView: NSViewRepresentable {
    @ObservedObject var appState: AppState
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = FoofoilPDFView()
        pdfView.autoScales = false
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = false
        pdfView.document = PDFDocument(url: url)
        pdfView.scaleFactor = CGFloat(appState.imageScale)
        context.coordinator.defaultBackgroundColor = pdfView.backgroundColor
        applyBackgroundColor(to: pdfView, defaultColor: context.coordinator.defaultBackgroundColor)
        pdfView.contextMenuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeContextMenu()
        }
        context.coordinator.pdfView = pdfView
        context.coordinator.loadedURL = url
        context.coordinator.postCurrentPageSize()
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            pdfView.document = PDFDocument(url: url)
            context.coordinator.postCurrentPageSize()
        }
        if appState.isFullScreen {
            // 全屏只改变展示倍率，不写回窗口态缩放偏好。
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            let targetScale = CGFloat(appState.imageScale)
            if abs(pdfView.scaleFactor - targetScale) > 0.0001 {
                pdfView.scaleFactor = targetScale
            }
        }
        applyBackgroundColor(to: pdfView, defaultColor: context.coordinator.defaultBackgroundColor)
    }

    private func applyBackgroundColor(to pdfView: PDFView, defaultColor: NSColor?) {
        if let hex = appState.backgroundColorHex,
           let color = NSColor(hex: hex) {
            pdfView.backgroundColor = color
        } else if let defaultColor {
            // 重置时恢复 PDFKit 创建视图时的默认背景色。
            pdfView.backgroundColor = defaultColor
        }
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var loadedURL: URL?
        var defaultBackgroundColor: NSColor?
        private let appState: AppState
        private var observers: [NSObjectProtocol] = []

        init(appState: AppState) {
            self.appState = appState
            super.init()
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .shouldGoToPreviousPDFPage, object: nil, queue: .main) { [weak self] in self?.navigate($0, previous: true) },
                center.addObserver(forName: .shouldGoToNextPDFPage, object: nil, queue: .main) { [weak self] in self?.navigate($0, previous: false) },
                center.addObserver(forName: .shouldPromptForPDFPage, object: nil, queue: .main) { [weak self] in self?.promptForPage($0) },
                center.addObserver(forName: .PDFViewPageChanged, object: nil, queue: .main) { [weak self] in self?.handlePageChange($0) },
                center.addObserver(forName: .shouldFitPDFToWindow, object: nil, queue: .main) { [weak self] in self?.beginFitToWindow($0) },
                center.addObserver(forName: .shouldApplyPDFScaleToWindow, object: nil, queue: .main) { [weak self] in self?.applyFitToWindow($0) }
            ]
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func isForCurrentDocument(_ notification: Notification) -> Bool {
            notification.userInfo?["id"] as? UUID == appState.id
        }

        private func navigate(_ notification: Notification, previous: Bool) {
            guard isForCurrentDocument(notification) else { return }
            if previous {
                pdfView?.goToPreviousPage(nil)
            } else {
                pdfView?.goToNextPage(nil)
            }
        }

        private func beginFitToWindow(_ notification: Notification) {
            guard isForCurrentDocument(notification),
                  let pdfView,
                  let currentPage = pdfView.currentPage,
                  !appState.showBorder else { return }
            NotificationCenter.default.post(
                name: .shouldMatchPDFWindowAspectRatio,
                object: nil,
                userInfo: ["id": appState.id, "size": currentPage.bounds(for: .mediaBox).size]
            )
        }

        private func applyFitToWindow(_ notification: Notification) {
            guard isForCurrentDocument(notification),
                  let pdfView,
                  !appState.showBorder else { return }
            pdfView.autoScales = false
            let fittedScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fittedScale
            appState.imageScale = Double(fittedScale)
        }

        private func handlePageChange(_ notification: Notification) {
            guard notification.object as? PDFView === pdfView else { return }
            postCurrentPageSize()
            postPageIndicator()
        }

        func postCurrentPageSize() {
            guard let page = pdfView?.currentPage else { return }
            let pageSize = page.bounds(for: .mediaBox).size
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(
                    name: .pdfPageSizeDidChange,
                    object: nil,
                    userInfo: ["id": self.appState.id, "size": pageSize]
                )
            }
        }

        private func postPageIndicator() {
            guard let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            let pageIndex = document.index(for: currentPage)
            guard pageIndex != NSNotFound else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(
                    name: .pdfPageDidChange,
                    object: nil,
                    userInfo: [
                        "id": self.appState.id,
                        "currentPage": pageIndex + 1,
                        "pageCount": document.pageCount
                    ]
                )
            }
        }

        func makeContextMenu() -> NSMenu? {
            let menu = NSMenu()

            let pinItem = NSMenuItem(
                title: NSLocalizedString("Toggle Pin (ContextMenu)", comment: ""),
                action: #selector(togglePinAction(_:)),
                keyEquivalent: "t"
            )
            pinItem.withSymbol("pin")
            pinItem.keyEquivalentModifierMask = [.command]
            pinItem.target = self
            pinItem.state = appState.isPinned ? .on : .off
            menu.addItem(pinItem)

            if !appState.isFullScreen {
                let borderItem = NSMenuItem(
                    title: NSLocalizedString("Border (ContextMenu)", comment: ""),
                    action: #selector(toggleBorderAction(_:)),
                    keyEquivalent: "b"
                )
                borderItem.withSymbol("rectangle")
                borderItem.keyEquivalentModifierMask = [.command]
                borderItem.target = self
                borderItem.state = appState.showBorder ? .on : .off
                menu.addItem(borderItem)
            }

            menu.addItem(NSMenuItem.separator())

            let previousPageItem = NSMenuItem(
                title: NSLocalizedString("Previous Page", comment: ""),
                action: #selector(previousPageAction(_:)),
                keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            )
            previousPageItem.withSymbol("chevron.left")
            previousPageItem.keyEquivalentModifierMask = []
            previousPageItem.target = self
            menu.addItem(previousPageItem)

            let nextPageItem = NSMenuItem(
                title: NSLocalizedString("Next Page", comment: ""),
                action: #selector(nextPageAction(_:)),
                keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
            )
            nextPageItem.withSymbol("chevron.right")
            nextPageItem.keyEquivalentModifierMask = []
            nextPageItem.target = self
            menu.addItem(nextPageItem)

            let goToPageItem = NSMenuItem(
                title: NSLocalizedString("Go to Page Menu Item", comment: ""),
                action: #selector(goToPageAction(_:)),
                keyEquivalent: "g"
            )
            goToPageItem.withSymbol("number.square")
            goToPageItem.keyEquivalentModifierMask = [.command]
            goToPageItem.target = self
            menu.addItem(goToPageItem)

            menu.addItem(NSMenuItem.separator())

            let copyItem = NSMenuItem(
                title: NSLocalizedString("Copy Image", comment: ""),
                action: #selector(copyAction(_:)),
                keyEquivalent: "c"
            )
            copyItem.withSymbol("photo.on.rectangle")
            copyItem.keyEquivalentModifierMask = [.command]
            copyItem.target = self
            menu.addItem(copyItem)

            let resetItem = NSMenuItem(
                title: NSLocalizedString("Reset (ContextMenu)", comment: ""),
                action: #selector(resetAction(_:)),
                keyEquivalent: "k"
            )
            resetItem.withSymbol("arrow.counterclockwise")
            resetItem.keyEquivalentModifierMask = [.command]
            resetItem.target = self
            menu.addItem(resetItem)

            let closeItem = NSMenuItem(
                title: NSLocalizedString("Close (ContextMenu)", comment: ""),
                action: #selector(closeAction(_:)),
                keyEquivalent: "w"
            )
            closeItem.withSymbol("xmark.circle")
            closeItem.keyEquivalentModifierMask = [.command]
            closeItem.target = self
            menu.addItem(closeItem)

            return menu
        }

        @objc private func togglePinAction(_ sender: Any?) {
            appState.togglePin()
        }

        @objc private func toggleBorderAction(_ sender: Any?) {
            guard !appState.isFullScreen else { return }
            appState.showBorder.toggle()
        }

        @objc private func previousPageAction(_ sender: Any?) {
            pdfView?.goToPreviousPage(nil)
        }

        @objc private func nextPageAction(_ sender: Any?) {
            pdfView?.goToNextPage(nil)
        }

        @objc private func goToPageAction(_ sender: Any?) {
            promptForPage(Notification(name: .shouldPromptForPDFPage, userInfo: ["id": appState.id]))
        }

        @objc private func copyAction(_ sender: Any?) {
            pdfView?.copyCurrentPageToPasteboard()
        }

        @objc private func resetAction(_ sender: Any?) {
            appState.resetContent()
        }

        @objc private func closeAction(_ sender: Any?) {
            NotificationCenter.default.post(
                name: .shouldCloseWindow,
                object: nil,
                userInfo: ["id": appState.id]
            )
        }

        private func promptForPage(_ notification: Notification) {
            guard isForCurrentDocument(notification),
                  let pdfView,
                  let document = pdfView.document else { return }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Go to Page", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Enter a page number between 1 and %ld.", comment: ""), document.pageCount)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.placeholderString = "1"
            let currentPageIndex = pdfView.currentPage.map(document.index(for:)) ?? 0
            field.stringValue = "\(currentPageIndex + 1)"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: NSLocalizedString("Go", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

            guard alert.runModal() == .alertFirstButtonReturn,
                  let pageNumber = Int(field.stringValue),
                  (1...document.pageCount).contains(pageNumber),
                  let page = document.page(at: pageNumber - 1) else { return }
            pdfView.go(to: page)
        }
    }
}

private final class FoofoilPDFView: PDFView {
    var contextMenuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func copy(_ sender: Any?) {
        if let selection = currentSelection,
           let text = selection.string,
           !text.isEmpty {
            super.copy(sender)
        } else {
            copyCurrentPageToPasteboard()
        }
    }
}

extension PDFView {
    func copyCurrentPageToPasteboard() {
        guard let page = currentPage else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = scaleFactor
        let rotation = page.rotation
        let isRotated = (rotation == 90 || rotation == 270)
        let width = isRotated ? pageBounds.height : pageBounds.width
        let height = isRotated ? pageBounds.width : pageBounds.height
        
        let backingScale = window?.backingScaleFactor ?? 1.0
        let targetSize = NSSize(width: width * scale * backingScale, height: height * scale * backingScale)
        let image = page.thumbnail(of: targetSize, for: .mediaBox)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            if let window = self.window,
               let controller = window.windowController as? FloatingWindowController {
                NotificationCenter.default.post(
                    name: Notification.Name("flashWindow_\(controller.appState.id.uuidString)"),
                    object: nil
                )
            }
        }
    }
}
