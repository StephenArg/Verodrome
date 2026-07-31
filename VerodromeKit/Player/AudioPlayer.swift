import Foundation
import Combine

@MainActor
public final class AudioPlayer: ObservableObject {
    public let queueHandler: PlayQueueHandler
    public let backend: BackendAudioPlayer
    private let settings: () -> UserSettings
    private var cancellables = Set<AnyCancellable>()
    private var scrobbleSyncer: ScrobbleSyncer?
    @Published public private(set) var nowPlaying: QueueItem?
    @Published public var lyrics: String = ""
    private var isAdvancing = false
    private var consecutivePlayFailures = 0

    public init(queueHandler: PlayQueueHandler, backend: BackendAudioPlayer, settings: @escaping () -> UserSettings) {
        self.queueHandler = queueHandler
        self.backend = backend
        self.settings = settings
        backend.onTrackFinished = { [weak self] in Task { @MainActor in self?.handleTrackFinished() } }
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
    }

    public func attachScrobbleSyncer(_ syncer: ScrobbleSyncer) {
        scrobbleSyncer = syncer
    }

    public func playCurrent() async {
        guard let item = queueHandler.currentItem else {
            PlayTrace.error("playCurrent — no current item")
            return
        }
        PlayTrace.mark("AudioPlayer.playCurrent enter", details: "\(item.title) id=\(item.playableId)")
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
            try await backend.play(item: item, maxBitrate: bitrate, format: format)
            consecutivePlayFailures = 0
            PlayTrace.mark("backend.play returned OK")
        } catch {
            consecutivePlayFailures += 1
            PlayTrace.error("backend.play failed", details: "\(error) failures=\(consecutivePlayFailures)")
            // Skip broken items, but bail out before an infinite failure loop.
            if consecutivePlayFailures < 5, queueHandler.activeQueue.count > 1 {
                playNext()
            } else {
                consecutivePlayFailures = 0
                backend.stop()
            }
            return
        }
        // Don't hold first-audio behind lyrics / scrobble / gapless preload.
        let showLyrics = user.showLyricsWhenAvailable
        Task { @MainActor [weak self] in
            guard let self else { return }
            PlayTrace.mark("post-play deferred work scheduled (1.5s)")
            // Let the stream claim bandwidth before queue-prefetch downloads start.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
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

    /// Natural end-of-track. Repeat-one replays in place (Amperfy-style); otherwise advance.
    private func handleTrackFinished() {
        if queueHandler.repeatMode == .one {
            PlayTrace.mark("repeat one — replaying current")
            Task { await playCurrent() }
            return
        }
        playNext()
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
        queueHandler.replaceContext(with: items, startAt: index)
        PlayTrace.mark("replaceContext returned")
        await playCurrent()
        PlayTrace.mark("playCurrent await finished (audio may still be buffering)")
    }

    public func toggle() {
        if backend.isPlaying { backend.pause() } else { backend.resume() }
    }

    public func playNext() {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        if queueHandler.advance() != nil {
            Task { await playCurrent() }
        } else {
            backend.stop()
        }
    }

    public func playPrevious() {
        if backend.currentTime > 3 {
            backend.seek(to: 0)
            return
        }
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
