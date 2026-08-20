//
//  VideoModeView.swift
//  flofoil
//
//  Created by tolg on 2026/8/20.
//

import SwiftUI
import Combine
import AVKit
import AVFoundation

/// 视频播放状态控制：负责播放器生命周期、进度汇报与播放/暂停切换。
@MainActor
final class VideoPlayerController: ObservableObject {
    let player: AVPlayer
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1.0
    /// 播放到结尾后是否循环播放；由窗口状态同步，默认开启。
    var isLooping: Bool
    /// 拖动进度条期间屏蔽时间观察者的回写，避免滑块抖动。
    var isScrubbing = false

    private let appStateID: UUID
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []

    init(appStateID: UUID, url: URL, isLooping: Bool) {
        self.appStateID = appStateID
        self.isLooping = isLooping
        self.player = AVPlayer(url: url)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                if self.isLooping {
                    // 循环播放：回到片头继续播放
                    self.player.seek(to: .zero)
                    self.currentTime = 0
                    self.player.play()
                } else {
                    self.isPlaying = false
                }
            }
        })
        // 窗口级空格键事件经通知路由到这里，与 PDF 翻页的处理方式一致。
        observers.append(center.addObserver(forName: .shouldToggleVideoPlayback, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                self.togglePlayPause()
            }
        })

        loadDuration()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func play() {
        // 已播到结尾时再次播放从头开始。
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
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
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
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

    /// 进度滚轮步进（秒）：触摸板精细滚动小步长，鼠标滚轮整格大步长。
    static func timeScrollStep(deltaY: Double, preciseScrolling: Bool) -> Double {
        deltaY * (preciseScrolling ? 0.2 : 2.0)
    }

    /// 音量滚轮步进（0...1）：触摸板精细滚动小步长，鼠标滚轮整格大步长。
    static func volumeScrollStep(deltaY: Double, preciseScrolling: Bool) -> Float {
        Float(deltaY) * (preciseScrolling ? 0.005 : 0.05)
    }

    /// 从滚轮事件提取纵向滚动量。
    static func scrollDeltaY(for event: NSEvent) -> Double {
        event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
    }

    /// 同一窗口内换片时替换播放内容并自动开始播放。
    func load(url: URL) {
        guard (player.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = 0
        duration = 0
        loadDuration()
        play()
    }

    private func loadDuration() {
        guard let asset = player.currentItem?.asset else { return }
        Task { [weak self] in
            guard let duration = try? await asset.load(.duration),
                  duration.isNumeric, duration.seconds > 0 else { return }
            self?.duration = duration.seconds
        }
    }
}

/// 使用系统 AVPlayerView 渲染视频画面，关闭自带控件以使用自定义悬浮控制条。
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// 捕获滚轮事件的 NSSlider：滚轮滚动时按回调换算的增量调节值，其余行为与系统滑块一致。
private final class WheelSlider: NSSlider {
    var scrollHandler: ((NSEvent) -> Void)?
    var trackingHandler: ((Bool) -> Void)?
    /// 值镜像开关：纵向滑块在 SwiftUI 宿主中方向固定为上小下大，开启后显示值按范围镜像，恢复上=大、下=小。
    var isValueInverted = false

    /// 视图显示值与外部绑定值之间的换算（镜像时关于范围中点对称）。
    func displayValue(for value: Double) -> Double {
        isValueInverted ? (minValue + maxValue - value) : value
    }

    func externalValue(for displayedValue: Double) -> Double {
        isValueInverted ? (minValue + maxValue - displayedValue) : displayedValue
    }

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
private struct WheelSliderView: NSViewRepresentable {
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
        slider.isValueInverted = isVertical
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = slider.displayValue(for: value)
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
        let displayValue = nsView.displayValue(for: value)
        if abs(nsView.doubleValue - displayValue) > 0.0001 {
            nsView.doubleValue = displayValue
        }
    }

    final class Coordinator: NSObject {
        var parent: WheelSliderView
        var isTracking = false

        init(_ parent: WheelSliderView) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: WheelSlider) {
            parent.value = sender.externalValue(for: sender.doubleValue)
        }
    }
}

/// 捕获滚轮事件的音量图标按钮：点击切换，滚轮调节。
private final class WheelVolumeButton: NSButton {
    var scrollHandler: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        scrollHandler?(event)
    }
}

/// SwiftUI 包装：支持滚轮的图标按钮。
private struct WheelIconButton: NSViewRepresentable {
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
        // 不同音量档位的图标宽度不同；固定占位宽度，避免切换图标时控制条布局跳动
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
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

/// 视频模式视图；窗口行为与图片模式一致，鼠标移入时显示播放控件。
struct VideoModeView: View {
    @ObservedObject var appState: AppState
    let url: URL
    let shouldHideBorder: Bool
    @StateObject private var controller: VideoPlayerController
    @State private var isHovering = false
    @State private var isVolumeHovering = false

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: VideoPlayerController(appStateID: appState.id, url: url, isLooping: appState.isVideoLooping))
    }

    var body: some View {
        ZStack {
            PlayerView(player: controller.player)

            if isHovering {
                // 底部单行控制条：播放/暂停 + 进度条 + 静音 + 循环开关；
                // 整个控制条区域不触发窗口拖动，控制条以外区域拖拽仍可移动窗口。
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
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

                        // 进度条：可拖动，滚轮前后滚动调节播放进度
                        WheelSliderView(
                            value: Binding(
                                get: { controller.currentTime },
                                set: { controller.seek(to: $0) }
                            ),
                            range: 0...max(controller.duration, 0.01),
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

                        // 音量控制：点击图标切换静音，图标上滚滚轮调节音量；
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
                                    .frame(height: 20)
                                }
                                // hover 覆盖滑轨、间隙与图标，鼠标上下移动不闪烁
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        isVolumeHovering = hovering
                                    }
                                }
                            }

                        Button {
                            appState.isVideoLooping.toggle()
                        } label: {
                            Image(systemName: "repeat")
                                .font(.system(size: 13))
                                .frame(width: 20)
                                // 循环开启时用强调色高亮，关闭时置灰
                                .foregroundStyle(appState.isVideoLooping ? Color.accentColor : Color.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("Loop Playback", comment: ""))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .background(NonMovableBackground())
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
        // 与图片有边框模式保持一致的 8pt 内容边距
        .padding(shouldHideBorder ? 0 : 8)
        .onAppear { controller.play() }
        .onDisappear { controller.pause() }
        .onChange(of: url) {
            controller.load(url: url)
        }
        // 右键菜单或控制条上的循环开关变化时同步到播放器
        .onChange(of: appState.isVideoLooping) {
            controller.isLooping = appState.isVideoLooping
        }
    }
}
