import AVFoundation
import XCTest
@testable import VerodromeKit

/// iOS asks for a resume whenever the audio that interrupted us lets go (a Safari video
/// ending, a call hanging up), whether or not anything was playing here first. Only
/// playback the interruption itself paused may come back.
@MainActor
final class AudioSessionHandlerTests: XCTestCase {
    /// Stand-in player state. It follows the handler's requests the way the real player
    /// does: paused when an interruption begins, playing again when asked to resume.
    private var isPlaying = false
    private var resumes = 0

    private func makeHandler(playing: Bool) -> AudioSessionHandler {
        isPlaying = playing
        let handler = AudioSessionHandler()
        handler.isPlaying = { self.isPlaying }
        handler.onInterrupt = { began in
            if !began { self.resumes += 1 }
            self.isPlaying = !began
        }
        return handler
    }

    func testEndDoesNotStartPlaybackThatWasAlreadyPaused() {
        // Paused hours ago, then a Safari video plays and stops.
        let handler = makeHandler(playing: false)
        handler.handleInterruption(.began, options: [])
        handler.handleInterruption(.ended, options: .shouldResume)
        XCTAssertEqual(resumes, 0)
        XCTAssertFalse(isPlaying)
    }

    func testEndResumesPlaybackTheInterruptionPaused() {
        let handler = makeHandler(playing: true)
        handler.handleInterruption(.began, options: [])
        XCTAssertFalse(isPlaying)
        handler.handleInterruption(.ended, options: .shouldResume)
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(isPlaying)
    }

    func testEndWithoutShouldResumeStaysPaused() {
        let handler = makeHandler(playing: true)
        handler.handleInterruption(.began, options: [])
        handler.handleInterruption(.ended, options: [])
        XCTAssertEqual(resumes, 0)
        XCTAssertFalse(isPlaying)
    }

    func testEndWithNoBeginOfItsOwnDoesNotResume() {
        let handler = makeHandler(playing: true)
        handler.handleInterruption(.began, options: [])
        handler.handleInterruption(.ended, options: [])
        // The earlier interruption is closed; this end has nothing to resume.
        handler.handleInterruption(.ended, options: .shouldResume)
        XCTAssertEqual(resumes, 0)
    }

    func testShortInterruptionResumes() {
        let handler = makeHandler(playing: true)
        let began = Date()
        handler.handleInterruption(.began, options: [], now: began)
        handler.handleInterruption(
            .ended,
            options: .shouldResume,
            now: began.addingTimeInterval(AudioSessionHandler.resumeWindow - 1)
        )
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(isPlaying)
    }

    func testEndLongAfterBeginStaysPaused() {
        // A video paused the music and never sent an end. Hours later another app's
        // video stops and iOS delivers an end with shouldResume.
        let handler = makeHandler(playing: true)
        let began = Date()
        handler.handleInterruption(.began, options: [], now: began)
        handler.handleInterruption(
            .ended,
            options: .shouldResume,
            now: began.addingTimeInterval(6 * 60 * 60)
        )
        XCTAssertEqual(resumes, 0)
        XCTAssertFalse(isPlaying)
    }

    func testEndJustPastTheWindowStaysPaused() {
        let handler = makeHandler(playing: true)
        let began = Date()
        handler.handleInterruption(.began, options: [], now: began)
        handler.handleInterruption(
            .ended,
            options: .shouldResume,
            now: began.addingTimeInterval(AudioSessionHandler.resumeWindow + 1)
        )
        XCTAssertEqual(resumes, 0)
    }
}
