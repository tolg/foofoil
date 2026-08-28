//
//  AudioPlaybackController.swift
//  foofoil
//
//  Created by tolg on 2026/8/28.
//

import AVFoundation
import Combine
import Foundation

/// 音频按采样点播一段：CUE+FLAC 不能靠 AVPlayer seek，要用 scheduleSegment。
@MainActor
final class AudioPlaybackController: ObservableObject, MediaTransportControlling {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1.0
    var isScrubbing = false
    var isLooping: Bool

    private let appStateID: UUID
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var segmentFrames: AVAudioFrameCount = 0
    private var sampleRate: Double = 44100
    private var scheduledDisplayStart: Double = 0
    private var scheduleGeneration: UInt64 = 0
    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(appStateID: UUID, url: URL, isLooping: Bool, range: MediaPlaybackRange? = nil) {
        self.appStateID = appStateID
        self.isLooping = isLooping
        engine.attach(playerNode)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .shouldToggleVideoPlayback,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                    self.togglePlayPause()
                }
            }
        )
        load(url: url, range: range)
        startProgressTimer()
    }

    deinit {
        progressTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        engine.stop()
    }

    func play() {
        if duration > 0, currentTime >= duration - 0.05 {
            schedule(from: 0, play: true)
            return
        }
        if !playerNode.isPlaying {
            if currentTime > 0 {
                schedule(from: currentTime, play: true)
            } else {
                ensureEngineRunning()
                playerNode.play()
                isPlaying = true
            }
        }
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        refreshCurrentTime()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
    }

    func setVolume(_ newValue: Float) {
        volume = max(0, min(1, newValue))
        if volume > 0, isMuted {
            isMuted = false
        }
        applyVolume()
    }

    var volumeIconName: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 1.0 / 3.0 { return "speaker.fill" }
        if volume < 2.0 / 3.0 { return "speaker.wave.1.fill" }
        if volume < 1.0 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func seek(to time: Double) {
        let clamped = min(duration, max(0, time))
        currentTime = clamped
        schedule(from: clamped, play: isPlaying || playerNode.isPlaying)
    }

    func adjustTime(by delta: Double) {
        guard duration > 0 else { return }
        seek(to: min(duration, max(0, currentTime + delta)))
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func load(url: URL, range: MediaPlaybackRange? = nil) {
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate > 0
                ? file.processingFormat.sampleRate
                : file.fileFormat.sampleRate
            reconnect(format: file.processingFormat)

            let total = file.length
            let start = range.map { CueTime.sampleFrame(cueFrames: $0.startCueFrames, sampleRate: sampleRate) } ?? 0
            let end: Int64
            if let endFrames = range?.endCueFrames {
                end = CueTime.sampleFrame(cueFrames: endFrames, sampleRate: sampleRate)
            } else {
                end = total
            }
            startFrame = max(0, min(start, total))
            let last = max(startFrame, min(end, total))
            segmentFrames = AVAudioFrameCount(max(0, last - startFrame))
            duration = sampleRate > 0 ? Double(segmentFrames) / sampleRate : 0
            currentTime = 0
            schedule(from: 0, play: true)
        } catch {
            NSLog("AudioPlaybackController failed to open \(url.path): \(error.localizedDescription)")
            audioFile = nil
            duration = 0
            currentTime = 0
        }
    }

    private func reconnect(format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        applyVolume()
    }

    private func schedule(from displayTime: Double, play: Bool) {
        guard let file = audioFile, segmentFrames > 0, sampleRate > 0 else { return }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let offset = AVAudioFramePosition((max(0, displayTime) * sampleRate).rounded())
        let localStart = min(max(0, offset), AVAudioFramePosition(segmentFrames))
        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(segmentFrames) - localStart))
        playerNode.stop()
        scheduledDisplayStart = Double(localStart) / sampleRate
        currentTime = scheduledDisplayStart
        guard remaining > 0 else {
            handleSegmentEnd()
            return
        }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame + localStart,
            frameCount: remaining,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.handleSegmentEnd()
            }
        }
        if play {
            ensureEngineRunning()
            playerNode.play()
            isPlaying = true
        }
    }

    private func handleSegmentEnd() {
        if isLooping {
            schedule(from: 0, play: true)
            return
        }
        pause()
        currentTime = duration
        NotificationCenter.default.post(
            name: .mediaPlaybackDidFinish,
            object: nil,
            userInfo: ["id": appStateID]
        )
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("AudioPlaybackController engine start failed: \(error.localizedDescription)")
        }
    }

    private func applyVolume() {
        playerNode.volume = isMuted ? 0 : volume
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshCurrentTime()
            }
        }
    }

    private func refreshCurrentTime() {
        guard !isScrubbing, isPlaying, sampleRate > 0 else { return }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = Double(playerTime.sampleTime) / sampleRate
        currentTime = min(duration, max(0, scheduledDisplayStart + elapsed))
    }
}
