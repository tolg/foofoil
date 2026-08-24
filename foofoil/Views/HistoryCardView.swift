//
//  HistoryCardView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

// 历史记录卡片视图，使用 DragGesture(minimumDistance: 0) 实现绝对零延迟的鼠标按下/抬起视觉反馈。
struct HistoryCardView: View {
    let config: WindowConfig
    var shortcutText: String? = nil
    let action: () -> Void
    var onHoverChanged: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var cardImage: NSImage? = nil

    var body: some View {
        historyCardContent(for: config)
            .background(
                Color(NSColor.controlBackgroundColor)
                    .opacity(isPressed ? 0.7 : (isHovered ? 1.0 : 0.95))
            )
            .cornerRadius(8)
            .overlay(
                shortcutOverlay
                    .animation(.easeInOut(duration: 0.15), value: shortcutText)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(isPressed ? 0.40 : (isHovered ? 0.30 : 0.25)),
                radius: isPressed ? 1.0 : (isHovered ? 6 : 3),
                x: 0,
                y: isPressed ? 1.0 : (isHovered ? 3.5 : 1.5)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .offset(y: isPressed ? 0 : (isHovered ? -3 : 0))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovered)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.8), value: isPressed)
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged?(hovering)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let localLocation = value.location
                        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
                        if rect.contains(localLocation) {
                            if !isPressed {
                                isPressed = true
                            }
                        } else {
                            if isPressed {
                                isPressed = false
                            }
                        }
                    }
                    .onEnded { value in
                        if isPressed {
                            isPressed = false
                            action()
                        }
                    }
            )
            .onAppear {
                loadImageAsync()
            }
            .onChange(of: config.imagePath) { _ in
                loadImageAsync()
            }
            .onChange(of: config.thumbnailPath) { _ in
                loadImageAsync()
            }
    }

    private var isSVG: Bool {
        guard let name = config.originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".svg")
    }

    private var historyKind: HistoryContentKind {
        config.contentKind ?? HistoryContentKind.infer(from: config)
    }

    private var isAudioHistory: Bool { historyKind == .audio }
    private var isVideoHistory: Bool { historyKind == .video }

    @ViewBuilder
    private var shortcutOverlay: some View {
        if let shortcutText = shortcutText {
            Text(shortcutText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.45))
                        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var audioPlaceholder: some View {
        mediaPlaceholder(systemName: "music.note")
    }

    private var videoPlaceholder: some View {
        mediaPlaceholder(systemName: "play.fill")
    }

    private func mediaPlaceholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 60, height: 60)
            .accessibilityHidden(true)
    }

    /// 叠在封面缩略图上的半透明类型标记，避免音频封面被当成普通图片。
    @ViewBuilder
    private var mediaKindOverlay: some View {
        if isAudioHistory || isVideoHistory {
            Image(systemName: isAudioHistory ? "music.note" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func renderCardImage(for nsImage: NSImage) -> some View {
        let baseImage = Image(nsImage: nsImage).resizable()

        if isSVG, let svgColorHex = config.svgColor, let color = Color(hex: svgColorHex) {
            baseImage
                .renderingMode(.template)
                .foregroundColor(color)
        } else {
            baseImage
        }
    }

    private func loadImageAsync() {
        // 优先使用已生成且单独存储的正方形 HEIC 缩略图，避免加载超大原图
        let path: String
        if let thumbnailPath = config.thumbnailPath, FileManager.default.fileExists(atPath: thumbnailPath) {
            path = thumbnailPath
        } else if !isAudioHistory, !isVideoHistory, let imagePath = config.imagePath, FileManager.default.fileExists(atPath: imagePath) {
            // 音视频原文件不是图片；无封面/首帧时保持空缩略图，由卡片显示类型图标。
            path = imagePath
        } else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let nsImage = NSImage(contentsOfFile: path) {
                // 后台预解码，避免渲染时主线程同步等待导致优先级反转
                let _ = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                DispatchQueue.main.async {
                    self.cardImage = nsImage
                }
            }
        }
    }

    @ViewBuilder
    private func historyCardContent(for config: WindowConfig) -> some View {
        Group {
            if config.imagePath != nil {
                if let nsImage = cardImage {
                    ZStack {
                        renderCardImage(for: nsImage)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipped()
                        mediaKindOverlay
                    }
                    .frame(width: 60, height: 60)
                    .clipped()
                } else if isAudioHistory {
                    audioPlaceholder
                } else if isVideoHistory {
                    videoPlaceholder
                } else {
                    Color(NSColor.controlBackgroundColor)
                        .frame(width: 60, height: 60)
                }
            } else if let webURLString = config.webURLString {
                VStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                    Text(config.originalImageName ?? webURLString)
                        .font(.system(size: 7, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(3)
                        .padding(.horizontal, 4)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 60, height: 60)
            } else {
                Text(config.text)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundColor(.primary.opacity(0.85))
                    .padding(6)
                    .frame(width: 60, height: 60, alignment: .topLeading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
            }
        }
        .frame(width: 60, height: 60)
    }
}
