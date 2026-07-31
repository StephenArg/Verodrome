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
}
