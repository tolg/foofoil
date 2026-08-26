//
//  ImageModeView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

struct ImageModeView: View {
    @ObservedObject var appState: AppState
    let nsImage: NSImage
    let shouldHideBorder: Bool

    var body: some View {
        Group {
            if shouldHideBorder {
                // 窗口态无边框会按受约束的窗口比例铺满；全屏比例不可控，改为完整显示以避免裁切。
                renderImage(
                    for: nsImage,
                    contentMode: appState.isFullScreen ? .fit : .fill,
                    width: nil,
                    height: nil
                )
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
                    .transaction { $0.animation = nil }
                }
                .padding(8) // 移至 ScrollView 外部，确保在滚动时边框始终保持同样粗细（12 像素）。
            }
        }
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
