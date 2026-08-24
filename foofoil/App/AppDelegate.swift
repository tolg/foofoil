//  AppDelegate.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit


public class AppDelegate: NSObject, NSApplicationDelegate {
    public var windowControllers: [FloatingWindowController] = []
    var historyMenu: NSMenu?
    var editMenu: NSMenu?
    var fileMenu: NSMenu?
    var goMenu: NSMenu?
    var goMenuItem: NSMenuItem?
    var viewMenu: NSMenu?
    var windowMenu: NSMenu?
    var contentModeCancellables = Set<AnyCancellable>()
    var didOpenFiles = false

    // 获取当前活跃（Key）窗口对应的 AppState
    var activeWindowController: FloatingWindowController? {
        guard let keyWindow = NSApplication.shared.keyWindow else { return nil }
        return windowControllers.first { $0.window == keyWindow }
    }

    var activeAppState: AppState? {
        return activeWindowController?.appState
    }

    /// 优先返回当前活跃的空白窗口；若没有，则返回任意一个已打开的空白窗口。
    var availableBlankWindowController: FloatingWindowController? {
        if let activeWindowController, isBlank(activeWindowController.appState) {
            return activeWindowController
        }
        return windowControllers.first { isBlank($0.appState) }
    }

    func isBlank(_ appState: AppState) -> Bool {
        appState.imageURL == nil
            && appState.webURL == nil
            && appState.textURL == nil
            && appState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func activateWindow(_ controller: FloatingWindowController) {
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
            selector: #selector(handleCreateNewFoofoilFromImage(_:)),
            name: .createNewFoofoilFromImage,
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

    func addWindowController(_ controller: FloatingWindowController) {
        windowControllers.append(controller)

        // 内容在当前窗口内切换时（例如通过“打开”或拖放）也立即更新 PDF 专用菜单。
        controller.appState.$imageURL
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateGoMenuVisibility()
            }
            .store(in: &contentModeCancellables)
    }

    @objc func handleKeyWindowChanged(_ notification: Notification) {
        // 交由下一轮事件循环执行，确保 AppKit 已更新 keyWindow。
        DispatchQueue.main.async { [weak self] in
            self?.updateGoMenuVisibility()
        }
    }
}
