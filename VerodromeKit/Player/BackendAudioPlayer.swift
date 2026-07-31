import Foundation
import Combine
import AVFoundation
import AudioStreaming
import UIKit

@MainActor
public final class BackendAudioPlayer: NSObject, ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    public var isOfflineMode = false
    public var onTrackFinished: (() -> Void)?
    public var onProgress: ((TimeInterval, TimeInterval) -> Void)?

    private let streamingPlayer: AudioStreaming.AudioPlayer
    private let urlProvider: any StreamURLProviding
    private let cache: any PlayableFileCaching
    private let eqUnit = AVAudioUnitEQ(numberOfBands: 10)
    private var equalizerAttached = false
    private var equalizerEnabled = false
    private var replayGainEnabled = false
    private var replayGainDb: Float = 0
    private var progressTimer: Timer?
    private var crossfadeSeconds: Double = 0
    private var gaplessEnabled = true
    private var pendingNextURL: URL?
    private var isCrossfading = false
    /// Absolute string of the URL currently intended to play. Finish callbacks for other
    /// entries (e.g. the track we just skipped away from) are ignored — matches Amperfy.
    private var currentPlayURL: String = ""
    /// Set while intentionally replacing/stopping audio so finish callbacks don't advance.
    private var ignoreFinishCallbacks = false

    private static let bandFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    public init(urlProvider: any StreamURLProviding, cache: any PlayableFileCaching) {
        self.urlProvider = urlProvider
        self.cache = cache
        // Start sooner than AudioStreaming's 1s default; keep underrun recovery modest
        // so a brief network blip doesn't stall playback for 7 seconds.
        self.streamingPlayer = AudioStreaming.AudioPlayer(
            configuration: AudioPlayerConfiguration(
                flushQueueOnSeek: true,
                bufferSizeInSeconds: 10,
                secondsRequiredToStartPlaying: 0.35,
                gracePeriodAfterSeekInSeconds: 0.5,
                secondsRequiredToStartPlayingAfterBufferUnderrun: 2,
                enableLogs: false
            )
        )
        super.init()
        streamingPlayer.delegate = self
        configureEQBands()
        // Keep EQ in the graph (Amperfy-style). Bands are bypassed until enabled.
        attachEqualizerIfNeeded()
        setEqualizerEnabled(false)
    }

    public func configure(
        equalizerEnabled: Bool,
        replayGainEnabled: Bool,
        equalizerBands: [Float] = Array(repeating: 0, count: 10),
        gaplessEnabled: Bool = true,
        crossfadeSeconds: Double = 0
    ) {
        self.replayGainEnabled = replayGainEnabled
        self.gaplessEnabled = gaplessEnabled
        self.crossfadeSeconds = max(0, crossfadeSeconds)
        applyEqualizerBands(equalizerBands)
        applyGlobalGain()
        setEqualizerEnabled(equalizerEnabled)
    }

    /// Engine-level single-track loop. Prefer this over gapless-next when repeating one.
    public func setRepeatOne(_ enabled: Bool) {
        streamingPlayer.loopMode = enabled ? .single(times: nil) : .off
        if enabled {
            clearPendingNext()
        }
    }

    public func clearPendingNext() {
        pendingNextURL = nil
        isCrossfading = false
    }

    public func setEqualizerBands(_ bands: [Float]) {
        applyEqualizerBands(bands)
        // Ensure the node is live when the user adjusts bands from the player UI.
        if equalizerEnabled {
            attachEqualizerIfNeeded()
            for i in 0..<eqUnit.bands.count {
                eqUnit.bands[i].bypass = false
            }
        }
    }

    public func setEqualizerEnabled(_ enabled: Bool) {
        equalizerEnabled = enabled
        attachEqualizerIfNeeded()
        for i in 0..<eqUnit.bands.count {
            eqUnit.bands[i].bypass = !enabled
        }
    }

    public func setReplayGain(db: Float) {
        replayGainDb = db
        applyGlobalGain()
    }

    public func play(item: QueueItem, maxBitrate: Int, format: StreamFormat) async throws {
        PlayTrace.mark("BackendAudioPlayer.play enter", details: "id=\(item.playableId) title=\(item.title) bitrate=\(maxBitrate) format=\(format)")
        let url: URL
        var source = "stream"
        var cachedPlayable: (id: String, kind: PlayableRef.Kind)?
        if let direct = item.directStreamURL {
            url = direct
            source = "direct"
            PlayTrace.mark("URL resolved (direct)", details: url.absoluteString)
        } else if let local = cache.fileURL(forPlayableId: item.playableId, kind: item.kind) {
            url = local
            source = "cache"
            cachedPlayable = (item.playableId, item.kind)
            PlayTrace.mark("URL resolved (cache)", details: url.lastPathComponent)
        } else {
            if isOfflineMode { throw BackendError.network("Offline and track not cached") }
            PlayTrace.mark("resolving stream URL…")
            url = try await urlProvider.streamURL(forPlayableId: item.playableId, maxBitrate: maxBitrate, format: format)
            PlayTrace.mark("URL resolved (stream)", details: url.host ?? url.absoluteString)
        }
        pendingNextURL = nil
        isCrossfading = false
        streamingPlayer.volume = 1
        // Mark the intended entry before replacing audio so the previous track's
        // finish callback (stopReason .none / .userAction) cannot advance the queue.
        ignoreFinishCallbacks = true
        currentPlayURL = url.absoluteString
        PlayTrace.mark("streamingPlayer.play(url:) call", details: "source=\(source)")
        streamingPlayer.play(url: url)
        ignoreFinishCallbacks = false
        duration = item.isLiveStream ? 0 : item.duration
        currentTime = 0
        isPlaying = true
        startProgressTimer()
        PlayTrace.mark("streamingPlayer.play returned (buffering may still be in progress)")
        // Touch cache after play starts so disk meta writes don't delay first audio.
        if let cachedPlayable {
            cache.touchPlayable(id: cachedPlayable.id, kind: cachedPlayable.kind, reason: nil)
            PlayTrace.mark("cache.touchPlayable done")
        }
    }

    public func preloadNext(item: QueueItem, maxBitrate: Int, format: StreamFormat) async {
        guard gaplessEnabled || crossfadeSeconds > 0 else { return }
        do {
            let url: URL
            if let local = cache.fileURL(forPlayableId: item.playableId, kind: item.kind) {
                url = local
            } else if !isOfflineMode {
                url = try await urlProvider.streamURL(forPlayableId: item.playableId, maxBitrate: maxBitrate, format: format)
            } else {
                return
            }
            pendingNextURL = url
            if gaplessEnabled && crossfadeSeconds <= 0 {
                streamingPlayer.queue(url: url)
            }
        } catch {}
    }

    public func pause() {
        streamingPlayer.pause()
        isPlaying = false
    }

    public func resume() {
        streamingPlayer.resume()
        isPlaying = true
        startProgressTimer()
    }

    public func stop() {
        ignoreFinishCallbacks = true
        currentPlayURL = ""
        streamingPlayer.stop()
        ignoreFinishCallbacks = false
        isPlaying = false
        currentTime = 0
        stopProgressTimer()
    }

    public func seek(to seconds: TimeInterval) {
        streamingPlayer.seek(to: seconds)
        currentTime = seconds
    }

    private func configureEQBands() {
        for i in 0..<eqUnit.bands.count {
            eqUnit.bands[i].bypass = false
            eqUnit.bands[i].filterType = .parametric
            eqUnit.bands[i].frequency = Self.bandFrequencies[min(i, Self.bandFrequencies.count - 1)]
            eqUnit.bands[i].bandwidth = 0.5
            eqUnit.bands[i].gain = 0
        }
    }

    private func applyEqualizerBands(_ bands: [Float]) {
        for i in 0..<min(bands.count, eqUnit.bands.count) {
            eqUnit.bands[i].gain = max(-12, min(12, bands[i]))
        }
    }

    private func applyGlobalGain() {
        let gain = replayGainEnabled ? replayGainDb : 0
        eqUnit.globalGain = max(-24, min(24, gain))
    }

    private func attachEqualizerIfNeeded() {
        guard !equalizerAttached else { return }
        streamingPlayer.attach(node: eqUnit)
        equalizerAttached = true
    }

    private func detachEqualizerIfNeeded() {
        guard equalizerAttached else { return }
        streamingPlayer.detach(node: eqUnit)
        equalizerAttached = false
    }

    private func startProgressTimer() {
        stopProgressTimer()
        // Target-action on the main run loop ticks even when Swift concurrency is
        // backed up — `Task { @MainActor }` was leaving the clock frozen at 0:00.
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(handleProgressTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    @objc private func handleProgressTimer() {
        tickProgress()
    }

    private func tickProgress() {
        let progress = streamingPlayer.progress
        let dur = streamingPlayer.duration
        // AudioStreaming reports `progress == 0` while `pendingNext` or briefly during
        // seek setup. Do not snap the UI clock back to 0:00 while audio is playing.
        if progress.isFinite {
            let looksLikeTransientZero = progress == 0 && isPlaying && currentTime > 1
            if !looksLikeTransientZero, abs(progress - currentTime) >= 0.05 {
                currentTime = progress
            }
        }
        if dur.isFinite, dur > 0, abs(dur - duration) >= 0.05 {
            duration = dur
        }
        onProgress?(currentTime, duration)
        maybeStartCrossfade()
    }

    private func maybeStartCrossfade() {
        guard crossfadeSeconds > 0, !isCrossfading, duration > 0 else { return }
        let remaining = duration - currentTime
        guard remaining <= crossfadeSeconds, remaining > 0 else { return }
        isCrossfading = true
        if let next = pendingNextURL {
            fadeVolume(to: 0, duration: crossfadeSeconds) { [weak self] in
                guard let self else { return }
                self.streamingPlayer.play(url: next)
                self.streamingPlayer.volume = 0
                self.fadeVolume(to: 1, duration: max(self.crossfadeSeconds * 0.5, 0.1), completion: nil)
            }
        }
    }

    private func fadeVolume(to target: Float, duration: Double, completion: (() -> Void)?) {
        let steps = max(Int(duration / 0.05), 1)
        let start = streamingPlayer.volume
        let delta = (target - start) / Float(steps)
        final class StepBox { var value = 0 }
        let step = StepBox()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                step.value += 1
                self.streamingPlayer.volume = start + delta * Float(step.value)
                if step.value >= steps {
                    timer.invalidate()
                    self.streamingPlayer.volume = target
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

extension BackendAudioPlayer: AudioPlayerDelegate {
    public nonisolated func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        PlayTrace.mark("AudioStreaming didStartPlaying", details: entryId.id)
        PlayTrace.end("first audio audible / didStartPlaying")
        Task { @MainActor in
            self.isPlaying = true
            self.startProgressTimer()
        }
    }

    public nonisolated func audioPlayerDidFinishBuffering(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {}

    public nonisolated func audioPlayerStateChanged(
        player: AudioStreaming.AudioPlayer,
        with newState: AudioPlayerState,
        previous: AudioPlayerState
    ) {
        Task { @MainActor in
            switch newState {
            case .playing, .running:
                PlayTrace.mark("AudioStreaming state → \(String(describing: newState))")
                self.isPlaying = true
            case .paused, .stopped, .disposed, .error:
                PlayTrace.mark("AudioStreaming state → \(String(describing: newState))")
                self.isPlaying = false
            case .bufferring, .ready:
                PlayTrace.mark("AudioStreaming state → \(String(describing: newState))")
            @unknown default:
                break
            }
        }
    }

    public nonisolated func audioPlayerDidFinishPlaying(
        player: AudioStreaming.AudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    ) {
        Task { @MainActor in
            // Only natural end-of-track advances the queue. Skip / replace / stop
            // report .userAction or .none and must not call onTrackFinished — that
            // was causing infinite skip loops.
            guard stopReason == .eof else { return }
            guard !self.ignoreFinishCallbacks else { return }
            guard !self.currentPlayURL.isEmpty, entryId.id == self.currentPlayURL else { return }
            self.currentPlayURL = ""
            self.onTrackFinished?()
        }
    }

    public nonisolated func audioPlayerUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        Task { @MainActor in
            self.isPlaying = false
            // Don't auto-advance on error here — AudioPlayer decides.
        }
    }

    public nonisolated func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {
        Task { @MainActor in
            // Cancelled queued items are expected when replacing tracks.
        }
    }

    public nonisolated func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String: String]) {}
}
