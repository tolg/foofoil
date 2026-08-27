//
//  VideoModeView.swift
//  foofoil
//
//  Created by tolg on 2026/8/20.
//

import SwiftUI
import AVKit
import AVFoundation

/// 使用系统 AVPlayerView 渲染视频画面，关闭自带控件以使用自定义悬浮控制条。
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// 视频模式视图；窗口行为与图片模式一致，鼠标移入时显示播放控件。
struct VideoModeView: View {
    @ObservedObject var appState: AppState
    let url: URL
    let shouldHideBorder: Bool
    @StateObject private var controller: VideoPlayerController
    @State private var isHovering = false

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: VideoPlayerController(appStateID: appState.id, url: url, isLooping: appState.shouldLoopCurrentItem))
    }

    var body: some View {
        ZStack {
            PlayerView(player: controller.player)

            if isHovering {
                // 底部控制条：播放/暂停 + 时间 + 进度条 + 静音 + 播放模式。
                // 整个控制条区域不触发窗口拖动，控制条以外区域拖拽仍可移动窗口。
                VStack {
                    Spacer(minLength: 0)
                    MediaPlaybackBar(appState: appState, controller: controller)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        // 与图片有边框模式保持一致的 8pt 内容边距
        .padding(shouldHideBorder ? 0 : 8)
        .onAppear {
            controller.isLooping = appState.shouldLoopCurrentItem
            controller.play()
        }
        .onDisappear { controller.pause() }
        .onChange(of: url) {
            controller.load(url: url)
        }
        .onChange(of: appState.shouldLoopCurrentItem) {
            controller.isLooping = appState.shouldLoopCurrentItem
        }
    }
}
