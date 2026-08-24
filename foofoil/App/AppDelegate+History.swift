//  AppDelegate+History.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit


extension AppDelegate {
    // MARK: - History Management

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = NSMenu()

        let configs = HistoryRepository.shared.recent(limit: 10)

        if configs.isEmpty {
            let noHistoryItem = NSMenuItem(title: NSLocalizedString("No History", comment: ""), action: nil, keyEquivalent: "")
            noHistoryItem.withSymbol("clock")
            noHistoryItem.isEnabled = false
            dockMenu.addItem(noHistoryItem)
        } else {
            for config in configs.prefix(10) {
                var title = config.historyMenuDisplayName

                if title.isEmpty {
                    title = NSLocalizedString("Untitled Note", comment: "")
                }

                let item = NSMenuItem(title: title, action: #selector(openHistoryItemAction(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: config.historyMenuSymbolName, accessibilityDescription: nil)
                item.representedObject = config
                item.target = self
                dockMenu.addItem(item)
            }
        }

        dockMenu.addItem(NSMenuItem.separator())

        let searchItem = NSMenuItem(title: NSLocalizedString("Search History Menu Item", comment: ""), action: #selector(showHistorySearchAction), keyEquivalent: "")
        searchItem.withSymbol("magnifyingglass")
        searchItem.target = self
        dockMenu.addItem(searchItem)

        let clearHistoryItem = NSMenuItem(title: NSLocalizedString("Clear History Menu Item", comment: ""), action: #selector(clearHistoryAction), keyEquivalent: "")
        clearHistoryItem.withSymbol("trash")
        clearHistoryItem.target = self
        dockMenu.addItem(clearHistoryItem)

        return dockMenu
    }

    public func updateHistoryMenu() {
        guard let historyMenu = historyMenu else { return }
        historyMenu.removeAllItems()

        let searchItem = NSMenuItem(title: NSLocalizedString("Search History Menu Item", comment: ""), action: #selector(showHistorySearchAction), keyEquivalent: "p")
        searchItem.withSymbol("magnifyingglass")
        searchItem.keyEquivalentModifierMask = [.command]
        searchItem.target = self
        historyMenu.addItem(searchItem)
        historyMenu.addItem(NSMenuItem.separator())

        let configs = HistoryRepository.shared.recent(limit: 10)

        if configs.isEmpty {
            let noHistoryItem = NSMenuItem(title: NSLocalizedString("No History", comment: ""), action: nil, keyEquivalent: "")
            noHistoryItem.withSymbol("clock")
            noHistoryItem.isEnabled = false
            historyMenu.addItem(noHistoryItem)
        } else {
            for (index, config) in configs.prefix(10).enumerated() {
                var title = config.historyMenuDisplayName

                if title.isEmpty {
                    title = NSLocalizedString("Untitled Note", comment: "")
                }

                let keyEquivalent = index < 9 ? "\(index + 1)" : ""
                let item = NSMenuItem(title: title, action: #selector(openHistoryItemAction(_:)), keyEquivalent: keyEquivalent)
                item.image = NSImage(systemSymbolName: config.historyMenuSymbolName, accessibilityDescription: nil)
                item.representedObject = config
                item.target = self
                historyMenu.addItem(item)
            }
        }

        historyMenu.addItem(NSMenuItem.separator())

        let clearHistoryItem = NSMenuItem(title: NSLocalizedString("Clear History Menu Item", comment: ""), action: #selector(clearHistoryAction), keyEquivalent: "")
        clearHistoryItem.withSymbol("trash")
        clearHistoryItem.target = self
        historyMenu.addItem(clearHistoryItem)
    }

    @objc func showHistorySearchAction() {
        NSApp.activate(ignoringOtherApps: true)
        HistorySearchWindowController.shared.show()
    }

    /// 搜索结果优先复用已打开的空白窗口，否则新建窗口。
    public func openSearchResultInNewWindow(id: UUID) {
        guard let config = HistoryRepository.shared.config(id: id) else { return }
        let requiredPaths = [config.imagePath, config.textPath].compactMap { $0 }
        if requiredPaths.contains(where: { !FileManager.default.fileExists(atPath: $0) }) {
            // 音视频经安全范围书签仍可访问时放行（沙盒重启后路径直接不可达但授权可恢复）。
            let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
            let isExternalMedia = kind == .video || kind == .audio
            if isExternalMedia, let bookmark = config.videoBookmark, AppState.resolveVideoBookmark(bookmark) != nil {
                openHistoryConfig(config: config, id: id)
                return
            }
            // 音视频源文件缺失时直接移除历史记录，不再提示。
            if isExternalMedia {
                HistoryRepository.shared.remove(id: config.id)
                HistoryManager.shared.refresh()
                HistorySearchWindowController.shared.dismiss()
                return
            }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("History Content Missing Title", comment: "")
            alert.informativeText = NSLocalizedString("History Content Missing Message", comment: "")
            alert.runModal()
            return
        }
        openHistoryConfig(config: config, id: id)
    }

    func openHistoryConfig(config: WindowConfig, id: UUID) {
        if let controller = availableBlankWindowController {
            controller.appState.loadConfig(config)
            activateWindow(controller)
        } else {
            let state = AppState(config: config)
            let controller = FloatingWindowController(appState: state)
            if config.windowFrame == nil { controller.window?.center() }
            addWindowController(controller)
            controller.showWindow(nil)
        }
        HistoryRepository.shared.touch(id: id)
        HistoryManager.shared.refresh()
        HistorySearchWindowController.shared.dismiss()
    }

    @objc func openHistoryItemAction(_ sender: NSMenuItem) {
        guard let config = sender.representedObject as? WindowConfig else { return }

        NSApp.activate(ignoringOtherApps: true)

        // 优先在当前活跃的空白窗口中加载
        if let activeState = activeAppState {
            if activeState.imageURL == nil && activeState.webURL == nil && activeState.text.isEmpty {
                withAnimation(.easeInOut(duration: 0.35)) {
                    activeState.loadConfig(config)
                }
                activeWindowController?.window?.makeKeyAndOrderFront(nil)
                return
            }
        }

        // 否则，创建一个新窗口并加载该历史项
        let state = AppState()
        state.loadConfig(config)
        let controller = FloatingWindowController(appState: state)

        // 只有当历史记录中没有保存窗口的位置时，才需要将其居中或根据 keyWindow 偏移
        if config.windowFrame == nil {
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
        }

        addWindowController(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func clearHistoryAction() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Confirm Clear History", comment: "")
        alert.informativeText = NSLocalizedString("This will clear history and cached content for closed windows, plus WebKit website cache, cookies, and stored website data.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Clear", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            HistoryManager.shared.clearHistory()
            clearWebKitWebsiteData()
        }
    }

    func clearWebKitWebsiteData() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) { }
        }
    }
}
