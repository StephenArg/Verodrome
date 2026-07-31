import XCTest
@testable import VerodromeKit

/// Covers the look-ahead used when a track cannot be loaded while offline: playback
/// should fail over to a nearby cached track instead of skipping blindly.
final class OfflineFailoverTests: XCTestCase {
    private func makeQueue(_ count: Int) -> [QueueItem] {
        (0..<count).map { QueueItem(playableId: "\($0)", title: "S\($0)") }
    }

    private func index(in queue: [QueueItem], after current: Int, cached: Set<String>) -> Int? {
        AudioPlayer.nextCachedIndex(in: queue, after: current) { cached.contains($0.playableId) }
    }

    func testFindsNearestCachedTrackAhead() {
        let queue = makeQueue(10)
        XCTAssertEqual(index(in: queue, after: 2, cached: ["5", "7"]), 5)
    }

    func testIgnoresCachedTracksBehindCurrent() {
        let queue = makeQueue(10)
        XCTAssertNil(index(in: queue, after: 4, cached: ["0", "1", "4"]))
    }

    func testStopsAtLookAheadWindow() {
        let queue = makeQueue(20)
        // Only track 9 is cached, which is 6 ahead — outside the 5-item window.
        XCTAssertNil(index(in: queue, after: 3, cached: ["9"]))
        // One closer is inside it.
        XCTAssertEqual(index(in: queue, after: 3, cached: ["8", "9"]), 8)
    }

    func testClampsToEndOfQueue() {
        let queue = makeQueue(4)
        XCTAssertEqual(index(in: queue, after: 1, cached: ["3"]), 3)
        XCTAssertNil(index(in: queue, after: 3, cached: ["0", "1", "2"]))
    }

    func testEmptyQueueHasNoCandidate() {
        XCTAssertNil(index(in: [], after: 0, cached: ["0"]))
    }

    func testNothingCachedAheadReturnsNil() {
        let queue = makeQueue(10)
        XCTAssertNil(index(in: queue, after: 2, cached: []))
    }
}
