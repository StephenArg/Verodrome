import XCTest
@testable import VerodromeKit

final class NavidromeVersionTests: XCTestCase {

    // MARK: - Parse

    func testParsesTrailingCommitHash() {
        // The exact `serverVersion` shape Navidrome puts on the ping response.
        XCTAssertEqual(NavidromeVersion.parse("0.61.2 (aa84e645)"),
                       NavidromeVersion.Components(major: 0, minor: 61, patch: 2))
    }

    func testParsesBareThreePart() {
        XCTAssertEqual(NavidromeVersion.parse("0.64.0"),
                       NavidromeVersion.Components(major: 0, minor: 64, patch: 0))
    }

    func testParsesLeadingVAndSnapshotSuffix() {
        XCTAssertEqual(NavidromeVersion.parse("v0.64.1-SNAPSHOT"),
                       NavidromeVersion.Components(major: 0, minor: 64, patch: 1))
    }

    func testParsesReleaseCandidateSuffix() {
        XCTAssertEqual(NavidromeVersion.parse("0.65.0-rc.1"),
                       NavidromeVersion.Components(major: 0, minor: 65, patch: 0))
    }

    func testEmptyOrDevReturnsNil() {
        // These are what appears in the wild for custom builds; the caller must fall
        // through to the probe rather than pick a wrong default.
        XCTAssertNil(NavidromeVersion.parse(""))
        XCTAssertNil(NavidromeVersion.parse("dev"))
        XCTAssertNil(NavidromeVersion.parse(nil))
        XCTAssertNil(NavidromeVersion.parse("0.64"))
    }

    // MARK: - Epoch classification

    func testEpochFor063IsZero() {
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.63.2 (aa84e645)"), 0)
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.63.2"), 0)
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.0.1"), 0)
    }

    func testEpochAt064IsOne() {
        // The migration lands in 0.64.0, so this is the boundary.
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.64.0"), 1)
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.64.1-SNAPSHOT"), 1)
        XCTAssertEqual(NavidromeVersion.epoch(of: "0.65.0"), 1)
        XCTAssertEqual(NavidromeVersion.epoch(of: "1.0.0"), 1)
    }

    func testEpochUnknownIsNil() {
        XCTAssertNil(NavidromeVersion.epoch(of: "dev"))
        XCTAssertNil(NavidromeVersion.epoch(of: nil))
    }

    // MARK: - Decision gate

    func testNonNavidromeSkipsRegardlessOfMarker() {
        // Ampache / generic Subsonic never participate in the canonical-ID scheme.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "ampache",
                reportedVersion: "6.0.0",
                markerVersion: nil),
            .skip
        )
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: nil,
                reportedVersion: "0.64.0",
                markerVersion: nil),
            .skip
        )
    }

    func testUnsetMarkerBelow064SeedsWithoutProbing() {
        // Pre-0.64 servers are trivially consistent with pre-existing local IDs — this is
        // the steady-state case for old-server users, so it must not cost a request.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.63.2 (aa84e645)",
                markerVersion: nil),
            .seedMarker
        )
    }

    func testUnsetMarkerAt064ProbesForward() {
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.64.0",
                markerVersion: nil),
            .probeForward
        )
    }

    func testUnsetMarkerUnknownVersionProbesForward() {
        // Unknown version could be a future release or a custom build; safe default is
        // to probe rather than assume the epoch.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "dev",
                markerVersion: nil),
            .probeForward
        )
    }

    func testSameEpochSkips() {
        // The two most common steady-state cases.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.63.2 (aa84e645)",
                markerVersion: "0.62.0"),
            .skip
        )
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.65.0",
                markerVersion: "0.64.1-SNAPSHOT"),
            .skip
        )
    }

    func testForwardEpochChangeProbesForward() {
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.64.0",
                markerVersion: "0.63.2"),
            .probeForward
        )
    }

    func testBackwardEpochChangeProbesBackward() {
        // This is the restored-from-backup case that a Bool marker cannot detect. The
        // marker says "we saw 0.64" but the server is now reporting a pre-0.64 version,
        // meaning the DB was rolled back and our local IDs may now be too new.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.63.2",
                markerVersion: "0.64.0"),
            .probeBackward
        )
    }

    func testUnparseableMarkerProbesForward() {
        // Marker written by a future version we do not know about — treat as forward for
        // safety.
        XCTAssertEqual(
            CanonicalIdEpochDecision.decide(
                serverTypeName: "navidrome",
                reportedVersion: "0.63.0",
                markerVersion: "quantum"),
            .probeForward
        )
    }
}
