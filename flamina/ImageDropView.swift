//
//  ImageDropView.swift
//  flamina
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers

public struct ImageDropView: View {
    @ObservedObject var appState: AppState
    @State private var isTargeted = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.image, .fileURL, .url, .text], isTargeted: $isTargeted) { providers in
                    self.appState.handleDrop(providers: providers)
                    return true
                }
                // 拖拽文件到窗口上方时显示高亮外框提示
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isTargeted ? Color.blue.opacity(0.8) : Color.clear, lineWidth: 3)
                )
        }
    }
}
