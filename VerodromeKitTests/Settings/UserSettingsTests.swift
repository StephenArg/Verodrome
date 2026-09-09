import XCTest
@testable import VerodromeKit

final class UserSettingsTests: XCTestCase {
    func testLrcLibDefaultsOn() {
        XCTAssertTrue(UserSettings.default.lrcLibLyricsEnabled)
    }

    /// A settings blob written before the LRCLIB fallback existed must decode with the
    /// feature opted in, matching the default for fresh installs.
    func testDecodingLegacyBlobEnablesLrcLib() throws {
        let json = Data("""
        {"showLyricsWhenAvailable": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)
        XCTAssertTrue(decoded.lrcLibLyricsEnabled)
    }

    func testRoundTripPreservesLrcLibFlag() throws {
        var settings = UserSettings.default
        settings.lrcLibLyricsEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertFalse(decoded.lrcLibLyricsEnabled)
    }
}
