import Combine
import Foundation
import VerodromeKit

/// High-frequency playback clock. Kept separate from `PlayerViewModel` so library lists
/// that only need now-playing identity are not redrawn on every progress tick.
@MainActor
final class PlayerProgressModel: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

/// Narrow now-playing identity. Kept separate from `PlayerViewModel` so library lists
/// and tab chrome that only need to know *what* is playing are not redrawn on every
/// queue / EQ / lyrics change.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var currentItem: QueueItem?
    @Published var isPlaying = false

    /// Whether `playableId` is the track the player is currently on. Nil-safe in
    /// both directions, so an idle player never marks rows that have no id.
    func isCurrent(_ playableId: String?) -> Bool {
        guard let playableId, let current = currentItem?.playableId else { return false }
        return current == playableId
    }
}

/// Queue sheet identity + mutations. Kept separate from `PlayerViewModel` so scrolling
/// the queue isn't invalidated by lyrics / EQ / progress / hold-speed publishes.
@MainActor
final class QueueListModel: ObservableObject {
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var currentEntryId: UUID?
    @Published private(set) var userQueuedRange: Range<Int> = 0..<0
    @Published private(set) var isReorderable = false
    @Published private(set) var queueOrigin: QueueOrigin?
    @Published private(set) var repeatMode: RepeatMode = .off

    fileprivate weak var player: PlayerViewModel?

    func apply(
        queue: [QueueItem],
        currentIndex: Int,
        origin: QueueOrigin? = nil,
        repeatMode: RepeatMode = .off
    ) {
        let entryId = queue.indices.contains(currentIndex) ? queue[currentIndex].entryId : nil
        let range = queue.userQueuedRun(after: currentIndex)
        let reorderable = !queue.isEmpty
        guard self.queue != queue
            || self.currentIndex != currentIndex
            || self.currentEntryId != entryId
            || self.userQueuedRange != range
            || self.isReorderable != reorderable
            || self.queueOrigin != origin
            || self.repeatMode != repeatMode
        else { return }
        self.queue = queue
        self.currentIndex = currentIndex
        self.currentEntryId = entryId
        self.userQueuedRange = range
        self.isReorderable = reorderable
        self.queueOrigin = origin
        self.repeatMode = repeatMode
    }

    func jump(to index: Int) { player?.jump(to: index) }
    func moveQueue(from source: IndexSet, to destination: Int) {
        player?.moveQueue(from: source, to: destination)
    }
    func removeFromQueue(at offsets: IndexSet) { player?.removeFromQueue(at: offsets) }
    func moveUserQueued(from source: IndexSet, to destination: Int) {
        player?.moveUserQueued(from: source, to: destination)
    }
    func removeUserQueued(at offsets: IndexSet) { player?.removeUserQueued(at: offsets) }
    func addToQueueTemporarily(_ items: [QueueItem], at insertAt: Int? = nil) {
        player?.addToQueueTemporarily(items, at: insertAt)
    }
}

/// Which way playback moved through the queue, so the player's cover can slide the way
/// the listener just travelled.
enum ArtworkSlideDirection {
    case forward
    case backward
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentItem: QueueItem?
    @Published var queue: [QueueItem] = []
    /// Position of the playing track within `queue`. Rows are identified by position, so
    /// a duplicated song can't light up the wrong row.
    @Published private(set) var currentIndex = 0
    /// Changes whenever a new context starts playing. Owners of an open-ended context
    /// watch it to know the user moved on to something else.
    @Published private(set) var contextGeneration = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleMode: ShuffleMode = .off
    /// Set for a queue that arrived already shuffled — Shuffle All draws a random batch
    /// from the server, so the shuffle control reads off even though nothing about the
    /// order is the user's choosing.
    @Published private(set) var queueArrivedShuffled = false
    @Published var lyrics = "" {
        didSet {
            guard lyrics != oldValue else { return }
            lyricLines = LyricsParser.parse(lyrics)
        }
    }
    /// Parsed form of `lyrics`, cached so the lyrics panel doesn't reparse on every
    /// playback tick.
    @Published private(set) var lyricLines: [LyricLine] = []
    /// True once the lyrics lookup for the current track has finished, found or not.
    @Published private(set) var lyricsLoaded = false
    /// Non-empty while playback is stalled, e.g. waiting for the network to come back.
    @Published var statusMessage = ""
    @Published var equalizerBands: [Float] = Array(repeating: 0, count: 10)
    @Published var equalizerEnabled = false
    @Published var isOfflineMode = false
    /// Sticky playback speed for the current queue context (`1` = normal).
    @Published private(set) var playbackSpeed: Float = 1
    /// True while Random mode rolls a per-track rate from `PlaybackSpeed.randomOptions`.
    @Published private(set) var isRandomPlaybackSpeed = false
    /// Temporary hold-to-scrub rate (`2` / `0.5`) while a skip control is held; nil otherwise.
    @Published private(set) var holdSpeedRate: Float?
    /// Wall-clock deadline for the sleep timer. Nil while inactive.
    @Published private(set) var sleepTimerDeadline: Date?
    /// Direction of the last move through the queue. Derived from the index rather than
    /// the transport buttons so auto-advance, CarPlay and the lock screen all animate the
    /// same way as a tap on skip.
    @Published private(set) var artworkSlideDirection: ArtworkSlideDirection = .forward
    /// True while Start Radio is waiting on the server for similar songs.
    @Published private(set) var isStartingRadio = false
    /// Seed track title for the active song-radio context. Nil for album / playlist / etc.
    @Published private(set) var radioSeedTitle: String?
    /// Album / playlist / song that seeded the playing context — labels radio continuation.
    @Published private(set) var queueOrigin: QueueOrigin?

    let progress = PlayerProgressModel()
    let nowPlaying = NowPlayingModel()
    let queueList = QueueListModel()

    func beginStartingRadio() {
        isStartingRadio = true
    }

    func endStartingRadio() {
        isStartingRadio = false
    }

    private var facade: PlayerFacadeImpl?
    private var cancellables = Set<AnyCancellable>()

    init() {
        queueList.player = self
    }

    func attach(facade: (any PlayerFacade)?) {
        cancellables.removeAll()
        queueList.player = self
        guard let impl = facade as? PlayerFacadeImpl else { return }
        self.facade = impl
        impl.$isPlaying.receive(on: DispatchQueue.main).assign(to: &$isPlaying)
        impl.$sessionPlaybackRate.receive(on: DispatchQueue.main).assign(to: &$playbackSpeed)
        impl.$isRandomPlaybackSpeed.receive(on: DispatchQueue.main).assign(to: &$isRandomPlaybackSpeed)
        impl.$sleepTimerDeadline.receive(on: DispatchQueue.main).assign(to: &$sleepTimerDeadline)
        impl.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.nowPlaying.isPlaying = value
        }.store(in: &cancellables)
        impl.$currentItem.receive(on: DispatchQueue.main).sink { [weak self] item in
            guard let self else { return }
            // Queue before `currentItem`: ShuffleAllCoordinator watches `$currentItem` and
            // checks whether its seed is already in `queue`. Publishing the item first
            // left that check looking at the previous context and clearing the session.
            self.syncQueue()
            self.currentItem = item
            self.nowPlaying.currentItem = item
            self.progress.duration = impl.duration
            self.repeatMode = impl.repeatMode
            self.shuffleMode = impl.shuffleMode
        }.store(in: &cancellables)
        impl.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] time in
            guard let self else { return }
            // Avoid redundant publishes that thrash SwiftUI (slider/tab gestures).
            if abs(self.progress.currentTime - time) >= 0.05 || (time == 0 && self.progress.currentTime != 0) {
                self.progress.currentTime = time
            }
        }.store(in: &cancellables)
        impl.$duration.receive(on: DispatchQueue.main).sink { [weak self] duration in
            guard let self else { return }
            if abs(self.progress.duration - duration) >= 0.05 || (duration > 0 && self.progress.duration == 0) {
                self.progress.duration = duration
            }
        }.store(in: &cancellables)
        // `sink` rather than `assign(to:)` so the `didSet` reparse actually runs.
        impl.$lyrics.receive(on: DispatchQueue.main).sink { [weak self] text in
            self?.lyrics = text
        }.store(in: &cancellables)
        impl.$lyricsLoaded.receive(on: DispatchQueue.main).assign(to: &$lyricsLoaded)
        impl.$statusMessage.receive(on: DispatchQueue.main).assign(to: &$statusMessage)
        syncQueue()
        let user = SettingsStore.shared.loadUserSettings()
        equalizerBands = user.equalizerBands
        equalizerEnabled = user.equalizerEnabled
        isOfflineMode = SettingsStore.shared.offlineModeEnabled
        // Apply persisted EQ into the live audio graph.
        impl.setEqualizerEnabled(equalizerEnabled)
        impl.setEqualizerBands(equalizerBands)
    }

    /// - Parameters:
    ///   - index: Track to start on. When nil, Shuffle picks a random track and Play
    ///     starts on the first.
    ///   - shuffle: Explicit shuffle state for the new context; nil keeps the current one.
    ///   - arrivedShuffled: The items are already in random order (Shuffle All). Shuffle
    ///     stays off so there is no original order to restore, but the queue is still
    ///     treated as user-arrangeable.
    ///   - radioSeedTitle: When non-nil, the queue is a song radio seeded by this title.
    ///   - origin: Where this context came from — used to label a radio-continuation section.
    func play(
        items: [QueueItem],
        startAt index: Int? = nil,
        shuffle: Bool? = nil,
        arrivedShuffled: Bool = false,
        radioSeedTitle: String? = nil,
        origin: QueueOrigin? = nil
    ) {
        guard !items.isEmpty else {
            PlayTrace.error("PlayerViewModel.play — empty items")
            return
        }
        let trimmedSeed = radioSeedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.radioSeedTitle = (trimmedSeed?.isEmpty == false) ? trimmedSeed : nil
        self.queueOrigin = origin
        queueArrivedShuffled = arrivedShuffled
        let mode: ShuffleMode? = shuffle.map { $0 ? .on : .off }
        let startIndex: Int
        if let index, items.indices.contains(index) {
            startIndex = index
        } else if mode == .on || (mode == nil && shuffleMode == .on) {
            // Shuffle starts on a random track; replaceContext keeps that track at the
            // front of the shuffled remainder.
            startIndex = items.indices.randomElement() ?? 0
        } else {
            startIndex = 0
        }
        PlayTrace.mark(
            "PlayerViewModel.play → Task",
            details: "count=\(items.count) startAt=\(startIndex) title=\(items[startIndex].title)"
        )
        let seedEntryId = items[startIndex].entryId
        Task(priority: .userInitiated) {
            PlayTrace.mark("PlayerViewModel Task running (await facade)")
            await facade?.play(items: items, startAt: startIndex, shuffle: mode, origin: origin)
            // A newer `play` may have replaced the context while we were awaiting.
            let stillOurs = facade?.currentItem?.entryId == seedEntryId
                || (facade?.queue.contains { $0.entryId == seedEntryId } ?? false)
            guard stillOurs else { return }
            syncQueue(fallback: items)
            currentItem = facade?.currentItem
            shuffleMode = facade?.shuffleMode ?? shuffleMode
            queueOrigin = facade?.queueOrigin ?? origin
            // Re-assert after the await so the flag matches the context that landed.
            queueArrivedShuffled = arrivedShuffled
            progress.duration = facade?.duration ?? items[startIndex].duration
            PlayTrace.mark("PlayerViewModel UI state updated after facade")
        }
    }

    /// Queues items to play next for one listen only — they leave the queue, and the
    /// cache, as soon as playback moves past them.
    func addToQueueTemporarily(_ items: [QueueItem], at insertAt: Int? = nil) {
        guard !items.isEmpty else { return }
        facade?.enqueueEphemeral(items, at: insertAt)
        syncQueue()
        ActionToast.addedToQueue()
    }

    /// Extends the playing context. Unlike `addToQueueTemporarily`, these are not
    /// user-queued rows — they belong to the context, which is what an open-ended
    /// shuffle keeps topping up.
    func appendToQueue(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        facade?.appendContext(items)
        syncQueue()
    }

    /// Mirrors the player's queue snapshot into the state the UI observes.
    private func syncQueue(fallback: [QueueItem]? = nil) {
        let previousIndex = currentIndex
        let previousGeneration = contextGeneration
        queue = facade?.queue ?? fallback ?? queue
        currentIndex = facade?.currentIndex ?? currentIndex
        contextGeneration = facade?.contextGeneration ?? contextGeneration
        queueOrigin = facade?.queueOrigin ?? queueOrigin
        if let facade {
            repeatMode = facade.repeatMode
        }
        queueList.apply(queue: queue, currentIndex: currentIndex, origin: queueOrigin, repeatMode: repeatMode)
        // A brand-new context isn't a step through a queue, so its index delta says
        // nothing about direction — leave the last one standing.
        if contextGeneration == previousGeneration,
           let direction = Self.slideDirection(
            from: previousIndex,
            to: currentIndex,
            count: queue.count,
            queue: queue
           ) {
            artworkSlideDirection = direction
        }
        PlayerArtworkWarmer.shared.warm(queue: queue, currentIndex: currentIndex, repeatMode: repeatMode)
    }

    /// Queue rows artwork swipe can peek. Same wrap rules as skip, from the published snapshot.
    var adjacentQueueItems: (previous: QueueItem?, next: QueueItem?) {
        PlayQueueHandler.peekAdjacent(queue: queue, currentIndex: currentIndex, repeatMode: repeatMode)
    }

    /// Nil when the queue didn't move. Repeat-all wraps the index around the ends, and
    /// that is still one step forward (or back), not a jump the length of the queue.
    /// When a radio-continuation tail exists, wrap is scoped to the original context.
    private static func slideDirection(from previous: Int, to new: Int, count: Int, queue: [QueueItem]) -> ArtworkSlideDirection? {
        guard count > 0, previous != new else { return nil }
        let scope = queue.indices.filter { !queue[$0].isRadioContinuation }
        let wrapScope = scope.isEmpty || scope.count == queue.count ? Array(queue.indices) : scope
        if let first = wrapScope.first, let last = wrapScope.last {
            if previous == last, new == first { return .forward }
            if previous == first, new == last { return .backward }
        }
        return new > previous ? .forward : .backward
    }

    func playPause() {
        facade?.togglePlayPause()
    }

    func skipForward() {
        facade?.next()
        syncQueue()
        currentItem = facade?.currentItem
    }

    func skipBackward() {
        // The restart-vs-previous-track decision lives in the player, which also knows
        // whether the engine can still seek at all.
        facade?.previous()
        syncQueue()
        currentItem = facade?.currentItem
    }

    /// Always the previous queue row. Artwork swipe has already peeked that cover, so
    /// the button's restart-if-late rule would fight the animation.
    func skipToPreviousTrack() {
        facade?.previousItem()
        syncQueue()
        currentItem = facade?.currentItem
    }

    /// Jump straight to a track in the queue (queue sheet tap). Same-index tap restarts
    /// the current track rather than reloading it through the network.
    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        if index == currentIndex {
            seek(to: 0)
            if !isPlaying { facade?.play() }
            return
        }
        facade?.jump(to: index)
        syncQueue()
        currentItem = facade?.currentItem
        nowPlaying.currentItem = currentItem
    }

    /// Hold skip-forward = 2×, hold previous = 0.5×. Starts playback if paused.
    func beginHoldSpeed(_ rate: Float) {
        guard currentItem?.isLiveStream != true else { return }
        if !isPlaying {
            facade?.play()
            isPlaying = facade?.isPlaying ?? isPlaying
        }
        holdSpeedRate = rate
        facade?.setPlaybackRate(rate)
    }

    func endHoldSpeed() {
        holdSpeedRate = nil
        facade?.restoreSessionPlaybackRate()
    }

    /// Sets a fixed sticky playback speed for the current play context (exits Random).
    func setPlaybackSpeed(_ rate: Float) {
        guard currentItem?.isLiveStream != true else { return }
        facade?.setSessionPlaybackRate(rate)
        playbackSpeed = facade?.sessionPlaybackRate ?? PlaybackSpeed.clamp(rate)
        isRandomPlaybackSpeed = facade?.isRandomPlaybackSpeed ?? false
    }

    /// Enables Random mode and rolls a rate for the current track.
    func setPlaybackSpeedRandom() {
        guard currentItem?.isLiveStream != true else { return }
        facade?.setRandomPlaybackSpeed()
        playbackSpeed = facade?.sessionPlaybackRate ?? playbackSpeed
        isRandomPlaybackSpeed = facade?.isRandomPlaybackSpeed ?? true
    }

    /// Starts (or restarts) a sleep timer for the given hours and minutes.
    func startSleepTimer(hours: Int, minutes: Int) {
        let duration = SleepTimer.duration(hours: hours, minutes: minutes)
        facade?.startSleepTimer(duration)
        sleepTimerDeadline = facade?.sleepTimerDeadline
    }

    /// Clears an active sleep timer without pausing playback.
    func cancelSleepTimer() {
        facade?.cancelSleepTimer()
        sleepTimerDeadline = nil
    }

    /// Asks the player to look up lyrics for the current track now, for when the
    /// automatic lookup is disabled or hasn't run yet.
    func requestLyrics() {
        facade?.requestLyrics()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(progress.duration, 1))
        facade?.seek(to: clamped)
        progress.currentTime = clamped
    }

    /// Records that the queue playing was handed over pre-shuffled, so the queue screen
    /// offers the same rearranging a locally shuffled one does.
    func markQueueArrivedShuffled() {
        queueArrivedShuffled = true
    }

    /// Any non-empty queue can be rearranged. An ordered album / playlist is not sacred —
    /// playing it again rebuilds the queue from the source.
    var isQueueReorderable: Bool { !queue.isEmpty }

    func moveQueue(from source: IndexSet, to destination: Int) {
        guard isQueueReorderable else { return }
        facade?.move(from: source, to: destination)
        syncQueue()
    }

    /// Drops rows from the queue, context tracks included. The playing one stays:
    /// removing it would leave the engine on a track no longer listed.
    func removeFromQueue(at offsets: IndexSet) {
        guard isQueueReorderable else { return }
        let removable = offsets.filter { queue.indices.contains($0) && $0 != currentIndex }
        guard !removable.isEmpty else { return }
        facade?.removeRows(at: IndexSet(removable))
        syncQueue()
    }

    /// Positions in `queue` holding the songs the user added themselves, which the queue
    /// screen lists as its own section. Derived from the same snapshot the rows render
    /// from, so section offsets can't drift from what is on screen.
    var userQueuedRange: Range<Int> { queue.userQueuedRun(after: currentIndex) }

    /// Reordering and removing what the user queued needs no shuffle, unlike the rest of
    /// the queue: that section is a list they built, not the order an album came in.
    /// Offsets are relative to the section.
    func moveUserQueued(from source: IndexSet, to destination: Int) {
        facade?.moveUserQueued(from: source, to: destination)
        syncQueue()
    }

    func removeUserQueued(at offsets: IndexSet) {
        facade?.removeUserQueued(at: offsets)
        syncQueue()
    }

    /// Empties the queue and forgets the one kept for the next launch.
    func clearQueue() {
        facade?.clearQueue()
        queue = []
        currentIndex = 0
        queueList.apply(queue: [], currentIndex: 0)
        currentItem = nil
        nowPlaying.currentItem = nil
        nowPlaying.isPlaying = false
        isPlaying = false
        lyrics = ""
        statusMessage = ""
        radioSeedTitle = nil
        queueOrigin = nil
        playbackSpeed = facade?.sessionPlaybackRate ?? 1
        isRandomPlaybackSpeed = facade?.isRandomPlaybackSpeed ?? false
        sleepTimerDeadline = facade?.sleepTimerDeadline
        progress.currentTime = 0
        progress.duration = 0
    }

    func toggleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        facade?.setRepeatMode(repeatMode)
        queueList.apply(
            queue: queue,
            currentIndex: currentIndex,
            origin: queueOrigin,
            repeatMode: repeatMode
        )
    }

    func toggleShuffle() {
        facade?.toggleShuffle()
        shuffleMode = facade?.shuffleMode ?? shuffleMode
        syncQueue()
        // Title / artwork follow `currentItem`, while the queue highlight follows
        // `currentIndex`. Re-anchor from the queue pointer so a stale facade publish
        // from mid-shuffle cannot leave the player showing a different song.
        if queue.indices.contains(currentIndex) {
            let item = queue[currentIndex]
            currentItem = item
            nowPlaying.currentItem = item
        }
    }

    func toggleOfflineMode() {
        isOfflineMode.toggle()
        SettingsStore.shared.offlineModeEnabled = isOfflineMode
        SettingsStore.shared.save()
        NotificationCenter.default.post(name: .offlineModeChanged, object: nil)
    }

    /// Apply bands to the live audio graph without disk I/O (safe during slider drag).
    func applyEqualizerBandsLive(_ bands: [Float]) {
        if !equalizerEnabled {
            equalizerEnabled = true
            facade?.setEqualizerEnabled(true)
        }
        facade?.setEqualizerBands(bands)
    }

    func applyEqualizerBands() {
        // Touching the EQ from the player UI implies it should be active.
        if !equalizerEnabled {
            equalizerEnabled = true
        }
        facade?.setEqualizerEnabled(equalizerEnabled)
        facade?.setEqualizerBands(equalizerBands)
        var user = SettingsStore.shared.loadUserSettings()
        user.equalizerBands = equalizerBands
        user.equalizerEnabled = equalizerEnabled
        SettingsStore.shared.saveUserSettings(user)
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        equalizerEnabled = enabled
        facade?.setEqualizerEnabled(enabled)
        facade?.setEqualizerBands(equalizerBands)
        var user = SettingsStore.shared.loadUserSettings()
        user.equalizerEnabled = enabled
        user.equalizerBands = equalizerBands
        SettingsStore.shared.saveUserSettings(user)
    }
}
