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

    func testFailureIsReportedUntilTheDownloadIsRetried() {
        center.enqueued(playableId: "a")
        center.fail(playableId: "a")

        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .failed)
        XCTAssertFalse(center.isWorking(on: "a"))

        center.enqueued(playableId: "a")
        XCTAssertEqual(center.status(for: "a", isDownloaded: false), .pending)
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
}
