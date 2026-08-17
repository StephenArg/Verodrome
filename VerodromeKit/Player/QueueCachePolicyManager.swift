import Foundation

@MainActor
public final class QueueCachePolicyManager {
    public static let previousKeepCount = UserSettings.defaultSongsBehind
    public static let nextKeepCount = UserSettings.defaultSongsAhead
    public static let previousKeepCountMax = UserSettings.maxSongsBehind
    public static let nextKeepCountMax = UserSettings.maxSongsAhead
    /// Covers reach further ahead than audio: a JPEG is a fraction of a track's bytes, and
    /// a warm cover is what keeps a run of skips from ever showing a placeholder.
    public static let artworkNextKeepCount = 10
    /// Player / Now Playing resolution; smaller UI sizes reuse this via ArtworkDownloadManager.
    public static let artworkPrefetchSize = ArtworkDownloadManager.largestRequestedSize

    private let queue: PlayQueueHandler
    private let cache: any PlayableFileCaching
    private let downloader: any DownloadManaging
    private let artwork: (any ArtworkPrefetching)?
    private let settings: () -> UserSettings
    private var observers: [NSObjectProtocol] = []
    private var reevaluateTask: Task<Void, Never>?

    /// Override in tests. Production looks up `Song.size` / bitrate in the library.
    public var estimatedByteSize: (QueueItem) -> Int64? = { item in
        libraryEstimatedByteSize(for: item)
    }

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
                Task { @MainActor in
                    self?.scheduleReevaluate()
                    self?.pruneStale()
                    self?.pruneOrphans()
                    self?.enforceCacheLimit()
                }
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
        let window = clampedWindow()
        return Set(queue.windowItems(previous: window.behind, next: window.ahead).map(\.id))
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
        guard user.smartQueuePrefetchEnabled else {
            // Turning the setting off must not strand what it already fetched — with an
            // early return here, nothing would ever prune those files again.
            drainPrefetchCache()
            enforceCacheLimit(limitBytes: user.cacheLimitBytes)
            return
        }
        let window = clampedWindow(from: user)
        let keepItems = queue.windowItems(previous: window.behind, next: window.ahead)
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
            // Refresh generation for the whole window (including current). Skipping the
            // playing track left its generation stale so a later bump (shuffle / replace)
            // treated it as obsolete and deleted the file under the playhead.
            cache.touchPlayable(id: item.playableId, kind: item.kind, reason: .queuePrefetch)
            cache.setQueueGeneration(id: item.playableId, kind: item.kind, generation: generation)
        }

        // Cover art is small and shared across album tracks; prefetch a wider window than
        // audio (including current) so skip / Now Playing don't wait on the network.
        if let artwork {
            let artItems = queue.windowItems(
                previous: window.behind,
                next: max(window.ahead, Self.artworkNextKeepCount)
            )
            var seenArtIds = Set<String>()
            for item in artItems {
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
        fillWindow(keepItems: keepItems, currentId: currentId, limitBytes: user.cacheLimitBytes)
        enforceCacheLimit(limitBytes: user.cacheLimitBytes)
    }

    /// Deletes cached files the cache has no record of. Both prune loops above iterate the
    /// cache's own metadata, so a file missing from it would otherwise stay on disk for
    /// good. A song the library still lists as downloaded is re-adopted instead of deleted,
    /// so a lost metadata entry can't silently drop a download the user asked for.
    public func pruneOrphans(minimumAge: TimeInterval = 300) {
        for orphan in cache.orphanedFiles(olderThan: minimumAge) {
            if orphan.kind == .song,
               let reason = LibraryActions.shared.recordedCacheReason(playableId: orphan.id),
               reason.isUserPinnedReason {
                cache.touchPlayable(id: orphan.id, kind: orphan.kind, reason: reason)
            } else {
                evict(id: orphan.id, kind: orphan.kind)
            }
        }
    }

    /// Deletes every prefetched file. Used when the feature is switched off, so the cache
    /// it built doesn't outlive it. User downloads are untouched — they are pinned.
    public func drainPrefetchCache() {
        for entry in cache.cachedPlayableIds(reason: .queuePrefetch) {
            if cache.isUserPinned(id: entry.id, kind: entry.kind) { continue }
            evict(id: entry.id, kind: entry.kind)
        }
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

    /// Drops the lowest-priority unpinned prefetch files until total cache size is at or
    /// under `limitBytes`. Current and the immediate next track are never removed for a
    /// size cap — a next song that is always too big still stays cached. User downloads
    /// are never removed. `0` is unlimited.
    public func enforceCacheLimit(limitBytes: Int64? = nil) {
        let limit = limitBytes ?? settings().cacheLimitBytes
        guard limit > 0 else { return }
        var total = cache.totalPlayableCacheSize()
        guard total > limit else { return }

        let candidates = cache.cachedPlayableIds(reason: .queuePrefetch)
            .filter { !cache.isUserPinned(id: $0.id, kind: $0.kind) }
            .sorted { lhs, rhs in
                let left = rank(id: lhs.id, kind: lhs.kind)
                let right = rank(id: rhs.id, kind: rhs.kind)
                if left != right { return left > right }
                return lhs.touched < rhs.touched
            }

        for entry in candidates {
            guard total > limit else { break }
            if rank(id: entry.id, kind: entry.kind).isProtected { continue }
            let size = cache.playableByteSize(id: entry.id, kind: entry.kind)
            evict(id: entry.id, kind: entry.kind)
            total -= size
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

    /// Deletes the file and every record of it together — a `relFilePath` or a lingering
    /// `DownloadCenter` completion would show the track as downloaded with nothing on disk.
    private func evict(id: String, kind: PlayableRef.Kind) {
        try? cache.deletePlayable(id: id, kind: kind)
        DownloadCenter.shared.clearActive(playableId: id)
        if kind == .song {
            LibraryActions.shared.forgetLocalFile(playableId: id)
        }
    }

    // MARK: - Window fill

    /// Enqueues neighbors in keep-priority order (nexts, then prevs), skipping a track
    /// that will not fit even after dropping lower-priority prefetch. The immediate next
    /// song is always fetched, even when it is larger than the remaining budget.
    private func fillWindow(keepItems: [QueueItem], currentId: String?, limitBytes: Int64) {
        for item in fillCandidates(from: keepItems, currentId: currentId) {
            if cache.hasPlayableFile(id: item.playableId, kind: item.kind) { continue }
            if shouldEnqueue(item, limitBytes: limitBytes) {
                evictWorseRankedToFit(item, limitBytes: limitBytes)
                Task { await downloader.enqueue(playableId: item.playableId, kind: item.kind, reason: .queuePrefetch) }
            }
        }
    }

    private func fillCandidates(from keepItems: [QueueItem], currentId: String?) -> [QueueItem] {
        let currentIndex = queue.currentIndex
        let neighbors = keepItems.filter { $0.id != currentId }
        return neighbors.sorted { lhs, rhs in
            rank(item: lhs, currentIndex: currentIndex) < rank(item: rhs, currentIndex: currentIndex)
        }
    }

    private func shouldEnqueue(_ item: QueueItem, limitBytes: Int64) -> Bool {
        if limitBytes <= 0 { return true }
        if isImmediateNext(item) { return true }
        guard let size = estimatedByteSize(item), size > 0 else { return true }
        return size <= remainingBudget(for: item, limitBytes: limitBytes)
    }

    private func remainingBudget(for item: QueueItem, limitBytes: Int64) -> Int64 {
        let candidateRank = rank(item: item, currentIndex: queue.currentIndex)
        let evictable = evictableBytes(worseThan: candidateRank)
        return limitBytes - (cache.totalPlayableCacheSize() - evictable)
    }

    private func evictableBytes(worseThan candidateRank: PrefetchRank) -> Int64 {
        cache.cachedPlayableIds(reason: .queuePrefetch)
            .filter { !cache.isUserPinned(id: $0.id, kind: $0.kind) }
            .reduce(0) { total, entry in
                let entryRank = rank(id: entry.id, kind: entry.kind)
                guard entryRank > candidateRank, !entryRank.isProtected else { return total }
                return total + cache.playableByteSize(id: entry.id, kind: entry.kind)
            }
    }

    private func evictWorseRankedToFit(_ item: QueueItem, limitBytes: Int64) {
        guard limitBytes > 0 else { return }
        let size = estimatedByteSize(item) ?? 0
        guard size > 0 else { return }
        var total = cache.totalPlayableCacheSize()
        guard total + size > limitBytes else { return }

        let candidateRank = rank(item: item, currentIndex: queue.currentIndex)
        let victims = cache.cachedPlayableIds(reason: .queuePrefetch)
            .filter { !cache.isUserPinned(id: $0.id, kind: $0.kind) }
            .filter {
                let entryRank = rank(id: $0.id, kind: $0.kind)
                return entryRank > candidateRank && !entryRank.isProtected
            }
            .sorted { lhs, rhs in
                let left = rank(id: lhs.id, kind: lhs.kind)
                let right = rank(id: rhs.id, kind: rhs.kind)
                if left != right { return left > right }
                return lhs.touched < rhs.touched
            }

        for entry in victims {
            guard total + size > limitBytes else { break }
            let victimSize = cache.playableByteSize(id: entry.id, kind: entry.kind)
            evict(id: entry.id, kind: entry.kind)
            total -= victimSize
        }
    }

    private func isImmediateNext(_ item: QueueItem) -> Bool {
        rank(item: item, currentIndex: queue.currentIndex).isImmediateNext
    }

    // MARK: - Ranking

    /// Lower is kept first: current, then nearer nexts, then nearer prevs, then outside.
    fileprivate struct PrefetchRank: Comparable {
        enum Tier: Int, Comparable {
            case current = 0
            case next = 1
            case previous = 2
            case outside = 3

            static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let tier: Tier
        let distance: Int

        var isProtected: Bool { tier == .current || isImmediateNext }
        var isImmediateNext: Bool { tier == .next && distance == 1 }

        static func < (lhs: PrefetchRank, rhs: PrefetchRank) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.distance < rhs.distance
        }
    }

    private func rank(item: QueueItem, currentIndex: Int) -> PrefetchRank {
        let q = queue.activeQueue
        var best = PrefetchRank(tier: .outside, distance: 0)
        for (index, queued) in q.enumerated() where queued.id == item.id {
            let candidate = rank(index: index, currentIndex: currentIndex)
            if candidate < best { best = candidate }
        }
        return best
    }

    private func rank(id: String, kind: PlayableRef.Kind) -> PrefetchRank {
        let q = queue.activeQueue
        let currentIndex = queue.currentIndex
        var best = PrefetchRank(tier: .outside, distance: 0)
        for (index, queued) in q.enumerated() where queued.playableId == id && queued.kind == kind {
            let candidate = rank(index: index, currentIndex: currentIndex)
            if candidate < best { best = candidate }
        }
        return best
    }

    private func rank(index: Int, currentIndex: Int) -> PrefetchRank {
        if index == currentIndex { return PrefetchRank(tier: .current, distance: 0) }
        if index > currentIndex { return PrefetchRank(tier: .next, distance: index - currentIndex) }
        return PrefetchRank(tier: .previous, distance: currentIndex - index)
    }

    private func clampedWindow(from user: UserSettings? = nil) -> (behind: Int, ahead: Int) {
        let user = user ?? settings()
        return (
            UserSettings.clampedBehind(user.queuePrefetchSongsBehind),
            UserSettings.clampedAhead(user.queuePrefetchSongsAhead)
        )
    }

    /// Best-effort size for a track that is not on disk yet. `nil` means unknown — the
    /// download is allowed and `enforceCacheLimit` cleans up after it lands.
    public static func libraryEstimatedByteSize(for item: QueueItem) -> Int64? {
        guard item.kind == .song,
              let repository = try? VerodromeKit.shared.repository(),
              let account = try? VerodromeKit.shared.activeAccount(),
              let song = try? repository.resolveSong(remoteId: item.playableId, account: account)
        else { return nil }
        if let size = song.size, size > 0 { return size }
        if let bitrate = song.bitrate, bitrate > 0, item.duration > 0 {
            return Int64((item.duration * Double(bitrate) * 1000 / 8).rounded())
        }
        return nil
    }
}
