//
//  ContentTypesSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/8/27.
//

import SwiftUI

/// 按内容类型分组的设置，包括图片轮播与音视频控制条行为。
struct ContentTypesSettingsView: View {
    @State private var slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
    @State private var mediaControlsAutoHideInterval = SettingsStore.shared.mediaPlaybackControlsAutoHideInterval

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("Slideshow Interval", comment: ""))
                        Spacer()
                        Text(intervalLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $slideshowInterval,
                        in: ImageListSlideshow.minInterval...ImageListSlideshow.maxInterval,
                        step: 1
                    )
                    .accessibilityLabel(NSLocalizedString("Slideshow Interval", comment: ""))
                    .accessibilityValue(intervalLabel)
                }
            } header: {
                Text(NSLocalizedString("Images", comment: ""))
            } footer: {
                Text(NSLocalizedString("Slideshow Interval Footer", comment: ""))
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("Playback Controls Hide Delay", comment: ""))
                        Spacer()
                        Text(mediaControlsIntervalLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $mediaControlsAutoHideInterval,
                        in: MediaPlaybackControlsAutoHide.minInterval...MediaPlaybackControlsAutoHide.maxInterval,
                        step: 1
                    )
                    .accessibilityLabel(NSLocalizedString("Playback Controls Hide Delay", comment: ""))
                    .accessibilityValue(mediaControlsIntervalLabel)
                }
            } header: {
                Text(NSLocalizedString("Audio and Video", comment: ""))
            } footer: {
                Text(NSLocalizedString("Playback Controls Hide Delay Footer", comment: ""))
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
        .onAppear {
            slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
            mediaControlsAutoHideInterval = SettingsStore.shared.mediaPlaybackControlsAutoHideInterval
        }
        .onChange(of: slideshowInterval) { _, value in
            SettingsStore.shared.imageListSlideshowInterval = value
        }
        .onChange(of: mediaControlsAutoHideInterval) { _, value in
            SettingsStore.shared.mediaPlaybackControlsAutoHideInterval = value
        }
    }

    private var intervalLabel: String {
        String(
            format: NSLocalizedString("Slideshow Interval Seconds Format", comment: ""),
            Int(slideshowInterval.rounded())
        )
    }

    private var mediaControlsIntervalLabel: String {
        String(
            format: NSLocalizedString("Playback Controls Hide Delay Seconds Format", comment: ""),
            Int(mediaControlsAutoHideInterval.rounded())
        )
    }
}
