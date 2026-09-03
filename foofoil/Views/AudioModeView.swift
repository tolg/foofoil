//
//  AudioModeView.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import SwiftUI
import Combine
import AppKit

/// 音频模式：封面按图片方式铺为背景，叠加曲目信息，播放控件与视频一致。
struct AudioModeView: View {
    @ObservedObject var appState: AppState
    let url: URL
    let shouldHideBorder: Bool
    @StateObject private var controller: AudioPlaybackController
    @State private var info: AudioTrackInfo

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: AudioPlaybackController(
            appStateID: appState.id,
            url: url,
            isLooping: appState.shouldLoopCurrentItem,
            range: appState.currentPlaybackRange,
            previousItemAction: { appState.activateMediaListItem(delta: -1) },
            nextItemAction: { appState.activateMediaListItem(delta: 1) }
        ))
        _info = State(initialValue: Self.overlay(AudioTrackInfo.fallback(fileName: url.lastPathComponent), with: appState.fileList?.currentItem?.cue))
    }

    var body: some View {
        AudioPresentationView(
            appState: appState,
            controller: controller,
            info: info,
            shouldHideBorder: shouldHideBorder
        )
        .onAppear {
            controller.isLooping = appState.shouldLoopCurrentItem
            controller.play()
        }
        .onDisappear {
            controller.pause()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        // 播放状态桥接到 appState，导航面板据此驱动“正在播放”图标的动效。
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .onChange(of: presentationID) {
            applyCurrentTrack()
        }
        .onChange(of: appState.shouldLoopCurrentItem) {
            controller.isLooping = appState.shouldLoopCurrentItem
        }
        .task(id: presentationID) {
            info = await loadTrackInfo()
        }
    }

    private var presentationID: String {
        let track = appState.fileList?.currentID ?? ""
        let start = appState.currentPlaybackRange?.startCueFrames ?? 0
        return "\(url.path)|\(track)|\(start)"
    }

    private func applyCurrentTrack() {
        controller.isLooping = appState.shouldLoopCurrentItem
        controller.load(url: url, range: appState.currentPlaybackRange, autoplay: true)
        info = Self.overlay(
            AudioTrackInfo.fallback(fileName: url.lastPathComponent),
            with: appState.fileList?.currentItem?.cue
        )
        Task { info = await loadTrackInfo() }
    }

    /// 读取曲目元数据；无内嵌封面且所在目录未获沙盒授权时向用户请求访问权限后重试，
    /// 成功读取同目录封面则保存文件夹书签，保证重启后仍能显示。
    private func loadTrackInfo() async -> AudioTrackInfo {
        var loaded = await AudioMetadataLoader.load(from: url)
        if loaded.artwork == nil, await appState.requestSidecarCoverAccessIfNeeded(for: url) {
            loaded = await AudioMetadataLoader.load(from: url)
            // 授权后封面才可读：补做窗口尺寸适配与历史缩略图重建
            if loaded.artwork != nil {
                appState.sidecarCoverDidBecomeAvailable()
            }
        }
        if loaded.sidecarCoverURL != nil {
            appState.recordSidecarCoverAccess(for: url)
        }
        return Self.overlay(loaded, with: appState.fileList?.currentItem?.cue)
    }

    /// 箔内展示 CUE 段落元数据，封面与格式信息仍取自音频文件。
    private static func overlay(_ info: AudioTrackInfo, with cue: FileListCueInfo?) -> AudioTrackInfo {
        guard let cue else { return info }
        var merged = info
        if let title = cue.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            merged.title = title
        }
        if let artist = cue.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            merged.artist = artist
        }
        if let album = cue.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            merged.album = album
        }
        if let composer = cue.composer?.trimmingCharacters(in: .whitespacesAndNewlines), !composer.isEmpty {
            merged.composer = composer
        }
        if let genre = cue.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            merged.genre = genre
        }
        if let year = cue.year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
            merged.year = year
        }
        if let trackNumber = cue.trackNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !trackNumber.isEmpty {
            merged.trackNumber = trackNumber
        }
        return merged
    }
}
