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

    let progress = PlayerProgressModel()
    let nowPlaying = NowPlayingModel()

    private var facade: PlayerFacadeImpl?
    private var cancellables = Set<AnyCancellable>()

    func attach(facade: (any PlayerFacade)?) {
        cancellables.removeAll()
        guard let impl = facade as? PlayerFacadeImpl else { return }
        self.facade = impl
        impl.$isPlaying.receive(on: DispatchQueue.main).assign(to: &$isPlaying)
        impl.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.nowPlaying.isPlaying = value
        }.store(in: &cancellables)
        impl.$currentItem.receive(on: DispatchQueue.main).sink { [weak self] item in
            self?.currentItem = item
            self?.nowPlaying.currentItem = item
            self?.progress.duration = impl.duration
            self?.syncQueue()
            self?.repeatMode = impl.repeatMode
            self?.shuffleMode = impl.shuffleMode
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
    func play(items: [QueueItem], startAt index: Int? = nil, shuffle: Bool? = nil) {
        guard !items.isEmpty else {
            PlayTrace.error("PlayerViewModel.play — empty items")
            return
        }
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
        Task(priority: .userInitiated) {
            PlayTrace.mark("PlayerViewModel Task running (await facade)")
            await facade?.play(items: items, startAt: startIndex, shuffle: mode)
            syncQueue(fallback: items)
            currentItem = facade?.currentItem
            shuffleMode = facade?.shuffleMode ?? shuffleMode
            progress.duration = facade?.duration ?? items[startIndex].duration
            PlayTrace.mark("PlayerViewModel UI state updated after facade")
        }
    }

    func playNext(_ items: [QueueItem]) {
        facade?.enqueueNext(items)
        syncQueue()
    }

    /// Extends the playing context. Unlike `playNext`, these are not user-queued rows —
    /// they belong to the context, which is what an open-ended shuffle keeps topping up.
    func appendToQueue(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        facade?.appendContext(items)
        syncQueue()
    }

    /// Mirrors the player's queue snapshot into the state the UI observes.
    private func syncQueue(fallback: [QueueItem]? = nil) {
        queue = facade?.queue ?? fallback ?? queue
        currentIndex = facade?.currentIndex ?? currentIndex
        contextGeneration = facade?.contextGeneration ?? contextGeneration
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
        facade?.setPlaybackRate(rate)
    }

    func endHoldSpeed() {
        facade?.setPlaybackRate(1)
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

    /// Reordering is offered only for a shuffled queue — played in order, the queue is the
    /// album / playlist exactly as the user asked for it.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard shuffleMode == .on else { return }
        facade?.move(from: source, to: destination)
        syncQueue()
    }

    /// Only songs the user queued themselves ("Play Next") can be taken back out.
    func removeFromQueue(at offsets: IndexSet) {
        guard shuffleMode == .on else { return }
        let removable = offsets.filter { queue.indices.contains($0) && queue[$0].isUserQueued }
        guard !removable.isEmpty else { return }
        facade?.remove(at: IndexSet(removable))
        syncQueue()
    }

    func toggleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .one
        case .one: repeatMode = .all
        case .all: repeatMode = .off
        }
        facade?.setRepeatMode(repeatMode)
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
