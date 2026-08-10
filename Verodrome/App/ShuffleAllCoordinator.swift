import Combine
import Foundation
import VerodromeKit

/// What the queue currently playing means for the shuffle control.
enum ShuffleContext {
    /// Seeded by `ShuffleAllCoordinator`, from the server's random endpoint or from the
    /// downloaded library. Either way the order is one the user can't get back.
    case shuffleAll
    /// A slice of the songs library, played in order. The list queues only the rows
    /// around the track that was tapped, so reordering those is a much smaller answer to
    /// "shuffle" than the user is asking for.
    case songsLibrary
}

/// Owns a running "Shuffle All" and keeps its queue topped up.
///
/// The queue is deliberately not the whole library: every backend caps a random request
/// well below that, and a queue in the thousands is expensive to hold, reorder and
/// persist. Instead one batch seeds playback and the next is fetched as the end comes
/// into view, which reads as endless without ever being large.
@MainActor
final class ShuffleAllCoordinator: ObservableObject {
    /// Tracks left ahead of the playing one before the next batch is requested. Enough
    /// to absorb a run of skips without the queue visibly running dry.
    private static let topUpThreshold = 15

    /// True while the first batch is in flight. Worth surfacing: a Subsonic server on a
    /// Navidrome build older than mid-2026 can spend ten seconds on `getRandomSongs`.
    @Published private(set) var isStarting = false

    /// Where the queue playing came from, or nil once the user has played something the
    /// coordinator doesn't know about.
    @Published private(set) var context: ShuffleContext?

    /// The shuffle control shows on and stops responding: the tracks came back in an
    /// order the server chose, so there is no original ordering to return to.
    var isShuffleLocked: Bool { context == .shuffleAll }

    /// Turning shuffle on should draw a fresh batch from the whole library and swap the
    /// queue for it, rather than reordering the handful of rows the list queued.
    var shufflePlaysWholeLibrary: Bool { context == .songsLibrary }

    private weak var player: PlayerViewModel?
    /// Nil once the walk is finished, or when the queue didn't come from one.
    private var session: (any ShuffleBatchSession)?
    /// The player context these belong to. Nil until the player publishes it; a change
    /// means the user started playing something else.
    private var contextGeneration: Int?
    /// A row known to be in the queue we started, used to recognise it when it arrives.
    private var seedEntryId: UUID?
    /// Whether the active Shuffle All walk is limited to downloads. Used so a locked
    /// reshuffle draws from the same pool instead of jumping to the whole library.
    private var shuffleAllIsDownloaded = false
    private var isToppingUp = false
    private var cancellables = Set<AnyCancellable>()

    func attach(player: PlayerViewModel) {
        self.player = player
        cancellables.removeAll()
        player.$currentItem
            .sink { [weak self] _ in self?.refreshContext() }
            .store(in: &cancellables)
    }

    /// Records that the player is starting on the songs library, so a later tap on
    /// shuffle knows it can reach for the whole thing.
    func trackSongsLibrary(seededBy item: QueueItem) {
        session = nil
        shuffleAllIsDownloaded = false
        begin(.songsLibrary, seedEntryId: item.entryId)
    }

    @discardableResult
    func shuffleAll() async -> Bool {
        guard let provider = VerodromeKit.shared.activeLibrarySyncer as? (any RandomSongProviding) else {
            return false
        }
        return await start(
            ShuffleAllSession(
                provider: provider,
                resolver: LocalLibrarySongResolver(
                    accountKey: AccountStore.shared.activeAccountKey()?.storageKey
                ),
                ingestor: VerodromeKit.shared.activeLibraryIngester
            ),
            downloadedOnly: false
        )
    }

    /// Shuffle All narrowed to the songs on disk, drawn from the local library rather
    /// than the backend — a random endpoint can't be told to stay within what this
    /// device downloaded, and this has to work with no network at all.
    @discardableResult
    func shuffleDownloaded() async -> Bool {
        await start(DownloadedShuffleSession(), downloadedOnly: true)
    }

    /// Fresh Shuffle All batch for the locked control: same pool as the walk already
    /// playing, replacing the queue and the current track.
    @discardableResult
    func reshuffle() async -> Bool {
        guard context == .shuffleAll else { return false }
        return shuffleAllIsDownloaded ? await shuffleDownloaded() : await shuffleAll()
    }

    private func start(_ session: any ShuffleBatchSession, downloadedOnly: Bool) async -> Bool {
        guard !isStarting, let player else { return false }

        isStarting = true
        defer { isStarting = false }

        // Keep the locked appearance up while a replacement batch loads; only tear the
        // old walk down enough that it stops topping up behind the fetch.
        let refreshingLocked = context == .shuffleAll
        if refreshingLocked {
            self.session = nil
            isToppingUp = false
        } else {
            clearContext()
        }

        let items: [QueueItem]
        do {
            items = try await session.next(count: nil)
        } catch {
            await EventLogger.shared.error("shuffle", "Shuffle all failed: \(error.localizedDescription)")
            return false
        }
        guard let first = items.first else { return false }

        // Replaces whatever was playing, the current track included. The batch already
        // arrives in random order, so start at the top with shuffle off: letting shuffle
        // pick the start index would drop everything before it.
        // Shuffle stays off (no original order to restore), but `arrivedShuffled` tells
        // the queue screen the batch is still user-arrangeable.
        player.play(items: items, startAt: 0, shuffle: false, arrivedShuffled: true)
        self.session = session
        shuffleAllIsDownloaded = downloadedOnly
        begin(.shuffleAll, seedEntryId: first.entryId)
        return true
    }

    private func begin(_ context: ShuffleContext, seedEntryId: UUID) {
        self.context = context
        self.seedEntryId = seedEntryId
        contextGeneration = nil
        // Keep the player's rearrange flag aligned with the session: the queue screen
        // and move/remove guards both read it.
        if context == .shuffleAll {
            player?.markQueueArrivedShuffled()
        }
    }

    private func clearContext() {
        // Leave `queueArrivedShuffled` alone — `play` owns that flag. Clearing it here
        // would race the install of a Shuffle All batch and leave the queue read-only.
        session = nil
        context = nil
        contextGeneration = nil
        seedEntryId = nil
        shuffleAllIsDownloaded = false
    }

    /// Follows the player between contexts, and tops the queue up while it's still ours.
    private func refreshContext() {
        guard let player, context != nil else { return }

        guard let generation = contextGeneration else {
            // First publish after starting. Check the queue on screen really is the one
            // we started before adopting its generation: the user can get an album
            // playing in the time it takes a batch to come back over the network.
            // `PlayerViewModel` syncs `queue` before publishing `currentItem` so this
            // check does not race the install of our own context.
            guard player.queue.contains(where: { $0.entryId == seedEntryId }) else {
                clearContext()
                return
            }
            contextGeneration = player.contextGeneration
            return
        }
        guard player.contextGeneration == generation else {
            clearContext()
            return
        }

        topUpIfNeeded(player)
    }

    private func topUpIfNeeded(_ player: PlayerViewModel) {
        guard let session, !isToppingUp else { return }

        let remaining = player.queue.count - player.currentIndex - 1
        guard remaining <= Self.topUpThreshold else { return }

        isToppingUp = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isToppingUp = false }
            do {
                let items = try await session.next(count: nil)
                // The user may have played something else while the batch was in flight.
                guard self.session === session,
                      let player = self.player,
                      player.contextGeneration == self.contextGeneration else { return }
                if items.isEmpty {
                    // Nothing left to add, but the queue is still ours and still shuffled,
                    // so the context — and the locked control — stay as they are.
                    self.session = nil
                } else {
                    player.appendToQueue(items)
                }
            } catch {
                await EventLogger.shared.warning(
                    "shuffle",
                    "Shuffle top-up failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
