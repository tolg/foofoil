//
//  FlofoilApp.swift
//  flofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit

extension NSMenuItem {
    /// 使用系统符号统一菜单图标，同时保留 AppKit 对禁用状态的自动着色。
    @discardableResult
    func withSymbol(_ symbolName: String) -> Self {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        return self
    }
}


@objc private protocol EditMenuCommands {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
    func cut(_ sender: Any?)
    func copy(_ sender: Any?)
    func paste(_ sender: Any?)
    func delete(_ sender: Any?)
    func selectAll(_ sender: Any?)
}

public class AppDelegate: NSObject, NSApplicationDelegate {
    public var windowControllers: [FloatingWindowController] = []
    private var historyMenu: NSMenu?
    private var editMenu: NSMenu?
    private var fileMenu: NSMenu?
    private var goMenu: NSMenu?
    private var goMenuItem: NSMenuItem?
    private var viewMenu: NSMenu?
    private var windowMenu: NSMenu?
    private var contentModeCancellables = Set<AnyCancellable>()
    private var didOpenFiles = false

    // 获取当前活跃（Key）窗口对应的 AppState
    private var activeWindowController: FloatingWindowController? {
        guard let keyWindow = NSApplication.shared.keyWindow else { return nil }
        return windowControllers.first { $0.window == keyWindow }
    }

    private var activeAppState: AppState? {
        return activeWindowController?.appState
    }

    /// 优先返回当前活跃的空白窗口；若没有，则返回任意一个已打开的空白窗口。
    private var availableBlankWindowController: FloatingWindowController? {
        if let activeWindowController, isBlank(activeWindowController.appState) {
            return activeWindowController
        }
        return windowControllers.first { isBlank($0.appState) }
    }

    private func isBlank(_ appState: AppState) -> Bool {
        appState.imageURL == nil
            && appState.webURL == nil
            && appState.textURL == nil
            && appState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func activateWindow(_ controller: FloatingWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // 处理文件关联打开事件 (右键 "打开方式" 或者双击文件)
    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        didOpenFiles = true
        for filename in filenames {
            let fileURL = URL(fileURLWithPath: filename)

            // 如果当前存在活跃的空白窗口，则直接在其中加载
            if let activeState = activeAppState, activeState.imageURL == nil && activeState.webURL == nil && activeState.text.isEmpty {
                activeState.openFile(url: fileURL)
                activeWindowController?.window?.makeKeyAndOrderFront(nil)
            } else {
                // 否则，创建一个新窗口加载该图片或网页
                let state = AppState()
                state.openFile(url: fileURL)

                let controller = FloatingWindowController(appState: state)
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
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 活跃窗口切换时立即同步 PDF 专用菜单，避免等待用户打开任意菜单后才更新。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyWindowChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyWindowChanged),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        // 注册截屏新窗口通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCreateNewFlofoilFromImage(_:)),
            name: .createNewFlofoilFromImage,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebSnapshotReadyForSave(_:)),
            name: .webSnapshotReadyForSave,
            object: nil
        )

        // 1. 启动时，如果尚未通过打开文件创建过窗口，且当前窗口列表为空，才显示一个默认尺寸的空白窗口
        if !didOpenFiles && windowControllers.isEmpty {
            let state = AppState()
            let controller = FloatingWindowController(appState: state)
            addWindowController(controller)
            controller.showWindow(nil)
        }

        // 2. 动态创建 macOS 菜单项 (延时到主线程下一个循环，确保在 SwiftUI 初始化菜单之后执行)
        DispatchQueue.main.async {
            self.setupMainMenu()
            self.updateHistoryMenu()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭后，不要退出应用，保持无窗口活动状态
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindowAction()
        }
        return true
    }

    public func removeWindowController(_ controller: FloatingWindowController) {
        guard let index = windowControllers.firstIndex(where: { $0 === controller }) else { return }
        windowControllers.remove(at: index)
    }

    private func addWindowController(_ controller: FloatingWindowController) {
        windowControllers.append(controller)

        // 内容在当前窗口内切换时（例如通过“打开”或拖放）也立即更新 PDF 专用菜单。
        controller.appState.$imageURL
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateGoMenuVisibility()
            }
            .store(in: &contentModeCancellables)
    }

    @objc private func handleKeyWindowChanged(_ notification: Notification) {
        // 交由下一轮事件循环执行，确保 AppKit 已更新 keyWindow。
        DispatchQueue.main.async { [weak self] in
            self?.updateGoMenuVisibility()
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App 菜单
        let appMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Flofoil"
        appMenu.addItem(withTitle: String(format: NSLocalizedString("About %@", comment: ""), appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            .withSymbol("info.circle")
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(
            title: String(format: NSLocalizedString("Hide %@", comment: ""), appName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.withSymbol("eye.slash")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: NSLocalizedString("Hide Others", comment: ""),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.withSymbol("eye.slash.fill")
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: NSLocalizedString("Show All", comment: ""),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.withSymbol("eye")
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: String(format: NSLocalizedString("Quit %@", comment: ""), appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .withSymbol("power")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. File 菜单
        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: ""))
        fileMenu.delegate = self
        self.fileMenu = fileMenu

        let newWindowItem = NSMenuItem(title: NSLocalizedString("New Flofoil", comment: ""), action: #selector(newWindowAction), keyEquivalent: "n")
        newWindowItem.withSymbol("plus.rectangle.on.rectangle")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)

        fileMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: NSLocalizedString("Open...", comment: ""), action: #selector(openFileAction), keyEquivalent: "o")
        openItem.withSymbol("folder")
        openItem.target = self
        fileMenu.addItem(openItem)

        let openClipboardImageItem = NSMenuItem(title: NSLocalizedString("Open Clipboard Image", comment: ""), action: #selector(openClipboardImageAction), keyEquivalent: "v")
        openClipboardImageItem.withSymbol("photo.on.rectangle")
        openClipboardImageItem.keyEquivalentModifierMask = [.command, .shift]
        openClipboardImageItem.target = self
        fileMenu.addItem(openClipboardImageItem)

        let openWebURLItem = NSMenuItem(title: NSLocalizedString("Open URL Menu Item", comment: ""), action: #selector(openWebURLAction), keyEquivalent: "l")
        openWebURLItem.withSymbol("link")
        openWebURLItem.target = self
        fileMenu.addItem(openWebURLItem)

        let saveAsItem = NSMenuItem(title: NSLocalizedString("Save As...", comment: ""), action: #selector(saveAsAction), keyEquivalent: "s")
        saveAsItem.withSymbol("square.and.arrow.down")
        saveAsItem.keyEquivalentModifierMask = [.command]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)

        let shareItem = NSMenuItem(title: NSLocalizedString("Share...", comment: ""), action: #selector(shareAction), keyEquivalent: "")
        shareItem.withSymbol("square.and.arrow.up")
        shareItem.target = self
        fileMenu.addItem(shareItem)

        let openInDefaultBrowserItem = NSMenuItem(
            title: defaultBrowserInfo().itemTitle,
            action: #selector(openInDefaultBrowserAction),
            keyEquivalent: ""
        )
        openInDefaultBrowserItem.withSymbol("safari")
        openInDefaultBrowserItem.target = self
        fileMenu.addItem(openInDefaultBrowserItem)

        let copyWebURLItem = NSMenuItem(
            title: NSLocalizedString("Copy URL", comment: ""),
            action: #selector(copyWebURLAction),
            keyEquivalent: ""
        )
        copyWebURLItem.withSymbol("link")
        copyWebURLItem.target = self
        fileMenu.addItem(copyWebURLItem)

        fileMenu.addItem(NSMenuItem.separator())

        let resetContentItem = NSMenuItem(title: NSLocalizedString("Reset", comment: ""), action: #selector(resetContentAction), keyEquivalent: "k")
        resetContentItem.withSymbol("arrow.counterclockwise")
        resetContentItem.keyEquivalentModifierMask = [.command]
        resetContentItem.target = self
        fileMenu.addItem(resetContentItem)

        let closeWindowItem = NSMenuItem(title: NSLocalizedString("Close Flofoil", comment: ""), action: #selector(closeWindowAction), keyEquivalent: "w")
        closeWindowItem.withSymbol("xmark.circle")
        closeWindowItem.target = self
        fileMenu.addItem(closeWindowItem)

        let fileMenuItem = NSMenuItem(title: NSLocalizedString("File", comment: ""), action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 2.5 Edit 菜单
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenu.delegate = self
        self.editMenu = editMenu
        rebuildEditMenu(editMenu)

        let editMenuItem = NSMenuItem(title: NSLocalizedString("Edit", comment: ""), action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. Go 菜单（仅在查看 PDF 时显示）
        let goMenu = NSMenu(title: NSLocalizedString("Go", comment: ""))
        goMenu.delegate = self
        self.goMenu = goMenu

        let previousPageItem = NSMenuItem(
            title: NSLocalizedString("Previous Page", comment: ""),
            action: #selector(previousPDFPageAction),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        previousPageItem.withSymbol("chevron.left")
        previousPageItem.keyEquivalentModifierMask = []
        previousPageItem.target = self
        goMenu.addItem(previousPageItem)

        let nextPageItem = NSMenuItem(
            title: NSLocalizedString("Next Page", comment: ""),
            action: #selector(nextPDFPageAction),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextPageItem.withSymbol("chevron.right")
        nextPageItem.keyEquivalentModifierMask = []
        nextPageItem.target = self
        goMenu.addItem(nextPageItem)

        goMenu.addItem(NSMenuItem.separator())
        let goToPageItem = NSMenuItem(title: NSLocalizedString("Go to Page Menu Item", comment: ""), action: #selector(goToPDFPageAction), keyEquivalent: "g")
        goToPageItem.withSymbol("number.square")
        goToPageItem.keyEquivalentModifierMask = [.command]
        goToPageItem.target = self
        goMenu.addItem(goToPageItem)

        let goMenuItem = NSMenuItem(title: NSLocalizedString("Go", comment: ""), action: nil, keyEquivalent: "")
        goMenuItem.submenu = goMenu
        self.goMenuItem = goMenuItem
        mainMenu.addItem(goMenuItem)

        // 4. View 菜单
        let viewMenu = NSMenu(title: NSLocalizedString("View", comment: ""))
        viewMenu.delegate = self
        self.viewMenu = viewMenu

        // Toggle Pin - 快捷键 Command + T
        let togglePinItem = NSMenuItem(title: NSLocalizedString("Toggle Pin", comment: ""), action: #selector(togglePinAction), keyEquivalent: "t")
        togglePinItem.withSymbol("pin")
        togglePinItem.keyEquivalentModifierMask = [.command]
        togglePinItem.target = self
        viewMenu.addItem(togglePinItem)

        // Toggle Border - 快捷键 Command + B
        let toggleBorderItem = NSMenuItem(title: NSLocalizedString("Border", comment: ""), action: #selector(toggleShowBorderAction), keyEquivalent: "b")
        toggleBorderItem.withSymbol("rectangle")
        toggleBorderItem.keyEquivalentModifierMask = [.command]
        toggleBorderItem.target = self
        viewMenu.addItem(toggleBorderItem)

        // Reload Page - 快捷键 Command + R
        let reloadPageItem = NSMenuItem(title: NSLocalizedString("Reload Page", comment: ""), action: #selector(reloadPageAction), keyEquivalent: "r")
        reloadPageItem.withSymbol("arrow.clockwise")
        reloadPageItem.keyEquivalentModifierMask = [.command]
        reloadPageItem.target = self
        viewMenu.addItem(reloadPageItem)

        // Capture Image Flofoil - 截取图片箔
        let captureImageFlofoilItem = NSMenuItem(
            title: NSLocalizedString("Capture Image Flofoil", comment: ""),
            action: #selector(captureImageFlofoilAction),
            keyEquivalent: ""
        )
        captureImageFlofoilItem.withSymbol("camera.viewfinder")
        captureImageFlofoilItem.target = self
        viewMenu.addItem(captureImageFlofoilItem)

        // Select Color - 选择颜色
        let selectColorItem = NSMenuItem(title: NSLocalizedString("Select Color", comment: ""), action: #selector(selectColorAction), keyEquivalent: "")
        selectColorItem.withSymbol("eyedropper")
        selectColorItem.target = self
        viewMenu.addItem(selectColorItem)

        viewMenu.addItem(NSMenuItem.separator())

        let zoomInItem = NSMenuItem(title: NSLocalizedString("Zoom In Content", comment: ""), action: #selector(zoomInAction), keyEquivalent: "+")
        zoomInItem.withSymbol("plus.magnifyingglass")
        zoomInItem.keyEquivalentModifierMask = [.command]
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: NSLocalizedString("Zoom Out Content", comment: ""), action: #selector(zoomOutAction), keyEquivalent: "-")
        zoomOutItem.withSymbol("minus.magnifyingglass")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)

        let actualSizeItem = NSMenuItem(title: NSLocalizedString("Actual Size", comment: ""), action: #selector(actualSizeAction), keyEquivalent: "0")
        actualSizeItem.withSymbol("arrow.up.left.and.arrow.down.right")
        actualSizeItem.keyEquivalentModifierMask = [.command]
        actualSizeItem.target = self
        viewMenu.addItem(actualSizeItem)

        let fitWindowToImageItem = NSMenuItem(title: NSLocalizedString("Fit Window to Image", comment: ""), action: #selector(fitWindowToImageAction), keyEquivalent: "[")
        fitWindowToImageItem.withSymbol("rectangle.inset.filled")
        fitWindowToImageItem.keyEquivalentModifierMask = [.command]
        fitWindowToImageItem.target = self
        viewMenu.addItem(fitWindowToImageItem)

        let fitImageToWidthItem = NSMenuItem(title: NSLocalizedString("Fit Image to Window Width", comment: ""), action: #selector(fitImageToWindowWidthAction), keyEquivalent: "]")
        fitImageToWidthItem.withSymbol("arrow.left.and.right")
        fitImageToWidthItem.keyEquivalentModifierMask = [.command]
        fitImageToWidthItem.target = self
        viewMenu.addItem(fitImageToWidthItem)

        let zoomOutWindowItem = NSMenuItem(title: NSLocalizedString("Zoom Out Window", comment: ""), action: #selector(zoomOutWindowAction), keyEquivalent: "<")
        zoomOutWindowItem.withSymbol("rectangle.compress.vertical")
        zoomOutWindowItem.keyEquivalentModifierMask = [.command]
        zoomOutWindowItem.target = self
        viewMenu.addItem(zoomOutWindowItem)

        let zoomInWindowItem = NSMenuItem(title: NSLocalizedString("Zoom In Window", comment: ""), action: #selector(zoomInWindowAction), keyEquivalent: ">")
        zoomInWindowItem.withSymbol("rectangle.expand.vertical")
        zoomInWindowItem.keyEquivalentModifierMask = [.command]
        zoomInWindowItem.target = self
        viewMenu.addItem(zoomInWindowItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Background Color - 同时设置窗体与 PDF 阅读区的背景色
        let backgroundColorItem = NSMenuItem(title: NSLocalizedString("Background Color", comment: ""), action: #selector(backgroundColorAction), keyEquivalent: "")
        backgroundColorItem.withSymbol("paintpalette")
        backgroundColorItem.target = self
        viewMenu.addItem(backgroundColorItem)

        // Increase Opacity - 快捷键 Command + Shift + ↑
        let increaseOpacityItem = NSMenuItem(title: NSLocalizedString("Increase Opacity", comment: ""), action: #selector(increaseOpacityAction), keyEquivalent: "")
        increaseOpacityItem.withSymbol("sun.max")
        // macOS AppKit 中，上箭头字符为 "\u{F700}" (NSUpArrowFunctionKey)
        increaseOpacityItem.keyEquivalent = "\u{F700}"
        increaseOpacityItem.keyEquivalentModifierMask = [.command, .shift]
        increaseOpacityItem.target = self
        viewMenu.addItem(increaseOpacityItem)

        // Decrease Opacity - 快捷键 Command + Shift + ↓
        let decreaseOpacityItem = NSMenuItem(title: NSLocalizedString("Decrease Opacity", comment: ""), action: #selector(decreaseOpacityAction), keyEquivalent: "")
        decreaseOpacityItem.withSymbol("sun.min")
        // macOS AppKit 中，下箭头字符为 "\u{F701}" (NSDownArrowFunctionKey)
        decreaseOpacityItem.keyEquivalent = "\u{F701}"
        decreaseOpacityItem.keyEquivalentModifierMask = [.command, .shift]
        decreaseOpacityItem.target = self
        viewMenu.addItem(decreaseOpacityItem)

        // Choose Opacity - 选择不透明度子菜单
        let chooseOpacitySubmenu = NSMenu(title: NSLocalizedString("Choose Opacity", comment: ""))
        for val in [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3] {
            let item = NSMenuItem(
                title: "\(Int(val * 100))%",
                action: #selector(chooseOpacityAction(_:)),
                keyEquivalent: ""
            )
            item.representedObject = val
            item.withSymbol("circle.lefthalf.filled")
            item.target = self
            chooseOpacitySubmenu.addItem(item)
        }

        let chooseOpacityItem = NSMenuItem(title: NSLocalizedString("Choose Opacity", comment: ""), action: nil, keyEquivalent: "")
        chooseOpacityItem.withSymbol("slider.horizontal.3")
        chooseOpacityItem.submenu = chooseOpacitySubmenu
        viewMenu.addItem(chooseOpacityItem)

        let viewMenuItem = NSMenuItem(title: NSLocalizedString("View", comment: ""), action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 4.5 Window 菜单
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        self.windowMenu = windowMenu

        let windowPositionItems: [(title: String, action: Selector, key: String, symbol: String)] = [
            (NSLocalizedString("Top-Left", comment: ""), #selector(moveToTopLeftAction), "q", "arrow.up.left"),
            (NSLocalizedString("Top", comment: ""), #selector(moveToTopAction), "w", "arrow.up"),
            (NSLocalizedString("Top-Right", comment: ""), #selector(moveToTopRightAction), "e", "arrow.up.right"),
            (NSLocalizedString("Left", comment: ""), #selector(moveToLeftAction), "a", "arrow.left"),
            (NSLocalizedString("Center", comment: ""), #selector(moveToCenterAction), "s", "scope"),
            (NSLocalizedString("Right", comment: ""), #selector(moveToRightAction), "d", "arrow.right"),
            (NSLocalizedString("Bottom-Left", comment: ""), #selector(moveToBottomLeftAction), "z", "arrow.down.left"),
            (NSLocalizedString("Bottom", comment: ""), #selector(moveToBottomAction), "x", "arrow.down"),
            (NSLocalizedString("Bottom-Right", comment: ""), #selector(moveToBottomRightAction), "c", "arrow.down.right")
        ]

        for itemInfo in windowPositionItems {
            let item = NSMenuItem(title: itemInfo.title, action: itemInfo.action, keyEquivalent: itemInfo.key)
            item.withSymbol(itemInfo.symbol)
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            windowMenu.addItem(item)
        }

        windowMenu.addItem(NSMenuItem.separator())

        let moveToNextScreenItem = NSMenuItem(
            title: NSLocalizedString("Move to Next Screen", comment: ""),
            action: #selector(moveToNextScreenAction),
            keyEquivalent: "\t"
        )
        moveToNextScreenItem.withSymbol("display.2")
        moveToNextScreenItem.keyEquivalentModifierMask = [.control, .option]
        moveToNextScreenItem.target = self
        windowMenu.addItem(moveToNextScreenItem)

        let windowMenuItem = NSMenuItem(title: NSLocalizedString("Window", comment: ""), action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // 5. History 菜单
        let historyMenuItem = NSMenuItem(title: NSLocalizedString("History", comment: ""), action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: NSLocalizedString("History", comment: ""))
        historyMenuItem.submenu = historyMenu
        self.historyMenu = historyMenu
        mainMenu.addItem(historyMenuItem)

        // 5. Help 菜单
        let helpMenu = NSMenu(title: NSLocalizedString("Help", comment: ""))
        helpMenu.addItem(withTitle: String(format: NSLocalizedString("About %@", comment: ""), appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            .withSymbol("info.circle")

        let helpMenuItem = NSMenuItem(title: NSLocalizedString("Help", comment: ""), action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        mainMenu.delegate = self
        NSApplication.shared.mainMenu = mainMenu
        updateGoMenuVisibility()
    }

    private func rebuildEditMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if activeAppState?.imageURL != nil, activeAppState?.webURL == nil {
            // 视频没有“拷贝图片”能力，不提供该菜单项。
            if activeAppState?.isVideoDocument != true {
                // 不设 target，让 Cmd+C 经由 responder chain 到当前图片窗口；文本编辑器仍可优先处理复制。
                let copyImageItem = NSMenuItem(
                    title: NSLocalizedString("Copy Image", comment: ""),
                    action: #selector(EditMenuCommands.copy(_:)),
                    keyEquivalent: "c"
                )
                copyImageItem.withSymbol("photo.on.rectangle")
                menu.addItem(copyImageItem)
            }
            return
        }

        let undoItem = NSMenuItem(title: NSLocalizedString("Undo", comment: ""), action: #selector(EditMenuCommands.undo(_:)), keyEquivalent: "z")
        undoItem.withSymbol("arrow.uturn.backward")
        menu.addItem(undoItem)

        let redoItem = NSMenuItem(title: NSLocalizedString("Redo", comment: ""), action: #selector(EditMenuCommands.redo(_:)), keyEquivalent: "z")
        redoItem.withSymbol("arrow.uturn.forward")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redoItem)

        menu.addItem(NSMenuItem.separator())

        let cutItem = NSMenuItem(title: NSLocalizedString("Cut", comment: ""), action: #selector(EditMenuCommands.cut(_:)), keyEquivalent: "x")
        cutItem.withSymbol("scissors")
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: NSLocalizedString("Copy", comment: ""), action: #selector(EditMenuCommands.copy(_:)), keyEquivalent: "c")
        copyItem.withSymbol("doc.on.doc")
        menu.addItem(copyItem)

        if activeAppState?.webURL != nil {
            let copyURLItem = NSMenuItem(
                title: NSLocalizedString("Copy URL", comment: ""),
                action: #selector(copyWebURLAction),
                keyEquivalent: "c"
            )
            copyURLItem.withSymbol("link")
            copyURLItem.keyEquivalentModifierMask = [.command, .option]
            copyURLItem.target = self
            menu.addItem(copyURLItem)
        }

        let pasteItem = NSMenuItem(title: NSLocalizedString("Paste", comment: ""), action: #selector(EditMenuCommands.paste(_:)), keyEquivalent: "v")
        pasteItem.withSymbol("clipboard")
        menu.addItem(pasteItem)

        let deleteItem = NSMenuItem(title: NSLocalizedString("Delete", comment: ""), action: #selector(EditMenuCommands.delete(_:)), keyEquivalent: "")
        deleteItem.withSymbol("trash")
        menu.addItem(deleteItem)

        let selectAllItem = NSMenuItem(title: NSLocalizedString("Select All", comment: ""), action: #selector(EditMenuCommands.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.withSymbol("checkmark.square")
        menu.addItem(selectAllItem)
    }

    // MARK: - Actions

    @objc private func newWindowAction() {
        showNewWindow(with: AppState())
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

    private func showSaveErrorAlert(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save Failed Title", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Save Failed Message Format", comment: ""), error.localizedDescription)
            alert.runModal()
        }
    }

    @objc private func saveAsAction() {
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
    private func sharingItems(for appState: AppState) -> [Any] {
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

    @objc private func shareAction() {
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

    private func defaultBrowserInfo() -> (name: String, itemTitle: String) {
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

    @objc private func openInDefaultBrowserAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyWebURLAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func handleWebSnapshotReadyForSave(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo["id"] as? UUID,
              let appState = activeAppState,
              appState.id == id else {
            return
        }

        // 截图和闪白已完成，现在弹出保存面板
        presentSavePanel(for: appState)
    }

    private func presentSavePanel(for appState: AppState) {
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

    private func performSaveAs(appState: AppState, to targetURL: URL) {
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
                        throw NSError(domain: "FlofoilError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Snapshot image not found"])
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

    @objc private func openFileAction() {
        guard let appState = activeAppState else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = [.image, .pdf, .html, .text, .movie]
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

    @objc private func openWebURLAction() {
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

    @objc private func openClipboardImageAction() {
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

    private func clipboardSupportedFileURL(using appState: AppState) -> URL? {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []

        // 若剪贴板包含文件，不能回退到它的 Finder 图标。
        guard !fileURLs.isEmpty else { return nil }
        return fileURLs.first { appState.canOpenFile(url: $0) }
    }

    private func clipboardImage() -> NSImage? {
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

    @objc private func resetContentAction() {
        activeAppState?.resetContent()
    }

    @objc private func closeWindowAction() {
        activeWindowController?.close()
    }

    @objc private func togglePinAction() {
        activeAppState?.togglePin()
    }

    @objc private func toggleShowBorderAction() {
        activeAppState?.showBorder.toggle()
    }

    @objc private func reloadPageAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("reloadWebView_\(appState.id.uuidString)"),
            object: nil
        )
    }

    @objc private func captureImageFlofoilAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("captureImageFlofoil_\(appState.id.uuidString)"),
            object: nil
        )
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        var filePaths: [String] = []
        for url in urls {
            if url.scheme == "flofoil" {
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

    @objc private func handleCreateNewFlofoilFromImage(_ notification: Notification) {
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

    @objc private func selectColorAction() {
        activeAppState?.showColorPanel()
    }

    @objc private func backgroundColorAction() {
        activeAppState?.showBackgroundColorPanel()
    }

    @objc private func previousPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToPreviousPDFPage)
    }

    @objc private func nextPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToNextPDFPage)
    }

    @objc private func goToPDFPageAction() {
        postPDFNavigationNotification(.shouldPromptForPDFPage)
    }

    private func postPDFNavigationNotification(_ name: Notification.Name) {
        guard let appState = activeAppState, appState.isPDFDocument else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["id": appState.id])
    }



    @objc private func increaseOpacityAction() {
        activeAppState?.increaseOpacity()
    }

    @objc private func decreaseOpacityAction() {
        activeAppState?.decreaseOpacity()
    }

    @objc private func chooseOpacityAction(_ sender: NSMenuItem) {
        if let val = sender.representedObject as? Double {
            activeAppState?.opacity = val
        }
    }

    @objc private func zoomInAction() {
        activeWindowController?.zoomIn()
    }

    @objc private func zoomOutAction() {
        activeWindowController?.zoomOut()
    }

    @objc private func actualSizeAction() {
        activeWindowController?.actualSize()
    }

    @objc private func fitWindowToImageAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.showBorder else { return }
        activeWindowController?.fitWindowToCurrentImageSize()
    }

    @objc private func fitImageToWindowWidthAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.showBorder else { return }
        activeWindowController?.fitImageToWindowWidth()
    }

    @objc private func zoomOutWindowAction() {
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

    @objc private func zoomInWindowAction() {
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

    @objc private func moveToTopLeftAction() {
        activeWindowController?.moveWindow(to: .topLeft)
    }

    @objc private func moveToTopAction() {
        activeWindowController?.moveWindow(to: .top)
    }

    @objc private func moveToTopRightAction() {
        activeWindowController?.moveWindow(to: .topRight)
    }

    @objc private func moveToLeftAction() {
        activeWindowController?.moveWindow(to: .left)
    }

    @objc private func moveToCenterAction() {
        activeWindowController?.moveWindow(to: .center)
    }

    @objc private func moveToRightAction() {
        activeWindowController?.moveWindow(to: .right)
    }

    @objc private func moveToBottomLeftAction() {
        activeWindowController?.moveWindow(to: .bottomLeft)
    }

    @objc private func moveToBottomAction() {
        activeWindowController?.moveWindow(to: .bottom)
    }

    @objc private func moveToBottomRightAction() {
        activeWindowController?.moveWindow(to: .bottomRight)
    }

    @objc private func moveToNextScreenAction() {
        activeWindowController?.moveToNextScreen()
    }

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

    @objc private func showHistorySearchAction() {
        NSApp.activate(ignoringOtherApps: true)
        HistorySearchWindowController.shared.show()
    }

    /// 搜索结果优先复用已打开的空白窗口，否则新建窗口。
    public func openSearchResultInNewWindow(id: UUID) {
        guard let config = HistoryRepository.shared.config(id: id) else { return }
        let requiredPaths = [config.imagePath, config.textPath].compactMap { $0 }
        if requiredPaths.contains(where: { !FileManager.default.fileExists(atPath: $0) }) {
            // 视频经安全范围书签仍可访问时放行（沙盒重启后路径直接不可达但授权可恢复）。
            let isVideo = (config.contentKind ?? HistoryContentKind.infer(from: config)) == .video
            if isVideo, let bookmark = config.videoBookmark, AppState.resolveVideoBookmark(bookmark) != nil {
                openHistoryConfig(config: config, id: id)
                return
            }
            // 视频源文件缺失时直接移除历史记录，不再提示。
            if isVideo {
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

    private func openHistoryConfig(config: WindowConfig, id: UUID) {
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

    @objc private func openHistoryItemAction(_ sender: NSMenuItem) {
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

    @objc private func clearHistoryAction() {
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

    private func clearWebKitWebsiteData() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) { }
        }
    }
}

extension AppDelegate: NSMenuItemValidation, NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        updateGoMenuVisibility()

        if let editMenu, menu === editMenu {
            rebuildEditMenu(menu)
        } else if let fileMenu, menu === fileMenu {
            updateFileMenu(menu)
        } else if let goMenu, menu === goMenu {
            updateGoMenu(goMenu)
        } else if let viewMenu, menu === viewMenu {
            updateViewMenu(menu)
        }
    }

    private func updateFileMenu(_ menu: NSMenu) {
        let isWebMode = activeAppState?.webURL != nil
        setMenuItem(withAction: #selector(openInDefaultBrowserAction), in: menu, isHidden: !isWebMode)
        setMenuItem(withAction: #selector(copyWebURLAction), in: menu, isHidden: !isWebMode)
    }

    private func updateGoMenu(_ menu: NSMenu) {
        let isPDFDocument = activeAppState?.isPDFDocument == true
        menu.items.forEach {
            $0.isHidden = false
            $0.isEnabled = isPDFDocument
        }
    }

    /// “前往”仅服务于 PDF 翻页，其他内容模式不在菜单栏中显示。
    private func updateGoMenuVisibility() {
        goMenuItem?.isHidden = activeAppState?.isPDFDocument != true
    }

    private func updateViewMenu(_ menu: NSMenu) {
        guard let appState = activeAppState else {
            // 没有活跃窗口时，默认隐藏图片专用和网页专用菜单项
            setMenuItem(withAction: #selector(toggleShowBorderAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(reloadPageAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(captureImageFlofoilAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(backgroundColorAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(selectColorAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(fitWindowToImageAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(fitImageToWindowWidthAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(zoomOutWindowAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(zoomInWindowAction), in: menu, isHidden: true)
            return
        }

        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        let isWebMode = appState.webURL != nil

        // 1. 图片和网页模式均可切换视觉边框。
        setMenuItem(withAction: #selector(toggleShowBorderAction), in: menu, isHidden: !(isImageMode || isWebMode))

        // 1.5 Reload Page 菜单项
        setMenuItem(withAction: #selector(reloadPageAction), in: menu, isHidden: !isWebMode)

        // 1.6 Capture Image Flofoil 菜单项
        setMenuItem(withAction: #selector(captureImageFlofoilAction), in: menu, isHidden: !isWebMode)

        // 2. Select Color 菜单项 (仅在 SVG 且为图片模式下有用)
        let isSVG = isImageMode && appState.isSVG
        setMenuItem(withAction: #selector(selectColorAction), in: menu, isHidden: !isSVG)

        // 2.5 Background Color 菜单项可用于所有浮箔模式。
        setMenuItem(withAction: #selector(backgroundColorAction), in: menu, isHidden: false)

        // 3. Fit Window to Image & Fit Image to Window Width 菜单项 - 仅图片且有边框时可见
        let showFitOptions = isImageMode && appState.showBorder
        setMenuItem(withAction: #selector(fitWindowToImageAction), in: menu, isHidden: !showFitOptions)
        setMenuItem(withAction: #selector(fitImageToWindowWidthAction), in: menu, isHidden: !showFitOptions)

        // 4. Zoom Out Window & Zoom In Window 菜单项 (增大/缩小箔) - 始终可见
        setMenuItem(withAction: #selector(zoomOutWindowAction), in: menu, isHidden: false)
        setMenuItem(withAction: #selector(zoomInWindowAction), in: menu, isHidden: false)
    }

    private func setMenuItem(withAction action: Selector, in menu: NSMenu, isHidden: Bool) {
        if let item = menu.items.first(where: { $0.action == action }) {
            item.isHidden = isHidden
        }
    }
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(moveToNextScreenAction) {
            return NSScreen.screens.count > 1
        }

        if menuItem.action == #selector(openInDefaultBrowserAction) {
            menuItem.title = defaultBrowserInfo().itemTitle
            return activeAppState?.webURL != nil
        }

        if menuItem.action == #selector(copyWebURLAction) {
            return activeAppState?.webURL != nil
        }

        if menuItem.action == #selector(saveAsAction) {
            guard let appState = activeAppState else { return false }
            if let webURL = appState.webURL, !webURL.isFileURL {
                menuItem.title = NSLocalizedString("Save Screenshot...", comment: "")
                return appState.imageURL != nil
            } else {
                menuItem.title = NSLocalizedString("Save As...", comment: "")
            }
            return appState.imageURL != nil || !appState.text.isEmpty
        }

        if menuItem.action == #selector(shareAction) {
            guard let appState = activeAppState else { return false }
            return !sharingItems(for: appState).isEmpty
        }

        if menuItem.action == #selector(selectColorAction) {
            return activeAppState?.isSVG == true
        }

        if menuItem.action == #selector(backgroundColorAction) {
            return activeAppState != nil
        }

        if menuItem.action == #selector(openClipboardImageAction) {
            return activeAppState != nil && clipboardImage() != nil
        }

        if menuItem.action == #selector(toggleShowBorderAction) {
            // 仅图片和网页模式支持切换视觉边框。
            guard let appState = activeAppState,
                  appState.imageURL != nil || appState.webURL != nil else {
                menuItem.state = .off
                return false
            }
            menuItem.state = appState.showBorder ? .on : .off
            return true
        }

        if menuItem.action == #selector(togglePinAction) {
            if let appState = activeAppState {
                menuItem.state = appState.isPinned ? .on : .off
                return true
            }
            return false
        }

        if menuItem.action == #selector(fitWindowToImageAction) ||
            menuItem.action == #selector(fitImageToWindowWidthAction) {
            guard let appState = activeAppState else { return false }
            let isImageMode = appState.imageURL != nil && appState.webURL == nil
            return isImageMode && appState.showBorder
        }

        if menuItem.action == #selector(zoomOutWindowAction) ||
            menuItem.action == #selector(zoomInWindowAction) {
            return activeAppState != nil
        }

        if menuItem.action == #selector(actualSizeAction) {
            return activeAppState != nil
        }

        if menuItem.action == #selector(reloadPageAction) {
            return activeAppState?.webURL != nil
        }

        if menuItem.action == #selector(previousPDFPageAction) ||
            menuItem.action == #selector(nextPDFPageAction) ||
            menuItem.action == #selector(goToPDFPageAction) {
            return activeAppState?.isPDFDocument == true
        }



        if menuItem.action == #selector(chooseOpacityAction(_:)) {
            guard let appState = activeAppState else {
                menuItem.state = .off
                return false
            }
            if let val = menuItem.representedObject as? Double {
                menuItem.state = abs(appState.opacity - val) < 0.05 ? .on : .off
            } else {
                menuItem.state = .off
            }
            return true
        }

        if menuItem.action == #selector(increaseOpacityAction) ||
            menuItem.action == #selector(decreaseOpacityAction) {
            return activeAppState != nil
        }

        return true
    }
}
