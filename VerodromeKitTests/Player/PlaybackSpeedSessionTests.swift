import XCTest
@testable import VerodromeKit

@MainActor
final class PlaybackSpeedSessionTests: XCTestCase {
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

    private final class MockURLProvider: StreamURLProviding, @unchecked Sendable {
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

    private func makeFacade() -> PlayerFacadeImpl {
        let queue = PlayQueueHandler()
        let backend = BackendAudioPlayer(urlProvider: MockURLProvider(), cache: EmptyCache())
        let audio = AudioPlayer(queueHandler: queue, backend: backend, settings: { UserSettings() })
        return PlayerFacadeImpl(audioPlayer: audio)
    }

    func testSetSessionPlaybackRateAppliesToEngine() {
        let facade = makeFacade()
        facade.setSessionPlaybackRate(1.5)
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.sessionPlaybackRate, 1.5))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_enginePlaybackRate, 1.5))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_engineSessionRate, 1.5))
    }

    func testContextGenerationResetClearsSessionRate() {
        let facade = makeFacade()
        facade.setSessionPlaybackRate(1.75)
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.sessionPlaybackRate, 1.75))

        facade.test_queueHandler.replaceContext(
            with: [QueueItem(playableId: "1", title: "One")],
            startAt: 0
        )

        XCTAssertTrue(PlaybackSpeed.isEqual(facade.sessionPlaybackRate, 1))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_engineSessionRate, 1))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_enginePlaybackRate, 1))
    }

    func testClearQueueResetsSessionRate() {
        let facade = makeFacade()
        facade.test_queueHandler.replaceContext(
            with: [QueueItem(playableId: "1", title: "One")],
            startAt: 0
        )
        facade.setSessionPlaybackRate(0.75)
        facade.clearQueue()

        XCTAssertTrue(PlaybackSpeed.isEqual(facade.sessionPlaybackRate, 1))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_engineSessionRate, 1))
    }

    func testHoldEndRestoresSessionRateNotOne() {
        let facade = makeFacade()
        facade.setSessionPlaybackRate(1.25)
        facade.setPlaybackRate(2)
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_enginePlaybackRate, 2))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_engineSessionRate, 1.25))

        facade.restoreSessionPlaybackRate()

        XCTAssertTrue(PlaybackSpeed.isEqual(facade.test_enginePlaybackRate, 1.25))
        XCTAssertTrue(PlaybackSpeed.isEqual(facade.sessionPlaybackRate, 1.25))
    }

    func testPlaybackSpeedLabels() {
        XCTAssertEqual(PlaybackSpeed.label(for: 2), "2x")
        XCTAssertEqual(PlaybackSpeed.label(for: 1.75), "1.75x")
        XCTAssertEqual(PlaybackSpeed.label(for: 1.5), "1.5x")
        XCTAssertEqual(PlaybackSpeed.label(for: 1.25), "1.25x")
        XCTAssertEqual(PlaybackSpeed.label(for: 1), "1x")
        XCTAssertEqual(PlaybackSpeed.label(for: 0.75), ".75x")
        XCTAssertEqual(PlaybackSpeed.label(for: 0.5), ".5x")
    }
}
