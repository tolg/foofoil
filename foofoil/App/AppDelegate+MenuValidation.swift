//  AppDelegate+MenuValidation.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit

enum GoMenuItemTag {
    static let pdfPrevious = 801
    static let pdfNext = 802
    static let fileListPrevious = 803
    static let fileListNext = 804
    static let fileListExtra = 805
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
        } else if let extensionMenu, menu === extensionMenu {
            rebuildExtensionMenu(menu)
        }
    }

    func updateExtensionMenuVisibility() {
        extensionMenuItem?.isHidden = activeAppState?.extensionSession?.commands.isEmpty != false
    }

    func updateFileMenu(_ menu: NSMenu) {
        let isWebMode = activeAppState?.webURL != nil
        setMenuItem(withAction: #selector(openInDefaultBrowserAction), in: menu, isHidden: !isWebMode)
        setMenuItem(withAction: #selector(copyWebURLAction), in: menu, isHidden: !isWebMode)
    }

    func updateGoMenu(_ menu: NSMenu) {
        let isPDFDocument = activeAppState?.isPDFDocument == true
        let hasFileList = activeAppState?.fileList?.isPresentable == true
        for item in menu.items {
            if item.action == #selector(previousFileListItemAction)
                || item.action == #selector(nextFileListItemAction) {
                let isPrimaryArrow = item.tag == GoMenuItemTag.fileListPrevious
                    || item.tag == GoMenuItemTag.fileListNext
                item.isHidden = !hasFileList || !isPrimaryArrow
                item.isEnabled = hasFileList
            } else if item.isSeparatorItem {
                item.isHidden = !isPDFDocument && !hasFileList
            } else {
                item.isHidden = !isPDFDocument
                item.isEnabled = isPDFDocument
            }
        }
        syncGoMenuKeyEquivalents()
    }

    /// “前往”在 PDF 翻页或文件列表切项时显示。
    func updateGoMenuVisibility() {
        let appState = activeAppState
        goMenuItem?.isHidden = appState?.isPDFDocument != true
            && appState?.fileList?.isPresentable != true
        syncGoMenuKeyEquivalents()
    }

    /// AppKit 会在窗口 `keyDown` 之前匹配菜单快捷键；禁用项仍会吞掉对应按键。
    /// PDF 翻页与文件列表切项共用方向键，因此只给当前内容模式绑定。
    func syncGoMenuKeyEquivalents() {
        guard let menu = goMenu else { return }
        let isPDFDocument = activeAppState?.isPDFDocument == true
        let hasFileList = activeAppState?.fileList?.isPresentable == true
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        for item in menu.items {
            switch item.tag {
            case GoMenuItemTag.pdfPrevious:
                item.keyEquivalent = isPDFDocument ? left : ""
                item.keyEquivalentModifierMask = []
            case GoMenuItemTag.pdfNext:
                item.keyEquivalent = isPDFDocument ? right : ""
                item.keyEquivalentModifierMask = []
            case GoMenuItemTag.fileListPrevious:
                item.keyEquivalent = hasFileList ? left : ""
                item.keyEquivalentModifierMask = []
            case GoMenuItemTag.fileListNext:
                item.keyEquivalent = hasFileList ? right : ""
                item.keyEquivalentModifierMask = []
            case GoMenuItemTag.fileListExtra:
                let assigned = item.representedObject as? String ?? ""
                item.keyEquivalent = hasFileList ? assigned : ""
                if assigned == up || assigned == down {
                    item.keyEquivalentModifierMask = []
                }
            default:
                break
            }
        }
    }

    func updateViewMenu(_ menu: NSMenu) {
        guard let appState = activeAppState else {
            // 没有活跃窗口时，默认隐藏图片专用和网页专用菜单项
            setMenuItem(withAction: #selector(toggleShowBorderAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(toggleImageListSlideshowAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(reloadPageAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(captureImageFoofoilAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(backgroundColorAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(selectColorAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(fitWindowToImageAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(fitImageToWindowWidthAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(zoomOutWindowAction), in: menu, isHidden: true)
            setMenuItem(withAction: #selector(zoomInWindowAction), in: menu, isHidden: true)
            navigatorMenuItem?.isHidden = true
            return
        }

        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        let isWebMode = appState.webURL != nil
        navigatorMenuItem?.isHidden = appState.navigatorContributions.isEmpty

        // 1. 图片和网页模式均可切换视觉边框。
        setMenuItem(
            withAction: #selector(toggleShowBorderAction),
            in: menu,
            isHidden: appState.isFullScreen || !(isImageMode || isWebMode)
        )

        setMenuItem(
            withAction: #selector(toggleImageListSlideshowAction),
            in: menu,
            isHidden: !appState.canToggleImageListSlideshow
        )

        // 1.5 Reload Page 菜单项
        setMenuItem(withAction: #selector(reloadPageAction), in: menu, isHidden: !isWebMode)

        // 1.6 Capture Image Foofoil 菜单项
        setMenuItem(withAction: #selector(captureImageFoofoilAction), in: menu, isHidden: !isWebMode)

        // 2. Select Color 菜单项 (仅在 SVG 且为图片模式下有用)
        let isSVG = isImageMode && appState.isSVG
        setMenuItem(withAction: #selector(selectColorAction), in: menu, isHidden: !isSVG)

        // 2.5 Background Color 菜单项可用于所有浮箔模式。
        setMenuItem(withAction: #selector(backgroundColorAction), in: menu, isHidden: false)

        // 3. Fit Window to Image & Fit Image to Window Width 菜单项 - 仅图片且有边框时可见
        let showFitOptions = isImageMode && appState.effectiveShowBorder
        setMenuItem(withAction: #selector(fitWindowToImageAction), in: menu, isHidden: !showFitOptions)
        setMenuItem(withAction: #selector(fitImageToWindowWidthAction), in: menu, isHidden: !showFitOptions)

        // 4. Zoom Out Window & Zoom In Window 菜单项 (增大/缩小箔) - 始终可见
        setMenuItem(withAction: #selector(zoomOutWindowAction), in: menu, isHidden: appState.isFullScreen)
        setMenuItem(withAction: #selector(zoomInWindowAction), in: menu, isHidden: appState.isFullScreen)
    }

    func setMenuItem(withAction action: Selector, in menu: NSMenu, isHidden: Bool) {
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

        if menuItem.action == #selector(addToFileListAction) {
            return activeAppState?.listableKind != nil
        }

        if menuItem.action == #selector(toggleShowBorderAction) {
            // 仅图片和网页模式支持切换视觉边框。
            guard let appState = activeAppState,
                  !appState.isFullScreen,
                  appState.imageURL != nil || appState.webURL != nil else {
                menuItem.state = .off
                return false
            }
            menuItem.state = appState.showBorder ? .on : .off
            return true
        }


        if menuItem.action == #selector(toggleFullScreenAction) {
            guard let appState = activeAppState else { return false }
            menuItem.title = NSLocalizedString(
                appState.isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                comment: ""
            )
            return true
        }

        if menuItem.action == #selector(togglePinAction) {
            if let appState = activeAppState {
                menuItem.state = appState.isPinned ? .on : .off
                return true
            }
            return false
        }

        if menuItem.action == #selector(toggleNavigatorPanelAction) {
            guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else {
                menuItem.state = .off
                return false
            }
            menuItem.state = appState.navigatorPanelVisibilityMode == .always ? .on : .off
            return true
        }

        if menuItem.action == #selector(placeNavigatorOnLeftAction) {
            guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return false }
            menuItem.state = appState.navigatorPanelSide == .left ? .on : .off
            return true
        }

        if menuItem.action == #selector(placeNavigatorOnRightAction) {
            guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return false }
            menuItem.state = appState.navigatorPanelSide == .right ? .on : .off
            return true
        }

        if menuItem.action == #selector(fitWindowToImageAction) ||
            menuItem.action == #selector(fitImageToWindowWidthAction) {
            guard let appState = activeAppState else { return false }
            let isImageMode = appState.imageURL != nil && appState.webURL == nil
            return isImageMode && appState.showBorder
        }

        if menuItem.action == #selector(zoomOutWindowAction) ||
            menuItem.action == #selector(zoomInWindowAction) {
            return activeAppState?.isFullScreen == false
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

        if menuItem.action == #selector(previousFileListItemAction) ||
            menuItem.action == #selector(nextFileListItemAction) {
            return activeAppState?.fileList?.isPresentable == true
        }

        if menuItem.action == #selector(toggleImageListSlideshowAction) {
            guard let appState = activeAppState, appState.canToggleImageListSlideshow else {
                menuItem.state = .off
                return false
            }
            menuItem.state = appState.fileList?.isSlideshowEnabled == true ? .on : .off
            return true
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
