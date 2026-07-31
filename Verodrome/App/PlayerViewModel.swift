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
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentItem: QueueItem?
    @Published var queue: [QueueItem] = []
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleMode: ShuffleMode = .off
    @Published var lyrics = ""
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
            self?.queue = impl.queue
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
        impl.$lyrics.receive(on: DispatchQueue.main).assign(to: &$lyrics)
        impl.$statusMessage.receive(on: DispatchQueue.main).assign(to: &$statusMessage)
        queue = impl.queue
        let user = SettingsStore.shared.loadUserSettings()
        equalizerBands = user.equalizerBands
        equalizerEnabled = user.equalizerEnabled
        isOfflineMode = SettingsStore.shared.offlineModeEnabled
        // Apply persisted EQ into the live audio graph.
        impl.setEqualizerEnabled(equalizerEnabled)
        impl.setEqualizerBands(equalizerBands)
    }

    func play(items: [QueueItem], startAt index: Int = 0) {
        guard !items.isEmpty else {
            PlayTrace.error("PlayerViewModel.play — empty items")
            return
        }
        let startIndex = items.indices.contains(index) ? index : 0
        PlayTrace.mark(
            "PlayerViewModel.play → Task",
            details: "count=\(items.count) startAt=\(startIndex) title=\(items[startIndex].title)"
        )
        Task(priority: .userInitiated) {
            PlayTrace.mark("PlayerViewModel Task running (await facade)")
            await facade?.play(items: items, startAt: startIndex)
            queue = facade?.queue ?? items
            currentItem = facade?.currentItem
            progress.duration = facade?.duration ?? items[startIndex].duration
            PlayTrace.mark("PlayerViewModel UI state updated after facade")
        }
    }

    func playNext(_ items: [QueueItem]) {
        facade?.enqueueNext(items)
        queue = facade?.queue ?? queue
    }

    func playPause() {
        facade?.togglePlayPause()
    }

    func skipForward() {
        facade?.next()
        queue = facade?.queue ?? queue
        currentItem = facade?.currentItem
    }

    func skipBackward() {
        // The restart-vs-previous-track decision lives in the player, which also knows
        // whether the engine can still seek at all.
        facade?.previous()
        queue = facade?.queue ?? queue
        currentItem = facade?.currentItem
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(progress.duration, 1))
        facade?.seek(to: clamped)
        progress.currentTime = clamped
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        facade?.move(from: source, to: destination)
        queue = facade?.queue ?? queue
    }

    func removeFromQueue(at offsets: IndexSet) {
        facade?.remove(at: offsets)
        queue = facade?.queue ?? queue
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
        queue = facade?.queue ?? queue
        // Keep displayed now-playing in sync; shuffle must not change the playing track.
        currentItem = facade?.currentItem ?? currentItem
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
