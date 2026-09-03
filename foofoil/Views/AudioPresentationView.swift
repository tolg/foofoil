import AppKit
import SwiftUI

/// 宿主统一的音频呈现层。内置解码器和扩展播放器只提供传输状态，封面、元数据与控件均走这里。
struct AudioPresentationView<Controller: MediaTransportControlling>: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: Controller
    let info: AudioTrackInfo
    let shouldHideBorder: Bool

    var body: some View {
        ZStack {
            backgroundLayer

            metadataBlock
                .padding(.horizontal, shouldHideBorder ? 20 : 16)
                .padding(.top, 12)
                .padding(.bottom, appState.isMediaPlaybackControlsVisible ? MediaPlaybackBarMetrics.overlayBottomInset : 12)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: info.artwork == nil ? .center : .bottomLeading
                )
                .clipped()

            if appState.isMediaPlaybackControlsVisible {
                VStack {
                    Spacer(minLength: 0)
                    MediaPlaybackBar(appState: appState, controller: controller)
                }
                .transition(.opacity)
            }

            VStack {
                Spacer(minLength: 0)
                MediaBottomProgressLine(controller: controller, lightContent: info.artwork != nil)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: appState.isMediaPlaybackControlsVisible)
        .padding(shouldHideBorder ? 0 : 8)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let artwork = info.artwork {
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
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
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
                .font(.system(size: 22, weight: .semibold))
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

            if let tertiaryLine {
                Text(tertiaryLine)
                    .font(.system(size: 13))
                    .opacity(0.78)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
            }

            if let technicalLine {
                Text(technicalLine)
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
        joined([info.album, info.year, info.trackNumber.map(AudioMetadataLoader.formatTrackNumber), info.genre])
    }

    private var technicalLine: String? {
        joined([
            info.formatName,
            info.bitRate.map(AudioMetadataLoader.formatBitRate),
            info.sampleRate.map(AudioMetadataLoader.formatSampleRate),
            info.bitDepth.map(AudioMetadataLoader.formatBitDepth),
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
