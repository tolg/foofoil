import Combine
import FoofoilExtensionKit
import SwiftUI

/// 将扩展的可序列化播放快照适配到宿主通用媒体控制协议。
@MainActor
final class ExtensionAudioPlaybackController: ObservableObject, MediaTransportControlling {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1
    var isScrubbing = false
    let supportsVolumeControl = false
    let supportsPlaybackModeControl = true

    private let appStateID: UUID
    private let command: @MainActor (String) -> Void
    private let seekAction: @MainActor (TimeInterval) -> Void
    private let hasPreviousOrNext: @MainActor () -> Bool
    private let navigateHostList: @MainActor (Int) -> Bool
    private let handlePlaybackCompletion: @MainActor () -> Void
    private var mediaTitle: String
    private var observer: NSObjectProtocol?

    init(appState: AppState, session: ContentSession) {
        appStateID = appState.id
        command = { appState.performExtensionCommand($0) }
        seekAction = { appState.seekExtensionPlayback(to: $0) }
        hasPreviousOrNext = {
            appState.fileList?.isPresentable == true
                || (appState.extensionSession?.playbackQueue?.items.count ?? 0) > 1
        }
        navigateHostList = { appState.activateMediaListItem(delta: $0) }
        handlePlaybackCompletion = {
            if appState.shouldLoopCurrentItem {
                appState.performExtensionCommand("hifi.play")
            } else {
                appState.advanceFileListAfterPlayback()
            }
        }
        mediaTitle = Self.title(for: session)
        apply(session: session)
        observer = NotificationCenter.default.addObserver(
            forName: .shouldToggleVideoPlayback,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                self.togglePlayPause()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var volumeIconName: String { "speaker.wave.3.fill" }

    func apply(session: ContentSession) {
        let wasPlaying = isPlaying
        mediaTitle = Self.title(for: session)
        guard let playback = session.mediaPlayback else { return }
        isPlaying = playback.state == .playing
        if !isScrubbing { currentTime = playback.position }
        duration = playback.duration ?? 0
        MediaRemoteCommandCoordinator.shared.update(self, title: mediaTitle)
        if wasPlaying,
           playback.state == .stopped,
           duration > 0,
           currentTime >= duration - 0.05 {
            let completion = handlePlaybackCompletion
            Task { @MainActor in completion() }
        }
    }

    func activateRemoteCommands() {
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
    }

    func play() {
        command("hifi.play")
        isPlaying = true
        activateRemoteCommands()
    }

    func pause() {
        command("hifi.pause")
        isPlaying = false
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func togglePlayPause() { isPlaying ? pause() : play() }
    func toggleMute() {}
    func setVolume(_ newValue: Float) {}
    func adjustVolume(by delta: Float) {}

    func seek(to time: Double) {
        let clamped = min(duration, max(0, time))
        currentTime = clamped
        seekAction(clamped)
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func adjustTime(by delta: Double) {
        guard duration > 0 else { return }
        seek(to: currentTime + delta)
    }

    func playPreviousItem() -> Bool {
        guard hasPreviousOrNext() else { return false }
        if navigateHostList(-1) { return true }
        command("hifi.previous")
        return true
    }

    func playNextItem() -> Bool {
        guard hasPreviousOrNext() else { return false }
        if navigateHostList(1) { return true }
        command("hifi.next")
        return true
    }

    private static func title(for session: ContentSession) -> String {
        if let queue = session.playbackQueue,
           let currentID = queue.currentItemID,
           let item = queue.items.first(where: { $0.id == currentID }) {
            return item.title
        }
        return session.request.primaryFileURL?.deletingPathExtension().lastPathComponent ?? ""
    }
}

/// Hi-Fi 扩展仅负责播放；视觉、交互、封面与快捷键全部复用宿主音频模式。
struct ExtensionAudioModeView: View {
    @ObservedObject var appState: AppState
    let shouldHideBorder: Bool
    @StateObject private var controller: ExtensionAudioPlaybackController
    @State private var info: AudioTrackInfo

    init(appState: AppState, session: ContentSession, shouldHideBorder: Bool) {
        self.appState = appState
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: ExtensionAudioPlaybackController(appState: appState, session: session))
        let url = Self.currentURL(in: session)
        _info = State(initialValue: AudioTrackInfo.fallback(fileName: url?.lastPathComponent ?? ""))
    }

    var body: some View {
        AudioPresentationView(
            appState: appState,
            controller: controller,
            info: info,
            shouldHideBorder: shouldHideBorder
        )
        .overlay(alignment: .topTrailing) {
            statusOverlay
        }
        .onAppear {
            appState.isMediaPlaybackControlsVisible = !controller.isPlaying || appState.isPointerInsideWindow
            controller.activateRemoteCommands()
            controller.play()
        }
        .onDisappear {
            controller.pause()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        .onReceive(appState.$extensionSession.compactMap { $0 }) { session in
            guard session.providerID == "audio.hifi" else { return }
            controller.apply(session: session)
        }
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .task(id: presentationID) {
            if let url = appState.currentAudioPresentationURL {
                info = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
            }
            let loaded = await loadTrackInfo()
            guard !Task.isCancelled else { return }
            info = loaded
            NotificationCenter.default.post(
                name: .mediaPresentationSizeDidChange,
                object: nil,
                userInfo: [
                    "id": appState.id,
                    "size": AudioMetadataLoader.presentationSize(for: loaded)
                ]
            )
        }
        .task(id: controller.isPlaying) {
            while controller.isPlaying, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                appState.performExtensionCommand("hifi.status")
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let session = appState.extensionSession {
            VStack(alignment: .trailing, spacing: 6) {
                if let status = session.audioDeviceSelection?.statusDescription, !status.isEmpty {
                    Label(status, systemImage: "hifispeaker.2")
                }
                if session.mediaPlayback?.state == .failed {
                    Label(
                        session.mediaPlayback?.failureMessage
                            ?? NSLocalizedString("Hi-Fi Playback Failed", comment: ""),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .padding(14)
        }
    }

    private var presentationID: String {
        guard let session = appState.extensionSession else { return "" }
        return "\(session.id.uuidString)|\(session.playbackQueue?.currentItemID ?? "")"
    }

    private func loadTrackInfo() async -> AudioTrackInfo {
        guard let session = appState.extensionSession,
              let url = Self.currentURL(in: session) else {
            return AudioTrackInfo.fallback(fileName: "")
        }
        var loaded = await AudioMetadataLoader.load(from: url)
        if loaded.artwork == nil, await appState.requestSidecarCoverAccessIfNeeded(for: url) {
            loaded = await AudioMetadataLoader.load(from: url)
            if loaded.artwork != nil { appState.sidecarCoverDidBecomeAvailable() }
        }
        if loaded.sidecarCoverURL != nil { appState.recordSidecarCoverAccess(for: url) }
        return loaded
    }

    private static func currentURL(in session: ContentSession) -> URL? {
        let resources = session.request.resources
        guard let queue = session.playbackQueue,
              let currentID = queue.currentItemID else {
            return session.request.primaryFileURL
        }
        let sourceIndex = currentID.hasPrefix("file:")
            ? Int(currentID.dropFirst("file:".count))
            : queue.items.firstIndex(where: { $0.id == currentID })
        guard let index = sourceIndex,
              resources.indices.contains(index) else {
            return session.request.primaryFileURL
        }
        return resources[index].url
    }
}
