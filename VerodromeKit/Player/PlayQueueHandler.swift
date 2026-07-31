import Foundation

@MainActor
public final class PlayQueueHandler: ObservableObject {
    @Published public private(set) var contextQueue: [QueueItem] = []
    @Published public private(set) var userQueue: [QueueItem] = []
    @Published public private(set) var podcastQueue: [QueueItem] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var queueGeneration: Int = 0
    @Published public var repeatMode: RepeatMode = .off
    @Published public var shuffleMode: ShuffleMode = .off
    @Published public var playerMode: PlayerMode = .music

    private var unshuffledContext: [QueueItem] = []
    private let persister: (any PlayerQueuePersisting)?

    public init(persister: (any PlayerQueuePersisting)? = nil) {
        self.persister = persister
    }

    public var activeQueue: [QueueItem] {
        playerMode == .podcast ? podcastQueue : contextQueue
    }

    public var currentItem: QueueItem? {
        let q = activeQueue
        guard q.indices.contains(currentIndex) else { return nil }
        return q[currentIndex]
    }

    public func replaceContext(with items: [QueueItem], startAt index: Int = 0) {
        PlayTrace.mark("PlayQueueHandler.replaceContext", details: "items=\(items.count) startAt=\(index) shuffleMode=\(shuffleMode)")
        unshuffledContext = items
        let safeIndex = items.isEmpty ? 0 : min(max(0, index), items.count - 1)
        if shuffleMode == .on, !items.isEmpty {
            let t0 = CFAbsoluteTimeGetCurrent()
            let startItem = items[safeIndex]
            var rest = items
            rest.remove(at: safeIndex)
            rest.shuffle()
            // Playing / start track stays first so startAt remains meaningful.
            contextQueue = [startItem] + rest
            currentIndex = 0
            PlayTrace.mark("context shuffled", details: "took \(Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))ms")
        } else {
            contextQueue = items
            currentIndex = items.isEmpty ? 0 : safeIndex
        }
        queueGeneration += 1
        userQueue.removeAll()
        PlayTrace.mark("persist queue…")
        persist()
        PlayTrace.mark("persist done; posting queueChanged")
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
        PlayTrace.mark("queueChanged posted", details: "current=\(currentItem?.title ?? "nil")")
    }

    public func enqueueNext(_ items: [QueueItem]) {
        let items = items.map(Self.markUserQueued)
        let insertAt = min(currentIndex + 1, contextQueue.count)
        contextQueue.insert(contentsOf: items, at: insertAt)
        mirrorEdit(inserted: items)
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    public func enqueueLast(_ items: [QueueItem]) {
        let items = items.map(Self.markUserQueued)
        contextQueue.append(contentsOf: items)
        mirrorEdit(inserted: items)
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    /// Removes queue rows. Only items the user queued themselves can be removed — the
    /// tracks a context (album, playlist, …) brought in stay for as long as it plays.
    public func remove(at offsets: IndexSet) {
        let removable = offsets.filter { contextQueue.indices.contains($0) && contextQueue[$0].isUserQueued }
        guard !removable.isEmpty else { return }
        // Positional arithmetic rather than an id lookup: the same song can sit in the
        // queue twice (context copy plus a queued copy), so ids are not unique.
        let removedBefore = removable.filter { $0 < currentIndex }.count
        let removed = removable.sorted(by: >).map { contextQueue.remove(at: $0) }
        currentIndex = min(max(0, currentIndex - removedBefore), max(0, contextQueue.count - 1))
        mirrorEdit(removedIds: Set(removed.map(\.id)))
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: removed)
    }

    private static func markUserQueued(_ item: QueueItem) -> QueueItem {
        var copy = item
        copy.isUserQueued = true
        // Fresh row identity — the source item may already sit in the queue.
        copy.entryId = UUID()
        return copy
    }

    /// Reorders the context queue. `currentIndex` follows the playing track through the
    /// move so the pointer, the prefetch window, and the next-up track stay in sync with
    /// what the engine is playing.
    public func move(from source: IndexSet, to destination: Int) {
        let sources = source.filter { contextQueue.indices.contains($0) }
        guard !sources.isEmpty else { return }
        let previousIndex = currentIndex

        // The same permutation is applied to the positions, so the playing track can be
        // found again by where its old position landed — ids are not unique enough, the
        // same song can sit in the queue twice.
        var positions = Array(contextQueue.indices)
        Self.applyMove(sources: sources, destination: destination, to: &contextQueue)
        Self.applyMove(sources: sources, destination: destination, to: &positions)
        currentIndex = positions.firstIndex(of: previousIndex) ?? previousIndex

        // Deliberately no `queueGeneration` bump: prefetch re-evaluation treats an older
        // generation as obsolete and would delete the playing track's cached file.
        mirrorEdit()
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    private static func applyMove<T>(sources: [Int], destination: Int, to array: inout [T]) {
        let moved = sources.sorted().map { array[$0] }
        let insertAt = destination - sources.filter { $0 < destination }.count
        for index in sources.sorted(by: >) {
            array.remove(at: index)
        }
        array.insert(contentsOf: moved, at: min(max(0, insertAt), array.count))
    }

    /// Keeps the restore-order copy aligned with queue edits, so turning shuffle off
    /// later cannot resurrect removed tracks or drop newly queued ones.
    private func mirrorEdit(inserted: [QueueItem] = [], removedIds: Set<String> = []) {
        guard shuffleMode == .on else {
            unshuffledContext = contextQueue
            return
        }
        if !removedIds.isEmpty {
            unshuffledContext.removeAll { removedIds.contains($0.id) }
        }
        unshuffledContext.append(contentsOf: inserted)
    }

    /// Moves to the next queue item. Used for manual skip and for auto-advance when
    /// repeat is off/all. Repeat-one never calls this on natural finish — it replays
    /// in `AudioPlayer` — but next/previous still use this and always advance.
    public func advance() -> QueueItem? {
        let q = activeQueue
        guard !q.isEmpty else { return nil }
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex + 1) % q.count
        case .off, .one:
            if currentIndex + 1 < q.count { currentIndex += 1 } else { return nil }
        }
        persist()
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
        return currentItem
    }

    public func retreat() -> QueueItem? {
        let q = activeQueue
        guard !q.isEmpty else { return nil }
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex - 1 + q.count) % q.count
        case .off, .one:
            if currentIndex > 0 { currentIndex -= 1 } else { return currentItem }
        }
        persist()
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
        return currentItem
    }

    public func jump(to index: Int) {
        guard activeQueue.indices.contains(index) else { return }
        currentIndex = index
        persist()
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
    }

    public func setRepeat(_ mode: RepeatMode) { repeatMode = mode; persist() }

    public func toggleShuffle() {
        setShuffle(shuffleMode == .on ? .off : .on)
    }

    /// Applies shuffle state idempotently: turning it on shuffles the context around
    /// the playing track, turning it off puts the context back in the order it had
    /// before. Pass `reorder: false` to record the mode only — used right before
    /// `replaceContext`, which builds the shuffled order itself.
    public func setShuffle(_ mode: ShuffleMode, reorder: Bool = true) {
        guard mode != shuffleMode else { return }
        guard reorder else {
            shuffleMode = mode
            persist()
            return
        }

        PlayTrace.begin("setShuffle", details: "was=\(shuffleMode) count=\(contextQueue.count)")
        // Anchor on the playing *position*, not an id lookup — the same song can appear
        // twice (context + Play Next), and a wrong firstIndex would pull a different row
        // to the front while the engine keeps playing the original.
        let playingAt = currentIndex
        let playingItem = contextQueue.indices.contains(playingAt) ? contextQueue[playingAt] : nil
        let playingId = playingItem?.id

        if mode == .on {
            // Turn ON — move the playing track to the front, then shuffle the rest.
            // Done as swap-then-shuffle so `currentItem` never points at a different
            // song between the two @Published writes (that flash corrupts now-playing).
            shuffleMode = .on
            unshuffledContext = contextQueue
            if playingItem != nil, contextQueue.indices.contains(playingAt) {
                if playingAt != 0 {
                    contextQueue.swapAt(0, playingAt)
                    currentIndex = 0
                }
                if contextQueue.count > 1 {
                    var rest = Array(contextQueue[1...])
                    rest.shuffle()
                    contextQueue = [contextQueue[0]] + rest
                }
                PlayTrace.mark("shuffled remainder behind playing track")
            } else {
                contextQueue = contextQueue.shuffled()
                PlayTrace.mark("shuffled all (no current item)")
            }
        } else {
            // Turn OFF — restore original order; keep pointing at the same playing track.
            // Staged via swaps so `currentItem` never resolves to a different song between
            // the @Published writes (same flash as turning shuffle on).
            shuffleMode = .off
            let restored = unshuffledContext.isEmpty ? contextQueue : unshuffledContext
            let restoredIndex = playingId.flatMap { id in
                restored.firstIndex(where: { $0.id == id })
            } ?? min(playingAt, max(0, restored.count - 1))
            if restoredIndex == currentIndex || !restored.indices.contains(currentIndex) {
                contextQueue = restored
                currentIndex = restoredIndex
            } else {
                var staged = restored
                staged.swapAt(currentIndex, restoredIndex) // playing track sits at currentIndex
                contextQueue = staged
                contextQueue.swapAt(currentIndex, restoredIndex)
                currentIndex = restoredIndex
            }
            PlayTrace.mark("restored unshuffled context", details: "index=\(currentIndex)")
        }

        queueGeneration += 1
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
        PlayTrace.end("setShuffle done", details: "now=\(shuffleMode)")
    }

    public func windowItems(previous: Int, next: Int) -> [QueueItem] {
        let q = activeQueue
        guard !q.isEmpty else { return [] }
        let start = max(0, currentIndex - previous)
        let end = min(q.count - 1, currentIndex + next)
        guard start <= end else { return [] }
        return Array(q[start...end])
    }

    public func loadFromDisk() async {
        guard let persister else { return }
        let snapshot = await persister.loadQueue()
        contextQueue = snapshot.context
        userQueue = snapshot.user
        podcastQueue = snapshot.podcast
        currentIndex = snapshot.index
        queueGeneration = snapshot.generation
        repeatMode = snapshot.repeatMode
        shuffleMode = snapshot.shuffleMode
        playerMode = snapshot.playerMode
        unshuffledContext = contextQueue
    }

    private func persist() {
        guard let persister else { return }
        let snapshot = (contextQueue, userQueue, podcastQueue, currentIndex, queueGeneration, repeatMode, shuffleMode, playerMode)
        Task {
            await persister.saveQueue(
                context: snapshot.0, user: snapshot.1, podcast: snapshot.2, index: snapshot.3,
                generation: snapshot.4, repeatMode: snapshot.5, shuffleMode: snapshot.6, playerMode: snapshot.7
            )
        }
    }
}
