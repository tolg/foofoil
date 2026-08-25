//  AppDelegate+Actions.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit


extension AppDelegate {
    // MARK: - Actions

    @objc func newWindowAction() {
        showNewWindow(with: AppState())
    }

    @objc func extensionCommandAction(_ sender: NSMenuItem) {
        guard let commandID = sender.representedObject as? String else { return }
        activeAppState?.performExtensionCommand(commandID)
    }

    func showNewWindow(with state: AppState) {
        let controller = FloatingWindowController(appState: state)

        // 如果存在激活的窗口，则稍作偏移，避免新窗口完全重合
        if let keyWindow = NSApplication.shared.keyWindow {
            let keyFrame = keyWindow.frame
            let size = controller.window?.frame.size ?? NSSize(width: 400, height: 400)
            let offsetFrame = NSRect(
                x: keyFrame.minX + 30,
                y: keyFrame.minY - 30,
                width: size.width,
                height: size.height
            )
            controller.window?.setFrame(offsetFrame, display: true)
        } else {
            controller.window?.center()
        }

        addWindowController(controller)
        controller.showWindow(nil)
    }

    func showSaveErrorAlert(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save Failed Title", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Save Failed Message Format", comment: ""), error.localizedDescription)
            alert.runModal()
        }
    }

    @objc func saveAsAction() {
        guard let appState = activeAppState else { return }

        if let webURL = appState.webURL, !webURL.isFileURL {
            // 在线网页：先出发截图和闪白信号
            NotificationCenter.default.post(
                name: Notification.Name("triggerSaveSnapshot_\(appState.id.uuidString)"),
                object: nil
            )
        } else {
            // 文本、图片或本地 HTML 模式：直接弹出另存为面板
            presentSavePanel(for: appState)
        }
    }

    /// 根据当前内容提供系统共享所需的原生对象，保留文件类型或文本内容。
    func sharingItems(for appState: AppState) -> [Any] {
        if let webURL = appState.webURL {
            return [webURL]
        }

        if let imageURL = appState.imageURL {
            return [imageURL]
        }

        if let textURL = appState.textURL {
            return [textURL]
        }

        let text = appState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }

    @objc func shareAction() {
        guard let controller = activeWindowController,
              let contentView = controller.window?.contentView else {
            return
        }

        let items = sharingItems(for: controller.appState)
        guard !items.isEmpty else { return }

        let picker = NSSharingServicePicker(items: items)
        let anchorRect = NSRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY,
            width: 1,
            height: 1
        )
        picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
    }

    func defaultBrowserInfo() -> (name: String, itemTitle: String) {
        let defaultBrowserName: String
        if let httpsURL = URL(string: "https://www.apple.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL) {
            let bundle = Bundle(url: appURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? FileManager.default.displayName(atPath: appURL.path)
            var displayName = name
            if displayName.hasSuffix(".app") {
                displayName = String(displayName.dropLast(4))
            }
            defaultBrowserName = displayName.isEmpty ? NSLocalizedString("Default Browser", comment: "") : displayName
        } else {
            defaultBrowserName = NSLocalizedString("Default Browser", comment: "")
        }
        let title = String(format: NSLocalizedString("Open in %@", comment: ""), defaultBrowserName)
        return (defaultBrowserName, title)
    }

    @objc func openInDefaultBrowserAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyWebURLAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc func handleWebSnapshotReadyForSave(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo["id"] as? UUID,
              let appState = activeAppState,
              appState.id == id else {
            return
        }

        // 截图和闪白已完成，现在弹出保存面板
        presentSavePanel(for: appState)
    }

    func presentSavePanel(for appState: AppState) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true

        var defaultName = "Untitled"
        var allowedTypes: [UTType] = []

        // 1. 优先判定是否为网页模式 (即便后台已缓存网页截图 imageURL，核心类型依然属于网页)
        if let webURL = appState.webURL {
            if webURL.isFileURL {
                if let name = appState.originalImageName, !name.isEmpty {
                    defaultName = name
                } else {
                    defaultName = webURL.lastPathComponent
                }
                let ext = webURL.pathExtension
                if let type = UTType(filenameExtension: ext) {
                    allowedTypes = [type]
                } else {
                    allowedTypes = [.html, .data]
                }
            } else {
                // 在线网页：直接保存为生成的截图图片 (PNG)
                guard let _ = appState.imageURL else {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Web Snapshot Loading Title", comment: "")
                    alert.informativeText = NSLocalizedString("Web Snapshot Loading Message", comment: "")
                    alert.runModal()
                    return
                }
                if let name = appState.originalImageName, !name.isEmpty {
                    defaultName = name
                } else if let host = webURL.host {
                    defaultName = host
                } else {
                    defaultName = "Snapshot"
                }

                // 去除所有已知网页相关的后缀
                if defaultName.lowercased().hasSuffix(".webloc") {
                    defaultName = String(defaultName.dropLast(7))
                }
                if defaultName.lowercased().hasSuffix(".webarchive") {
                    defaultName = String(defaultName.dropLast(11))
                }
                if defaultName.lowercased().hasSuffix(".pdf") {
                    defaultName = String(defaultName.dropLast(4))
                }

                if !defaultName.lowercased().hasSuffix(".png") {
                    defaultName += ".png"
                }
                allowedTypes = [.png]
            }
        } else if let imageURL = appState.imageURL { // 2. 其次判定是否为独立的图片或 PDF
            if let name = appState.originalImageName {
                defaultName = name
            } else {
                defaultName = imageURL.lastPathComponent
            }
            let ext = imageURL.pathExtension
            if let type = UTType(filenameExtension: ext) {
                allowedTypes = [type]
            } else {
                allowedTypes = [.image, .data]
            }
        } else if !appState.text.isEmpty { // 3. 最后判定是否为文本
            if let name = appState.originalImageName, !name.isEmpty {
                defaultName = name
            } else {
                defaultName = appState.isMarkdownPreview ? "Untitled.md" : "Untitled.txt"
            }

            let ext = URL(fileURLWithPath: defaultName).pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                if let mdType = UTType("net.daringfireball.markdown") {
                    allowedTypes.append(mdType)
                }
                if let pubMdType = UTType("public.markdown") {
                    allowedTypes.append(pubMdType)
                }
                allowedTypes.append(.plainText)
            } else if ext == "csv" {
                if let csvType = UTType(filenameExtension: "csv") {
                    allowedTypes.append(csvType)
                }
                allowedTypes.append(.plainText)
            } else {
                allowedTypes = [.plainText]
            }
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save As Failed Title", comment: "")
            alert.informativeText = NSLocalizedString("Save As Failed Message", comment: "")
            alert.runModal()
            return
        }

        savePanel.nameFieldStringValue = defaultName
        if !allowedTypes.isEmpty {
            savePanel.allowedContentTypes = allowedTypes
        }

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                DispatchQueue.main.async {
                    self.performSaveAs(appState: appState, to: targetURL)
                }
            }
        }
    }

    func performSaveAs(appState: AppState, to targetURL: URL) {
        let isAccessing = targetURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // 1. 优先处理网页模式
            if let webURL = appState.webURL {
                if webURL.isFileURL {
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: webURL, to: targetURL)
                } else {
                    // 在线网页另存为：拷贝截图文件
                    guard let imageURL = appState.imageURL else {
                        throw NSError(domain: "FoofoilError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Snapshot image not found"])
                    }
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: imageURL, to: targetURL)
                }
            } else if let imageURL = appState.imageURL { // 2. 其次处理图片模式
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: imageURL, to: targetURL)
            } else if !appState.text.isEmpty { // 3. 最后处理文本
                try appState.text.write(to: targetURL, atomically: true, encoding: .utf8)
            }
        } catch {
            self.showSaveErrorAlert(error)
        }
    }

    @objc func openFileAction() {
        guard let appState = activeAppState else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = [.image, .pdf, .html, .text, .movie, .audio]
        if let testExtensionType = UTType("app.foofoil.test-document") {
            types.append(testExtensionType)
        }
        if let webarchiveType = UTType("com.apple.webarchive") {
            types.append(webarchiveType)
        }
        panel.allowedContentTypes = types

        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    appState.openFile(url: url)
                }
            }
        }
    }

    @objc func openWebURLAction() {
        let currentURLString: String? = {
            guard let appState = activeAppState,
                  let url = appState.actualWebURL ?? appState.webURL else { return nil }
            return url.absoluteString
        }()
        HistorySearchWindowController.shared.showURLInput(initialQuery: currentURLString)
    }

    /// 在空白窗口中打开网页；若没有空白窗口，则创建新窗口。
    public func openWebURLInPreferredWindow(_ url: URL) {
        if let controller = availableBlankWindowController {
            controller.appState.openWeb(url: url)
            activateWindow(controller)
        } else {
            let state = AppState()
            state.openWeb(url: url)
            showNewWindow(with: state)
        }
        HistorySearchWindowController.shared.dismiss()
    }

    @objc func openClipboardImageAction() {
        _ = openClipboardImageInNewWindow()
    }

    @discardableResult
    func openClipboardImageInNewWindow() -> Bool {
        let state = AppState()
        if let fileURL = clipboardSupportedFileURL(using: state) {
            // Finder 复制文件时也会提供文件图标；必须从原文件读取实际内容。
            if let controller = availableBlankWindowController {
                controller.appState.openFile(url: fileURL)
                activateWindow(controller)
            } else {
                state.openFile(url: fileURL)
                showNewWindow(with: state)
            }
        } else if let image = clipboardImage() {
            if let controller = availableBlankWindowController {
                controller.appState.openImage(image: image, imageSource: .clipboard)
                activateWindow(controller)
            } else {
                state.openImage(image: image, imageSource: .clipboard)
                showNewWindow(with: state)
            }
        } else {
            return false
        }
        return true
    }

    func clipboardSupportedFileURL(using appState: AppState) -> URL? {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []

        // 若剪贴板包含文件，不能回退到它的 Finder 图标。
        guard !fileURLs.isEmpty else { return nil }
        return fileURLs.first { appState.canOpenFile(url: $0) }
    }

    func clipboardImage() -> NSImage? {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !fileURLs.isEmpty {
            return nil
        }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else {
            return nil
        }
        return NSImage(pasteboard: pasteboard)
    }

    @objc func resetContentAction() {
        activeAppState?.resetContent()
    }

    @objc func closeWindowAction() {
        activeWindowController?.close()
    }

    @objc func togglePinAction() {
        activeAppState?.togglePin()
    }

    @objc func toggleShowBorderAction() {
        activeAppState?.showBorder.toggle()
    }

    @objc func reloadPageAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("reloadWebView_\(appState.id.uuidString)"),
            object: nil
        )
    }

    @objc func captureImageFoofoilAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("captureImageFoofoil_\(appState.id.uuidString)"),
            object: nil
        )
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        var filePaths: [String] = []
        for url in urls {
            if url.scheme == "foofoil" {
                if url.host == "open-clipboard" {
                    NSApp.activate(ignoringOtherApps: true)
                    _ = openClipboardImageInNewWindow()
                }
            } else if url.isFileURL {
                filePaths.append(url.path)
            }
        }
        if !filePaths.isEmpty {
            self.application(application, openFiles: filePaths)
        }
    }

    @objc func handleCreateNewFoofoilFromImage(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo["id"] as? UUID,
              let imageURL = userInfo["imageURL"] as? URL,
              let originalName = userInfo["originalName"] as? String else {
            return
        }

        let config = WindowConfig(
            id: id,
            imagePath: imageURL.path,
            originalImageName: originalName,
            showBorder: false,
            createdAt: Date()
        )

        let newState = AppState(config: config)

        // 显示新窗口
        showNewWindow(with: newState)

        // 保存新状态并将其加入历史记录
        newState.saveState()
    }

    @objc func selectColorAction() {
        activeAppState?.showColorPanel()
    }

    @objc func backgroundColorAction() {
        activeAppState?.showBackgroundColorPanel()
    }

    @objc func previousPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToPreviousPDFPage)
    }

    @objc func nextPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToNextPDFPage)
    }

    @objc func goToPDFPageAction() {
        postPDFNavigationNotification(.shouldPromptForPDFPage)
    }

    func postPDFNavigationNotification(_ name: Notification.Name) {
        guard let appState = activeAppState, appState.isPDFDocument else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["id": appState.id])
    }



    @objc func increaseOpacityAction() {
        activeAppState?.increaseOpacity()
    }

    @objc func decreaseOpacityAction() {
        activeAppState?.decreaseOpacity()
    }

    @objc func chooseOpacityAction(_ sender: NSMenuItem) {
        if let val = sender.representedObject as? Double {
            activeAppState?.opacity = val
        }
    }

    @objc func zoomInAction() {
        activeWindowController?.zoomIn()
    }

    @objc func zoomOutAction() {
        activeWindowController?.zoomOut()
    }

    @objc func actualSizeAction() {
        activeWindowController?.actualSize()
    }

    @objc func fitWindowToImageAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.showBorder else { return }
        activeWindowController?.fitWindowToCurrentImageSize()
    }

    @objc func fitImageToWindowWidthAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.showBorder else { return }
        activeWindowController?.fitImageToWindowWidth()
    }

    @objc func zoomOutWindowAction() {
        guard let appState = activeAppState else { return }
        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        if isImageMode {
            if appState.showBorder {
                activeWindowController?.zoomOutWindow()
            } else {
                activeWindowController?.zoomOut()
            }
        } else {
            activeWindowController?.zoomOutWindow()
        }
    }

    @objc func zoomInWindowAction() {
        guard let appState = activeAppState else { return }
        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        if isImageMode {
            if appState.showBorder {
                activeWindowController?.zoomInWindow()
            } else {
                activeWindowController?.zoomIn()
            }
        } else {
            activeWindowController?.zoomInWindow()
        }
    }

    // MARK: - Window Positioning Actions

    @objc func moveToTopLeftAction() {
        activeWindowController?.moveWindow(to: .topLeft)
    }

    @objc func moveToTopAction() {
        activeWindowController?.moveWindow(to: .top)
    }

    @objc func moveToTopRightAction() {
        activeWindowController?.moveWindow(to: .topRight)
    }

    @objc func moveToLeftAction() {
        activeWindowController?.moveWindow(to: .left)
    }

    @objc func moveToCenterAction() {
        activeWindowController?.moveWindow(to: .center)
    }

    @objc func moveToRightAction() {
        activeWindowController?.moveWindow(to: .right)
    }

    @objc func moveToBottomLeftAction() {
        activeWindowController?.moveWindow(to: .bottomLeft)
    }

    @objc func moveToBottomAction() {
        activeWindowController?.moveWindow(to: .bottom)
    }

    @objc func moveToBottomRightAction() {
        activeWindowController?.moveWindow(to: .bottomRight)
    }

    @objc func moveToNextScreenAction() {
        activeWindowController?.moveToNextScreen()
    }
}
