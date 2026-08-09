import XCTest
@testable import VerodromeKit

final class ShareParserTests: XCTestCase {
    // MARK: - Subsonic

    func testSubsonicShareParserReadsLinkAndCounts() throws {
        let shares = try SubsonicParsers.parseShares(data: try fixture("subsonic_shares.xml"))

        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares[0].id, "ab12cd")
        XCTAssertEqual(shares[0].url?.absoluteString, "https://music.example.com/share/ab12cd")
        XCTAssertEqual(shares[0].description, "Living Fields")
        XCTAssertEqual(shares[0].owner, "vero")
        XCTAssertEqual(shares[0].visitCount, 7)
        XCTAssertEqual(shares[0].entryCount, 1)
    }

    /// A share with no expiry has no `expires` attribute at all, and must not be read as
    /// "expired at the epoch" — that would show every permanent link as dead.
    func testSubsonicShareParserLeavesAbsentExpiryNil() throws {
        let shares = try SubsonicParsers.parseShares(data: try fixture("subsonic_shares.xml"))

        XCTAssertNotNil(shares[0].expires)
        XCTAssertNil(shares[1].expires)
        XCTAssertFalse(shares[1].isExpired)
        XCTAssertNil(shares[1].lastVisited)
    }

    /// Go writes timestamps as RFC 3339 Nano, so the same field arrives with fractional
    /// seconds on one row and without them on the next.
    func testSubsonicShareParserReadsBothTimestampPrecisions() throws {
        let shares = try SubsonicParsers.parseShares(data: try fixture("subsonic_shares.xml"))

        XCTAssertNotNil(shares[0].created, "fractional-second timestamp should parse")
        XCTAssertNotNil(shares[1].created, "whole-second timestamp should parse")
    }

    /// Subsonic never states what a share points at, so the entries are the only clue.
    func testSubsonicShareParserInfersTypeFromEntries() throws {
        let shares = try SubsonicParsers.parseShares(data: try fixture("subsonic_shares.xml"))

        XCTAssertEqual(shares[0].resourceType, .album)
        XCTAssertEqual(shares[1].resourceType, .song)
    }

    /// Navidrome has no downloadable concept in its Subsonic responses, and reporting
    /// `false` there would show a disabled-looking toggle on a share that does allow it.
    func testSubsonicShareParserLeavesDownloadableUnknown() throws {
        let shares = try SubsonicParsers.parseShares(data: try fixture("subsonic_shares.xml"))
        XCTAssertNil(shares[0].isDownloadable)
    }

    // MARK: - Ampache

    func testAmpacheShareParserReadsFields() throws {
        let shares = try AmpacheParsers.parseShares(data: try fixture("ampache_shares.xml"))

        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares[0].id, "4")
        XCTAssertEqual(shares[0].description, "Album for Jo")
        XCTAssertEqual(shares[0].contentsLabel, "Living Fields")
        XCTAssertEqual(shares[0].resourceType, .album)
        XCTAssertEqual(shares[0].isDownloadable, true)
        XCTAssertEqual(shares[0].visitCount, 3)
        XCTAssertEqual(shares[1].resourceType, .song)
        XCTAssertEqual(shares[1].isDownloadable, false)
    }

    /// Ampache stores days from creation, not an instant, so the absolute expiry has to
    /// be reconstructed — and `0` days means the link never expires.
    func testAmpacheShareParserRebuildsExpiryFromDays() throws {
        let shares = try AmpacheParsers.parseShares(data: try fixture("ampache_shares.xml"))

        let created = try XCTUnwrap(shares[0].created)
        let expires = try XCTUnwrap(shares[0].expires)
        XCTAssertEqual(expires.timeIntervalSince(created), 7 * 86_400, accuracy: 1)

        XCTAssertNil(shares[1].expires, "expire_days of 0 means no expiry")
    }

    /// `lastvisit_date` is `0` for a link nobody has opened, which is not the epoch.
    func testAmpacheShareParserTreatsZeroDatesAsAbsent() throws {
        let shares = try AmpacheParsers.parseShares(data: try fixture("ampache_shares.xml"))
        XCTAssertNotNil(shares[0].lastVisited)
        XCTAssertNil(shares[1].lastVisited)
    }

    // MARK: - Expiry conversion

    /// Rounding up rather than down: a link that dies before the moment the user picked
    /// is a worse failure than one that outlives it by less than a day.
    func testExpiryDaysRoundUp() {
        let now = Date()
        XCTAssertEqual(ShareExpiry.days(until: now.addingTimeInterval(86_400), from: now), 1)
        XCTAssertEqual(ShareExpiry.days(until: now.addingTimeInterval(86_401), from: now), 2)
        XCTAssertEqual(ShareExpiry.days(until: now.addingTimeInterval(60), from: now), 1)
    }

    /// A date in the past can't become zero days, because zero is Ampache's "never".
    func testExpiryDaysNeverCollapseToNever() {
        let now = Date()
        XCTAssertEqual(ShareExpiry.days(until: now.addingTimeInterval(-86_400), from: now), 1)
        XCTAssertEqual(ShareExpiry.days(until: now, from: now), 1)
    }

    func testExpiryDateRoundTripsThroughDays() {
        let created = Date(timeIntervalSince1970: 1_785_542_400)
        let target = created.addingTimeInterval(3 * 86_400)

        let days = ShareExpiry.days(until: target, from: created)
        XCTAssertEqual(days, 3)
        XCTAssertEqual(ShareExpiry.date(created: created, expireDays: days), target)
        XCTAssertNil(ShareExpiry.date(created: created, expireDays: 0))
    }

    func testEpochMillisecondsMatchSubsonicWireFormat() {
        XCTAssertEqual(ShareExpiry.epochMilliseconds(Date(timeIntervalSince1970: 1_785_542_400)), 1_785_542_400_000)
    }

    // MARK: - Error mapping

    /// Navidrome answers a plain 501 when an admin has turned sharing off, which never
    /// reaches the Subsonic error envelope. Collapsing it into a generic server error
    /// would make "disabled" indistinguishable from "broken".
    func testNotImplementedStatusMapsToItsOwnError() {
        guard case .notImplemented = BackendApiError.from(status: 501, message: "Not Implemented") else {
            return XCTFail("501 should map to .notImplemented")
        }
    }

    func testOtherStatusesKeepTheirCode() {
        guard case .http(let status, _) = BackendApiError.from(status: 403, message: "Forbidden") else {
            return XCTFail("403 should map to .http")
        }
        XCTAssertEqual(status, 403)
    }

    /// A transport failure with no response at all still has to produce an error.
    func testMissingStatusFallsBackToServerError() {
        guard case .server = BackendApiError.from(status: nil, message: "Timed out") else {
            return XCTFail("a statusless failure should map to .server")
        }
    }

    // MARK: - Navidrome native

    /// The download flag and resource type only exist on the native row, and Go omits
    /// zero values so an absent `downloadable` has to read as false rather than fail.
    func testNavidromeShareRowsDecode() throws {
        let json = """
        [
          {"id":"ab12cd","description":"Living Fields","downloadable":true,"resourceType":"album",
           "contents":"Living Fields","expiresAt":"2026-09-01T10:15:00.5Z"},
          {"id":"ef34gh","resourceType":"media_file","contents":"Blue Line"}
        ]
        """
        let rows = try NavidromeNativeApi.shares(from: Data(json.utf8))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].downloadable, true)
        XCTAssertEqual(rows[0].shareResourceType, .album)
        XCTAssertNotNil(rows[0].expiresAt)

        XCTAssertEqual(rows[1].downloadable, false)
        XCTAssertEqual(rows[1].shareResourceType, .song, "media_file is Navidrome's spelling for a single track")
        XCTAssertNil(rows[1].expiresAt)
    }

    private func fixture(_ name: String) throws -> Data {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: path)
    }
}
