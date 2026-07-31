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
        let insertAt = min(currentIndex + 1, contextQueue.count)
        contextQueue.insert(contentsOf: items, at: insertAt)
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    public func enqueueLast(_ items: [QueueItem]) {
        contextQueue.append(contentsOf: items)
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    public func remove(at offsets: IndexSet) {
        let removed = offsets.sorted(by: >).compactMap { index -> QueueItem? in
            guard contextQueue.indices.contains(index) else { return nil }
            return contextQueue.remove(at: index)
        }
        if currentIndex >= contextQueue.count {
            currentIndex = max(0, contextQueue.count - 1)
        }
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: removed)
    }

    public func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, contextQueue.indices.contains(from) else { return }
        let item = contextQueue.remove(at: from)
        let insertAt = destination > from ? destination - 1 : destination
        contextQueue.insert(item, at: min(max(0, insertAt), contextQueue.count))
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
    }

    /// Moves to the next queue item. Used for skip / auto-advance after a track ends.
    /// Repeat-one is handled by replaying in `AudioPlayer` — skip still advances.
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
        if currentIndex > 0 { currentIndex -= 1 }
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
        PlayTrace.begin("toggleShuffle", details: "was=\(shuffleMode) count=\(contextQueue.count)")
        let playingId = currentItem?.id
        let playingItem = currentItem

        if shuffleMode == .off {
            // Turn ON — keep the playing track in place; only shuffle the others.
            // Reshuffling the whole array and then re-finding the track is fragile:
            // a missed match leaves currentIndex on a different song while audio
            // keeps playing the original (title appears to change).
            shuffleMode = .on
            unshuffledContext = contextQueue
            if let playingItem, let playingId,
               let keepAt = contextQueue.firstIndex(where: { $0.id == playingId }) {
                var rest = contextQueue
                rest.remove(at: keepAt)
                rest.shuffle()
                rest.insert(playingItem, at: min(keepAt, rest.count))
                contextQueue = rest
                currentIndex = contextQueue.firstIndex(where: { $0.id == playingId }) ?? keepAt
                PlayTrace.mark("shuffled others; kept playing in place", details: "index=\(currentIndex)")
            } else {
                contextQueue = contextQueue.shuffled()
                PlayTrace.mark("shuffled all (no current item)")
            }
        } else {
            // Turn OFF — restore original order; keep pointing at the same playing track.
            shuffleMode = .off
            contextQueue = unshuffledContext.isEmpty ? contextQueue : unshuffledContext
            if let playingId, let idx = contextQueue.firstIndex(where: { $0.id == playingId }) {
                currentIndex = idx
            }
            PlayTrace.mark("restored unshuffled context", details: "index=\(currentIndex)")
        }

        queueGeneration += 1
        persist()
        NotificationCenter.default.post(name: .verodromeQueueChanged, object: nil)
        PlayTrace.end("toggleShuffle done", details: "now=\(shuffleMode)")
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
