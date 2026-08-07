import Foundation

@MainActor
public final class QueueCachePolicyManager {
    public static let previousKeepCount = 2
    public static let nextKeepCount = 5
    /// Player / Now Playing resolution; smaller UI sizes reuse this via ArtworkDownloadManager.
    public static let artworkPrefetchSize = ArtworkDownloadManager.largestRequestedSize

    private let queue: PlayQueueHandler
    private let cache: any PlayableFileCaching
    private let downloader: any DownloadManaging
    private let artwork: (any ArtworkPrefetching)?
    private let settings: () -> UserSettings
    private var observers: [NSObjectProtocol] = []
    private var reevaluateTask: Task<Void, Never>?

    public init(
        queue: PlayQueueHandler,
        cache: any PlayableFileCaching,
        downloader: any DownloadManaging,
        artwork: (any ArtworkPrefetching)? = nil,
        settings: @escaping () -> UserSettings
    ) {
        self.queue = queue
        self.cache = cache
        self.downloader = downloader
        self.artwork = artwork
        self.settings = settings
    }

    public func start() {
        stop()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .verodromeQueueChanged, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if let removed = note.object as? [QueueItem] { self?.handleRemovedItems(removed) }
                    self?.scheduleReevaluate()
                }
            },
            center.addObserver(forName: .verodromeQueueIndexChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReevaluate() }
            },
            center.addObserver(forName: .verodromeForegroundRefresh, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReevaluate(); self?.pruneStale() }
            },
            center.addObserver(forName: .verodromeQueueCacheReevaluate, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReevaluate(delayNanoseconds: 0) }
            }
        ]
        scheduleReevaluate(delayNanoseconds: 0)
    }

    public func stop() {
        reevaluateTask?.cancel()
        reevaluateTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    public func computeKeepSet() -> Set<String> {
        Set(queue.windowItems(previous: Self.previousKeepCount, next: Self.nextKeepCount).map(\.id))
    }

    /// Debounce prefetch so it doesn't race the stream's first buffer on play/skip.
    public func scheduleReevaluate(delayNanoseconds: UInt64 = 1_500_000_000) {
        reevaluateTask?.cancel()
        reevaluateTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.reevaluate()
        }
    }

    public func reevaluate() {
        let user = settings()
        guard user.smartQueuePrefetchEnabled else { return }
        let keepItems = queue.windowItems(previous: Self.previousKeepCount, next: Self.nextKeepCount)
        let keepIds = Set(keepItems.map(\.id))
        let generation = queue.queueGeneration
        let currentId = queue.currentItem?.id

        // A mid-queue jump moves the prefetch window away from the old neighbors. Drop
        // their pending downloads so the new window's bandwidth isn't spent finishing
        // tracks the user just left behind. In-flight downloads are left to complete;
        // the prune loop below deletes anything that lands outside the window.
        let keepPlayableIds = Set(keepItems.map(\.playableId))
        Task { await downloader.cancelPending(reason: .queuePrefetch, except: keepPlayableIds) }

        for item in keepItems {
            // Don't download the track that is already streaming — that races the
            // first buffer and makes play-start feel stuck.
            if item.id == currentId { continue }
            cache.touchPlayable(id: item.playableId, kind: item.kind, reason: .queuePrefetch)
            cache.setQueueGeneration(id: item.playableId, kind: item.kind, generation: generation)
            Task { await downloader.enqueue(playableId: item.playableId, kind: item.kind, reason: .queuePrefetch) }
        }

        // Cover art is small and shared across album tracks; prefetch the whole window
        // (including current) so skip / Now Playing don't wait on the network.
        if let artwork {
            var seenArtIds = Set<String>()
            for item in keepItems {
                guard let artId = item.artworkId, !artId.isEmpty, seenArtIds.insert(artId).inserted else { continue }
                let artKind: ArtworkKind = item.kind == .podcastEpisode ? .podcast : .album
                Task {
                    await artwork.enqueue(artId: artId, kind: artKind, size: Self.artworkPrefetchSize)
                }
            }
        }

        for entry in cache.cachedPlayableIds(reason: .queuePrefetch) {
            let itemId = entry.id + "|" + entry.kind.rawValue
            if cache.isUserPinned(id: entry.id, kind: entry.kind) { continue }
            guard cache.cacheReason(forPlayableId: entry.id, kind: entry.kind) == .queuePrefetch else { continue }
            let outsideWindow = !keepIds.contains(itemId)
            let obsoleteGeneration = entry.generation != 0 && entry.generation < generation
            if outsideWindow || obsoleteGeneration {
                evict(id: entry.id, kind: entry.kind)
            }
        }
        pruneStale(staleHours: user.queuePrefetchStaleHours)
    }

    public func pruneStale(staleHours: Int? = nil) {
        let hours = staleHours ?? settings().queuePrefetchStaleHours
        let cutoff = Date().addingTimeInterval(-TimeInterval(hours) * 3600)
        for entry in cache.cachedPlayableIds(reason: .queuePrefetch) {
            if cache.isUserPinned(id: entry.id, kind: entry.kind) { continue }
            if entry.touched < cutoff {
                evict(id: entry.id, kind: entry.kind)
            }
        }
    }

    public func handleRemovedItems(_ items: [QueueItem]) {
        for item in items {
            if cache.isUserPinned(id: item.playableId, kind: item.kind) { continue }
            if cache.cacheReason(forPlayableId: item.playableId, kind: item.kind) == .queuePrefetch {
                evict(id: item.playableId, kind: item.kind)
            }
        }
    }

    /// Deletes the file and the library's record of it together — a `relFilePath` left
    /// behind would show the track as downloaded with nothing on disk.
    private func evict(id: String, kind: PlayableRef.Kind) {
        try? cache.deletePlayable(id: id, kind: kind)
        if kind == .song {
            LibraryActions.shared.forgetLocalFile(playableId: id)
        }
    }
}
