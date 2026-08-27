//
//  ContentTypesSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/8/27.
//

import SwiftUI

/// 按内容类型分组的设置；目前先提供图片轮播间隔。
struct ContentTypesSettingsView: View {
    @State private var slideshowInterval = SettingsStore.shared.imageListSlideshowInterval

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
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
        .onAppear {
            slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
        }
        .onChange(of: slideshowInterval) { _, value in
            SettingsStore.shared.imageListSlideshowInterval = value
        }
    }

    private var intervalLabel: String {
        String(
            format: NSLocalizedString("Slideshow Interval Seconds Format", comment: ""),
            Int(slideshowInterval.rounded())
        )
    }
}
