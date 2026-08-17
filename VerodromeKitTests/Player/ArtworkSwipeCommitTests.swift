import XCTest
@testable import VerodromeKit

final class ArtworkSwipeCommitTests: XCTestCase {
    func testCommitsNextAtThreshold() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -45,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .commitNext
        )
    }

    func testCommitsPreviousAtThreshold() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: 45,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .commitPrevious
        )
    }

    func testCancelsJustBelowThreshold() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -44.9,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: 44.9,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
    }

    func testPastThresholdWithoutNeighborCancels() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -80,
                width: 100,
                canGoPrevious: true,
                canGoNext: false
            ),
            .cancel
        )
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: 80,
                width: 100,
                canGoPrevious: false,
                canGoNext: true
            ),
            .cancel
        )
    }

    func testZeroWidthCancels() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -100,
                width: 0,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
    }

    func testFlickCommitsNextBelowDistanceThreshold() {
        // 20% travel, flicking left at 1500 pt/s projects well past 45%.
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -20,
                velocity: -1500,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .commitNext
        )
    }

    func testFlickCommitsPreviousBelowDistanceThreshold() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: 20,
                velocity: 1500,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .commitPrevious
        )
    }

    func testSlowDragBelowThresholdStillCancels() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -20,
                velocity: -50,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
    }

    func testFlickBackCancelsPastDistanceThreshold() {
        // 50% travel, but a 1500 pt/s flick the other way projects back under 45%.
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -50,
                velocity: 1500,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: 50,
                velocity: -1500,
                width: 100,
                canGoPrevious: true,
                canGoNext: true
            ),
            .cancel
        )
    }

    func testFlickWithoutNeighborCancels() {
        XCTAssertEqual(
            ArtworkSwipeCommit.decision(
                translation: -20,
                velocity: -1500,
                width: 100,
                canGoPrevious: true,
                canGoNext: false
            ),
            .cancel
        )
    }

    func testDragOffsetFollowsFingerWhenNeighborExists() {
        XCTAssertEqual(
            ArtworkSwipeCommit.dragOffset(translation: -40, canGoPrevious: true, canGoNext: true),
            -40
        )
        XCTAssertEqual(
            ArtworkSwipeCommit.dragOffset(translation: 40, canGoPrevious: true, canGoNext: true),
            40
        )
    }

    func testDragOffsetRubberBandsWithoutNeighbor() {
        XCTAssertEqual(
            ArtworkSwipeCommit.dragOffset(translation: -50, canGoPrevious: true, canGoNext: false),
            -10
        )
        XCTAssertEqual(
            ArtworkSwipeCommit.dragOffset(translation: 50, canGoPrevious: false, canGoNext: true),
            10
        )
    }
}

final class MiniSkipSeekTests: XCTestCase {
    func testForwardStaysInsideDuration() {
        XCTAssertEqual(MiniSkipSeek.target(current: 10, duration: 100, delta: 5), 15)
        XCTAssertEqual(MiniSkipSeek.target(current: 98, duration: 100, delta: 5), 100)
        XCTAssertEqual(MiniSkipSeek.target(current: 100, duration: 100, delta: 5), 100)
    }

    func testBackwardClampsToZero() {
        XCTAssertEqual(MiniSkipSeek.target(current: 10, duration: 100, delta: -5), 5)
        XCTAssertEqual(MiniSkipSeek.target(current: 3, duration: 100, delta: -5), 0)
        XCTAssertEqual(MiniSkipSeek.target(current: 0, duration: 100, delta: -5), 0)
    }

    func testZeroOrMissingDuration() {
        XCTAssertEqual(MiniSkipSeek.target(current: 4, duration: 0, delta: 5), 0)
        XCTAssertEqual(MiniSkipSeek.target(current: 0, duration: 0, delta: -5), 0)
        XCTAssertEqual(MiniSkipSeek.target(current: 2, duration: -1, delta: 5), 0)
    }
}

final class HoldSpeedZoneTests: XCTestCase {
    func testLeftIsSlow() {
        XCTAssertEqual(HoldSpeedZone.zone(x: 0, width: 100), .slow)
        XCTAssertEqual(HoldSpeedZone.zone(x: 39, width: 100), .slow)
        XCTAssertEqual(HoldSpeedZone.zone(x: 0, width: 100).rate, 0.5)
    }

    func testRightIsFast() {
        XCTAssertEqual(HoldSpeedZone.zone(x: 61, width: 100), .fast)
        XCTAssertEqual(HoldSpeedZone.zone(x: 100, width: 100), .fast)
        XCTAssertEqual(HoldSpeedZone.zone(x: 100, width: 100).rate, 2)
    }

    func testCenterIsDeadZone() {
        XCTAssertEqual(HoldSpeedZone.zone(x: 40, width: 100), .none)
        XCTAssertEqual(HoldSpeedZone.zone(x: 50, width: 100), .none)
        XCTAssertEqual(HoldSpeedZone.zone(x: 60, width: 100), .none)
        XCTAssertNil(HoldSpeedZone.zone(x: 50, width: 100).rate)
    }

    func testZeroWidthIsNone() {
        XCTAssertEqual(HoldSpeedZone.zone(x: 10, width: 0), .none)
    }
}
