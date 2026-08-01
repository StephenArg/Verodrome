import XCTest
@testable import VerodromeKit

final class LibrarySyncProgressTests: XCTestCase {
    func testCatalogStagesAdvanceWithinTheCatalogSlice() {
        XCTAssertEqual(LibrarySyncCatalogStage.genres.fraction, 0, accuracy: 0.0001)
        XCTAssertEqual(LibrarySyncCatalogStage.albums.fraction, 0.05, accuracy: 0.0001)
        // The last stage still leaves room for the rest of the catalog to finish.
        XCTAssertLessThan(LibrarySyncCatalogStage.radios.fraction, LibrarySyncPhase.catalog.overall(1))
    }

    /// The catalog and track phases have to meet exactly, or the bar jumps or stalls
    /// at the handover.
    func testPhasesMeetWithoutAGap() {
        XCTAssertEqual(LibrarySyncPhase.catalog.overall(1), LibrarySyncPhase.tracks.overall(0), accuracy: 0.0001)
        XCTAssertEqual(LibrarySyncPhase.tracks.overall(1), 1, accuracy: 0.0001)
    }

    func testTrackProgressIsClampedToItsPhase() {
        XCTAssertEqual(LibrarySyncPhase.tracks.overall(-2), LibrarySyncPhase.tracks.overall(0), accuracy: 0.0001)
        XCTAssertEqual(LibrarySyncPhase.tracks.overall(9), 1, accuracy: 0.0001)
    }

    /// A crawl that doesn't know its size yet must report no position rather than
    /// guessing one, so the bar holds where the last measured step left it.
    func testUnsizedTrackReportCarriesNoFraction() {
        var received: [LibrarySyncProgress] = []
        let handler: LibrarySyncProgressHandler = { received.append($0) }

        CommonLibrarySyncer.report(handler, "Backfilling…", tracksCompleted: 0, of: nil)
        CommonLibrarySyncer.report(handler, "Backfilling…", tracksCompleted: 5, of: 0)
        CommonLibrarySyncer.report(handler, "Backfilling…", tracksCompleted: 50, of: 100)

        XCTAssertNil(received[0].fraction)
        XCTAssertNil(received[1].fraction)
        XCTAssertEqual(try XCTUnwrap(received[2].fraction), LibrarySyncPhase.tracks.overall(0.5), accuracy: 0.0001)
    }
}
