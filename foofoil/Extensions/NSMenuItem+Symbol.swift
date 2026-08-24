//  NSMenuItem+Symbol.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import AppKit

extension NSMenuItem {
    /// 使用系统符号统一菜单图标，同时保留 AppKit 对禁用状态的自动着色。
    @discardableResult
    func withSymbol(_ symbolName: String) -> Self {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        return self
    }
}
