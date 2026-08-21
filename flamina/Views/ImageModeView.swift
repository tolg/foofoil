//
//  ImageModeView.swift
//  flamina
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

struct ImageModeView: View {
    @ObservedObject var appState: AppState
    let nsImage: NSImage
    let shouldHideBorder: Bool

    @State private var isPinching = false
    @State private var baseScale: Double = 1.0

    var body: some View {
        Group {
            if shouldHideBorder {
                renderImage(for: nsImage, contentMode: .fill, width: nil, height: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    renderImage(
                        for: nsImage,
                        contentMode: .fit,
                        width: nsImage.size.width * CGFloat(appState.imageScale),
                        height: nsImage.size.height * CGFloat(appState.imageScale)
                    )
                }
                .padding(8) // 移至 ScrollView 外部，确保在滚动时边框始终保持同样粗细（12 像素）。
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        isPinching = true
                        baseScale = appState.imageScale
                    }
                    let newScale = baseScale * Double(value)
                    appState.isInteractiveZooming = true
                    appState.imageScale = AppState.clampImageScale(newScale)

                    if !appState.showBorder {
                        NotificationCenter.default.post(
                            name: .shouldFitWindowToImage,
                            object: nil,
                            userInfo: ["id": appState.id, "animated": false]
                        )
                    }
                }
                .onEnded { _ in
                    appState.isInteractiveZooming = false
                    appState.saveState()
                    isPinching = false
                }
        )
    }

    @ViewBuilder
    private func renderImage(for nsImage: NSImage, contentMode: ContentMode, width: CGFloat?, height: CGFloat?) -> some View {
        let baseImage = Image(nsImage: nsImage).resizable()

        if appState.isSVG, let svgColorHex = appState.svgColor, let color = Color(hex: svgColorHex) {
            baseImage
                .renderingMode(.template)
                .aspectRatio(contentMode: contentMode)
                .foregroundColor(color)
                .frame(width: width, height: height)
        } else {
            baseImage
                .aspectRatio(contentMode: contentMode)
                .frame(width: width, height: height)
        }
    }
}
