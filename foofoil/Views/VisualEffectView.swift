//
//  VisualEffectView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

// 桥接 NSVisualEffectView 以实现真正的 macOS 毛玻璃效果
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
