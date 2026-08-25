//
//  ContentView.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

public struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted = false // 拖放高亮状态
    @State private var isResizingWindowWithPinch = false
    @State private var pdfPageIndicator: String?
    @State private var pdfPageIndicatorDismissTask: DispatchWorkItem?
    @State private var flashOpacity: Double = 0.0

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        // 网页和图片都支持仅隐藏视觉边框；网页切换边框不应改变窗口的缩放规则。
        let shouldHideBorder = (appState.imageURL != nil || appState.webURL != nil) && !appState.showBorder
        // 网页即使同时保留了截图缓存，也不能套用图片无边框模式的最小尺寸规则。
        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        let usesCompactMinimumSize = isImageMode && !appState.showBorder
        let minimumLength: CGFloat = usesCompactMinimumSize ? 80 : 150
        // 音视频窗口再抬高最小宽度，保证底部播放条单行能放下。
        let minimumWidth = appState.isExternalMediaDocument
            ? max(minimumLength, MediaPlaybackBar.minimumWindowWidth)
            : minimumLength
        // PDF 显示边框时，四周保留 12pt 的边框区域。
        let isMarkdownPreview = appState.isMarkdownPreview && appState.isMarkdownDocument
        let contentPadding: CGFloat = isMarkdownPreview ? 0 : (appState.isPDFDocument && appState.showBorder ? 12 : (shouldHideBorder ? 0 : 4))
        let backgroundColor = appState.backgroundColorHex.flatMap(NSColor.init(hex:)) ?? .windowBackgroundColor

        ZStack {
            // 毛玻璃背景 (玻璃拟态效果)
            if !shouldHideBorder {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    Color(backgroundColor).opacity(0.6) // 叠加半透明窗口背景色以降低背景透明度，提升内容清晰度
                }
                .cornerRadius(12)
            } else if appState.webURL != nil {
                // 网页视图关闭了 WebKit 自身背景；无边框时仍保留与有边框模式一致的毛玻璃背景，避免透明区域直接露出桌面。
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    Color(backgroundColor).opacity(0.6)
                }
            }

            // 内容区域
            Group {
                if appState.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                        .transition(.opacity)
                } else if appState.extensionSession != nil {
                    ExtensionPresentationView(appState: appState)
                        .transition(.opacity)
                } else if let webURL = appState.webURL {
                    // 网页支持内容缩放；调整窗口大小只改变可视区域。
                    WebContainerView(url: webURL, zoom: appState.webZoom, appState: appState, onTitleChange: { title in
                        appState.originalImageName = title
                    }, onScreenshotTaken: { image in
                        appState.saveWebScreenshot(image)
                    }, shouldHideBorder: shouldHideBorder)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let videoURL = appState.imageURL, appState.isVideoDocument {
                    VideoModeView(appState: appState, url: videoURL, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if let audioURL = appState.imageURL, appState.isAudioDocument {
                    AudioModeView(appState: appState, url: audioURL, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if let pdfURL = appState.imageURL, appState.isPDFDocument {
                    PDFModeView(appState: appState, url: pdfURL)
                        .transition(.opacity)
                } else if let imageURL = appState.imageURL, let nsImage = appState.loadImage(from: imageURL) {
                    ImageModeView(appState: appState, nsImage: nsImage, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if appState.isCSVDocument {
                    CSVTableView(content: appState.text, fontSize: appState.textFontSize)
                        .transition(.opacity)
                } else {
                    // 文字模式
                    TextEditorModeView(appState: appState)
                        .transition(.opacity)
                }
            }
            .padding(contentPadding)

            // 截图闪白覆盖层
            Color.white
                .cornerRadius(shouldHideBorder ? 0 : 12)
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .frame(minWidth: minimumWidth, minHeight: minimumLength)
        // 直接在最外层容器上处理拖放逻辑，避免使用覆盖整窗的透明交互层拦截正常点击事件
        .onDrop(of: [.image, .fileURL, .url, .text], isTargeted: $isDropTargeted) { providers in
            self.appState.handleDrop(providers: providers)
            return true
        }
        // 增加高精细度细微边框，且拖拽时显示蓝色高亮边框
        .overlay(
            RoundedRectangle(cornerRadius: shouldHideBorder ? 0 : 12)
                .stroke(isDropTargeted ? Color.blue.opacity(0.8) : (shouldHideBorder ? Color.clear : Color.white.opacity(0.15)), lineWidth: isDropTargeted ? 3 : 1)
        )
        .overlay(alignment: .bottom) {
            if let pdfPageIndicator {
                Text(pdfPageIndicator)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, shouldHideBorder ? 12 : 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pdfPageIndicator)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flashWindow_\(appState.id.uuidString)"))) { _ in
            // 瞬间变白（0.85 不透明度）
            flashOpacity = 0.85
            // 渐变褪去
            withAnimation(.easeOut(duration: 0.4)) {
                flashOpacity = 0.0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfPageDidChange)) { notification in
            guard let targetId = notification.userInfo?["id"] as? UUID,
                  targetId == appState.id,
                  let currentPage = notification.userInfo?["currentPage"] as? Int,
                  let pageCount = notification.userInfo?["pageCount"] as? Int else { return }

            pdfPageIndicator = "\(currentPage)/\(pageCount)"
            pdfPageIndicatorDismissTask?.cancel()
            let dismissTask = DispatchWorkItem {
                withAnimation {
                    pdfPageIndicator = nil
                }
            }
            pdfPageIndicatorDismissTask = dismissTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: dismissTask)
        }
        // 图片模式下：有边框时鼠标双击作用改为和cmd.一样，无边框时双击作用改为和cmd=一样（放大）
        .onTapGesture(count: 2) {
            if appState.imageURL != nil {
                if appState.showBorder {
                    NotificationCenter.default.post(
                        name: .shouldFitImageToWindowWidth,
                        object: nil,
                        userInfo: ["id": appState.id]
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .shouldZoomIn,
                        object: nil,
                        userInfo: ["id": appState.id]
                    )
                }
            }
        }
        // 图片模式继续由 ImageModeView 自己处理捏合缩放；音视频及其余模式仅缩放窗口，不改变内容字号或网页倍率。
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard appState.imageURL == nil || appState.isExternalMediaDocument || appState.webURL != nil else { return }

                    if !isResizingWindowWithPinch {
                        isResizingWindowWithPinch = true
                    }
                    NotificationCenter.default.post(
                        name: .shouldResizeWindowWithPinch,
                        object: nil,
                        userInfo: ["id": appState.id, "magnification": value]
                    )
                }
                .onEnded { _ in
                    guard (appState.imageURL == nil || appState.isExternalMediaDocument || appState.webURL != nil), isResizingWindowWithPinch else { return }

                    NotificationCenter.default.post(
                        name: .shouldEndWindowPinchResize,
                        object: nil,
                        userInfo: ["id": appState.id]
                    )
                    isResizingWindowWithPinch = false
                }
        )
        .contextMenu {
            Toggle(isOn: $appState.isPinned) {
                Label(NSLocalizedString("Toggle Pin (ContextMenu)", comment: ""), systemImage: "pin")
            }
                .keyboardShortcut("t", modifiers: [.command])

            if appState.imageURL != nil || appState.webURL != nil {
                Toggle(isOn: $appState.showBorder) {
                    Label(NSLocalizedString("Border (ContextMenu)", comment: ""), systemImage: "rectangle")
                }
                    .keyboardShortcut("b", modifiers: [.command])
            }

            if appState.imageURL != nil, appState.webURL == nil {
                // 视频/音频没有“拷贝图片”能力
                if !appState.isExternalMediaDocument {
                    Button(action: {
                        appState.copyCurrentImageToPasteboard()
                    }) {
                        Label(NSLocalizedString("Copy Image", comment: ""), systemImage: "photo.on.rectangle")
                    }
                    .keyboardShortcut("c", modifiers: [.command])
                }

                if appState.isSVG {
                    Button(action: {
                        appState.showColorPanel()
                    }) {
                        Label(NSLocalizedString("Select Color", comment: ""), systemImage: "eyedropper")
                    }
                }

                if appState.showBorder {
                    Button(action: {
                        NotificationCenter.default.post(
                            name: .shouldFitWindowToImage,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }) {
                        Label(NSLocalizedString("Fit Window to Image", comment: ""), systemImage: "rectangle.inset.filled")
                    }
                    .keyboardShortcut("[", modifiers: [.command])

                    Button(action: {
                        NotificationCenter.default.post(
                            name: .shouldFitImageToWindowWidth,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }) {
                        Label(NSLocalizedString("Fit Image to Window Width", comment: ""), systemImage: "arrow.left.and.right")
                    }
                    .keyboardShortcut("]", modifiers: [.command])
                }
            }

            Divider()

            Button(action: {
                appState.resetContent()
            }) {
                Label(NSLocalizedString("Reset (ContextMenu)", comment: ""), systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button(action: {
                NotificationCenter.default.post(
                    name: .shouldCloseWindow,
                    object: nil,
                    userInfo: ["id": appState.id]
                )
            }) {
                Label(NSLocalizedString("Close (ContextMenu)", comment: ""), systemImage: "xmark.circle")
            }
            .keyboardShortcut("w", modifiers: [.command])
        }
    }
}
