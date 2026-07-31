import AudioStreaming
import Foundation
import Combine

@MainActor
public final class AudioPlayer: ObservableObject {
    /// A track that could not be loaded because the network was unavailable, kept so it
    /// can be re-attempted at the same position once connectivity returns. Only reachable
    /// from an active play request, so restoring it always means resuming audio.
    private struct StalledTrack {
        let itemId: String
        let position: TimeInterval
    }

    private static let maxConsecutiveFailures = 5

    public let queueHandler: PlayQueueHandler
    public let backend: BackendAudioPlayer
    private let settings: () -> UserSettings
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var scrobbleSyncer: ScrobbleSyncer?
    @Published public private(set) var nowPlaying: QueueItem?
    @Published public var lyrics: String = ""
    /// Non-empty while playback is stalled and waiting on something the user can see.
    @Published public private(set) var statusMessage: String = ""
    private var isAdvancing = false
    private var consecutivePlayFailures = 0
    private var stalled: StalledTrack?
    private var deferredWorkTask: Task<Void, Never>?

    public init(queueHandler: PlayQueueHandler, backend: BackendAudioPlayer, settings: @escaping () -> UserSettings) {
        self.queueHandler = queueHandler
        self.backend = backend
        self.settings = settings
        backend.onTrackFinished = { [weak self] in Task { @MainActor in self?.handleTrackFinished() } }
        backend.onTrackAdvancedGaplessly = { [weak self] in Task { @MainActor in self?.handleEngineAdvance() } }
        backend.onPlaybackError = { [weak self] error in
            Task { @MainActor in self?.handlePlaybackError(error) }
        }
        backend.onProgress = { [weak self] elapsed, duration in
            guard let self, let item = self.nowPlaying, !item.isLiveStream else { return }
            self.scrobbleSyncer?.trackProgress(item: item, elapsed: elapsed, duration: duration)
        }
        queueHandler.$currentIndex.sink { [weak self] _ in
            guard let self else { return }
            let item = self.queueHandler.currentItem
            // Ignore index-only reshuffles of the same track (e.g. toggle shuffle).
            guard item?.id != self.nowPlaying?.id else { return }
            self.nowPlaying = item
        }.store(in: &cancellables)
        NetworkMonitor.shared.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard connected else { return }
                Task { @MainActor in self?.handleConnectivityRestored() }
            }
            .store(in: &cancellables)
        observers.append(
            NotificationCenter.default.addObserver(forName: .offlineModeChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.settings().isOfflineMode else { return }
                    self.retryStalledPlayback(trigger: "offline mode disabled")
                }
            }
        )
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public func attachScrobbleSyncer(_ syncer: ScrobbleSyncer) {
        scrobbleSyncer = syncer
    }

    public func playCurrent(startAt: TimeInterval = 0) async {
        guard let item = queueHandler.currentItem else {
            PlayTrace.error("playCurrent — no current item")
            return
        }
        PlayTrace.mark("AudioPlayer.playCurrent enter", details: "\(item.title) id=\(item.playableId) startAt=\(Int(startAt))")
        nowPlaying = item
        lyrics = ""
        let user = settings()
        let bitrate = NetworkMonitor.shared.isExpensive ? user.streamingBitrateCellular : user.streamingBitrateWifi
        let format = user.cacheTranscodingFormat.streamFormat ?? .original
        PlayTrace.mark("settings loaded", details: "bitrate=\(bitrate) format=\(format) eq=\(user.equalizerEnabled) expensiveNet=\(NetworkMonitor.shared.isExpensive)")
        // Repeat-one must not gapless-queue the next track — AudioStreaming would
        // auto-start it at EOF and bypass our replay path.
        let repeatOne = queueHandler.repeatMode == .one
        backend.configure(
            equalizerEnabled: user.equalizerEnabled,
            replayGainEnabled: user.replayGainEnabled,
            equalizerBands: user.equalizerBands,
            gaplessEnabled: user.gaplessPlaybackEnabled && !repeatOne,
            crossfadeSeconds: (user.crossfadeEnabled && !repeatOne) ? user.crossfadeDurationSeconds : 0
        )
        backend.setRepeatOne(repeatOne)
        backend.isOfflineMode = user.isOfflineMode
        PlayTrace.mark("backend.configure done")
        do {
            try await backend.play(item: item, maxBitrate: bitrate, format: format, startAt: startAt)
            consecutivePlayFailures = 0
            stalled = nil
            statusMessage = ""
            PlayTrace.mark("backend.play returned OK")
        } catch {
            PlayTrace.error("backend.play failed", details: "\(error)")
            handleLoadFailure(for: item, position: startAt, error: error)
            return
        }
        // Don't hold first-audio behind lyrics / scrobble / gapless preload.
        let showLyrics = user.showLyricsWhenAvailable
        scheduleDeferredWork(for: item, showLyrics: showLyrics, bitrate: bitrate, format: format)
    }

    /// Post-play work shared by `playCurrent()` and `handleEngineAdvance()`: cache
    /// re-evaluation, gapless preload of the *following* track, scrobble, and lyrics.
    /// Runs after a short delay so the new stream can claim bandwidth first.
    private func scheduleDeferredWork(
        for item: QueueItem,
        showLyrics: Bool? = nil,
        bitrate: Int? = nil,
        format: StreamFormat? = nil
    ) {
        let user = settings()
        let showLyrics = showLyrics ?? user.showLyricsWhenAvailable
        let bitrate = bitrate ?? (NetworkMonitor.shared.isExpensive ? user.streamingBitrateCellular : user.streamingBitrateWifi)
        let format = format ?? (user.cacheTranscodingFormat.streamFormat ?? .original)
        // Rapid skips would otherwise stack up prefetch passes for tracks we left behind.
        deferredWorkTask?.cancel()
        deferredWorkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            PlayTrace.mark("post-play deferred work scheduled (1.5s)")
            // Let the stream claim bandwidth before queue-prefetch downloads start.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            PlayTrace.mark("post-play deferred work running")
            NotificationCenter.default.post(name: .verodromeQueueCacheReevaluate, object: nil)
            await self.preloadUpcoming(bitrate: bitrate, format: format)
            PlayTrace.mark("preloadUpcoming done")
            await self.reportNowPlaying(for: item)
            PlayTrace.mark("reportNowPlaying done")
            if showLyrics {
                await self.fetchLyrics(for: item)
                PlayTrace.mark("fetchLyrics done", details: "len=\(self.lyrics.count)")
            }
        }
    }

    /// True when the track cannot possibly be streamed right now, so failing over to
    /// another uncached queue item is pointless.
    private var isEffectivelyOffline: Bool {
        settings().isOfflineMode || !NetworkMonitor.shared.isConnected
    }

    /// `backend.play` threw before audio started — a missing URL, or offline with no
    /// cached file. Fail over to a cached neighbour when there is one, otherwise park.
    private func handleLoadFailure(for item: QueueItem, position: TimeInterval, error: Error) {
        if isEffectivelyOffline {
            if let index = nextCachedIndex() {
                PlayTrace.mark("offline — jumping to cached queue item", details: "index=\(index)")
                consecutivePlayFailures = 0
                queueHandler.jump(to: index)
                Task { await playCurrent() }
                return
            }
            stall(item: item, position: position, reason: "Nothing cached nearby: \(error)")
            return
        }
        consecutivePlayFailures += 1
        // Skip broken items, but bail out before an infinite failure loop.
        if consecutivePlayFailures < Self.maxConsecutiveFailures, queueHandler.activeQueue.count > 1 {
            playNext()
        } else {
            consecutivePlayFailures = 0
            backend.stop()
            statusMessage = "Can't play this track"
            log(.error, "Gave up loading \(item.title) after \(Self.maxConsecutiveFailures) failures: \(error)")
        }
    }

    /// The streaming engine failed after we handed it a URL. It is now in its `.error`
    /// state where `resume()` does nothing, so remember where we were and wait.
    private func handlePlaybackError(_ error: AudioPlayerError) {
        guard let item = nowPlaying else { return }
        let position = backend.currentTime
        guard isEffectivelyOffline || isNetworkError(error) else {
            consecutivePlayFailures += 1
            if consecutivePlayFailures < Self.maxConsecutiveFailures, queueHandler.activeQueue.count > 1 {
                log(.warning, "Stream failed for \(item.title), skipping: \(error.localizedDescription)")
                playNext()
            } else {
                consecutivePlayFailures = 0
                statusMessage = "Playback failed"
                log(.error, "Stream failed for \(item.title): \(error.localizedDescription)")
            }
            return
        }
        stall(item: item, position: position, reason: error.localizedDescription)
    }

    /// Parks the current track so the play button and connectivity recovery can pick it
    /// back up, instead of leaving the engine wedged with nothing watching it.
    private func stall(item: QueueItem, position: TimeInterval, reason: String) {
        consecutivePlayFailures = 0
        stalled = StalledTrack(itemId: item.id, position: position)
        // Only the offline case has a connectivity edge to wait for; otherwise the
        // server is unreachable and tapping play is the way out.
        statusMessage = isEffectivelyOffline
            ? "No connection — will retry when back online"
            : "Can't reach the server — tap play to retry"
        log(.warning, "Playback stalled on \(item.title) at \(Int(position))s: \(reason)")
    }

    private func handleConnectivityRestored() {
        if stalled != nil {
            retryStalledPlayback(trigger: "network restored")
            return
        }
        // The stall watchdog may not have fired yet — the user can restore the network
        // within seconds of the failed load. A stream that has produced no audio since
        // the drop will never start on its own, so reload it rather than waiting.
        guard backend.isSilentlyStuck, queueHandler.currentItem != nil else { return }
        log(.info, "Reloading silent stream after network restored")
        reloadCurrent()
    }

    /// Re-attempts the parked track from where it died.
    private func retryStalledPlayback(trigger: String) {
        guard let stalled, let item = queueHandler.currentItem else { return }
        guard item.id == stalled.itemId else {
            // The user moved on while we were offline; nothing to restore.
            self.stalled = nil
            statusMessage = ""
            return
        }
        // Offline mode still blocks uncached streams, so stay parked rather than
        // burning the retry and reporting a second failure.
        guard !settings().isOfflineMode || backend.isCached(item: item) else { return }
        self.stalled = nil
        statusMessage = ""
        PlayTrace.mark("retrying stalled playback", details: trigger)
        log(.info, "Retrying stalled playback (\(trigger))")
        Task { await playCurrent(startAt: stalled.position) }
    }

    private func nextCachedIndex() -> Int? {
        Self.nextCachedIndex(
            in: queueHandler.activeQueue,
            after: queueHandler.currentIndex,
            isCached: { backend.isCached(item: $0) }
        )
    }

    /// Index of the nearest upcoming queue item that satisfies `isCached`, searched only
    /// within the same look-ahead window the prefetch policy keeps on disk.
    nonisolated static func nextCachedIndex(
        in queue: [QueueItem],
        after currentIndex: Int,
        lookAhead: Int = QueueCachePolicyManager.nextKeepCount,
        isCached: (QueueItem) -> Bool
    ) -> Int? {
        let start = currentIndex + 1
        let end = min(queue.count - 1, currentIndex + lookAhead)
        guard start <= end, start >= 0 else { return nil }
        return (start...end).first { isCached(queue[$0]) }
    }

    private func isNetworkError(_ error: AudioPlayerError) -> Bool {
        if case .networkError = error { return true }
        if case .dataNotFound = error { return true }
        return false
    }

    private func log(_ level: EventLogger.LogLevel, _ message: String) {
        Task { await EventLogger.shared.log(level, category: "player", message) }
    }

    /// Natural end-of-track. Repeat-one replays in place (Amperfy-style); otherwise advance.
    private func handleTrackFinished() {
        if queueHandler.repeatMode == .one {
            PlayTrace.mark("repeat one — replaying current")
            Task { await playCurrent() }
            return
        }
        playNext()
    }

    /// The engine already started the pre-queued track (gapless / crossfade). Move the
    /// queue pointer and refresh published metadata only — calling `playCurrent()` here
    /// would restart the already-playing audio from zero and destroy the gapless join.
    private func handleEngineAdvance() {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        guard let item = queueHandler.advance() else {
            // Nothing to advance to (e.g. repeat off at end of queue). Let the engine
            // stop on its own; the `.eof` finish path will handle the final state.
            return
        }
        PlayTrace.mark("handleEngineAdvance", details: "\(item.title) id=\(item.playableId)")
        nowPlaying = item
        lyrics = ""
        backend.adoptEngineAdvancedTrack(duration: item.isLiveStream ? 0 : item.duration)
        scheduleDeferredWork(for: item)
    }

    /// Keep engine-level loop / gapless in sync when the user toggles repeat mid-track.
    public func applyRepeatMode(_ mode: RepeatMode) {
        let repeatOne = mode == .one
        backend.setRepeatOne(repeatOne)
        if repeatOne {
            backend.clearPendingNext()
        }
    }

    public func play(items: [QueueItem], startAt index: Int = 0) async {
        PlayTrace.mark("AudioPlayer.play(items:)", details: "count=\(items.count) startAt=\(index) first=\(items.first?.title ?? "nil")")
        consecutivePlayFailures = 0
        stalled = nil
        queueHandler.replaceContext(with: items, startAt: index)
        PlayTrace.mark("replaceContext returned")
        await playCurrent()
        PlayTrace.mark("playCurrent await finished (audio may still be buffering)")
    }

    public func toggle() {
        // A known stall takes priority over the engine's own state: it can report
        // `.paused` or even `.bufferring` while holding an entry that will never make a
        // sound, so pause/resume would just ping-pong between two silent states.
        if stalled != nil {
            reloadCurrent()
            return
        }
        if backend.isPlaying {
            backend.pause()
            return
        }
        if backend.canResume {
            backend.resume()
            return
        }
        // Stopped, errored, or holding a never-started entry — all cases where
        // `resume()` silently does nothing. Reload from the current position.
        reloadCurrent()
    }

    private func reloadCurrent() {
        let resumeAt = stalled?.position ?? backend.currentTime
        PlayTrace.mark("reloading current track", details: "at=\(Int(resumeAt))s")
        stalled = nil
        statusMessage = ""
        Task { await playCurrent(startAt: resumeAt) }
    }

    public func playNext() {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        stalled = nil
        if queueHandler.advance() != nil {
            Task { await playCurrent() }
        } else {
            backend.stop()
        }
    }

    public func playPrevious() {
        // Restart the track instead of stepping back — but only while the engine can
        // actually seek. On a dead engine that would leave the button doing nothing.
        if backend.currentTime > 3, backend.isPlaying || backend.canResume {
            backend.seek(to: 0)
            return
        }
        stalled = nil
        _ = queueHandler.retreat()
        Task { await playCurrent() }
    }

    public func stop() { backend.stop() }

    public func applyEqualizerBands(_ bands: [Float]) {
        backend.setEqualizerBands(bands)
    }

    public func setEqualizerEnabled(_ enabled: Bool) {
        backend.setEqualizerEnabled(enabled)
    }

    private func preloadUpcoming(bitrate: Int, format: StreamFormat) async {
        // Never queue the next song while repeating one track.
        guard queueHandler.repeatMode != .one else { return }
        let window = queueHandler.windowItems(
            previous: 0,
            next: QueueCachePolicyManager.nextKeepCount
        )
        guard window.count > 1 else { return }
        let next = window[1]
        await backend.preloadNext(item: next, maxBitrate: bitrate, format: format)
    }

    private func reportNowPlaying(for item: QueueItem) async {
        guard !item.isLiveStream, item.kind == .song else { return }
        guard let syncer = VerodromeKit.shared.activeLibrarySyncer else { return }
        try? await syncer.reportNowPlaying(playableId: item.playableId, position: 0)
    }

    private func fetchLyrics(for item: QueueItem) async {
        guard !item.isLiveStream else { return }
        // Prefer any pending lyrics from the syncer; otherwise keep empty placeholder.
        if let syncer = VerodromeKit.shared.activeLibrarySyncer as? (any LyricsProviding) {
            if let text = try? await syncer.fetchLyrics(playableId: item.playableId) {
                lyrics = text
                return
            }
        }
        // Fallback: embedded ID3 lyrics from a downloaded file.
        if let cache = VerodromeKit.shared.playableCache,
           let fileURL = cache.fileURL(forPlayableId: item.playableId, kind: item.kind),
           let text = EmbeddedTagExtractor.lyrics(from: fileURL) {
            lyrics = text
        }
    }
}

public protocol LyricsProviding: AnyObject, Sendable {
    func fetchLyrics(playableId: String) async throws -> String?
}
