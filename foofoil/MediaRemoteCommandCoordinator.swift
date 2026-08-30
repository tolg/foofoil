//
//  MediaRemoteCommandCoordinator.swift
//  foofoil
//
//  Created by tolg on 2026/8/30.
//

import Foundation
import MediaPlayer

/// 进程级媒体命令协调器：系统媒体键只有一组，始终交给最近操作的音视频箔。
@MainActor
final class MediaRemoteCommandCoordinator {
    static let shared = MediaRemoteCommandCoordinator()

    private weak var activeTarget: (any MediaTransportControlling)?
    private var title = ""
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    private init() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { $0.play() }
        register(center.pauseCommand) { $0.pause() }
        register(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        register(center.previousTrackCommand) { target in
            guard target.playPreviousItem() else { return false }
            return true
        }
        register(center.nextTrackCommand) { target in
            guard target.playNextItem() else { return false }
            return true
        }
    }

    func activate(_ target: any MediaTransportControlling, title: String) {
        activeTarget = target
        self.title = title
        updateNowPlayingInfo(for: target)
    }

    func update(_ target: any MediaTransportControlling, title: String? = nil) {
        guard isActive(target) else { return }
        if let title { self.title = title }
        updateNowPlayingInfo(for: target)
    }

    func deactivate(_ target: any MediaTransportControlling) {
        guard isActive(target) else { return }
        activeTarget = nil
        title = ""
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (any MediaTransportControlling) -> Bool = { target in
            target.togglePlayPause()
            return true
        }
    ) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let target = self.activeTarget else { return }
                if action(target) {
                    self.updateNowPlayingInfo(for: target)
                }
            }
            return .success
        }
        commandTargets.append((command, token))
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (any MediaTransportControlling) -> Void
    ) {
        register(command) { target in
            action(target)
            return true
        }
    }

    private func isActive(_ target: any MediaTransportControlling) -> Bool {
        guard let activeTarget else { return false }
        return activeTarget === target
    }

    private func updateNowPlayingInfo(for target: any MediaTransportControlling) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: target.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: target.isPlaying ? 1.0 : 0.0
        ]
        if target.duration.isFinite, target.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = target.duration
        }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = target.isPlaying ? .playing : .paused
    }
}
