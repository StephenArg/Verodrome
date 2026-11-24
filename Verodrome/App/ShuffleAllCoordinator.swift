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
    /// The player's context generation when ours was handed to it. Until that moves on,
    /// the queue on screen is still the previous one and ours just hasn't landed yet.
    private var generationAtBegin: Int?
    /// Whether the active Shuffle All walk is limited to downloads. Used so a locked
    /// reshuffle draws from the same pool instead of jumping to the whole library.
    private var shuffleAllIsDownloaded = false
    private var isToppingUp = false
    private var cancellables = Set<AnyCancellable>()

    func attach(player: PlayerViewModel) {
        self.player = player
        cancellables.removeAll()
        // `$queue` is there because Hide Explicit can drop upcoming rows without changing
        // the current track. `@Published` emits from `willSet`, so reading the player
        // inside a direct sink sees the queue and generation from before the change —
        // which made a freshly started walk look like someone else's queue. Hop to the
        // next main-queue turn so the player has finished updating before we look.
        player.$currentItem.map { _ in () }
            .merge(with: player.$queue.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshContext() }
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
        guard let session = makeSession(downloadedOnly: false) else { return false }
        return await start(session, downloadedOnly: false)
    }

    /// Shuffle All narrowed to the songs on disk, drawn from the local library rather
    /// than the backend — a random endpoint can't be told to stay within what this
    /// device downloaded, and this has to work with no network at all.
    @discardableResult
    func shuffleDownloaded() async -> Bool {
        guard let session = makeSession(downloadedOnly: true) else { return false }
        return await start(session, downloadedOnly: true)
    }

    /// A walk over the whole library or over what's on disk. Nil when the backend has
    /// no random endpoint to walk.
    /// - Parameter excluding: Track ids the walk should never hand out.
    private func makeSession(
        downloadedOnly: Bool,
        excluding: Set<String> = []
    ) -> (any ShuffleBatchSession)? {
        let hideExplicit = SettingsStore.shared.hideExplicitSongs
        if downloadedOnly {
            return DownloadedShuffleSession(hideExplicit: hideExplicit, excluding: excluding)
        }
        guard let provider = VerodromeKit.shared.activeLibrarySyncer as? (any RandomSongProviding) else {
            return nil
        }
        return ShuffleAllSession(
            provider: provider,
            resolver: LocalLibrarySongResolver(
                accountKey: AccountStore.shared.activeAccountKey()?.storageKey
            ),
            ingestor: VerodromeKit.shared.activeLibraryIngester,
            hideExplicit: hideExplicit,
            excluding: excluding
        )
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

        // Whatever the shuffle control is showing stays up while the batch loads: locked
        // for a reshuffle, or the songs-list state, which is where the spinner shows.
        // Clearing it here hid the control for the length of the fetch. The walk being
        // replaced only has to stop topping up behind that fetch.
        let interrupted = self.session
        self.session = nil
        isToppingUp = false

        let items: [QueueItem]
        do {
            items = try await session.next(count: nil)
        } catch {
            await EventLogger.shared.error("shuffle", "Shuffle all failed: \(error.localizedDescription)")
            resumeWalk(interrupted)
            return false
        }
        guard let first = items.first else {
            resumeWalk(interrupted)
            return false
        }

        // Replaces whatever was playing, the current track included. The batch already
        // arrives in random order, so start at the top with shuffle off: letting shuffle
        // pick the start index would drop everything before it.
        // Shuffle stays off (no original order to restore), but `arrivedShuffled` tells
        // the queue screen the batch is still user-arrangeable.
        // The origin is stored with the queue, which is how a relaunch recognises it.
        player.play(
            items: items,
            startAt: 0,
            shuffle: false,
            arrivedShuffled: true,
            origin: .shuffleAll(downloadedOnly: downloadedOnly)
        )
        self.session = session
        shuffleAllIsDownloaded = downloadedOnly
        begin(.shuffleAll, seedEntryId: first.entryId)
        return true
    }

    /// A start that came back empty-handed leaves the walk that was playing in place, so
    /// it goes back to topping up — unless the user moved on to something else meanwhile.
    private func resumeWalk(_ interrupted: (any ShuffleBatchSession)?) {
        guard context == .shuffleAll, session == nil else { return }
        session = interrupted
    }

    /// Picks a Shuffle All walk back up when the queue playing is one and nothing here is
    /// tracking it. That is a relaunch: the queue is restored from disk, this coordinator
    /// is not. The origin stored with the queue says what it is, so the control locks
    /// again and the walk carries on topping up, minus what the queue already holds.
    private func adoptWalkInProgress(_ player: PlayerViewModel) {
        guard case .shuffleAll(let downloadedOnly) = player.queueOrigin,
              !player.queue.isEmpty else { return }
        context = .shuffleAll
        contextGeneration = player.contextGeneration
        generationAtBegin = nil
        seedEntryId = nil
        shuffleAllIsDownloaded = downloadedOnly
        session = makeSession(
            downloadedOnly: downloadedOnly,
            excluding: Set(player.queue.map(\.playableId))
        )
        player.markQueueArrivedShuffled()
        topUpIfNeeded(player)
    }

    private func begin(_ context: ShuffleContext, seedEntryId: UUID) {
        self.context = context
        self.seedEntryId = seedEntryId
        contextGeneration = nil
        generationAtBegin = player?.contextGeneration
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
        generationAtBegin = nil
        seedEntryId = nil
        shuffleAllIsDownloaded = false
    }

    /// Follows the player between contexts, and tops the queue up while it's still ours.
    private func refreshContext() {
        guard let player else { return }
        guard context != nil else {
            adoptWalkInProgress(player)
            return
        }

        guard let generation = contextGeneration else {
            // Not adopted yet. Check the queue on screen really is the one we started
            // before taking its generation: the user can get an album playing in the
            // time it takes a batch to come back over the network.
            guard player.queue.contains(where: { $0.entryId == seedEntryId }) else {
                // Still the queue from before ours was handed over: keep waiting. Any
                // other generation is a context the user started instead.
                if player.contextGeneration != generationAtBegin {
                    clearContext()
                }
                return
            }
            contextGeneration = player.contextGeneration
            topUpIfNeeded(player)
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
