//  AppState+ColorPanel.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        // MARK: - NSColorPanel Support

        public func showColorPanel() {
            let panel = NSColorPanel.shared
            panel.showsAlpha = true
            if let hex = svgColor, let nsColor = NSColor(hex: hex) {
                panel.color = nsColor
            }
            panel.setTarget(self)
            panel.setAction(#selector(colorPanelChanged(_:)))

            // 创建一个重置按钮的 accessoryView，当点击时重置为原色
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
            let button = NSButton(title: NSLocalizedString("Reset Color", comment: ""), target: self, action: #selector(resetColorFromPanel))
            button.frame = NSRect(x: 10, y: 4, width: 180, height: 24)
            button.bezelStyle = .rounded
            accessory.addSubview(button)
            panel.accessoryView = accessory

            panel.makeKeyAndOrderFront(nil)
        }

        /// 打开窗体与 PDF 共用的背景色选择器，支持设置颜色透明度。
        public func showBackgroundColorPanel() {
            let panel = NSColorPanel.shared
            panel.showsAlpha = true
            if let hex = backgroundColorHex, let color = NSColor(hex: hex) {
                panel.color = color
            } else {
                panel.color = .windowBackgroundColor
            }
            panel.setTarget(self)
            panel.setAction(#selector(backgroundColorPanelChanged(_:)))

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
            let button = NSButton(
                title: NSLocalizedString("Reset Background Color", comment: ""),
                target: self,
                action: #selector(resetBackgroundColorFromPanel)
            )
            button.frame = NSRect(x: 10, y: 4, width: 180, height: 24)
            button.bezelStyle = .rounded
            accessory.addSubview(button)
            panel.accessoryView = accessory
            panel.makeKeyAndOrderFront(nil)
        }

        @objc func colorPanelChanged(_ sender: NSColorPanel) {
            // 确保应用处于活动状态，且颜色面板当前是可见的
            guard NSApplication.shared.isActive else { return }
            guard sender.isVisible else { return }

            // 确保只有当前处于主窗口（mainWindow）或关键窗口（keyWindow）状态的 AppState 才接受颜色面板的修改事件
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            let activeWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
            let activeState = appDelegate.windowControllers.first(where: { $0.window == activeWindow })?.appState
            guard activeState === self else { return }

            if let hex = sender.color.toHex() {
                self.svgColor = hex
            }
        }

        @objc func backgroundColorPanelChanged(_ sender: NSColorPanel) {
            // 将色板颜色以 sRGB（含 Alpha）保存，供窗体背景与 PDFView 共用。
            guard NSApplication.shared.isActive, sender.isVisible else { return }
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            let activeWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
            let activeState = appDelegate.windowControllers.first(where: { $0.window == activeWindow })?.appState
            guard activeState === self,
                  let color = sender.color.usingColorSpace(.sRGB) else { return }

            backgroundColorHex = color.toHex()
        }

        @objc func resetBackgroundColorFromPanel() {
            backgroundColorHex = nil

            // 避免为同步色板颜色而再次触发颜色回调，导致默认状态被覆盖。
            let panel = NSColorPanel.shared
            panel.setAction(nil)
            panel.color = .windowBackgroundColor
            panel.setAction(#selector(backgroundColorPanelChanged(_:)))
        }

        @objc func resetColorFromPanel() {
            self.svgColor = nil
            // 同步把调色盘重设为某个默认值，防止用户误以为没生效，不过其实重置为原色后，调色盘里的颜色本身没有硬性规定
        }
}
