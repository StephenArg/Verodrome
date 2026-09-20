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

    func testArtistTopSongsDefaultsOn() {
        XCTAssertTrue(UserSettings.default.showArtistTopSongs)
    }

    /// A settings blob written before the artist Top Songs toggle existed must decode
    /// with the section opted in, matching the default for fresh installs.
    func testDecodingLegacyBlobEnablesArtistTopSongs() throws {
        let json = Data("""
        {"showLyricsWhenAvailable": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)
        XCTAssertTrue(decoded.showArtistTopSongs)
    }

    func testRoundTripPreservesArtistTopSongsFlag() throws {
        var settings = UserSettings.default
        settings.showArtistTopSongs = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertFalse(decoded.showArtistTopSongs)
    }

    func testAutoCacheArtistPopularSongsDefaultsOn() {
        XCTAssertTrue(UserSettings.default.autoCacheArtistPopularSongs)
    }

    func testDecodingLegacyBlobEnablesAutoCacheArtistPopularSongs() throws {
        let json = Data("""
        {"showLyricsWhenAvailable": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)
        XCTAssertTrue(decoded.autoCacheArtistPopularSongs)
    }

    func testRoundTripPreservesAutoCacheArtistPopularSongsFlag() throws {
        var settings = UserSettings.default
        settings.autoCacheArtistPopularSongs = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertFalse(decoded.autoCacheArtistPopularSongs)
    }
}
