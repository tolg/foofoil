//
//  AudioModeView.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import SwiftUI
import AppKit

/// 音频模式：封面按图片方式铺为背景，叠加曲目信息，播放控件与视频一致。
struct AudioModeView: View {
    @ObservedObject var appState: AppState
    let url: URL
    let shouldHideBorder: Bool
    @StateObject private var controller: VideoPlayerController
    @State private var isHovering = false
    @State private var info: AudioTrackInfo

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: VideoPlayerController(appStateID: appState.id, url: url, isLooping: appState.isVideoLooping))
        _info = State(initialValue: AudioTrackInfo.fallback(fileName: url.lastPathComponent))
    }

    var body: some View {
        ZStack {
            backgroundLayer

            // 元数据随窗口压缩裁剪，避免矮窗口时与播放条抢高度导致布局崩溃。
            metadataBlock
                .padding(.horizontal, shouldHideBorder ? 20 : 16)
                .padding(.top, 12)
                .padding(.bottom, isHovering ? MediaPlaybackBar.overlayBottomInset : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: info.artwork == nil ? .center : .bottomLeading)
                .clipped()

            if isHovering {
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
        .padding(shouldHideBorder ? 0 : 8)
        .onAppear { controller.play() }
        .onDisappear { controller.pause() }
        .onChange(of: url) {
            controller.load(url: url)
            info = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
            Task { info = await AudioMetadataLoader.load(from: url) }
        }
        .onChange(of: appState.isVideoLooping) {
            controller.isLooping = appState.isVideoLooping
        }
        .task(id: url) {
            info = await AudioMetadataLoader.load(from: url)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let artwork = info.artwork {
            // 封面作为背景：无边框铺满裁剪，有边框等比完整显示，与图片模式一致。
            ZStack {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: shouldHideBorder ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(false)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.18), location: 0),
                        .init(color: .black.opacity(0.08), location: 0.42),
                        .init(color: .black.opacity(0.72), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor),
                        Color(nsColor: .windowBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 280, height: 280)
                    .blur(radius: 40)
                    .offset(x: -40, y: -80)
            }
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if info.artwork == nil {
                artworkPlaceholder
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }

            Text(info.title)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .lineLimit(2)
                .multilineTextAlignment(info.artwork == nil ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)

            if let artist = info.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.92)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
            }

            if let tertiary = tertiaryLine {
                Text(tertiary)
                    .font(.system(size: 13, weight: .regular))
                    .opacity(0.78)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
            }

            if let technical = technicalLine {
                Text(technical)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(info.artwork == nil ? Color.primary : Color.white)
        .shadow(color: info.artwork == nil ? .clear : .black.opacity(0.35), radius: 6, y: 1)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.quaternary)
                .frame(width: 148, height: 148)
            Image(systemName: "music.note")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var tertiaryLine: String? {
        joined([
            info.album,
            info.year,
            info.trackNumber.map(AudioMetadataLoader.formatTrackNumber),
            info.genre
        ])
    }

    private var technicalLine: String? {
        joined([
            info.formatName,
            info.bitRate.map(AudioMetadataLoader.formatBitRate),
            info.sampleRate.map(AudioMetadataLoader.formatSampleRate),
            info.channelCount.map(AudioMetadataLoader.formatChannels),
            AudioMetadataLoader.formatDuration(controller.duration)
        ])
    }

    private func joined(_ parts: [String?]) -> String? {
        let values = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "  ·  ")
    }
}
