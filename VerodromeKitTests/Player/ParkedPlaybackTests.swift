import XCTest
@testable import VerodromeKit

/// A track parked at launch or at the end of the queue has to stay out of the engine
/// (loading it starts audio and claims the session), and a stream that dies while the
/// user has it paused must not bring the music back.
@MainActor
final class ParkedPlaybackTests: XCTestCase {
    private final class EmptyCache: PlayableFileCaching, @unchecked Sendable {
        func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? { nil }
        func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
            temporaryURL
        }
        func deletePlayable(id: String, kind: PlayableRef.Kind) throws {}
        func totalPlayableCacheSize() -> Int64 { 0 }
        func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64 { 0 }
        func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {}
        func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason { .none }
        func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool { false }
        func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] { [] }
        func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {}
        func orphanedFiles(olderThan minimumAge: TimeInterval) -> [(id: String, kind: PlayableRef.Kind)] { [] }
    }

    /// Counts stream requests: every path that starts playback asks for one first.
    private final class CountingURLProvider: StreamURLProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.withLock { count } }

        private func record() { lock.withLock { count += 1 } }

        func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            record()
            return URL(string: "https://example.invalid/\(id)")!
        }
        func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            record()
            return URL(string: "https://example.invalid/\(id)")!
        }
        func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
            URL(string: "https://example.invalid/art/\(artId)")!
        }
    }

    private var provider: CountingURLProvider!
    private var player: AudioPlayer!

    override func setUp() async throws {
        provider = CountingURLProvider()
        let backend = BackendAudioPlayer(urlProvider: provider, cache: EmptyCache())
        player = AudioPlayer(queueHandler: PlayQueueHandler(), backend: backend, settings: { UserSettings() })
        player.queueHandler.replaceContext(
            with: [QueueItem(playableId: "1", title: "One"), QueueItem(playableId: "2", title: "Two")],
            startAt: 0
        )
    }

    override func tearDown() async throws {
        player = nil
        provider = nil
    }

    /// Lets the main-actor tasks the player and backend schedule run.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testRestoredTrackIsParkedWithoutLoadingTheEngine() async throws {
        await player.restoreSession(at: 42)
        try await settle()

        XCTAssertEqual(provider.requests, 0)
        XCTAssertFalse(player.backend.isPlaying)
        XCTAssertFalse(player.backend.wantsPlayback)
        XCTAssertEqual(player.backend.currentTime, 42, accuracy: 0.01)
        XCTAssertEqual(player.nowPlaying?.playableId, "1")
    }

    func testNetworkDropWhilePausedDoesNotArmARetry() async throws {
        await player.restoreSession(at: 42)
        player.backend.onPlaybackError?(.dataNotFound)
        try await settle()

        XCTAssertEqual(player.statusMessage, "")
        // Turning offline mode off retries a stalled track. Nothing should be stalled.
        NotificationCenter.default.post(name: .offlineModeChanged, object: nil)
        try await settle()

        XCTAssertEqual(provider.requests, 0)
        XCTAssertFalse(player.backend.isPlaying)
        XCTAssertEqual(player.backend.currentTime, 42, accuracy: 0.01)
    }

    func testStreamFailureWhilePausedDoesNotSkipToTheNextSong() async throws {
        await player.restoreSession(at: 42)
        player.backend.onPlaybackError?(.codecError)
        try await settle()

        XCTAssertEqual(player.queueHandler.currentIndex, 0)
        XCTAssertEqual(provider.requests, 0)
        XCTAssertFalse(player.backend.isPlaying)
    }
}
