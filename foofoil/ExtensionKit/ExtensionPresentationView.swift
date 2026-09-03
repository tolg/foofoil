//  ExtensionPresentationView.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import FoofoilExtensionKit
import SwiftUI

struct ExtensionPresentationView: View {
    @ObservedObject var appState: AppState
    let shouldHideBorder: Bool

    var body: some View {
        Group {
            if let session = appState.extensionSession {
                if session.providerID == "audio.hifi", session.mediaPlayback != nil {
                    ExtensionAudioModeView(
                        appState: appState,
                        session: session,
                        shouldHideBorder: shouldHideBorder
                    )
                } else {
                    genericPresentation(session)
                        .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func genericPresentation(_ session: ContentSession) -> some View {
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
                    playbackControls(playback, hasQueue: (session.playbackQueue?.items.count ?? 0) > 1)
                    if playback.state == .failed {
                        Label(
                            NSLocalizedString(
                                playback.failureMessage ?? "Hi-Fi Playback Failed",
                                comment: ""
                            ),
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

    @ViewBuilder
    private func playbackControls(_ playback: MediaPlaybackSnapshot, hasQueue: Bool) -> some View {
        let isPlaying = playback.state == .playing
        HStack(spacing: 12) {
            if hasQueue {
                Button { appState.performExtensionCommand("hifi.previous") } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Previous", comment: ""))
            }
            Button {
                appState.performExtensionCommand(isPlaying ? "hifi.pause" : "hifi.play")
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(NSLocalizedString(isPlaying ? "Pause" : "Play", comment: ""))

            if hasQueue {
                Button { appState.performExtensionCommand("hifi.next") } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Next", comment: ""))
            }

            if playback.isSeekable, let duration = playback.duration {
                ExtensionPlaybackSlider(
                    position: playback.position,
                    duration: duration,
                    onSeek: appState.seekExtensionPlayback(to:)
                )
            } else {
                ProgressView(value: playback.position, total: max(playback.duration ?? 1, 1))
                    .accessibilityLabel(NSLocalizedString("Playback Progress", comment: ""))
            }

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

private struct ExtensionPlaybackSlider: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var pendingPosition: TimeInterval = 0
    @State private var isEditing = false

    var body: some View {
        Slider(
            value: $pendingPosition,
            in: 0...max(duration, 0.001),
            onEditingChanged: { editing in
                isEditing = editing
                if !editing { onSeek(pendingPosition) }
            }
        )
        .accessibilityLabel(NSLocalizedString("Playback Progress", comment: ""))
        .onAppear { pendingPosition = min(position, duration) }
        .onChange(of: position) { _, newValue in
            if !isEditing { pendingPosition = min(newValue, duration) }
        }
    }
}
