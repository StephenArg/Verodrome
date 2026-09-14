import XCTest
@testable import VerodromeKit

final class NavidromeRequestIDTests: XCTestCase {

    func testPre064LeavesOverflowingNanoidAlone() {
        XCTAssertEqual(
            NavidromeRequestID.resolve(
                "zzzzzzzzzzzzzzzzzzzzzz",
                serverTypeName: "navidrome",
                version: "0.63.2 (aa84e645)"
            ),
            "zzzzzzzzzzzzzzzzzzzzzz"
        )
    }

    func test064RemapsOverflowingNanoid() {
        XCTAssertEqual(
            NavidromeRequestID.resolve(
                "zzzzzzzzzzzzzzzzzzzzzz",
                serverTypeName: "navidrome",
                version: "0.64.0"
            ),
            "3LyqmwQBm5IRqlVjNYASwb"
        )
    }

    func test064LeavesAlreadyCanonicalIdAlone() {
        XCTAssertEqual(
            NavidromeRequestID.resolve(
                "5cLJPkLA5DK2BADhoeotPk",
                serverTypeName: "navidrome",
                version: "0.64.0"
            ),
            "5cLJPkLA5DK2BADhoeotPk"
        )
    }

    func testUnknownVersionDoesNotRewrite() {
        XCTAssertEqual(
            NavidromeRequestID.resolve(
                "zzzzzzzzzzzzzzzzzzzzzz",
                serverTypeName: "navidrome",
                version: nil
            ),
            "zzzzzzzzzzzzzzzzzzzzzz"
        )
    }

    func testNonNavidromeDoesNotRewrite() {
        XCTAssertEqual(
            NavidromeRequestID.resolve(
                "zzzzzzzzzzzzzzzzzzzzzz",
                serverTypeName: "Ampache",
                version: "6.6.0"
            ),
            "zzzzzzzzzzzzzzzzzzzzzz"
        )
    }
}
