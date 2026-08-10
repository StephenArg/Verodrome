import XCTest
@testable import VerodromeKit

@MainActor
final class QueueCachePolicyTests: XCTestCase {
    final class MockCache: PlayableFileCaching, @unchecked Sendable {
        var files: [String: (kind: PlayableRef.Kind, reason: CacheReason, touched: Date, generation: Int, pinned: Bool)] = [:]
        /// Synthetic sizes so the limit tests don't need real files on disk.
        var sizes: [String: Int64] = [:]
        /// Files on disk that `files` has no record of, keyed the same way, with the date
        /// they landed — what a lost metadata write leaves behind.
        var untracked: [String: Date] = [:]
        func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? {
            files["\(kind.rawValue)::\(id)"] == nil ? nil : URL(fileURLWithPath: "/tmp/\(id)")
        }
        func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
            files["\(kind.rawValue)::\(id)"] = (kind, reason, Date(), 0, reason.isUserPinnedReason)
            return URL(fileURLWithPath: "/tmp/\(id)")
        }
        func deletePlayable(id: String, kind: PlayableRef.Kind) throws {
            files.removeValue(forKey: "\(kind.rawValue)::\(id)")
            sizes.removeValue(forKey: "\(kind.rawValue)::\(id)")
            untracked.removeValue(forKey: "\(kind.rawValue)::\(id)")
        }
        func totalPlayableCacheSize() -> Int64 {
            files.keys.reduce(0) { $0 + (sizes[$1] ?? 1) }
        }
        func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64 {
            sizes["\(kind.rawValue)::\(id)"] ?? (files["\(kind.rawValue)::\(id)"] == nil ? 0 : 1)
        }
        func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {
            let key = "\(kind.rawValue)::\(id)"
            var existing = files[key] ?? (kind, reason ?? .queuePrefetch, Date(), 0, false)
            existing.touched = Date()
            if let reason { existing.reason = reason; existing.pinned = reason.isUserPinnedReason || existing.pinned }
            files[key] = existing
        }
        func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason {
            files["\(kind.rawValue)::\(id)"]?.reason ?? .none
        }
        func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool {
            files["\(kind.rawValue)::\(id)"]?.pinned == true
        }
        func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] {
            files.compactMap { key, value in
                if let reason, value.reason != reason { return nil }
                let id = key.components(separatedBy: "::").last ?? key
                return (id, value.kind, value.touched, value.generation)
            }
        }
        func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {
            let key = "\(kind.rawValue)::\(id)"
            guard var existing = files[key] else { return }
            existing.generation = generation
            files[key] = existing
        }
        func orphanedFiles(olderThan minimumAge: TimeInterval) -> [(id: String, kind: PlayableRef.Kind)] {
            let cutoff = Date().addingTimeInterval(-minimumAge)
            return untracked.compactMap { key, landed in
                guard landed < cutoff else { return nil }
                let parts = key.components(separatedBy: "::")
                guard let kind = parts.first.flatMap(PlayableRef.Kind.init(rawValue:)),
                      let id = parts.last
                else { return nil }
                return (id, kind)
            }
        }
    }

    final class MockURLProvider: StreamURLProviding, @unchecked Sendable {
        func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            URL(string: "https://example.com/\(id)")!
        }
        func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            URL(string: "https://example.com/\(id)")!
        }
        func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
            URL(string: "https://example.com/art/\(artId)")!
        }
    }

    func testKeepWindowAndPruneBehind() async throws {
        let cache = MockCache()
        let downloader = DownloadManager(urlProvider: MockURLProvider(), cache: cache)
        let queue = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 5)

        // Seed prefetch files for all
        for item in items {
            cache.files["song::\(item.playableId)"] = (.song, .queuePrefetch, Date(), queue.queueGeneration, false)
        }
        // Pin one far behind
        cache.files["song::0"] = (.song, .userDownload, Date(), queue.queueGeneration, true)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()

        // Keep 3,4,5,6,7,8,9,10? prev2=3,4 current=5 next5=6..10 but only to 9
        XCTAssertNotNil(cache.files["song::3"])
        XCTAssertNotNil(cache.files["song::5"])
        XCTAssertNotNil(cache.files["song::9"])
        // Behind window and not pinned should be gone
        XCTAssertNil(cache.files["song::1"])
        XCTAssertNil(cache.files["song::2"])
        // Pinned survives
        XCTAssertNotNil(cache.files["song::0"])
    }

    /// A reorder moves the prefetch window with the playing track: songs that became
    /// upcoming are kept, songs that dropped out of the window are pruned, and the
    /// playing track's own file survives (a queue-generation bump would delete it).
    func testWindowFollowsQueueReorder() {
        let cache = MockCache()
        let downloader = DownloadManager(urlProvider: MockURLProvider(), cache: cache)
        let queue = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 5)
        for item in items {
            cache.files["song::\(item.playableId)"] = (.song, .queuePrefetch, Date(), queue.queueGeneration, false)
        }

        // Pull the last track to the front; the playing track slides one slot down.
        queue.move(from: IndexSet(integer: 9), to: 0)
        XCTAssertEqual(queue.currentItem?.playableId, "5")

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()

        // New order [9,0,1,2,3,4,5,6,7,8] with "5" at index 6 → window covers 3…8.
        for kept in ["3", "4", "5", "6", "7", "8"] {
            XCTAssertNotNil(cache.files["song::\(kept)"], "\(kept) should still be cached")
        }
        for pruned in ["9", "0", "1", "2"] {
            XCTAssertNil(cache.files["song::\(pruned)"], "\(pruned) fell outside the window")
        }
    }

    func testStalePrune() {
        let cache = MockCache()
        let downloader = DownloadManager(urlProvider: MockURLProvider(), cache: cache)
        let queue = PlayQueueHandler()
        queue.replaceContext(with: [QueueItem(playableId: "a", title: "A")], startAt: 0)
        let old = Date().addingTimeInterval(-20 * 3600)
        cache.files["song::old"] = (.song, .queuePrefetch, old, 0, false)
        cache.files["song::pinned"] = (.song, .userDownload, old, 0, true)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.pruneStale()
        XCTAssertNil(cache.files["song::old"])
        XCTAssertNotNil(cache.files["song::pinned"])
    }

    /// A jump moves the prefetch window with the playing track: songs that became
    /// upcoming are kept, songs that dropped out of the window are pruned.
    func testWindowFollowsJump() {
        let cache = MockCache()
        let downloader = DownloadManager(urlProvider: MockURLProvider(), cache: cache)
        let queue = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 5)
        for item in items {
            cache.files["song::\(item.playableId)"] = (.song, .queuePrefetch, Date(), queue.queueGeneration, false)
        }

        // Jump from index 5 to index 1; the window should re-center on 1.
        queue.jump(to: 1)
        XCTAssertEqual(queue.currentItem?.playableId, "1")

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()

        // prev2 = 0,1,2 current=1 next5 = 2..6 → keep 0,1,2,3,4,5,6
        for kept in ["0", "1", "2", "3", "4", "5", "6"] {
            XCTAssertNotNil(cache.files["song::\(kept)"], "\(kept) should still be cached")
        }
        for pruned in ["7", "8", "9"] {
            XCTAssertNil(cache.files["song::\(pruned)"], "\(pruned) fell outside the window after jump")
        }
    }

    /// Switching the feature off has to take its cache with it. Pruning used to live
    /// behind the same setting check as fetching, so everything already prefetched was
    /// stranded on disk with nothing left to delete it.
    func testDisablingPrefetchDrainsTheCache() async {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        let items = (0..<3).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 0)
        for item in items {
            cache.files["song::\(item.playableId)"] = (.song, .queuePrefetch, Date(), queue.queueGeneration, false)
        }
        cache.files["song::owned"] = (.song, .userDownload, Date(), 0, true)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: false, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()
        try? await Task.sleep(nanoseconds: 100_000_000)

        for drained in ["0", "1", "2"] {
            XCTAssertNil(cache.files["song::\(drained)"], "\(drained) has nothing left to prune it")
        }
        XCTAssertNotNil(cache.files["song::owned"], "an explicit download is not a prefetch")
        XCTAssertTrue(downloader.enqueued.isEmpty, "nothing should be fetched with the feature off")
    }

    /// `status(for:)` reads `completedIds`, so a completion recorded for the UI outlives
    /// the file unless eviction clears it — the row keeps the downloaded glyph over an
    /// empty cache for the rest of the session.
    func testEvictionClearsARecordedCompletion() {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        queue.replaceContext(with: [QueueItem(playableId: "a", title: "A")], startAt: 0)
        cache.files["song::stale"] = (.song, .queuePrefetch, Date().addingTimeInterval(-20 * 3600), 0, false)

        DownloadCenter.shared.complete(playableId: "stale")
        XCTAssertEqual(DownloadCenter.shared.status(for: "stale", isDownloaded: false), .downloaded)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.pruneStale()

        XCTAssertNil(cache.files["song::stale"])
        XCTAssertEqual(DownloadCenter.shared.status(for: "stale", isDownloaded: false), DownloadStatus.none)
    }

    /// Oldest unpinned files go first; explicit downloads are never sacrificed for a size cap.
    func testEnforceCacheLimitEvictsOldestPrefetchFirst() {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        queue.replaceContext(with: [QueueItem(playableId: "playing", title: "P")], startAt: 0)

        let older = Date().addingTimeInterval(-3_600)
        let newer = Date().addingTimeInterval(-60)
        cache.files["song::old"] = (.song, .queuePrefetch, older, 0, false)
        cache.files["song::new"] = (.song, .queuePrefetch, newer, 0, false)
        cache.files["song::owned"] = (.song, .userDownload, older, 0, true)
        cache.sizes["song::old"] = 40
        cache.sizes["song::new"] = 40
        cache.sizes["song::owned"] = 40

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(cacheLimitBytes: 80, smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.enforceCacheLimit()

        XCTAssertNil(cache.files["song::old"], "oldest prefetch should be freed first")
        XCTAssertNotNil(cache.files["song::new"])
        XCTAssertNotNil(cache.files["song::owned"], "user downloads are outside the size budget")
        XCTAssertEqual(cache.totalPlayableCacheSize(), 80)
    }

    func testUnlimitedCacheLimitDoesNotEvict() {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        queue.replaceContext(with: [QueueItem(playableId: "a", title: "A")], startAt: 0)
        cache.files["song::a"] = (.song, .queuePrefetch, Date(), 0, false)
        cache.sizes["song::a"] = 1_000

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: {
                UserSettings(
                    cacheLimitBytes: PlayableCacheLimit.unlimited.rawValue,
                    smartQueuePrefetchEnabled: true,
                    queuePrefetchStaleHours: 18
                )
            }
        )
        policy.enforceCacheLimit()
        XCTAssertNotNil(cache.files["song::a"])
    }

    func testDefaultCacheLimitIsThreeGigabytes() {
        XCTAssertEqual(PlayableCacheLimit.default, .gb3)
        XCTAssertEqual(UserSettings.default.cacheLimitBytes, PlayableCacheLimit.gb3.rawValue)
        XCTAssertEqual(PlayableCacheLimit.allCases.map(\.label), [
            "250 MB", "500 MB", "1 GB", "2 GB", "3 GB", "5 GB", "7 GB", "10 GB", "12 GB", "20 GB", "Unlimited"
        ])
    }

    /// Both prune loops iterate the cache's own metadata, so a file missing from it is
    /// unreachable — the sweep is what stops those from living on disk forever.
    func testOrphanSweepDeletesUntrackedFilesOnceTheyAreOldEnough() {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        queue.replaceContext(with: [QueueItem(playableId: "a", title: "A")], startAt: 0)
        cache.untracked["song::stranded"] = Date().addingTimeInterval(-600)
        cache.untracked["song::justLanded"] = Date()

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.pruneOrphans()

        XCTAssertNil(cache.untracked["song::stranded"])
        XCTAssertNotNil(
            cache.untracked["song::justLanded"],
            "a transfer stores the file before recording it; sweeping that window would delete it"
        )
    }

    /// A spy downloader that records `enqueue` and `cancelPending` calls without
    /// touching the network, so the prefetch-cancel side of a jump can be asserted.
    final class SpyDownloader: DownloadManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [String] = []
        private var _cancelledExcept: Set<String>?

        var enqueued: [String] { lock.withLock { _enqueued } }
        var cancelledExcept: Set<String>? { lock.withLock { _cancelledExcept } }

        func enqueue(playableId: String, kind: PlayableRef.Kind, reason: CacheReason, force: Bool) async {
            lock.withLock { _enqueued.append(playableId) }
        }
        func cancel(playableId: String) async {}
        func cancelAll() async {}
        func cancelPending(reason: CacheReason, except keep: Set<String>) async {
            guard reason == .queuePrefetch else { return }
            lock.withLock { _cancelledExcept = keep }
        }
        func retryFailed() async {}
    }

    final class SpyArtwork: ArtworkPrefetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [(artId: String, kind: ArtworkKind, size: Int)] = []

        var enqueued: [(artId: String, kind: ArtworkKind, size: Int)] {
            lock.withLock { _enqueued }
        }

        func enqueue(artId: String, kind: ArtworkKind, size: Int) async {
            lock.withLock { _enqueued.append((artId, kind, size)) }
        }
    }

    /// Queue-window reevaluate also disk-prefetches cover art (player size) for
    /// upcoming tracks so skip / Now Playing don't wait on the network. Covers reach
    /// further ahead than audio: the next ten tracks rather than the next five.
    func testReevaluatePrefetchesArtworkForWindow() async {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let artwork = SpyArtwork()
        let queue = PlayQueueHandler()
        let items = (0..<30).map { i in
            QueueItem(
                playableId: "\(i)",
                title: "S\(i)",
                // Shared album art for even indices — should enqueue once.
                artworkId: i % 2 == 0 ? "album-A" : "art-\(i)"
            )
        }
        queue.replaceContext(with: items, startAt: 5)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            artwork: artwork,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Art window at index 5 keeps items 3…15; shared album-A is enqueued once.
        let artIds = Set(artwork.enqueued.map(\.artId))
        XCTAssertEqual(
            artIds,
            ["album-A", "art-3", "art-5", "art-7", "art-9", "art-11", "art-13", "art-15"]
        )
        XCTAssertTrue(artwork.enqueued.allSatisfy { $0.size == QueueCachePolicyManager.artworkPrefetchSize })
        XCTAssertTrue(artwork.enqueued.allSatisfy { $0.kind == .album })
        XCTAssertEqual(artwork.enqueued.filter { $0.artId == "album-A" }.count, 1)
    }

    /// After a jump, pending `.queuePrefetch` downloads outside the new window are
    /// cancelled so bandwidth isn't spent finishing tracks the user left behind.
    func testJumpCancelsPendingPrefetchOutsideWindow() async {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 5)

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        // First pass: nothing is cached, so all window neighbors get enqueued.
        policy.reevaluate()
        // reevaluate fires cancelPending in a detached Task; let it land.
        try? await Task.sleep(nanoseconds: 100_000_000)
        // After the initial pass the keep set was 3,4,5,6,7,8,9 (current=5 skipped from
        // download but still part of the keep set passed to cancelPending).
        let firstCancelled = downloader.cancelledExcept
        XCTAssertNotNil(firstCancelled)
        XCTAssertEqual(firstCancelled, ["3", "4", "5", "6", "7", "8", "9"])

        // Jump to index 1; the window re-centers on 1.
        queue.jump(to: 1)
        policy.reevaluate()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // New keep set is 0,1,2,3,4,5,6 — the old neighbors 7,8,9 are no longer kept.
        let secondCancelled = downloader.cancelledExcept
        XCTAssertNotNil(secondCancelled)
        XCTAssertEqual(secondCancelled, ["0", "1", "2", "3", "4", "5", "6"])
    }

    /// Advancing must prune only what left the window. The playing track's generation is
    /// stamped with the rest of the keep set so a later shuffle/replace bump cannot
    /// treat it as obsolete and delete the file under the playhead.
    func testAdvancePrunesOnlyOutsideWindowAndStampsCurrentGeneration() {
        let cache = MockCache()
        let downloader = SpyDownloader()
        let queue = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
        queue.replaceContext(with: items, startAt: 5)
        for item in items {
            // Stale generation mimics a file written before the current queue context.
            cache.files["song::\(item.playableId)"] = (.song, .queuePrefetch, Date(), 0, false)
        }

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            settings: { UserSettings(smartQueuePrefetchEnabled: true, queuePrefetchStaleHours: 18) }
        )
        policy.reevaluate()

        // Window at 5: keep 3…9; 0…2 outside (0 was never pinned here).
        for kept in ["3", "4", "5", "6", "7", "8", "9"] {
            XCTAssertNotNil(cache.files["song::\(kept)"])
            XCTAssertEqual(
                cache.files["song::\(kept)"]?.generation,
                queue.queueGeneration,
                "\(kept) should carry the current queue generation"
            )
        }
        XCTAssertNil(cache.files["song::1"])
        XCTAssertNil(cache.files["song::2"])

        _ = queue.advance()
        XCTAssertEqual(queue.currentItem?.playableId, "6")
        policy.reevaluate()

        // Window at 6: keep 4…9 (and nothing past 9). Track 3 fell out.
        XCTAssertNil(cache.files["song::3"])
        for kept in ["4", "5", "6", "7", "8", "9"] {
            XCTAssertNotNil(cache.files["song::\(kept)"], "\(kept) is still in the keep window")
        }
    }
}
