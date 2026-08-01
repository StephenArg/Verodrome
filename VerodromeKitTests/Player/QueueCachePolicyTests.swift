import XCTest
@testable import VerodromeKit

@MainActor
final class QueueCachePolicyTests: XCTestCase {
    final class MockCache: PlayableFileCaching, @unchecked Sendable {
        var files: [String: (kind: PlayableRef.Kind, reason: CacheReason, touched: Date, generation: Int, pinned: Bool)] = [:]
        func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? {
            files["\(kind.rawValue)::\(id)"] == nil ? nil : URL(fileURLWithPath: "/tmp/\(id)")
        }
        func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
            files["\(kind.rawValue)::\(id)"] = (kind, reason, Date(), 0, reason.isUserPinnedReason)
            return URL(fileURLWithPath: "/tmp/\(id)")
        }
        func deletePlayable(id: String, kind: PlayableRef.Kind) throws {
            files.removeValue(forKey: "\(kind.rawValue)::\(id)")
        }
        func totalPlayableCacheSize() -> Int64 { Int64(files.count) }
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
    }

    final class MockURLProvider: StreamURLProviding, @unchecked Sendable {
        func streamURL(forPlayableId id: String, maxBitrate: Int, format: StreamFormat) async throws -> URL {
            URL(string: "https://example.com/\(id)")!
        }
        func downloadURL(forPlayableId id: String, format: StreamFormat) async throws -> URL {
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

    /// A spy downloader that records `enqueue` and `cancelPending` calls without
    /// touching the network, so the prefetch-cancel side of a jump can be asserted.
    final class SpyDownloader: DownloadManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [String] = []
        private var _cancelledExcept: Set<String>?

        var enqueued: [String] { lock.withLock { _enqueued } }
        var cancelledExcept: Set<String>? { lock.withLock { _cancelledExcept } }

        func enqueue(playableId: String, kind: PlayableRef.Kind, reason: CacheReason) async {
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
}
