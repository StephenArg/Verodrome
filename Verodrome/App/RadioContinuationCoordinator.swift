import Combine
import Foundation
import VerodromeKit

/// Tops up the play queue with zipper-merged song radio when the end is near.
///
/// When Repeat is off and only a few tracks remain, picks 1–3 seeds from the queue,
/// fetches similar songs, zipper-merges them, and appends a radio-continuation section.
/// Repeat All cancels in-flight work and stops topping up; turning it off re-enables.
@MainActor
final class RadioContinuationCoordinator: ObservableObject {
    private weak var player: PlayerViewModel?
    private weak var shuffleAll: ShuffleAllCoordinator?
    private var isToppingUp = false
    private var topUpTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func attach(player: PlayerViewModel, shuffleAll: ShuffleAllCoordinator) {
        self.player = player
        self.shuffleAll = shuffleAll
        cancellables.removeAll()
        player.$currentItem
            .sink { [weak self] _ in self?.topUpIfNeeded() }
            .store(in: &cancellables)
        player.$repeatMode
            .sink { [weak self] mode in
                if mode != .off {
                    self?.cancelInFlight()
                } else {
                    self?.topUpIfNeeded()
                }
            }
            .store(in: &cancellables)
        SettingsStore.shared.$radioContinuationEnabled
            .sink { [weak self] enabled in
                if enabled {
                    self?.topUpIfNeeded()
                } else {
                    self?.cancelInFlight()
                }
            }
            .store(in: &cancellables)
    }

    private func cancelInFlight() {
        topUpTask?.cancel()
        topUpTask = nil
        isToppingUp = false
    }

    private func topUpIfNeeded() {
        guard let player else { return }
        guard SettingsStore.shared.radioContinuationEnabled else { return }
        guard player.repeatMode == .off else { return }
        guard shuffleAll?.context != .shuffleAll else { return }
        guard !isToppingUp else { return }

        let queue = player.queue
        guard !queue.isEmpty else { return }
        guard player.currentItem?.kind == .song else { return }
        guard player.currentItem?.isLiveStream != true else { return }

        let remaining = queue.count - player.currentIndex - 1
        guard remaining <= SongRadioQueue.continuationThreshold else { return }

        // Need at least one song seed available.
        let seeds = SongRadioQueue.pickContinuationSeeds(from: queue)
        guard !seeds.isEmpty else { return }

        let generation = player.contextGeneration
        let excluding = Set(queue.map(\.playableId))
        isToppingUp = true
        topUpTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isToppingUp = false
                self.topUpTask = nil
            }

            let outcome = await LibraryActions.shared.prepareRadioContinuation(
                seeds: seeds,
                excluding: excluding
            )

            guard !Task.isCancelled else { return }
            guard let player = self.player else { return }
            // Context replaced, setting turned off, or Repeat turned on — drop the batch.
            guard SettingsStore.shared.radioContinuationEnabled else { return }
            guard player.contextGeneration == generation else { return }
            guard player.repeatMode == .off else { return }
            guard self.shuffleAll?.context != .shuffleAll else { return }

            if case .ready(let items) = outcome, !items.isEmpty {
                player.appendToQueue(items)
            }
        }
    }
}
