import XCTest
@testable import VerodromeKit

@MainActor
final class ScrobbleSyncerTests: XCTestCase {
    private let duration: TimeInterval = 180

    func testStandardTimingWaitsForHalfTheTrack() {
        let syncer = makeSyncer(timing: .standard)
        syncer.trackProgress(item: track, elapsed: 89, duration: duration)
        XCTAssertEqual(counted, [])

        syncer.trackProgress(item: track, elapsed: 90, duration: duration)
        XCTAssertEqual(counted, ["song-1"])
    }

    func testStandardTimingCapsLongTracksAtFourMinutes() {
        let syncer = makeSyncer(timing: .standard)
        let longTrack = QueueItem(playableId: "long", title: "Long", duration: 20 * 60)
        syncer.trackProgress(item: longTrack, elapsed: 239, duration: 20 * 60)
        XCTAssertEqual(counted, [])

        syncer.trackProgress(item: longTrack, elapsed: 240, duration: 20 * 60)
        XCTAssertEqual(counted, ["long"])
    }

    func testOnStartCountsFromTheFirstProgressTick() {
        let syncer = makeSyncer(timing: .onStart)
        syncer.trackProgress(item: track, elapsed: 0, duration: duration)
        XCTAssertEqual(counted, ["song-1"])
    }

    /// `never` suppresses the local hook too, so a play the server never hears about does
    /// not bump this device's play count either.
    func testNeverCountsNothingEvenAtTheEnd() {
        let syncer = makeSyncer(timing: .never)
        syncer.trackProgress(item: track, elapsed: duration, duration: duration)
        XCTAssertEqual(counted, [])
    }

    func testOnFinishCountsJustBeforeTheTrackEnds() {
        let syncer = makeSyncer(timing: .onFinish)
        syncer.trackProgress(item: track, elapsed: 170, duration: duration)
        XCTAssertEqual(counted, [])

        syncer.trackProgress(item: track, elapsed: 179, duration: duration)
        XCTAssertEqual(counted, ["song-1"])
    }

    func testEachTrackCountsOnlyOnce() {
        let syncer = makeSyncer(timing: .onStart)
        syncer.trackProgress(item: track, elapsed: 0, duration: duration)
        syncer.trackProgress(item: track, elapsed: 10, duration: duration)
        syncer.trackProgress(item: track, elapsed: 20, duration: duration)
        XCTAssertEqual(counted, ["song-1"])
    }

    func testAdvancingToTheNextTrackRearms() {
        let syncer = makeSyncer(timing: .onStart)
        syncer.trackProgress(item: track, elapsed: 0, duration: duration)
        syncer.trackProgress(
            item: QueueItem(playableId: "song-2", title: "Second", duration: duration),
            elapsed: 0,
            duration: duration
        )
        XCTAssertEqual(counted, ["song-1", "song-2"])
    }

    func testUnknownDurationNeverQualifies() {
        let syncer = makeSyncer(timing: .onStart)
        syncer.trackProgress(item: track, elapsed: 30, duration: 0)
        XCTAssertEqual(counted, [])
    }

    /// The threshold is read per tick, so raising the bar mid-track holds back a play that
    /// had not yet qualified, and lowering it lets one through.
    func testChangingTheSettingMidTrackTakesEffect() {
        var timing = ScrobbleTiming.onFinish
        let syncer = ScrobbleSyncer(uploader: StubUploader(), timing: { timing })
        syncer.onScrobble = { [weak self] id in self?.counted.append(id) }

        syncer.trackProgress(item: track, elapsed: 90, duration: duration)
        XCTAssertEqual(counted, [])

        timing = .standard
        syncer.trackProgress(item: track, elapsed: 91, duration: duration)
        XCTAssertEqual(counted, ["song-1"])
    }

    // MARK: - Helpers

    /// Plays recorded through `onScrobble`, which fires synchronously the moment a play
    /// qualifies. The upload itself is awaited on a detached task, so asserting on the
    /// transport would race; qualifying is what this suite is about.
    private var counted: [String] = []

    private var track: QueueItem {
        QueueItem(playableId: "song-1", title: "First", duration: duration)
    }

    private func makeSyncer(timing: ScrobbleTiming) -> ScrobbleSyncer {
        let syncer = ScrobbleSyncer(uploader: StubUploader(), timing: { timing })
        syncer.onScrobble = { [weak self] id in self?.counted.append(id) }
        return syncer
    }
}

private final class StubUploader: ScrobbleUploading, @unchecked Sendable {
    func uploadScrobble(id: String, at date: Date, duration: TimeInterval?) async throws {}
}
