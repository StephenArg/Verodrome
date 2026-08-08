import Foundation

@MainActor
public final class PlayQueueHandler: ObservableObject {
    /// Played tracks kept behind the playing one before `appendContext` trims them.
    public static let maxPlayedHistory = 100

    @Published public private(set) var contextQueue: [QueueItem] = []
    @Published public private(set) var userQueue: [QueueItem] = []
    @Published public private(set) var podcastQueue: [QueueItem] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var queueGeneration: Int = 0
    /// Increments only when a new context starts, so an owner of an open-ended context
    /// can tell "the user played something else" from "the queue was reordered".
    /// `queueGeneration` can't answer that — toggling shuffle bumps it too.
    @Published public private(set) var contextGeneration: Int = 0
    @Published public var repeatMode: RepeatMode = .off
    @Published public var shuffleMode: ShuffleMode = .off
    @Published public var playerMode: PlayerMode = .music

    /// How far into the current track playback had reached, carried into every snapshot
    /// so a relaunch resumes mid-song rather than at the start. Kept here rather than
    /// read from the engine because the snapshot is written from queue edits too.
    public private(set) var playbackPosition: TimeInterval = 0

    /// Coalesced disk work. Context and the "Added to Queue" list are separate files, so
    /// an enqueue can refresh the small one without rewriting the album / playlist.
    private struct PendingWrites {
        var context: PersistedPlayerQueue?
        var user: [QueueItem]?
        var forget = false
    }

    private var unshuffledContext: [QueueItem] = []
    private let persister: (any PlayerQueuePersisting)?
    private var pendingWrites = PendingWrites()
    private var writeTask: Task<Void, Never>?

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
        contextGeneration += 1
        userQueue.removeAll()
        playbackPosition = 0
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
        // Only the "Added to Queue" file changes — the context album / playlist stays put.
        syncAndPersistUserQueue()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    public func enqueueLast(_ items: [QueueItem]) {
        let items = items.map(Self.markUserQueued)
        contextQueue.append(contentsOf: items)
        mirrorEdit(inserted: items)
        // These sit at the end of the context, outside the "Added to Queue" run, so the
        // context file has to carry them.
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    /// Queues tracks for a single listen: they play after the current one and leave the
    /// queue the moment playback moves past them, taking their prefetched file with them.
    ///
    /// - Parameter at: Absolute queue index to insert at. Clamped into the "Added to Queue"
    ///   run (right after the playhead through the end of that run). `nil` appends after
    ///   any temporary rows already waiting, so adding two albums in a row plays them in
    ///   the order they were added rather than in reverse.
    public func enqueueEphemeral(_ items: [QueueItem], at insertAt: Int? = nil) {
        guard !items.isEmpty else { return }
        let items = items.map { item -> QueueItem in
            var copy = Self.markUserQueued(item)
            copy.isEphemeral = true
            return copy
        }
        let position = ephemeralInsertIndex(at: insertAt)
        contextQueue.insert(contentsOf: items, at: position)
        mirrorEdit(inserted: items)
        syncAndPersistUserQueue()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    /// Where a temporary add lands: an explicit index clamped to the queued run, or the
    /// default "after every ephemeral already waiting" slot.
    private func ephemeralInsertIndex(at insertAt: Int?) -> Int {
        let lower = min(currentIndex + 1, contextQueue.count)
        let run = userQueuedRange
        let upper = run.isEmpty ? lower : run.upperBound
        guard let insertAt else {
            var end = lower
            while end < contextQueue.count, contextQueue[end].isEphemeral { end += 1 }
            return end
        }
        return min(max(insertAt, lower), upper)
    }

    /// Drops a temporary row the playhead just left. Posting the removal on
    /// `verodromeQueueChanged` is what gets its cached file deleted — `QueueCachePolicyManager`
    /// listens for exactly this and skips anything the user pinned, so a song that is also
    /// downloaded survives.
    private func dropEphemeral(leftAt index: Int) {
        guard playerMode == .music else { return }
        guard index != currentIndex, contextQueue.count > 1 else { return }
        guard contextQueue.indices.contains(index), contextQueue[index].isEphemeral else { return }

        let removed = contextQueue.remove(at: index)
        if currentIndex > index { currentIndex -= 1 }
        mirrorEdit(removedEntryIds: [removed.entryId])
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: [removed])
    }

    /// Extends the current context, as opposed to `enqueueLast`, which marks items as
    /// user-queued and therefore removable. Used to top up an open-ended context — a
    /// shuffle-all walk — while it plays.
    ///
    /// Deliberately no `queueGeneration` bump, for the same reason `move` skips it:
    /// prefetch treats an older generation as obsolete and would delete the playing
    /// track's cached file mid-play.
    public func appendContext(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        contextQueue.append(contentsOf: items)
        mirrorEdit(inserted: items)
        trimPlayedHistory()
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    /// Drops tracks that played long ago, keeping at most `maxPlayedHistory` behind the
    /// playing one. An open-ended context tops itself up for as long as playback runs,
    /// so without a bound both the queue array and the rows persisted alongside it grow
    /// all session.
    private func trimPlayedHistory() {
        let excess = currentIndex - Self.maxPlayedHistory
        guard excess > 0 else { return }

        contextQueue.removeFirst(excess)
        currentIndex -= excess
        // Restore order only means anything for tracks still in the queue. Matched on
        // `entryId` rather than `id` because the same song can sit in the queue twice.
        let remaining = Set(contextQueue.map(\.entryId))
        unshuffledContext.removeAll { !remaining.contains($0.entryId) }
    }

    /// Where the tracks the user queued themselves sit: the run right after the playing
    /// track, which is where every enqueue inserts. The queue screen lists these on their
    /// own and edits them through the two calls below.
    public var userQueuedRange: Range<Int> {
        // Podcast playback runs off `podcastQueue`, which nothing enqueues into.
        guard playerMode == .music else { return 0..<0 }
        return contextQueue.userQueuedRun(after: currentIndex)
    }

    public var userQueuedItems: [QueueItem] { Array(contextQueue[userQueuedRange]) }

    /// Reorders within the user-queued run. Offsets and destination are relative to that
    /// run and clamped to it, so dragging what was queued can neither disturb the context
    /// nor jump a row ahead of the playing track.
    public func moveUserQueued(from source: IndexSet, to destination: Int) {
        let range = userQueuedRange
        guard !range.isEmpty else { return }
        let sources = source.filter { (0..<range.count).contains($0) }.map { $0 + range.lowerBound }
        guard !sources.isEmpty else { return }
        move(
            from: IndexSet(sources),
            to: min(max(0, destination), range.count) + range.lowerBound,
            writeUserQueueOnly: true
        )
    }

    /// Removes rows from the user-queued run, offsets relative to the run.
    public func removeUserQueued(at offsets: IndexSet) {
        let range = userQueuedRange
        let absolute = offsets.filter { (0..<range.count).contains($0) }.map { $0 + range.lowerBound }
        guard !absolute.isEmpty else { return }
        remove(at: IndexSet(absolute), writeUserQueueOnly: true, userQueuedOnly: true)
    }

    /// Removes queue rows. Only items the user queued themselves can be removed — the
    /// tracks a context (album, playlist, …) brought in stay for as long as it plays.
    public func remove(at offsets: IndexSet) {
        remove(at: offsets, writeUserQueueOnly: false, userQueuedOnly: true)
    }

    /// Removes rows whoever put them there, for a queue whose order is the user's rather
    /// than a context's — a shuffle, where there is no album ordering left to protect.
    public func removeRows(at offsets: IndexSet) {
        remove(at: offsets, writeUserQueueOnly: false, userQueuedOnly: false)
    }

    /// The playing track is never removed: dropping it would leave the engine on a track
    /// the queue no longer lists.
    private func remove(at offsets: IndexSet, writeUserQueueOnly: Bool, userQueuedOnly: Bool) {
        let removable = offsets.filter {
            contextQueue.indices.contains($0)
                && $0 != currentIndex
                && (!userQueuedOnly || contextQueue[$0].isUserQueued)
        }
        guard !removable.isEmpty else { return }
        // Positional arithmetic rather than an id lookup: the same song can sit in the
        // queue twice (context copy plus a queued copy), so ids are not unique.
        let removedBefore = removable.filter { $0 < currentIndex }.count
        let removed = removable.sorted(by: >).map { contextQueue.remove(at: $0) }
        currentIndex = min(max(0, currentIndex - removedBefore), max(0, contextQueue.count - 1))
        mirrorEdit(removedEntryIds: Set(removed.map(\.entryId)))
        if writeUserQueueOnly {
            syncAndPersistUserQueue()
        } else {
            persist()
        }
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
        move(from: source, to: destination, writeUserQueueOnly: false)
    }

    private func move(from source: IndexSet, to destination: Int, writeUserQueueOnly: Bool) {
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
        if writeUserQueueOnly {
            syncAndPersistUserQueue()
        } else {
            persist()
        }
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
    ///
    /// `removedEntryIds` exists for removals that must hit one specific row: the same
    /// song can sit in the queue twice, and dropping a temporary copy by playable id
    /// would take the context's copy with it.
    private func mirrorEdit(
        inserted: [QueueItem] = [],
        removedIds: Set<String> = [],
        removedEntryIds: Set<UUID> = []
    ) {
        guard shuffleMode == .on else {
            unshuffledContext = contextQueue
            return
        }
        if !removedIds.isEmpty {
            unshuffledContext.removeAll { removedIds.contains($0.id) }
        }
        if !removedEntryIds.isEmpty {
            unshuffledContext.removeAll { removedEntryIds.contains($0.entryId) }
        }
        unshuffledContext.append(contentsOf: inserted)
    }

    /// Moves to the next queue item. Used for manual skip and for auto-advance when
    /// repeat is off/all. Repeat-one never calls this on natural finish — it replays
    /// in `AudioPlayer` — but next/previous still use this and always advance.
    public func advance() -> QueueItem? {
        let q = activeQueue
        guard !q.isEmpty else { return nil }
        let departedIndex = currentIndex
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex + 1) % q.count
        case .off, .one:
            if currentIndex + 1 < q.count { currentIndex += 1 } else { return nil }
        }
        dropEphemeral(leftAt: departedIndex)
        playbackPosition = 0
        persist()
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
        return currentItem
    }

    public func retreat() -> QueueItem? {
        let q = activeQueue
        guard !q.isEmpty else { return nil }
        let departedIndex = currentIndex
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex - 1 + q.count) % q.count
        case .off, .one:
            if currentIndex > 0 { currentIndex -= 1 } else { return currentItem }
        }
        // Same as advancing or jumping away: an "Added to Queue" listen is done once the
        // playhead leaves it, including when the user steps back to the previous track.
        dropEphemeral(leftAt: departedIndex)
        playbackPosition = 0
        persist()
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
        return currentItem
    }

    public func jump(to index: Int) {
        guard activeQueue.indices.contains(index) else { return }
        // Relocating the queued run can slide rows under the old playhead index, so the
        // departed track is found again by entry id after the rewrite.
        let departedEntryId = contextQueue.indices.contains(currentIndex)
            ? contextQueue[currentIndex].entryId
            : nil
        // Leaving the playhead (forward or back) would strand the "Added to Queue" run
        // where it was. Pull it along so it stays next up after whatever was tapped.
        // Jumping into the run itself leaves it alone — those rows are about to play.
        let relocated = relocateUserQueuedAroundJump(to: index)
        if !relocated {
            currentIndex = index
        }
        if let departedEntryId,
           let departedIndex = contextQueue.firstIndex(where: { $0.entryId == departedEntryId }) {
            dropEphemeral(leftAt: departedIndex)
        }
        playbackPosition = 0
        persist()
        if relocated {
            NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
        }
        NotificationCenter.default.post(name: .verodromeQueueIndexChanged, object: currentIndex)
    }

    /// Moves the user-queued run after the playhead to right after `index`, when the jump
    /// lands outside that run. Sets `currentIndex` to the jump target. Returns whether
    /// the queue was rewritten.
    @discardableResult
    private func relocateUserQueuedAroundJump(to index: Int) -> Bool {
        guard playerMode == .music else { return false }
        let range = contextQueue.userQueuedRun(after: currentIndex)
        guard !range.isEmpty else { return false }
        // Inside the run: play that queued row where it sits.
        guard index < range.lowerBound || index >= range.upperBound else { return false }
        // Same row — nothing to move, and restart shouldn't reshuffle the section.
        guard index != currentIndex else { return false }

        let items = Array(contextQueue[range])
        contextQueue.removeSubrange(range)
        // Rows removed before the target slide it down; rows after leave it put.
        currentIndex = index >= range.upperBound ? index - range.count : index
        contextQueue.insert(contentsOf: items, at: currentIndex + 1)
        mirrorEdit()
        return true
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
        // twice (context + a queued copy), and a wrong firstIndex would pull a different
        // row to the front while the engine keeps playing the original.
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

    /// Records where playback sits in the current track, for the next snapshot. Callers
    /// throttle this: it rewrites the whole queue file, which is far heavier than the one
    /// value it carries.
    public func updatePlaybackPosition(_ seconds: TimeInterval) {
        let clamped = max(0, seconds)
        guard abs(clamped - playbackPosition) >= 0.5 else { return }
        playbackPosition = clamped
        persist()
    }

    /// Empties the queue and, unless the caller is only swapping accounts, forgets the
    /// stored one too. Stopping playback is the caller's job — the handler has no engine.
    ///
    /// Posts the dropped rows so their prefetched files go with them.
    public func clear(forgetStored: Bool = true) {
        let removed = contextQueue + podcastQueue
        contextQueue = []
        userQueue = []
        podcastQueue = []
        unshuffledContext = []
        playbackPosition = 0
        currentIndex = 0
        queueGeneration += 1
        contextGeneration += 1
        if forgetStored {
            pendingWrites = PendingWrites(forget: true)
            kickWriteTask()
        }
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: removed)
    }

    public func loadFromDisk() async {
        guard let persister, let snapshot = await persister.loadQueue() else { return }

        // Context file is the album / playlist without the "Added to Queue" run. Older
        // builds embedded that run in `context` or `user`; peel it out so merge is one path.
        var context = snapshot.context
        var index = min(max(0, snapshot.index), max(0, context.count - 1))
        let restoredEntryId = context.indices.contains(index) ? context[index].entryId : nil

        var user = await persister.loadUserQueue()
        if user.isEmpty, !snapshot.user.isEmpty {
            user = snapshot.user
        }
        if user.isEmpty {
            let embedded = context.userQueuedRun(after: index)
            if !embedded.isEmpty {
                user = Array(context[embedded])
                context.removeSubrange(embedded)
            }
        }

        // Drop one-listen rows that leaked into an older context snapshot and are not the
        // playing track. The "Added to Queue" list (including its ephemerals) is re-merged
        // below from the side file.
        context.removeAll { $0.isEphemeral && $0.entryId != restoredEntryId }
        if let restoredEntryId {
            index = context.firstIndex(where: { $0.entryId == restoredEntryId })
                ?? min(index, max(0, context.count - 1))
        } else {
            index = min(index, max(0, context.count - 1))
        }

        if !user.isEmpty {
            let insertAt = min(index + 1, context.count)
            context.insert(contentsOf: user, at: insertAt)
        }

        contextQueue = context
        userQueue = user
        podcastQueue = snapshot.podcast
        let userEntryIds = Set(user.map(\.entryId))
        if snapshot.unshuffledContext.isEmpty {
            unshuffledContext = context
        } else if snapshot.shuffleMode == .on {
            // Matches `mirrorEdit`: while shuffled, newly queued rows are appended to the
            // restore-order copy rather than spliced into the middle.
            var restored = snapshot.unshuffledContext.filter { !userEntryIds.contains($0.entryId) && !$0.isEphemeral }
            restored.append(contentsOf: user)
            unshuffledContext = restored
        } else {
            unshuffledContext = context
        }
        queueGeneration = snapshot.generation
        repeatMode = snapshot.repeatMode
        shuffleMode = snapshot.shuffleMode
        playerMode = snapshot.playerMode
        playbackPosition = snapshot.playbackPosition
        if playerMode == .music, let restoredEntryId,
           let found = context.firstIndex(where: { $0.entryId == restoredEntryId }) {
            currentIndex = found
        } else {
            currentIndex = min(max(0, index), max(0, activeQueue.count - 1))
        }
    }

    /// Writes only the "Added to Queue" side file. Used when the context album / playlist
    /// did not change — enqueue, reorder, or remove within that section.
    private func syncAndPersistUserQueue() {
        userQueue = userQueuedItems
        guard persister != nil else { return }
        pendingWrites.forget = false
        pendingWrites.user = userQueue
        kickWriteTask()
    }

    /// Writes the context file (without the "Added to Queue" run) and refreshes the user
    /// side file so the two stay consistent after playhead / shuffle / replace changes.
    private func persist() {
        userQueue = Array(contextQueue[userQueuedRange])
        guard persister != nil else { return }
        pendingWrites.forget = false
        pendingWrites.context = contextSnapshotForDisk()
        pendingWrites.user = userQueue
        kickWriteTask()
    }

    /// Context as it should sit on disk: the playing album / playlist with the "Added to
    /// Queue" run pulled out, so that run can live in its own file.
    private func contextSnapshotForDisk() -> PersistedPlayerQueue {
        let range = userQueuedRange
        var context = contextQueue
        var unshuffled = unshuffledContext
        if !range.isEmpty {
            let removedIds = Set(context[range].map(\.entryId))
            context.removeSubrange(range)
            unshuffled.removeAll { removedIds.contains($0.entryId) }
        }
        return PersistedPlayerQueue(
            context: context,
            user: [],
            podcast: podcastQueue,
            unshuffledContext: unshuffled,
            index: currentIndex,
            generation: queueGeneration,
            repeatMode: repeatMode,
            shuffleMode: shuffleMode,
            playerMode: playerMode,
            playbackPosition: playbackPosition
        )
    }

    /// Queues disk work behind whichever write is already running. A task per edit would
    /// let two snapshots reach the store in either order — dragging a row or scrubbing
    /// produces plenty of them — and the stored queue would end up on whichever landed last.
    private func kickWriteTask() {
        guard let persister else { return }
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            while let batch = self?.takePendingWrites() {
                if batch.forget {
                    await persister.clearQueue()
                    continue
                }
                if let context = batch.context {
                    await persister.saveQueue(context)
                }
                if let user = batch.user {
                    await persister.saveUserQueue(user)
                }
            }
            self?.writeTask = nil
        }
    }

    private func takePendingWrites() -> PendingWrites? {
        let batch = pendingWrites
        guard batch.context != nil || batch.user != nil || batch.forget else { return nil }
        pendingWrites = PendingWrites()
        return batch
    }

    /// Waits for queued writes to reach the store. Callers that are about to point the
    /// store at another account use this so a snapshot of the queue being left behind
    /// can't land in the next account's file.
    public func flushPendingWrites() async {
        await writeTask?.value
    }
}
