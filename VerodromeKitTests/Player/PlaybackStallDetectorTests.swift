import XCTest
@testable import VerodromeKit

/// The detector is what notices a dead stream when AudioStreaming reports nothing at all,
/// and what keeps `resume()` from being trusted on an entry that never produced audio.
final class PlaybackStallDetectorTests: XCTestCase {
    private let timeout: TimeInterval = 12
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeDetector() -> PlaybackStallDetector {
        PlaybackStallDetector(timeout: timeout, now: start)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - First audio never arrives

    func testPreRollZeroProgressDoesNotCountAsStarted() {
        var detector = makeDetector()
        for tick in stride(from: 0.25, through: 3, by: 0.25) {
            XCTAssertFalse(detector.update(progress: 0, isPlaying: true, now: at(tick)))
        }
        XCTAssertFalse(
            detector.hasStartedAudio,
            "progress == 0 during pre-roll must not be treated as audio starting"
        )
    }

    func testReportsStallWhenFirstAudioNeverArrives() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 0, isPlaying: true, now: at(timeout - 0.5)))
        XCTAssertTrue(detector.update(progress: 0, isPlaying: true, now: at(timeout)))
        XCTAssertFalse(detector.hasStartedAudio)
    }

    // MARK: - Healthy playback

    func testForwardProgressMarksAudioStartedAndKeepsStreamHealthy() {
        var detector = makeDetector()
        var elapsed = 0.0
        for _ in 0..<200 {
            elapsed += 0.25
            XCTAssertFalse(detector.update(progress: elapsed, isPlaying: true, now: at(elapsed)))
        }
        XCTAssertTrue(detector.hasStartedAudio)
    }

    func testBriefUnderrunIsNotAStall() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 5, isPlaying: true, now: at(5)))
        // Clock frozen for a few seconds, well inside AudioStreaming's rebuffer window.
        for tick in stride(from: 5.25, through: 9, by: 0.25) {
            XCTAssertFalse(detector.update(progress: 5, isPlaying: true, now: at(tick)))
        }
        XCTAssertFalse(detector.update(progress: 5.5, isPlaying: true, now: at(9.25)))
    }

    func testJitterBelowEpsilonIsNotForwardProgress() {
        var detector = makeDetector()
        let jitter = PlaybackStallDetector.progressEpsilon / 2
        XCTAssertFalse(detector.update(progress: jitter, isPlaying: true, now: at(1)))
        XCTAssertFalse(detector.hasStartedAudio)
    }

    // MARK: - Mid-track drop

    func testReportsStallWhenClockFreezesMidTrack() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 30, isPlaying: true, now: at(30)))
        XCTAssertTrue(detector.hasStartedAudio)
        XCTAssertTrue(detector.update(progress: 30, isPlaying: true, now: at(30 + timeout)))
    }

    // MARK: - Pause / seek must not look like a stall

    func testPausedStreamNeverStalls() {
        var detector = makeDetector()
        for tick in stride(from: 1, through: timeout * 3, by: 1) {
            XCTAssertFalse(detector.update(progress: 12, isPlaying: false, now: at(tick)))
        }
    }

    func testResumeAfterLongPauseGetsAFreshWindow() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 12, isPlaying: true, now: at(12)))
        detector.extendWindow(now: at(600))
        XCTAssertFalse(detector.update(progress: 12, isPlaying: true, now: at(601)))
        XCTAssertTrue(detector.hasStartedAudio, "pausing must not forget that audio started")
    }

    func testSeekingBackwardsIsNotAStall() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 100, isPlaying: true, now: at(100)))
        detector.extendWindow(now: at(101))
        // Progress now reports a much lower value; that is a rebase, not a frozen clock.
        XCTAssertFalse(detector.update(progress: 10, isPlaying: true, now: at(101.25)))
        XCTAssertFalse(detector.update(progress: 11, isPlaying: true, now: at(102)))
    }

    // MARK: - Resumability

    func testGaplessHandOffStartsOutHealthy() {
        var detector = makeDetector()
        detector.adoptPlayingEntry(now: at(50))
        XCTAssertTrue(
            detector.hasStartedAudio,
            "the engine advanced on its own, so audio is already flowing"
        )
    }

    func testResetClearsAudioStartedSoResumeIsNotTrusted() {
        var detector = makeDetector()
        XCTAssertFalse(detector.update(progress: 30, isPlaying: true, now: at(30)))
        XCTAssertTrue(detector.hasStartedAudio)
        detector.reset(now: at(31))
        XCTAssertFalse(detector.hasStartedAudio)
    }

    // MARK: - Early recovery hook

    func testSilentlyStuckOnlyAfterGraceElapses() {
        var detector = makeDetector()
        XCTAssertFalse(detector.isSilentlyStuck(grace: 2, now: at(1)))
        XCTAssertTrue(detector.isSilentlyStuck(grace: 2, now: at(2)))
        // Once audio flows it is never considered stuck.
        _ = detector.update(progress: 1, isPlaying: true, now: at(3))
        XCTAssertFalse(detector.isSilentlyStuck(grace: 2, now: at(60)))
    }
}
