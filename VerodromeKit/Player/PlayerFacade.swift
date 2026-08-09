import Foundation
import Combine
import UIKit

@MainActor
public protocol PlayerControlling: AnyObject {
    var isPlaying: Bool { get }
    var currentItem: QueueItem? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var queue: [QueueItem] { get }
    var currentIndex: Int { get }
    /// Where the rows the user queued themselves sit inside `queue`.
    var userQueuedRange: Range<Int> { get }
    /// Changes when a new context starts, so callers can tell their queue was replaced.
    var contextGeneration: Int { get }
    var repeatMode: RepeatMode { get set }
    var shuffleMode: ShuffleMode { get }
    func play(items: [QueueItem], startAt: Int) async
    /// `shuffle == nil` keeps the current shuffle state.
    func play(items: [QueueItem], startAt: Int, shuffle: ShuffleMode?) async
    func play()
    func pause()
    func togglePlayPause()
    func stop()
    func next()
    func previous()
    func seek(to: TimeInterval)
    func enqueueNext(_ items: [QueueItem])
    func enqueueLast(_ items: [QueueItem])
    /// Queues items for one listen; they leave the queue and the cache once played.
    /// `at` is an absolute queue index clamped into the "Added to Queue" run; pass `nil`
    /// to append after any temporary rows already waiting.
    func enqueueEphemeral(_ items: [QueueItem], at insertAt: Int?)
    /// Extends the playing context rather than adding user-queued items.
    func appendContext(_ items: [QueueItem])
    func remove(at offsets: IndexSet)
    /// Removes rows whoever queued them, for a queue the user owns the order of.
    func removeRows(at offsets: IndexSet)
    func move(from: IndexSet, to: Int)
    /// Reorder / remove within the user-queued run, offsets relative to it.
    func moveUserQueued(from: IndexSet, to: Int)
    func removeUserQueued(at offsets: IndexSet)
    func jump(to index: Int)
    /// Empties the queue and forgets the stored one.
    func clearQueue()
    func toggleShuffle()
    func setShuffleMode(_ mode: ShuffleMode)
    func setRepeatMode(_ mode: RepeatMode)
    func requestLyrics()
}

@MainActor
public protocol PlayerFacade: PlayerControlling {}

extension PlayerControlling {
    public func enqueueEphemeral(_ items: [QueueItem]) {
        enqueueEphemeral(items, at: nil)
    }
}

@MainActor
public final class PlayerFacadeImpl: ObservableObject, PlayerFacade {
    private let audioPlayer: AudioPlayer
    private weak var nowPlayingHandler: NowPlayingInfoCenterHandler?
    private weak var artworkResolver: ArtworkResolver?
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentItem: QueueItem?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var lyrics: String = ""
    /// True once the lyrics lookup for the current track has finished, found or not.
    @Published public private(set) var lyricsLoaded = false
    /// Non-empty while playback is stalled, e.g. waiting for the network to come back.
    @Published public private(set) var statusMessage: String = ""
    /// Sticky playback speed for the current play context. Resets when the context is replaced.
    @Published public private(set) var sessionPlaybackRate: Float = 1
    /// True while Random mode is on (per-track rolls from `PlaybackSpeed.randomOptions`).
    @Published public private(set) var isRandomPlaybackSpeed = false
    /// Wall-clock deadline for the sleep timer. Nil while inactive. Publishes only on
    /// start / cancel / fire so the player is not redrawn every second.
    @Published public private(set) var sleepTimerDeadline: Date?

    /// The stored queue carries the scrub position, so it is rewritten as playback moves.
    /// Doing that per tick would be a file write a second; this interval keeps a relaunch
    /// within a few seconds of where the user was.
    private static let positionPersistInterval: TimeInterval = 5
    private var lastPersistedPosition: TimeInterval = 0
    private var sleepTimer: Timer?

    public init(audioPlayer: AudioPlayer) {
        self.audioPlayer = audioPlayer
        audioPlayer.backend.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self else { return }
                self.isPlaying = playing
                // Rate-only update — never rebuild metadata (that flashes empty artwork).
                self.nowPlayingHandler?.updatePlaybackState(
                    isPlaying: playing,
                    elapsed: self.currentTime,
                    rate: self.audioPlayer.backend.playbackRate
                )
            }
            .store(in: &cancellables)
        audioPlayer.backend.$sessionPlaybackRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let self else { return }
                self.sessionPlaybackRate = rate
                self.nowPlayingHandler?.updatePlaybackState(
                    isPlaying: self.isPlaying,
                    elapsed: self.currentTime,
                    rate: self.audioPlayer.backend.playbackRate
                )
            }
            .store(in: &cancellables)
        audioPlayer.backend.$isRandomPlaybackSpeed
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRandomPlaybackSpeed)
        // A new play context (or cleared queue) drops any sticky speed / Random mode
        // and cancels an active sleep timer — same "session" lifetime as playback speed.
        // No `receive(on:)` — queue mutations already happen on the main actor, and
        // the reset must land before the next `play(item:)` re-asserts session rate.
        audioPlayer.queueHandler.$contextGeneration
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.setSessionPlaybackRate(1)
                self?.cancelSleepTimer()
            }
            .store(in: &cancellables)
        audioPlayer.backend.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.currentTime = time
                self.persistPositionIfDue(time)
                // While rate ≠ 1×, refresh lock-screen elapsed so the scrubber
                // tracks the engine instead of drifting on extrapolated time.
                let rate = self.audioPlayer.backend.playbackRate
                guard rate != 1, self.isPlaying else { return }
                self.nowPlayingHandler?.updatePlaybackState(
                    isPlaying: true,
                    elapsed: time,
                    rate: rate
                )
            }
            .store(in: &cancellables)
        audioPlayer.backend.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)
        audioPlayer.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.lastPersistedPosition = 0
                self?.currentItem = item
                self?.pushNowPlaying(reloadArtwork: true)
            }
            .store(in: &cancellables)
        audioPlayer.$lyrics
            .receive(on: DispatchQueue.main)
            .assign(to: &$lyrics)
        audioPlayer.$lyricsLoaded
            .receive(on: DispatchQueue.main)
            .assign(to: &$lyricsLoaded)
        audioPlayer.$statusMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$statusMessage)
        refreshPublished()
    }

    public func attachNowPlaying(_ handler: NowPlayingInfoCenterHandler) {
        nowPlayingHandler = handler
        pushNowPlaying(reloadArtwork: true)
    }

    public func attachArtworkResolver(_ resolver: ArtworkResolver) {
        artworkResolver = resolver
    }

    public var queue: [QueueItem] { audioPlayer.queueHandler.activeQueue }
    public var currentIndex: Int { audioPlayer.queueHandler.currentIndex }
    public var userQueuedRange: Range<Int> { audioPlayer.queueHandler.userQueuedRange }
    public var contextGeneration: Int { audioPlayer.queueHandler.contextGeneration }

    /// Test seam for session-speed coverage without playing audio.
    var test_queueHandler: PlayQueueHandler { audioPlayer.queueHandler }
    var test_enginePlaybackRate: Float { audioPlayer.backend.playbackRate }
    var test_engineSessionRate: Float { audioPlayer.backend.sessionPlaybackRate }
    var test_engineIsRandomSpeed: Bool { audioPlayer.backend.isRandomPlaybackSpeed }

    func test_applySessionRateForNewTrack() {
        audioPlayer.backend.applySessionRateForNewTrack()
        sessionPlaybackRate = audioPlayer.backend.sessionPlaybackRate
    }

    /// Test seam: evaluate the sleep timer against an injected clock.
    func test_fireSleepTimerIfDue(now: Date) {
        fireSleepTimerIfDue(now: now)
    }
    public var repeatMode: RepeatMode {
        get { audioPlayer.queueHandler.repeatMode }
        set {
            audioPlayer.queueHandler.setRepeat(newValue)
            audioPlayer.applyRepeatMode(newValue)
        }
    }
    public var shuffleMode: ShuffleMode { audioPlayer.queueHandler.shuffleMode }

    public func play(items: [QueueItem], startAt: Int) async {
        PlayTrace.mark("PlayerFacade.play", details: "count=\(items.count) startAt=\(startAt)")
        await audioPlayer.play(items: items, startAt: startAt)
        PlayTrace.mark("PlayerFacade.play — audioPlayer returned; refreshPublished")
        refreshPublished()
        PlayTrace.mark("PlayerFacade.refreshPublished done")
    }

    /// Starts a new context with an explicit shuffle state. The mode is recorded
    /// before the context is replaced so the queue handler shuffles the incoming
    /// items itself and remembers their unshuffled order.
    public func play(items: [QueueItem], startAt: Int, shuffle: ShuffleMode?) async {
        if let shuffle {
            audioPlayer.queueHandler.setShuffle(shuffle, reorder: false)
        }
        await play(items: items, startAt: startAt)
    }

    public func play() {
        if !isPlaying {
            audioPlayer.toggle()
            // isPlaying sink updates Now Playing rate; avoid a full metadata rebuild.
            isPlaying = audioPlayer.backend.isPlaying
        }
    }

    public func pause() {
        if isPlaying {
            audioPlayer.toggle()
            isPlaying = audioPlayer.backend.isPlaying
        }
    }

    public func replaceQueue(with items: [QueueItem], startAt: Int) {
        Task { await play(items: items, startAt: startAt) }
    }

    public func togglePlayPause() {
        audioPlayer.toggle()
        isPlaying = audioPlayer.backend.isPlaying
    }

    public func stop() {
        audioPlayer.stop()
        refreshPublished()
    }

    public func next() {
        audioPlayer.playNext()
        refreshPublished()
    }

    public func previous() {
        audioPlayer.playPrevious()
        refreshPublished()
    }

    public func seek(to seconds: TimeInterval) {
        audioPlayer.backend.seek(to: seconds)
        currentTime = seconds
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Temporarily change engine rate (e.g. hold skip = 2× / hold previous = 0.5×).
    public func setPlaybackRate(_ rate: Float) {
        audioPlayer.backend.setRate(rate)
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Sets a fixed sticky playback speed for the current play context (exits Random).
    public func setSessionPlaybackRate(_ rate: Float) {
        audioPlayer.backend.setSessionPlaybackRate(rate)
        // Keep published state in sync immediately — Combine `receive(on:)` would lag a turn.
        sessionPlaybackRate = audioPlayer.backend.sessionPlaybackRate
        isRandomPlaybackSpeed = false
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Enables Random mode and rolls a rate for the current track.
    public func setRandomPlaybackSpeed() {
        audioPlayer.backend.setRandomPlaybackSpeed()
        sessionPlaybackRate = audioPlayer.backend.sessionPlaybackRate
        isRandomPlaybackSpeed = true
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Restores the engine to the sticky context speed after a temporary hold-speed.
    public func restoreSessionPlaybackRate() {
        audioPlayer.backend.restoreSessionPlaybackRate()
        nowPlayingHandler?.updatePlaybackState(
            isPlaying: isPlaying,
            elapsed: currentTime,
            rate: audioPlayer.backend.playbackRate
        )
    }

    /// Starts (or restarts) a wall-clock sleep timer. Zero / negative durations cancel.
    public func startSleepTimer(_ duration: TimeInterval) {
        guard duration > 0 else {
            cancelSleepTimer()
            return
        }
        stopSleepTimerTick()
        sleepTimerDeadline = Date().addingTimeInterval(duration)
        startSleepTimerTick()
    }

    /// Clears an active sleep timer without pausing playback.
    public func cancelSleepTimer() {
        stopSleepTimerTick()
        sleepTimerDeadline = nil
    }

    private func startSleepTimerTick() {
        stopSleepTimerTick()
        // Block-based timer on the main run loop; wall-clock comparison each tick
        // survives drift and system sleep better than a single fire-at-deadline timer.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fireSleepTimerIfDue(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    private func stopSleepTimerTick() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    private func fireSleepTimerIfDue(now: Date) {
        guard let deadline = sleepTimerDeadline, now >= deadline else { return }
        cancelSleepTimer()
        pause()
    }

    public func enqueueNext(_ items: [QueueItem]) { audioPlayer.queueHandler.enqueueNext(items) }
    public func enqueueLast(_ items: [QueueItem]) { audioPlayer.queueHandler.enqueueLast(items) }
    public func enqueueEphemeral(_ items: [QueueItem], at insertAt: Int? = nil) {
        audioPlayer.queueHandler.enqueueEphemeral(items, at: insertAt)
    }
    public func appendContext(_ items: [QueueItem]) { audioPlayer.queueHandler.appendContext(items) }
    public func remove(at offsets: IndexSet) { audioPlayer.queueHandler.remove(at: offsets) }
    public func remove(at index: Int) { audioPlayer.queueHandler.remove(at: IndexSet(integer: index)) }
    public func removeRows(at offsets: IndexSet) { audioPlayer.queueHandler.removeRows(at: offsets) }
    public func move(from: IndexSet, to: Int) { audioPlayer.queueHandler.move(from: from, to: to) }
    public func moveUserQueued(from: IndexSet, to: Int) { audioPlayer.queueHandler.moveUserQueued(from: from, to: to) }
    public func removeUserQueued(at offsets: IndexSet) { audioPlayer.queueHandler.removeUserQueued(at: offsets) }
    public func jump(to index: Int) {
        audioPlayer.queueHandler.jump(to: index)
        Task { await audioPlayer.playCurrent(); refreshPublished() }
    }
    public func clearQueue() {
        audioPlayer.clearQueue()
        lastPersistedPosition = 0
        refreshPublished()
    }
    public func toggleShuffle() { audioPlayer.queueHandler.toggleShuffle() }
    public func setRepeatMode(_ mode: RepeatMode) {
        audioPlayer.queueHandler.setRepeat(mode)
        audioPlayer.applyRepeatMode(mode)
    }
    public func setShuffleMode(_ mode: ShuffleMode) {
        audioPlayer.queueHandler.setShuffle(mode)
    }

    public func requestLyrics() { audioPlayer.requestLyrics() }

    public func setEqualizerBands(_ bands: [Float]) {
        audioPlayer.applyEqualizerBands(bands)
    }

    public func setEqualizerEnabled(_ enabled: Bool) {
        audioPlayer.setEqualizerEnabled(enabled)
    }

    /// Writes the scrub position into the stored queue now. Called when the app leaves the
    /// foreground, where the tick that would have carried it may never arrive.
    public func persistPlaybackPosition() {
        lastPersistedPosition = currentTime
        audioPlayer.queueHandler.updatePlaybackPosition(currentTime)
    }

    private func persistPositionIfDue(_ time: TimeInterval) {
        guard abs(time - lastPersistedPosition) >= Self.positionPersistInterval else { return }
        lastPersistedPosition = time
        audioPlayer.queueHandler.updatePlaybackPosition(time)
    }

    /// Republishes player state after something changed the queue behind the facade —
    /// a cold-launch restore, or an account switch — neither of which arrives through the
    /// playback events the published state normally follows.
    public func syncPublishedState() {
        refreshPublished()
    }

    private var lastArtworkLoadedItemId: String?

    private func refreshPublished() {
        isPlaying = audioPlayer.backend.isPlaying
        let previousId = currentItem?.id
        currentItem = audioPlayer.nowPlaying ?? audioPlayer.queueHandler.currentItem
        currentTime = audioPlayer.backend.currentTime
        duration = audioPlayer.backend.duration
        lyrics = audioPlayer.lyrics
        lyricsLoaded = audioPlayer.lyricsLoaded
        statusMessage = audioPlayer.statusMessage
        let trackChanged = currentItem?.id != previousId
        pushNowPlaying(reloadArtwork: trackChanged || lastArtworkLoadedItemId != currentItem?.id)
    }

    private func pushNowPlaying(reloadArtwork: Bool) {
        let rate = audioPlayer.backend.playbackRate
        nowPlayingHandler?.update(
            item: currentItem,
            isPlaying: isPlaying,
            elapsed: currentTime,
            duration: duration,
            rate: rate
        )
        guard reloadArtwork,
              let artworkId = currentItem?.artworkId,
              let resolver = artworkResolver
        else { return }

        let itemId = currentItem?.id
        Task {
            guard let image = await resolver.managerImage(for: artworkId) else { return }
            guard self.currentItem?.id == itemId else { return }
            self.lastArtworkLoadedItemId = itemId
            self.nowPlayingHandler?.update(
                item: self.currentItem,
                isPlaying: self.isPlaying,
                elapsed: self.currentTime,
                duration: self.duration,
                rate: self.audioPlayer.backend.playbackRate,
                artwork: image
            )
        }
    }
}

extension ArtworkResolver {
    public func managerImage(for token: String) async -> UIImage? {
        if let url = await resolvedURL(
            for: token,
            kind: .album,
            size: ArtworkDownloadManager.largestRequestedSize
        ) {
            if url.isFileURL {
                return UIImage(contentsOfFile: url.path)
            }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                return UIImage(data: data)
            }
        }
        return nil
    }
}
