//  AppDelegate+MenuSetup.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit


extension AppDelegate {
    // MARK: - Menu Bar Setup

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App 菜单
        let appMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "foofoil"
        appMenu.addItem(withTitle: String(format: NSLocalizedString("About %@", comment: ""), appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            .withSymbol("info.circle")
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("Settings...", comment: ""),
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.withSymbol("gearshape")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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

        let newWindowItem = NSMenuItem(title: NSLocalizedString("New foofoil", comment: ""), action: #selector(newWindowAction), keyEquivalent: "n")
        newWindowItem.withSymbol("plus.rectangle.on.rectangle")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)

        fileMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: NSLocalizedString("Open...", comment: ""), action: #selector(openFileAction), keyEquivalent: "o")
        openItem.withSymbol("folder")
        openItem.target = self
        fileMenu.addItem(openItem)

        let addToListItem = NSMenuItem(
            title: NSLocalizedString("Add to List...", comment: ""),
            action: #selector(addToFileListAction),
            keyEquivalent: ""
        )
        addToListItem.withSymbol("plus.rectangle.on.folder")
        addToListItem.target = self
        fileMenu.addItem(addToListItem)

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

        let closeWindowItem = NSMenuItem(title: NSLocalizedString("Close foofoil", comment: ""), action: #selector(closeWindowAction), keyEquivalent: "w")
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
            keyEquivalent: ""
        )
        previousPageItem.withSymbol("chevron.left")
        previousPageItem.tag = GoMenuItemTag.pdfPrevious
        previousPageItem.target = self
        goMenu.addItem(previousPageItem)

        let nextPageItem = NSMenuItem(
            title: NSLocalizedString("Next Page", comment: ""),
            action: #selector(nextPDFPageAction),
            keyEquivalent: ""
        )
        nextPageItem.withSymbol("chevron.right")
        nextPageItem.tag = GoMenuItemTag.pdfNext
        nextPageItem.target = self
        goMenu.addItem(nextPageItem)

        let previousItem = NSMenuItem(
            title: NSLocalizedString("Previous Item", comment: ""),
            action: #selector(previousFileListItemAction),
            keyEquivalent: ""
        )
        previousItem.withSymbol("chevron.left")
        previousItem.tag = GoMenuItemTag.fileListPrevious
        previousItem.target = self
        goMenu.addItem(previousItem)

        let nextItem = NSMenuItem(
            title: NSLocalizedString("Next Item", comment: ""),
            action: #selector(nextFileListItemAction),
            keyEquivalent: ""
        )
        nextItem.withSymbol("chevron.right")
        nextItem.tag = GoMenuItemTag.fileListNext
        nextItem.target = self
        goMenu.addItem(nextItem)

        func addFileListShortcut(
            title: String,
            action: Selector,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.isHidden = true
            item.tag = GoMenuItemTag.fileListExtra
            item.representedObject = keyEquivalent
            item.allowsKeyEquivalentWhenHidden = true
            goMenu.addItem(item)
        }
        addFileListShortcut(
            title: NSLocalizedString("Previous Item", comment: ""),
            action: #selector(previousFileListItemAction),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: []
        )
        addFileListShortcut(
            title: NSLocalizedString("Next Item", comment: ""),
            action: #selector(nextFileListItemAction),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: []
        )
        addFileListShortcut(
            title: NSLocalizedString("Previous Item", comment: ""),
            action: #selector(previousFileListItemAction),
            keyEquivalent: "p",
            modifiers: [.control]
        )
        addFileListShortcut(
            title: NSLocalizedString("Next Item", comment: ""),
            action: #selector(nextFileListItemAction),
            keyEquivalent: "n",
            modifiers: [.control]
        )
        addFileListShortcut(
            title: NSLocalizedString("Previous Item", comment: ""),
            action: #selector(previousFileListItemAction),
            keyEquivalent: "b",
            modifiers: [.control]
        )
        addFileListShortcut(
            title: NSLocalizedString("Next Item", comment: ""),
            action: #selector(nextFileListItemAction),
            keyEquivalent: "f",
            modifiers: [.control]
        )

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

        let slideshowItem = NSMenuItem(
            title: NSLocalizedString("Slideshow", comment: ""),
            action: #selector(toggleImageListSlideshowAction),
            keyEquivalent: ""
        )
        slideshowItem.withSymbol("play.rectangle")
        slideshowItem.target = self
        viewMenu.addItem(slideshowItem)

        let toggleFullScreenItem = NSMenuItem(
            title: NSLocalizedString("Enter Full Screen", comment: ""),
            action: #selector(toggleFullScreenAction),
            keyEquivalent: "f"
        )
        toggleFullScreenItem.withSymbol("arrow.up.left.and.arrow.down.right")
        toggleFullScreenItem.keyEquivalentModifierMask = [.command, .control]
        toggleFullScreenItem.target = self
        viewMenu.addItem(toggleFullScreenItem)
        viewMenu.addItem(NSMenuItem.separator())

        let navigatorMenu = NSMenu(title: NSLocalizedString("Navigator", comment: ""))
        let alwaysShowNavigatorItem = NSMenuItem(
            title: NSLocalizedString("Always Show Navigator", comment: ""),
            action: #selector(toggleNavigatorPanelAction),
            keyEquivalent: "s"
        )
        alwaysShowNavigatorItem.withSymbol("sidebar.left")
        alwaysShowNavigatorItem.keyEquivalentModifierMask = [.command, .control]
        alwaysShowNavigatorItem.target = self
        navigatorMenu.addItem(alwaysShowNavigatorItem)
        navigatorMenu.addItem(NSMenuItem.separator())

        let navigatorLeftItem = NSMenuItem(
            title: NSLocalizedString("Navigator on Left", comment: ""),
            action: #selector(placeNavigatorOnLeftAction),
            keyEquivalent: ""
        )
        navigatorLeftItem.withSymbol("sidebar.left")
        navigatorLeftItem.target = self
        navigatorMenu.addItem(navigatorLeftItem)

        let navigatorRightItem = NSMenuItem(
            title: NSLocalizedString("Navigator on Right", comment: ""),
            action: #selector(placeNavigatorOnRightAction),
            keyEquivalent: ""
        )
        navigatorRightItem.withSymbol("sidebar.right")
        navigatorRightItem.target = self
        navigatorMenu.addItem(navigatorRightItem)

        let navigatorItem = NSMenuItem(title: NSLocalizedString("Navigator", comment: ""), action: nil, keyEquivalent: "")
        navigatorItem.withSymbol("sidebar.left")
        navigatorItem.submenu = navigatorMenu
        self.navigatorMenuItem = navigatorItem
        viewMenu.addItem(navigatorItem)

        // Reload Page - 快捷键 Command + R
        let reloadPageItem = NSMenuItem(title: NSLocalizedString("Reload Page", comment: ""), action: #selector(reloadPageAction), keyEquivalent: "r")
        reloadPageItem.withSymbol("arrow.clockwise")
        reloadPageItem.keyEquivalentModifierMask = [.command]
        reloadPageItem.target = self
        viewMenu.addItem(reloadPageItem)

        // Capture Image Foofoil - 截取图片箔
        let captureImageFoofoilItem = NSMenuItem(
            title: NSLocalizedString("Capture Image foofoil", comment: ""),
            action: #selector(captureImageFoofoilAction),
            keyEquivalent: ""
        )
        captureImageFoofoilItem.withSymbol("camera.viewfinder")
        captureImageFoofoilItem.target = self
        viewMenu.addItem(captureImageFoofoilItem)

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

        // 增大/缩小箔使用 ⇧⌘+/-，避免 ⌘<（即 ⇧⌘,）与设置的 ⌘, 冲突。
        let zoomOutWindowItem = NSMenuItem(title: NSLocalizedString("Zoom Out Window", comment: ""), action: #selector(zoomOutWindowAction), keyEquivalent: "-")
        zoomOutWindowItem.withSymbol("rectangle.compress.vertical")
        zoomOutWindowItem.keyEquivalentModifierMask = [.command, .shift]
        zoomOutWindowItem.target = self
        viewMenu.addItem(zoomOutWindowItem)

        let zoomInWindowItem = NSMenuItem(title: NSLocalizedString("Zoom In Window", comment: ""), action: #selector(zoomInWindowAction), keyEquivalent: "+")
        zoomInWindowItem.withSymbol("rectangle.expand.vertical")
        zoomInWindowItem.keyEquivalentModifierMask = [.command, .shift]
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

        // 扩展只能贡献值类型命令描述，原生菜单、路由、校验和快捷键归宿主所有。
        let extensionMenu = NSMenu(title: NSLocalizedString("Extension", comment: ""))
        extensionMenu.delegate = self
        self.extensionMenu = extensionMenu
        let extensionMenuItem = NSMenuItem(title: NSLocalizedString("Extension", comment: ""), action: nil, keyEquivalent: "")
        extensionMenuItem.submenu = extensionMenu
        self.extensionMenuItem = extensionMenuItem
        mainMenu.addItem(extensionMenuItem)

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
        updateExtensionMenuVisibility()
    }

    func rebuildExtensionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let commands = activeAppState?.extensionSession?.commands else { return }
        for command in commands {
            let item = NSMenuItem(
                title: NSLocalizedString(command.titleLocalizationKey, comment: ""),
                action: #selector(extensionCommandAction(_:)),
                keyEquivalent: command.keyEquivalent ?? ""
            )
            item.target = self
            item.representedObject = command.id
            item.isEnabled = command.isEnabled
            item.state = command.isChecked ? .on : .off
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: command.modifierFlags)
            if let symbolName = command.symbolName {
                item.withSymbol(symbolName)
            }
            menu.addItem(item)
        }
    }

    func rebuildEditMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if activeAppState?.imageURL != nil, activeAppState?.webURL == nil {
            // 视频/音频没有“拷贝图片”能力，不提供该菜单项。
            if activeAppState?.isExternalMediaDocument != true {
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
}
