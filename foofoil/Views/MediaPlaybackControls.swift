//
//  MediaPlaybackControls.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import SwiftUI
import Combine
import AVFoundation

@MainActor
protocol MediaTransportControlling: ObservableObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var isMuted: Bool { get }
    var volume: Float { get }
    var volumeIconName: String { get }
    var isScrubbing: Bool { get set }
    var supportsVolumeControl: Bool { get }
    var supportsPlaybackModeControl: Bool { get }
    func play()
    func pause()
    func togglePlayPause()
    func toggleMute()
    func setVolume(_ newValue: Float)
    func seek(to time: Double)
    func adjustTime(by delta: Double)
    func adjustVolume(by delta: Float)
    func playPreviousItem() -> Bool
    func playNextItem() -> Bool
}

extension MediaTransportControlling {
    var supportsVolumeControl: Bool { true }
    var supportsPlaybackModeControl: Bool { true }
}

/// 媒体播放状态控制：负责播放器生命周期、进度汇报与播放/暂停切换。视频与音频共用。
@MainActor
final class VideoPlayerController: ObservableObject, MediaTransportControlling {
    let player: AVPlayer
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1.0
    /// 播放到结尾后是否由播放器自己循环当前项；由窗口播放模式同步。
    var isLooping: Bool
    /// 拖动进度条期间屏蔽时间观察者的回写，避免滑块抖动。
    var isScrubbing = false

    private let appStateID: UUID
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var observers: [NSObjectProtocol] = []
    /// CUE 曲目起点，CMTime timescale 75。
    private var rangeStart: CMTime = .zero
    /// CUE 曲目终点；空表示用文件总时长。
    private var rangeEnd: CMTime?
    private var fileDuration: CMTime = .invalid
    private var isHandlingEnd = false
    private var seekGeneration: UInt64 = 0
    private var mediaTitle: String
    private let previousItemAction: @MainActor () -> Bool
    private let nextItemAction: @MainActor () -> Bool

    init(
        appStateID: UUID,
        url: URL,
        isLooping: Bool,
        range: MediaPlaybackRange? = nil,
        previousItemAction: @escaping @MainActor () -> Bool = { false },
        nextItemAction: @escaping @MainActor () -> Bool = { false }
    ) {
        self.appStateID = appStateID
        self.isLooping = isLooping
        self.mediaTitle = url.deletingPathExtension().lastPathComponent
        self.previousItemAction = previousItemAction
        self.nextItemAction = nextItemAction
        self.player = AVPlayer(url: url)
        apply(range)
        loadFileDuration()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: CueTime.timescale),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.handlePlayerTime(time)
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.handleItemEnd()
            }
        })
        // 窗口级空格键事件经通知路由到这里，与 PDF 翻页的处理方式一致。
        observers.append(center.addObserver(forName: .shouldToggleVideoPlayback, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                self.togglePlayPause()
            }
        })

        seek(to: 0)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func play() {
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
        // 已播到结尾时再次播放从头开始。
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0, thenPlay: true)
            return
        }
        let playerTime = player.currentTime()
        if CMTIME_IS_NUMERIC(rangeStart), CMTimeCompare(rangeStart, .zero) > 0 {
            let expected = CMTimeAdd(rangeStart, CMTime(seconds: currentTime, preferredTimescale: CueTime.timescale))
            if CMTIME_IS_NUMERIC(playerTime),
               abs(CMTimeGetSeconds(CMTimeSubtract(playerTime, expected))) > 0.05 {
                seek(to: currentTime, thenPlay: true)
                return
            }
        }
        player.play()
        isPlaying = true
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func pause() {
        player.pause()
        isPlaying = false
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// 静音切换；音量与静音均为运行时状态，不随窗口配置持久化。
    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// 调节音量大小；静音状态下拖起音量时按 macOS 惯例自动解除静音。
    func setVolume(_ newValue: Float) {
        let clamped = max(0, min(1, newValue))
        volume = clamped
        player.volume = clamped
        if clamped > 0, isMuted {
            toggleMute()
        }
    }

    /// 音量图标随静音状态与音量档位变化。
    var volumeIconName: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 1.0 / 3.0 { return "speaker.fill" }
        if volume < 2.0 / 3.0 { return "speaker.wave.1.fill" }
        if volume < 1.0 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func seek(to time: Double) {
        seek(to: time, thenPlay: nil)
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func seek(to time: Double, thenPlay: Bool?) {
        var absolute = CMTimeAdd(
            rangeStart,
            CMTime(seconds: max(0, time), preferredTimescale: CueTime.timescale)
        )
        if let end = effectiveRangeEnd, CMTimeCompare(absolute, end) > 0 {
            absolute = end
        }
        if CMTimeCompare(absolute, rangeStart) < 0 {
            absolute = rangeStart
        }
        currentTime = max(0, CMTimeGetSeconds(CMTimeSubtract(absolute, rangeStart)))
        seekGeneration &+= 1
        let generation = seekGeneration
        player.seek(
            to: absolute,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.seekGeneration == generation, finished else { return }
                if thenPlay == true {
                    self.player.play()
                    self.isPlaying = true
                    MediaRemoteCommandCoordinator.shared.update(self)
                } else if thenPlay == false {
                    self.pause()
                }
                self.isHandlingEnd = false
            }
        }
    }

    /// 滚轮微调播放进度（秒），自动钳制到有效范围。
    func adjustTime(by delta: Double) {
        guard duration > 0 else { return }
        seek(to: min(duration, max(0, currentTime + delta)))
    }

    /// 滚轮微调音量大小，自动钳制到 0...1。
    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func playPreviousItem() -> Bool {
        previousItemAction()
    }

    func playNextItem() -> Bool {
        nextItemAction()
    }

    /// 进度滚轮步进（秒）：触摸板精细滚动小步长，鼠标滚轮整格大步长。
    static func timeScrollStep(deltaY: Double, preciseScrolling: Bool) -> Double {
        deltaY * (preciseScrolling ? 0.2 : 2.0)
    }

    /// 音量滚轮步进（0...1）：触摸板精细滚动小步长，鼠标滚轮整格大步长。
    /// 纵向音量条向上增大；滚轮增量取反，使向上滚动与滑块上移、音量增大一致。
    static func volumeScrollStep(deltaY: Double, preciseScrolling: Bool) -> Float {
        Float(-deltaY) * (preciseScrolling ? 0.005 : 0.05)
    }

    /// 从滚轮事件提取纵向滚动量。
    static func scrollDeltaY(for event: NSEvent) -> Double {
        event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
    }

    /// 播放时间标签：始终输出可读字符串；片长达到小时时，当前时间同样补齐时:分:秒。
    static func formatPlaybackTime(_ seconds: Double, includeHours: Bool = false) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if includeHours || hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// 同一窗口内换片时替换播放内容并自动开始播放。同一文件的 CUE 曲目只切换区间。
    func load(url: URL, range: MediaPlaybackRange? = nil) {
        mediaTitle = url.deletingPathExtension().lastPathComponent
        let currentURL = (player.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            fileDuration = .invalid
            duration = 0
            loadFileDuration()
        }
        apply(range)
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
        seek(to: 0, thenPlay: true)
    }

    func apply(_ range: MediaPlaybackRange?) {
        if let range {
            rangeStart = CueTime.time(range.startCueFrames)
            rangeEnd = range.endCueFrames.map(CueTime.time)
        } else {
            rangeStart = .zero
            rangeEnd = nil
        }
        updateDisplayedDuration()
        updateBoundaryObserver()
    }

    private var effectiveRangeEnd: CMTime? {
        if let rangeEnd, CMTIME_IS_NUMERIC(rangeEnd), CMTimeCompare(rangeEnd, rangeStart) > 0 {
            return rangeEnd
        }
        if CMTIME_IS_NUMERIC(fileDuration), CMTimeCompare(fileDuration, rangeStart) > 0 {
            return fileDuration
        }
        return nil
    }

    private func handlePlayerTime(_ time: CMTime) {
        guard CMTIME_IS_NUMERIC(time) else { return }
        if let end = effectiveRangeEnd, CMTimeCompare(time, end) >= 0 {
            currentTime = duration
            if isPlaying {
                handleItemEnd()
            }
            return
        }
        currentTime = max(0, CMTimeGetSeconds(CMTimeSubtract(time, rangeStart)))
    }

    private func handleItemEnd() {
        guard !isHandlingEnd else { return }
        isHandlingEnd = true
        if isLooping {
            seek(to: 0, thenPlay: true)
        } else {
            pause()
            currentTime = duration
            NotificationCenter.default.post(
                name: .mediaPlaybackDidFinish,
                object: nil,
                userInfo: ["id": appStateID]
            )
            isHandlingEnd = false
        }
    }

    private func updateDisplayedDuration() {
        guard let end = effectiveRangeEnd else { return }
        duration = max(0, CMTimeGetSeconds(CMTimeSubtract(end, rangeStart)))
    }

    private func updateBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        guard let end = effectiveRangeEnd else { return }
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleItemEnd()
            }
        }
    }

    /// 末轨终点用 AVAsset.duration；分轨起点仍是 CUE 的 1/75 秒 CMTime。
    private func loadFileDuration() {
        guard let asset = player.currentItem?.asset else { return }
        Task { [weak self] in
            guard let duration = try? await asset.load(.duration),
                  duration.isNumeric, duration.seconds > 0 else { return }
            self?.fileDuration = duration
            self?.updateDisplayedDuration()
            self?.updateBoundaryObserver()
            if let self {
                MediaRemoteCommandCoordinator.shared.update(self)
            }
        }
    }
}

/// 捕获滚轮事件的 NSSlider：滚轮滚动时按回调换算的增量调节值，其余行为与系统滑块一致。
final class WheelSlider: NSSlider {
    var scrollHandler: ((NSEvent) -> Void)?
    var trackingHandler: ((Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        scrollHandler?(event)
    }

    override func mouseDown(with event: NSEvent) {
        // super.mouseDown 会在内部运行跟踪循环直到鼠标抬起
        trackingHandler?(true)
        super.mouseDown(with: event)
        trackingHandler?(false)
    }
}

/// SwiftUI 包装：支持滚轮调节的滑块，外观与系统 NSSlider 一致（且不会触发窗口背景拖动）。
struct WheelSliderView: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var controlSize: NSControl.ControlSize = .small
    var isVertical: Bool = false
    var onScroll: (NSEvent) -> Void
    var onEditingChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WheelSlider {
        let slider = WheelSlider()
        slider.controlSize = controlSize
        slider.isVertical = isVertical
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.scrollHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.parent.onScroll(event)
        }
        slider.trackingHandler = { [weak coordinator = context.coordinator] editing in
            guard let coordinator else { return }
            coordinator.isTracking = editing
            coordinator.parent.onEditingChanged?(editing)
        }
        return slider
    }

    func updateNSView(_ nsView: WheelSlider, context: Context) {
        context.coordinator.parent = self
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        // 拖动/滚动过程中不回写，避免值抖动
        guard !context.coordinator.isTracking else { return }
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var parent: WheelSliderView
        var isTracking = false

        init(_ parent: WheelSliderView) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: WheelSlider) {
            parent.value = sender.doubleValue
        }
    }
}

/// 捕获滚轮事件的音量图标按钮：点击切换，滚轮调节。
final class WheelVolumeButton: NSButton {
    var scrollHandler: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        scrollHandler?(event)
    }
}

/// SwiftUI 包装：支持滚轮的图标按钮。
struct WheelIconButton: NSViewRepresentable {
    let iconName: String
    var accessibilityTitle: String
    var onClick: () -> Void
    var onScroll: (NSEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WheelVolumeButton {
        let button = WheelVolumeButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked)
        button.scrollHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.parent.onScroll(event)
        }
        // 不同音量档位的图标宽度由 SwiftUI 固定，避免额外 Auto Layout 约束在窗口缩放时冲突。
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return button
    }

    func updateNSView(_ nsView: WheelVolumeButton, context: Context) {
        context.coordinator.parent = self
        nsView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: accessibilityTitle)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        nsView.toolTip = accessibilityTitle
        nsView.setAccessibilityLabel(accessibilityTitle)
    }

    final class Coordinator: NSObject {
        var parent: WheelIconButton

        init(_ parent: WheelIconButton) {
            self.parent = parent
        }

        @objc func clicked() {
            parent.onClick()
        }
    }
}

/// 底部播放控制条：播放/暂停 + 当前时间 + 进度 + 总时长 + 音量 + 播放模式；视频与音频共用。
enum MediaPlaybackBarMetrics {
    /// 单行播放条所需的最小窗口宽度，含时间标签、滑块与按钮，避免音视频窗口缩到控件放不下。
    static let minimumWindowWidth: CGFloat = 380
    /// 悬浮控制条占用的底部空间，供音频元数据避让。
    static let overlayBottomInset: CGFloat = 56
    /// 箔底常显进度线高度；极细但可见。
    static let bottomProgressLineHeight: CGFloat = 2
}

struct MediaPlaybackBar<Controller: MediaTransportControlling>: View {

    @ObservedObject var appState: AppState
    @ObservedObject var controller: Controller
    @State private var isVolumeHovering = false

    var body: some View {
        HStack(spacing: 8) {
            playPauseButton
            elapsedTimeLabel
            progressSlider
            durationLabel
            if controller.supportsVolumeControl {
                volumeControl
            }
            if controller.supportsPlaybackModeControl {
                playbackModeButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(NonMovableBackground())
    }

    private var includeHours: Bool {
        max(controller.duration, controller.currentTime) >= 3600
    }

    private var elapsedTimeLabel: some View {
        playbackTimeLabel(
            controller.currentTime,
            accessibilityKey: "Elapsed Time"
        )
    }

    private var durationLabel: some View {
        playbackTimeLabel(
            controller.duration,
            accessibilityKey: "Duration"
        )
    }

    private func playbackTimeLabel(_ seconds: Double, accessibilityKey: String) -> some View {
        Text(VideoPlayerController.formatPlaybackTime(seconds, includeHours: includeHours))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(NSLocalizedString(accessibilityKey, comment: ""))
            .accessibilityValue(VideoPlayerController.formatPlaybackTime(seconds, includeHours: includeHours))
    }

    private var playPauseButton: some View {
        Button {
            controller.togglePlayPause()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(controller.isPlaying ? "Pause" : "Play", comment: ""))
    }

    private var progressSlider: some View {
        WheelSliderView(
            value: Binding(
                get: { controller.currentTime },
                set: { controller.seek(to: $0) }
            ),
            range: 0...max(controller.duration, controller.currentTime, 0.01),
            controlSize: .small,
            onScroll: { event in
                controller.adjustTime(by: VideoPlayerController.timeScrollStep(
                    deltaY: VideoPlayerController.scrollDeltaY(for: event),
                    preciseScrolling: event.hasPreciseScrollingDeltas
                ))
            },
            onEditingChanged: { editing in
                controller.isScrubbing = editing
            }
        )
        .accessibilityLabel(NSLocalizedString("Playback Progress", comment: ""))
    }

    private var volumeControl: some View {
        // 点击图标切换静音，图标上滚滚轮调节音量；
        // hover 图标时纵向音量滑轨从图标上方向上弹出（占位视图保持控制条布局不变）。
        Color.clear
            .frame(width: 24, height: 20)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if isVolumeHovering {
                        WheelSliderView(
                            value: Binding(
                                get: { Double(controller.volume) },
                                set: { controller.setVolume(Float($0)) }
                            ),
                            range: 0...1,
                            controlSize: .mini,
                            isVertical: true,
                            onScroll: { event in
                                controller.adjustVolume(by: VideoPlayerController.volumeScrollStep(
                                    deltaY: VideoPlayerController.scrollDeltaY(for: event),
                                    preciseScrolling: event.hasPreciseScrollingDeltas
                                ))
                            }
                        )
                        .frame(width: 20, height: 84)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(NSLocalizedString("Volume", comment: ""))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    }

                    WheelIconButton(
                        iconName: controller.volumeIconName,
                        accessibilityTitle: NSLocalizedString(controller.isMuted ? "Unmute" : "Mute", comment: ""),
                        onClick: {
                            controller.toggleMute()
                        },
                        onScroll: { event in
                            controller.adjustVolume(by: VideoPlayerController.volumeScrollStep(
                                deltaY: VideoPlayerController.scrollDeltaY(for: event),
                                preciseScrolling: event.hasPreciseScrollingDeltas
                            ))
                        }
                    )
                    .frame(width: 20, height: 20)
                }
                // hover 覆盖滑轨、间隙与图标，鼠标上下移动不闪烁
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isVolumeHovering = hovering
                    }
                }
            }
    }

    private var playbackModeButton: some View {
        let mode = appState.mediaPlaybackMode
        let title = NSLocalizedString(mode.localizationKey, comment: "")
        return Button {
            appState.cycleMediaPlaybackMode()
        } label: {
            Image(systemName: mode.symbolName)
                .font(.system(size: 13))
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 箔底常显的极细播放进度线；与控制条显隐无关，展示进度信息可在设置中关闭。
struct MediaBottomProgressLine<Controller: MediaTransportControlling>: View {
    @ObservedObject var controller: Controller
    /// 覆盖在深色封面/画面上时改用白色前景，避免随系统外观变成不可见的深色。
    var lightContent = false
    @State private var isEnabled = SettingsStore.shared.showsMediaBottomProgressBar

    private var progress: Double {
        guard controller.duration > 0 else { return 0 }
        return min(max(controller.currentTime / controller.duration, 0), 1)
    }

    var body: some View {
        Group {
            if isEnabled, controller.duration > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(lineColor.opacity(0.18))
                        Capsule()
                            .fill(lineColor.opacity(0.5))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: MediaPlaybackBarMetrics.bottomProgressLineHeight)
                .accessibilityHidden(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showsMediaBottomProgressBarDidChange)) { _ in
            isEnabled = SettingsStore.shared.showsMediaBottomProgressBar
        }
    }

    private var lineColor: Color {
        lightContent ? .white : .primary
    }
}
