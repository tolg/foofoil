//
//  main.swift
//  foofoil
//
//  Created by tolg on 2026/7/7.
//

import Cocoa

@MainActor
private var appDelegate: AppDelegate?

@MainActor
private func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
