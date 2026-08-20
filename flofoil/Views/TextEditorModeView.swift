//
//  TextEditorModeView.swift
//  flofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

struct TextEditorModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var textHeight: CGFloat = 40 // 动态高度
    @State private var hoveredConfig: WindowConfig? = nil
    @State private var showRenameAlert = false
    @State private var newTitleText = ""
    @State private var targetRenameConfig: WindowConfig? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 100 || geometry.size.height < 100 {
                Color.clear
            } else {
                let isBlank = appState.imageURL == nil && appState.webURL == nil && appState.textURL == nil && appState.text.isEmpty
                let showTipsAndHistory = geometry.size.height >= 140

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // 编辑器外侧的留白是真实窗口背景，交由 AppKit 原生处理窗口移动。
                        MovableBackground()

                        if appState.isMarkdownPreview && appState.isMarkdownDocument && !appState.text.isEmpty {
                            MarkdownTextView(attributedText: appState.renderedMarkdown, calculatedHeight: $textHeight)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if appState.textURL != nil && !appState.isMarkdownDocument {
                            ReadOnlyTextView(text: appState.text, fontSize: appState.textFontSize)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            CustomTextEditor(
                                text: $appState.text,
                                calculatedHeight: $textHeight,
                                fontSize: appState.textFontSize,
                                shouldMaintainFocus: isBlank
                            )
                                .padding(8)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: appState.text.isEmpty ? nil : .infinity
                                )
                                .frame(height: appState.text.isEmpty ? min(textHeight, max(0, geometry.size.height - 8)) : nil)
                        }
                    }

                    if isBlank && showTipsAndHistory {
                        BlankStateTipCarousel()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 24)
                            // 不接收鼠标事件，保留窗口背景的拖拽行为和输入焦点。
                            .allowsHitTesting(false)
                    } else {
                        // 剩余区域保持为窗口背景，以支持拖动。
                        Spacer(minLength: 0)
                    }

                    if isBlank && showTipsAndHistory {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    let configs = Array(historyManager.historyConfigs.prefix(30))
                                    ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                                        VStack(spacing: 4) {
                                            HistoryCardView(
                                                config: config,
                                                shortcutText: index < 9 && appState.isCommandKeyPressed ? "⌘\(index + 1)" : nil,
                                                action: {
                                                    let isCurrentlyBlank = appState.imageURL == nil && appState.webURL == nil && appState.text.isEmpty
                                                    if isCurrentlyBlank {
                                                        withAnimation(.easeInOut(duration: 0.35)) {
                                                            appState.loadConfig(config)
                                                        }
                                                    } else {
                                                        appState.loadConfig(config)
                                                    }
                                                },
                                                onHoverChanged: { hovering in
                                                    if hovering {
                                                        hoveredConfig = config
                                                    } else if hoveredConfig?.id == config.id {
                                                        hoveredConfig = nil
                                                    }
                                                }
                                            )
                                            .contextMenu {
                                                Button(action: {
                                                    targetRenameConfig = config
                                                    let rawTitle = config.originalImageName ?? config.historyMenuDisplayName
                                                    newTitleText = rawTitle
                                                    showRenameAlert = true
                                                }) {
                                                    Label(NSLocalizedString("Change Title", comment: ""), systemImage: "pencil")
                                                }

                                                Button(action: {
                                                    historyManager.removeFromHistory(config)
                                                }) {
                                                    Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                                }
                                            }

                                            // 预留标题高度，按住 ⌘ 时仅切换透明度，避免布局跳动；复用现有底部 padding 的空间。
                                            Text(config.historyMenuDisplayName)
                                                .font(.system(size: 9, design: .rounded))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(width: 60)
                                                .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                                .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                        }
                                    }
                                    VStack(spacing: 4) {
                                        SearchHistoryCard(shortcutText: appState.isCommandKeyPressed ? "⌘P" : nil) {
                                            HistorySearchWindowController.shared.show()
                                        }
                                        Text(NSLocalizedString("Search History", comment: ""))
                                            .font(.system(size: 9, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 60)
                                            .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                            .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 8)
                            }

                            Group {
                                if let config = hoveredConfig {
                                    let title = config.historyMenuDisplayName
                                    let url = config.actualWebURLString ?? config.webURLString
                                    HStack(spacing: 4) {
                                        Image(systemName: config.historyMenuSymbolName)
                                        if let url = url {
                                            Text("\(title) (\(url))")
                                        } else {
                                            Text(title)
                                        }
                                    }
                                } else {
                                    Text(" ")
                                }
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .frame(height: 14)
                        }
                        .background(NonMovableBackground())
                    }
                }
            }
        }
        .alert(NSLocalizedString("Change Title", comment: ""), isPresented: $showRenameAlert) {
            TextField(NSLocalizedString("Change Title", comment: ""), text: $newTitleText)
            Button(NSLocalizedString("OK", comment: "")) {
                if let config = targetRenameConfig {
                    historyManager.updateHistoryTitle(configId: config.id, newTitle: newTitleText)
                }
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                targetRenameConfig = nil
            }
        } message: {
            Text("")
        }
        // 暗色/亮色切换时重新生成 markdown 富文本，使颜色跟随系统外观
        .onChange(of: colorScheme) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
    }
}

private struct SearchHistoryCard: View {
    let shortcutText: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(hovered ? 1 : 0.95))
                Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let shortcutText {
                    Text(shortcutText).font(.system(size: 10, weight: .bold)).padding(4)
                }
            }.frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(NSLocalizedString("Search History", comment: ""))
    }
}
