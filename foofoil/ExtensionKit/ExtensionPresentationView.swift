//  ExtensionPresentationView.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import SwiftUI

struct ExtensionPresentationView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            if let session = appState.extensionSession {
                switch session.presentation {
                case .text(let titleKey, let body):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(NSLocalizedString(titleKey, comment: ""), systemImage: "puzzlepiece.extension")
                            .font(.headline)
                        ScrollView {
                            Text(body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if appState.extensionFallbackProviderID != nil {
                            Text(NSLocalizedString("Extension Provider Fallback Notice", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let outputStatus = session.audioDeviceSelection?.statusDescription,
                           !outputStatus.isEmpty {
                            Label(outputStatus, systemImage: "hifispeaker.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(outputStatus)
                        }
                        if let playback = session.mediaPlayback {
                            playbackControls(playback)
                            if playback.state == .failed {
                                Label(
                                    NSLocalizedString("Hi-Fi Playback Failed", comment: ""),
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                case .unavailable(let titleKey, let messageKey):
                    ContentUnavailableView(
                        NSLocalizedString(titleKey, comment: ""),
                        systemImage: "puzzlepiece.extension",
                        description: Text(NSLocalizedString(messageKey, comment: ""))
                    )
                }
            }
        }
        .padding(16)
        .task(id: appState.extensionSession?.mediaPlayback?.state) {
            while appState.extensionSession?.mediaPlayback?.state == .playing,
                  !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                appState.performExtensionCommand("hifi.status")
            }
        }
    }

    @ViewBuilder
    private func playbackControls(_ playback: MediaPlaybackSnapshot) -> some View {
        let isPlaying = playback.state == .playing
        HStack(spacing: 12) {
            Button {
                appState.performExtensionCommand(isPlaying ? "hifi.pause" : "hifi.play")
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(NSLocalizedString(isPlaying ? "Pause" : "Play", comment: ""))

            ProgressView(value: playback.position, total: max(playback.duration ?? 1, 1))
                .accessibilityLabel(NSLocalizedString("Playback Progress", comment: ""))

            Text(playbackTime(playback.position))
                .monospacedDigit()
            if let duration = playback.duration {
                Text("/ \(playbackTime(duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func playbackTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
