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
    /// Engine playback rate (1 = normal). May temporarily differ from `sessionPlaybackRate`
    /// while hold-to-scrub is active.
    @Published public private(set) var playbackRate: Float = 1
    /// Sticky rate for the current play context. Re-applied (or re-rolled) on every new track.
    @Published public private(set) var sessionPlaybackRate: Float = 1
    /// When true, each new track start picks a rate from `PlaybackSpeed.randomOptions`.
    @Published public private(set) var isRandomPlaybackSpeed = false
    public var isOfflineMode = false
    public var onTrackFinished: (() -> Void)?
    /// Fires when the engine starts an entry it advanced to on its own (gapless or
    /// crossfade), so the queue pointer can follow without restarting audio.
    public var onTrackAdvancedGaplessly: (() -> Void)?
    public var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    /// Fires when the streaming engine fails mid-load or mid-playback (most often a
    /// network drop). The engine is unusable until the next `play(item:)`.
    public var onPlaybackError: ((AudioPlayerError) -> Void)?

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
    /// When set, `play` loads the entry but keeps playback paused (and re-asserts pause
    /// if the engine reports `.playing` before our pause sticks).
    private var preferPaused = false
    /// Offset to seek to once the engine reports the entry as playing. `seek(to:)` is a
    /// no-op until AudioStreaming has an `audioPlayingEntry`, so it cannot run inline.
    private var pendingSeek: TimeInterval?
    /// How long the engine may report no forward progress before we declare the stream
    /// dead. Comfortably above AudioStreaming's own 2s underrun rebuffer threshold.
    private static let stallTimeout: TimeInterval = 12
    /// Shorter window used when connectivity returns and we can act early.
    private static let silentStuckGrace: TimeInterval = 2
    private static let startRampDuration: TimeInterval = 0.08
    private static let startRampPollInterval: TimeInterval = 0.03
    /// Mute before a scan-seek so the buffer flush is not audible.
    private static let intervalSeekFadeOut: TimeInterval = 0.06
    private static let intervalSeekFadeIn: TimeInterval = 0.10
    private static let intervalSeekFadeOutNanos: UInt64 = 60_000_000
    private static let progressPollInterval: TimeInterval = 0.25
    private var stallDetector = PlaybackStallDetector(timeout: BackendAudioPlayer.stallTimeout)
    /// True until the new entry has produced real progress, so we can fade in and hide
    /// the click some files have in their first encoded samples.
    private var wantsStartRamp = false
    private var volumeFadeTimer: Timer?

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

    /// AudioStreaming's `resume()` early-returns unless its internal state is exactly
    /// `.paused`, so from `.error` / `.stopped` the only way back to audio is a fresh
    /// `play(url:)`. Callers must check this before treating `resume()` as effective.
    ///
    /// A never-started entry also has to be excluded: `.waitingForData` contains
    /// `.running`, so pausing a stream that never delivered a byte moves the engine to
    /// `.paused` around a dead entry, where `resume()` succeeds but stays silent.
    public var canResume: Bool {
        streamingPlayer.state == .paused && stallDetector.hasStartedAudio
    }

    /// Nominally loading or playing, but the engine has not produced a single frame of
    /// audio for long enough that it is not going to on its own. Lets callers recover
    /// before the stall watchdog's full timeout elapses.
    public var isSilentlyStuck: Bool {
        guard !currentPlayURL.isEmpty else { return false }
        return stallDetector.isSilentlyStuck(grace: Self.silentStuckGrace)
    }

    public func isCached(item: QueueItem) -> Bool {
        item.directStreamURL != nil || cache.hasPlayableFile(id: item.playableId, kind: item.kind)
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

    /// Prepare the engine for app-level repeat-one.
    ///
    /// Repeat-one is handled in `AudioPlayer.handleTrackFinished` (replay current),
    /// not via AudioStreaming's `.single` loop — a preloaded next entry bypasses that
    /// loop and would advance the queue. Manual next/previous still call `playNext` /
    /// `playPrevious` and are unaffected.
    public func setRepeatOne(_ enabled: Bool) {
        streamingPlayer.loopMode = .off
        if enabled {
            gaplessEnabled = false
            crossfadeSeconds = 0
            clearPendingNext()
        }
    }

    /// True while the engine is holding a track to play after the current one.
    public var hasPendingNext: Bool { pendingNextURL != nil }

    public func clearPendingNext() {
        if let url = pendingNextURL {
            streamingPlayer.removeFromQueue(url: url)
        }
        pendingNextURL = nil
        isCrossfading = false
    }

    /// Drops the identity of the outgoing stream so a late EOF or gapless hand-off cannot
    /// advance the queue, without stopping audio yet — the replacement `play(item:)` cuts
    /// over once its URL is ready.
    public func abandonCurrentPlayback() {
        clearPendingNext()
        currentPlayURL = ""
    }

    /// Clock seed for a track the engine advanced to by itself (gapless / crossfade).
    /// The engine is already playing it; we only need to reset our published clock.
    public func adoptEngineAdvancedTrack(duration newDuration: TimeInterval) {
        duration = newDuration
        currentTime = 0
        stallDetector.adoptPlayingEntry()
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

    public func play(
        item: QueueItem,
        maxBitrate: Int?,
        format: StreamFormat,
        startAt: TimeInterval = 0,
        startPaused: Bool = false,
        isStillCurrent: () -> Bool = { true }
    ) async throws {
        PlayTrace.mark("BackendAudioPlayer.play enter", details: "id=\(item.playableId) title=\(item.title) bitrate=\(maxBitrate.map(String.init) ?? "nil") format=\(format) startAt=\(Int(startAt)) paused=\(startPaused)")
        // Mute the outgoing cut immediately. The fade-in waits for first progress so a
        // stream that is still buffering does not become audible at full volume.
        cancelVolumeFade()
        if startPaused {
            wantsStartRamp = false
            streamingPlayer.volume = 1
        } else {
            wantsStartRamp = true
            streamingPlayer.volume = 0
        }
        let quality = AudioTranscodeQuality.from(format: format, maxBitrate: maxBitrate)
        let url: URL
        var source = "stream"
        var cachedPlayable: (id: String, kind: PlayableRef.Kind)?
        if let direct = item.directStreamURL {
            url = direct
            source = "direct"
            PlayTrace.mark("URL resolved (direct)", details: url.absoluteString)
        } else {
            do {
                let local = try await localPlaybackURL(
                    for: item,
                    quality: quality,
                    maxBitrate: maxBitrate,
                    format: format
                )
                url = local.url
                source = local.source
                if local.fromCache {
                    cachedPlayable = (item.playableId, item.kind)
                }
                PlayTrace.mark("URL resolved (\(source))", details: url.lastPathComponent)
            } catch {
                restoreVolumeAfterFailedStart()
                throw error
            }
        }
        guard isStillCurrent() else {
            PlayTrace.mark("BackendAudioPlayer.play discarded — superseded")
            return
        }
        // A queued next URL from the previous track would auto-advance after this one
        // ends (gapless / crossfade). Jumping mid-queue must drop it; otherwise the
        // engine would carry the old track's neighbor into the new context. `play(url:)`
        // replaces current audio, but `removeFromQueue` is what actually evicts a
        // pre-queued entry, so route through `clearPendingNext()` like reorder does.
        clearPendingNext()
        preferPaused = startPaused
        // Live streams have no meaningful position to restore.
        pendingSeek = (startAt > 1 && !item.isLiveStream) ? startAt : nil
        // Mark the intended entry before replacing audio so the previous track's
        // finish callback (stopReason .none / .userAction) cannot advance the queue.
        ignoreFinishCallbacks = true
        currentPlayURL = url.absoluteString
        PlayTrace.mark("streamingPlayer.play(url:) call", details: "source=\(source)")
        streamingPlayer.play(url: url)
        ignoreFinishCallbacks = false
        // Re-assert (or re-roll, in Random mode) — engine may snap back to 1× on a new URL.
        applySessionRateForNewTrack()
        duration = item.isLiveStream ? 0 : item.duration
        currentTime = pendingSeek ?? 0
        stallDetector.reset()
        if startPaused {
            streamingPlayer.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            isPlaying = true
            startProgressTimer()
        }
        PlayTrace.mark("streamingPlayer.play returned (buffering may still be in progress)")
        // Touch cache after play starts so disk meta writes don't delay first audio.
        if let cachedPlayable {
            cache.touchPlayable(id: cachedPlayable.id, kind: cachedPlayable.kind, reason: nil)
            PlayTrace.mark("cache.touchPlayable done")
        }
    }

    public func preloadNext(item: QueueItem, maxBitrate: Int?, format: StreamFormat) async {
        guard gaplessEnabled || crossfadeSeconds > 0 else { return }
        do {
            let quality = AudioTranscodeQuality.from(format: format, maxBitrate: maxBitrate)
            let local = try await localPlaybackURL(
                for: item,
                quality: quality,
                maxBitrate: maxBitrate,
                format: format
            )
            let url = local.url
            guard url != pendingNextURL else { return }
            // Drop whatever was queued before, otherwise a second preload stacks another
            // entry behind the current track and the engine plays the stale one.
            clearPendingNext()
            pendingNextURL = url
            if gaplessEnabled && crossfadeSeconds <= 0 {
                streamingPlayer.queue(url: url)
            }
        } catch {}
    }

    /// Prefer a local file (original or matching MP3 variant). When transcoding is on and
    /// the variant is missing, download it into the cache first so seeks stay local.
    private func localPlaybackURL(
        for item: QueueItem,
        quality: AudioTranscodeQuality,
        maxBitrate: Int?,
        format: StreamFormat
    ) async throws -> (url: URL, source: String, fromCache: Bool) {
        if let cached = cache.fileURL(forPlayableId: item.playableId, kind: item.kind, quality: quality) {
            return (cached, "cache", true)
        }
        // Offline: fall back to any available original if the requested variant is missing.
        if isOfflineMode {
            if quality != .original,
               let original = cache.fileURL(forPlayableId: item.playableId, kind: item.kind, quality: .original) {
                return (original, "cache", true)
            }
            throw BackendError.network("Offline and track not cached")
        }
        if quality == .original {
            let remote = try await urlProvider.streamURL(
                forPlayableId: item.playableId,
                maxBitrate: maxBitrate,
                format: format
            )
            return (remote, "stream", false)
        }
        // Transcoded: fetch once into the playable cache, then play the file.
        PlayTrace.mark("caching transcoded playable…", details: "quality=\(quality.rawValue)")
        let remote = try await urlProvider.downloadURL(
            forPlayableId: item.playableId,
            maxBitrate: maxBitrate,
            format: format
        )
        let tempURL = try await ProgressDownloadSession().download(from: remote) { _ in }
        let stored = try cache.storePlayable(
            id: item.playableId,
            kind: item.kind,
            from: tempURL,
            reason: .queuePrefetch,
            quality: quality
        )
        PlayTrace.mark("transcoded playable cached", details: stored.lastPathComponent)
        return (stored, "cache-transcode", true)
    }

    public func pause() {
        if wantsStartRamp {
            wantsStartRamp = false
            cancelVolumeFade()
            streamingPlayer.volume = 1
        }
        streamingPlayer.pause()
        isPlaying = false
    }

    public func resume() {
        preferPaused = false
        streamingPlayer.resume()
        // Re-assert rate: some engine transitions snap back to 1×.
        streamingPlayer.rate = playbackRate
        isPlaying = true
        // Give the stream a fresh window to deliver audio before we call it dead.
        stallDetector.extendWindow()
        startProgressTimer()
    }

    public func stop() {
        ignoreFinishCallbacks = true
        preferPaused = false
        wantsStartRamp = false
        cancelVolumeFade()
        streamingPlayer.volume = 1
        clearPendingNext()
        currentPlayURL = ""
        streamingPlayer.stop()
        ignoreFinishCallbacks = false
        isPlaying = false
        currentTime = 0
        pendingSeek = nil
        stallDetector.reset()
        stopProgressTimer()
        setRate(sessionPlaybackRate)
    }

    public func seek(to seconds: TimeInterval) {
        streamingPlayer.seek(to: seconds)
        currentTime = seconds
        // The clock jumps (possibly backwards), so rebase rather than reading it as a stall.
        stallDetector.extendWindow()
    }

    /// Duck, seek, then ramp back up so a hold-to-scan jump does not click.
    public func seekWithRamp(to seconds: TimeInterval) async {
        fadeVolume(to: 0, duration: Self.intervalSeekFadeOut, completion: nil)
        try? await Task.sleep(nanoseconds: Self.intervalSeekFadeOutNanos)
        cancelVolumeFade()
        if Task.isCancelled {
            streamingPlayer.volume = 1
            return
        }
        seek(to: seconds)
        fadeVolume(to: 1, duration: Self.intervalSeekFadeIn, completion: nil)
    }

    public func restoreFullVolume() {
        cancelVolumeFade()
        streamingPlayer.volume = 1
    }

    /// Enables Random mode and immediately rolls a rate for the current track.
    public func setRandomPlaybackSpeed() {
        isRandomPlaybackSpeed = true
        rerollRandomSessionRate()
    }

    /// Sets a fixed sticky context rate and leaves Random mode.
    public func setSessionPlaybackRate(_ rate: Float) {
        isRandomPlaybackSpeed = false
        sessionPlaybackRate = PlaybackSpeed.clamp(rate)
        setRate(sessionPlaybackRate)
    }

    /// Restores the engine to the sticky context rate after a temporary hold-speed.
    public func restoreSessionPlaybackRate() {
        setRate(sessionPlaybackRate)
    }

    /// Picks a new rate from the Random pool and applies it.
    public func rerollRandomSessionRate() {
        sessionPlaybackRate = PlaybackSpeed.clamp(PlaybackSpeed.randomRate())
        setRate(sessionPlaybackRate)
    }

    /// Called when a track starts: re-roll in Random mode, otherwise re-assert sticky rate.
    public func applySessionRateForNewTrack() {
        if isRandomPlaybackSpeed {
            rerollRandomSessionRate()
        } else {
            setRate(sessionPlaybackRate)
        }
    }

    /// Sets engine playback rate. Values outside a sensible range are clamped.
    /// Does not change the sticky session rate (use `setSessionPlaybackRate` for that).
    public func setRate(_ rate: Float) {
        let clamped = PlaybackSpeed.clamp(rate)
        playbackRate = clamped
        streamingPlayer.rate = clamped
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
        // Poll faster while waiting for first audio so the start ramp can begin
        // on the first real samples instead of a quarter-second later.
        let timer = Timer(
            timeInterval: wantsStartRamp ? Self.startRampPollInterval : Self.progressPollInterval,
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
        if progress.isFinite, pendingSeek == nil {
            let looksLikeTransientZero = progress == 0 && isPlaying && currentTime > 1
            if !looksLikeTransientZero, abs(progress - currentTime) >= 0.05 {
                currentTime = progress
            }
        }
        if dur.isFinite, dur > 0, abs(dur - duration) >= 0.05 {
            duration = dur
        }
        onProgress?(currentTime, duration)
        checkForStall(progress: progress)
        if wantsStartRamp, stallDetector.hasStartedAudio {
            beginStartRamp()
        }
        maybeStartCrossfade()
    }

    private func checkForStall(progress: Double) {
        let startedAudio = stallDetector.hasStartedAudio
        guard stallDetector.update(progress: progress, isPlaying: isPlaying) else { return }
        PlayTrace.error(
            "playback stalled",
            details: "no progress for \(Int(Self.stallTimeout))s startedAudio=\(startedAudio)"
        )
        reportDeadStream()
    }

    /// Tears the engine down to a known-clean `.stopped` state and reports the failure.
    /// Leaving the hung entry in place would let a later `resume()` report success while
    /// staying silent forever, which is unrecoverable without restarting the app.
    private func reportDeadStream() {
        let position = currentTime
        ignoreFinishCallbacks = true
        streamingPlayer.stop()
        ignoreFinishCallbacks = false
        stopProgressTimer()
        isPlaying = false
        currentPlayURL = ""
        pendingSeek = nil
        clearPendingNext()
        stallDetector.reset()
        wantsStartRamp = false
        cancelVolumeFade()
        streamingPlayer.volume = 1
        // Preserve the position so the retry can pick up where the audio died.
        currentTime = position
        onPlaybackError?(.dataNotFound)
    }

    private func maybeStartCrossfade() {
        guard crossfadeSeconds > 0, !isCrossfading, duration > 0 else { return }
        let remaining = duration - currentTime
        guard remaining <= crossfadeSeconds, remaining > 0 else { return }
        // Only latch the flag once there is something to fade into, otherwise a failed
        // preload would disable crossfade for the rest of the track.
        guard let next = pendingNextURL else { return }
        isCrossfading = true
        fadeVolume(to: 0, duration: crossfadeSeconds) { [weak self] in
            guard let self else { return }
            self.streamingPlayer.play(url: next)
            self.streamingPlayer.volume = 0
            self.fadeVolume(to: 1, duration: max(self.crossfadeSeconds * 0.5, 0.1), completion: nil)
        }
    }

    private func beginStartRamp() {
        wantsStartRamp = false
        fadeVolume(to: 1, duration: Self.startRampDuration, completion: nil)
        if progressTimer != nil {
            startProgressTimer()
        }
    }

    private func restoreVolumeAfterFailedStart() {
        wantsStartRamp = false
        cancelVolumeFade()
        streamingPlayer.volume = 1
    }

    private func cancelVolumeFade() {
        volumeFadeTimer?.invalidate()
        volumeFadeTimer = nil
    }

    private func fadeVolume(to target: Float, duration: Double, completion: (() -> Void)?) {
        cancelVolumeFade()
        let tick = min(0.05, max(duration / 8, 0.016))
        let steps = max(Int((duration / tick).rounded()), 1)
        let start = streamingPlayer.volume
        let delta = (target - start) / Float(steps)
        final class StepBox { var value = 0 }
        let step = StepBox()
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                step.value += 1
                self.streamingPlayer.volume = start + delta * Float(step.value)
                if step.value >= steps {
                    timer.invalidate()
                    self.volumeFadeTimer = nil
                    self.streamingPlayer.volume = target
                    completion?()
                }
            }
        }
        volumeFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

extension BackendAudioPlayer: AudioPlayerDelegate {
    public nonisolated func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        PlayTrace.mark("AudioStreaming didStartPlaying", details: entryId.id)
        PlayTrace.end("first audio audible / didStartPlaying")
        Task { @MainActor in
            // Fires the moment the engine adopts the entry, *before* any audio data
            // arrives. A callback for an entry we already gave up on (play / error both
            // clear `currentPlayURL`) must not resurrect the playing state.
            guard entryId.id == self.currentPlayURL
                    || entryId.id == self.pendingNextURL?.absoluteString else { return }
            if let offset = self.pendingSeek, entryId.id == self.currentPlayURL {
                self.pendingSeek = nil
                PlayTrace.mark("applying resume offset", details: "\(Int(offset))s")
                self.seek(to: offset)
            }
            if self.preferPaused {
                self.streamingPlayer.pause()
                self.isPlaying = false
                self.stopProgressTimer()
                return
            }
            // Gapless / crossfade hand-offs never report `.eof`, so this is the only
            // signal that the engine moved on to the pre-queued entry on its own.
            // `play(item:)` clears `pendingNextURL` and sets `currentPlayURL` before
            // starting audio, so an explicit play / manual skip can never match here.
            let isGaplessAdvance = entryId.id != self.currentPlayURL
                && entryId.id == self.pendingNextURL?.absoluteString
            if isGaplessAdvance {
                self.currentPlayURL = entryId.id
                self.pendingNextURL = nil
                self.isCrossfading = false
                // New song via gapless — re-roll before the engine rate is re-asserted.
                self.applySessionRateForNewTrack()
                self.onTrackAdvancedGaplessly?()
            } else {
                // Engine can reset rate when an entry becomes audible.
                self.streamingPlayer.rate = self.playbackRate
            }
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
                // No intended entry means we already abandoned this stream.
                guard !self.currentPlayURL.isEmpty else { return }
                if self.preferPaused {
                    self.streamingPlayer.pause()
                    self.isPlaying = false
                    return
                }
                self.isPlaying = true
            case .paused, .stopped, .disposed:
                PlayTrace.mark("AudioStreaming state → \(String(describing: newState))")
                self.isPlaying = false
            case .error:
                PlayTrace.mark("AudioStreaming state → error")
                self.isPlaying = false
                self.stopProgressTimer()
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
        PlayTrace.error("AudioStreaming unexpected error", details: error.localizedDescription)
        Task { @MainActor in
            let position = self.currentTime
            self.isPlaying = false
            self.stopProgressTimer()
            // The engine is now in its `.error` state, where `resume()` is a no-op and
            // the queued entries are dead. Drop them so nothing tries to reuse them.
            self.currentPlayURL = ""
            self.pendingSeek = nil
            self.clearPendingNext()
            self.stallDetector.reset()
            self.wantsStartRamp = false
            self.cancelVolumeFade()
            self.streamingPlayer.volume = 1
            self.currentTime = position
            self.onPlaybackError?(error)
        }
    }

    public nonisolated func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {
        Task { @MainActor in
            // Cancelled queued items are expected when replacing tracks.
        }
    }

    public nonisolated func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String: String]) {}
}
