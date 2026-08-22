//  EditMenuCommands.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//

import AppKit

@objc protocol EditMenuCommands {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
    func cut(_ sender: Any?)
    func copy(_ sender: Any?)
    func paste(_ sender: Any?)
    func delete(_ sender: Any?)
    func selectAll(_ sender: Any?)
}
