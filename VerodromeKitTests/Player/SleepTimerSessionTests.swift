import XCTest
@testable import VerodromeKit

@MainActor
final class SleepTimerSessionTests: XCTestCase {
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

    func testStartSetsDeadline() {
        let facade = makeFacade()
        XCTAssertNil(facade.sleepTimerDeadline)

        facade.startSleepTimer(90 * 60)

        guard let deadline = facade.sleepTimerDeadline else {
            return XCTFail("Expected a sleep timer deadline")
        }
        let remaining = deadline.timeIntervalSinceNow
        XCTAssertEqual(remaining, 90 * 60, accuracy: 1.5)
    }

    func testZeroDurationCancels() {
        let facade = makeFacade()
        facade.startSleepTimer(60)
        XCTAssertNotNil(facade.sleepTimerDeadline)

        facade.startSleepTimer(0)
        XCTAssertNil(facade.sleepTimerDeadline)
    }

    func testDueTickClearsDeadlineAndPauses() {
        let facade = makeFacade()
        // Seed a deadline in the past without waiting on a real timer.
        facade.startSleepTimer(60)
        // Overwrite with a known past deadline via start + fire: start sets now+60,
        // then fire with a clock past that.
        let deadline = facade.sleepTimerDeadline!
        facade.test_fireSleepTimerIfDue(now: deadline.addingTimeInterval(-1))
        XCTAssertNotNil(facade.sleepTimerDeadline)

        facade.test_fireSleepTimerIfDue(now: deadline)
        XCTAssertNil(facade.sleepTimerDeadline)
        XCTAssertFalse(facade.isPlaying)
    }

    func testNotYetDueTickLeavesTimerAlone() {
        let facade = makeFacade()
        facade.startSleepTimer(120)
        let deadline = facade.sleepTimerDeadline

        facade.test_fireSleepTimerIfDue(now: Date().addingTimeInterval(30))
        XCTAssertEqual(facade.sleepTimerDeadline, deadline)
    }

    func testContextGenerationCancelsSleepTimer() {
        let facade = makeFacade()
        facade.startSleepTimer(30 * 60)
        XCTAssertNotNil(facade.sleepTimerDeadline)

        facade.test_queueHandler.replaceContext(
            with: [QueueItem(playableId: "1", title: "One")],
            startAt: 0
        )

        XCTAssertNil(facade.sleepTimerDeadline)
    }

    func testClearQueueCancelsSleepTimer() {
        let facade = makeFacade()
        facade.test_queueHandler.replaceContext(
            with: [QueueItem(playableId: "1", title: "One")],
            startAt: 0
        )
        facade.startSleepTimer(15 * 60)
        XCTAssertNotNil(facade.sleepTimerDeadline)

        facade.clearQueue()
        XCTAssertNil(facade.sleepTimerDeadline)
    }

    func testCancelClearsWithoutRequiringDue() {
        let facade = makeFacade()
        facade.startSleepTimer(45 * 60)
        facade.cancelSleepTimer()
        XCTAssertNil(facade.sleepTimerDeadline)
    }

    func testDurationHelpers() {
        XCTAssertEqual(SleepTimer.duration(hours: 1, minutes: 30), 5400)
        XCTAssertEqual(SleepTimer.duration(hours: 0, minutes: 45), 2700)
        XCTAssertEqual(SleepTimer.duration(hours: 99, minutes: 99), SleepTimer.duration(hours: 23, minutes: 59))
        XCTAssertEqual(SleepTimer.label(hours: 1, minutes: 29), "1h 29m")
        XCTAssertEqual(SleepTimer.label(hours: 2, minutes: 0), "2h")
        XCTAssertEqual(SleepTimer.label(hours: 0, minutes: 45), "45m")
        XCTAssertEqual(SleepTimer.label(hours: 0, minutes: 0), "Off")
        XCTAssertEqual(SleepTimer.label(remaining: 90), "1m")
        XCTAssertEqual(SleepTimer.label(remaining: 120), "2m")
        XCTAssertEqual(SleepTimer.label(remaining: 0), "Off")
    }
}
