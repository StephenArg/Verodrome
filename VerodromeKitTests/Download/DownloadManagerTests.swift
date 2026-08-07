import XCTest
@testable import VerodromeKit

@MainActor
final class DownloadManagerTests: XCTestCase {
    /// Holds `downloadURL` open so a transfer can be inspected mid-flight, and fails
    /// instead of reaching the network once released.
    final class HeldURLProvider: StreamURLProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _started: [String] = []
        private var _isReleased = false

        var started: [String] { lock.withLock { _started } }
        func release() { lock.withLock { _isReleased = true } }
        private var isReleased: Bool { lock.withLock { _isReleased } }

        func downloadURL(forPlayableId id: String, format: StreamFormat) async throws -> URL {
            lock.withLock { _started.append(id) }
            while !isReleased {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw BackendError.invalidURL
        }

        func streamURL(forPlayableId id: String, maxBitrate: Int, format: StreamFormat) async throws -> URL {
            throw BackendError.invalidURL
        }

        func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
            throw BackendError.invalidURL
        }
    }

    /// Nothing is ever on disk, so every enqueue starts a transfer.
    final class EmptyCache: PlayableFileCaching, @unchecked Sendable {
        func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? { nil }
        func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
            URL(fileURLWithPath: "/tmp/\(id)")
        }
        func deletePlayable(id: String, kind: PlayableRef.Kind) throws {}
        func totalPlayableCacheSize() -> Int64 { 0 }
        func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {}
        func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason { .none }
        func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool { false }
        func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] { [] }
        func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {}
    }

    override func setUp() async throws {
        try await super.setUp()
        DownloadCenter.shared.clearAllActive()
        DownloadCenter.shared.clearCompleted()
        DownloadCenter.shared.clearFailed()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// A prefetch is a cache the policy manager can delete at any time. Reported to
    /// `DownloadCenter` it would put a progress ring on whatever rows are on screen and
    /// an entry in the Downloads list, for a download the user never asked for.
    func testAPrefetchStaysOutOfTheDownloadCenter() async {
        let provider = HeldURLProvider()
        let manager = DownloadManager(urlProvider: provider, cache: EmptyCache())

        await manager.enqueue(playableId: "a", kind: .song, reason: .queuePrefetch)
        await waitUntil("the prefetch to start") { provider.started == ["a"] }

        XCTAssertTrue(DownloadCenter.shared.workingIds.isEmpty)
        XCTAssertEqual(DownloadCenter.shared.status(for: "a", isDownloaded: false), DownloadStatus.none)

        provider.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            DownloadCenter.shared.failedIds.contains("a"),
            "a prefetch that fails is not something to show the user"
        )
    }

    func testAUserDownloadIsReportedFromTheMomentItIsQueued() async {
        let provider = HeldURLProvider()
        let manager = DownloadManager(urlProvider: provider, cache: EmptyCache())

        await manager.enqueue(playableId: "a", kind: .song, reason: .userDownload)

        await waitUntil("the download to be reported") { DownloadCenter.shared.isWorking(on: "a") }

        provider.release()
        await waitUntil("the failure to surface") { DownloadCenter.shared.failedIds.contains("a") }
    }

    /// The manager dedupes by id, so an explicit download of a track a prefetch already
    /// started used to be dropped — and with prefetch no longer writing library state,
    /// the tap would leave no trace at all.
    func testAnExplicitDownloadUpgradesAnInFlightPrefetch() async {
        let provider = HeldURLProvider()
        let manager = DownloadManager(urlProvider: provider, cache: EmptyCache())

        await manager.enqueue(playableId: "a", kind: .song, reason: .queuePrefetch)
        await waitUntil("the prefetch to start") { provider.started == ["a"] }

        await manager.enqueue(playableId: "a", kind: .song, reason: .userDownload)

        XCTAssertEqual(DownloadCenter.shared.status(for: "a", isDownloaded: false), .pending)
        XCTAssertEqual(provider.started, ["a"], "the upgrade should adopt the transfer already running")

        // The upgraded reason is what the outcome is reported against.
        provider.release()
        await waitUntil("the failure to surface") { DownloadCenter.shared.failedIds.contains("a") }
    }
}
