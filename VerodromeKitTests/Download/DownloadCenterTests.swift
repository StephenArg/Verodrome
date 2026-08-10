import XCTest
@testable import VerodromeKit

@MainActor
final class DownloadCenterTests: XCTestCase {
    private var center: DownloadCenter { DownloadCenter.shared }

    override func setUp() async throws {
        try await super.setUp()
        center.clearAllActive()
        center.clearCompleted()
        center.clearFailed()
    }

    func testStatusFollowsTheLifeOfADownload() {
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), DownloadStatus.none)

        center.enqueued(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .pending)

        center.begin(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .downloading(0))

        center.update(playableId: "a", progress: 0.5)
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .downloading(0.5))

        center.complete(playableId: "a")
        // Completed this session: show downloaded even before the library model is observed.
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .downloaded)
        XCTAssertEqual(center.status(for: "a", isDownloaded: true), .downloaded)
        XCTAssertFalse(center.isWorking(on: "a"))
    }

    /// Dense lists observe `activityEpoch` so progress ticks don't rebuild every row.
    func testActivityEpochIgnoresProgressTicks() {
        let before = center.activityEpoch
        center.enqueued(playableId: "a")
        let afterEnqueue = center.activityEpoch
        XCTAssertGreaterThan(afterEnqueue, before)

        center.begin(playableId: "a")
        let afterBegin = center.activityEpoch
        XCTAssertGreaterThan(afterBegin, afterEnqueue)

        center.update(playableId: "a", progress: 0.25)
        center.update(playableId: "a", progress: 0.75)
        XCTAssertEqual(center.activityEpoch, afterBegin)

        center.complete(playableId: "a")
        XCTAssertGreaterThan(center.activityEpoch, afterBegin)
    }

    func testFailureIsReportedUntilTheDownloadIsRetried() {
        center.enqueued(playableId: "a")
        center.fail(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .failed)
        XCTAssertFalse(center.isWorking(on: "a"))

        center.enqueued(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .pending)
    }

    /// The glyph must be droppable: a cached file can be evicted or removed after the
    /// transfer finished, and `completedIds` would otherwise keep reporting `.downloaded`.
    func testClearingADownloadForgetsItsCompletion() {
        center.begin(playableId: "a")
        center.complete(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .downloaded)

        center.clearActive(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: false), DownloadStatus.none)
    }

    func testProgressOutranksAnAlreadyDownloadedFile() {
        center.begin(playableId: "a")
        center.update(playableId: "a", progress: 0.25)

        XCTAssertEqual(
            center.status(for: "a", isDownloaded: true),
            .downloading(0.25),
            "a re-download in flight should read as running, not finished"
        )
    }

    func testBatchProgressCountsQueuedTracksAsZeroAndFinishedOnesAsWhole() {
        center.begin(playableId: "a")
        center.update(playableId: "a", progress: 0.5)
        center.enqueued(playableId: "b")

        let progress = center.batchProgress(for: ["a", "b", "c", "d"], downloadedIds: ["c", "d"])

        // 0.5 + 0 + 1 + 1 over four tracks.
        XCTAssertEqual(try XCTUnwrap(progress), 0.625, accuracy: 0.0001)
    }

    func testBatchProgressIsNilWhenNothingIsRunning() {
        XCTAssertNil(center.batchProgress(for: ["a", "b"], downloadedIds: ["a"]))
        XCTAssertNil(center.batchProgress(for: [], downloadedIds: []))
    }

    func testWaitingIsReportedUntilTheDownloadIsReleased() {
        center.deferDownload(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .waiting)
        XCTAssertFalse(center.isWorking(on: "a"), "a parked download is not occupying the queue")

        center.enqueued(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .pending)
    }

    /// A deferral left over from an earlier pass must never contradict a file that is
    /// already on disk.
    func testAnExistingFileOutranksAWaitingDownload() {
        center.deferDownload(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: true), .downloaded)
    }

    func testWaitingOutranksAnEarlierFailure() {
        center.fail(playableId: "a")
        center.deferDownload(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .waiting)
    }

    func testStartingAWaitingDownloadClearsIt() {
        center.deferDownload(playableId: "a")
        center.begin(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .downloading(0))
        XCTAssertTrue(center.deferredIds.isEmpty)
    }
}
