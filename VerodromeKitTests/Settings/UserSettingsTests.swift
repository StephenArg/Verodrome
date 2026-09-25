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

    func testExplicitDetectionDefaultsOnAverageAndVisible() {
        XCTAssertTrue(UserSettings.default.explicitDetectionEnabled)
        XCTAssertEqual(UserSettings.default.explicitSensitivity, .average)
        XCTAssertFalse(UserSettings.default.hideExplicitSongs)
        XCTAssertFalse(UserSettings.default.highlightExplicitLyrics)
        XCTAssertTrue(UserSettings.default.explicitBlacklistWords.isEmpty)
        XCTAssertTrue(UserSettings.default.explicitWhitelistWords.isEmpty)
    }

    func testDecodingLegacyBlobEnablesExplicitDetection() throws {
        let json = Data("""
        {"showLyricsWhenAvailable": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: json)
        XCTAssertTrue(decoded.explicitDetectionEnabled)
        XCTAssertEqual(decoded.explicitSensitivity, .average)
        XCTAssertFalse(decoded.hideExplicitSongs)
        XCTAssertFalse(decoded.highlightExplicitLyrics)
        XCTAssertTrue(decoded.explicitBlacklistWords.isEmpty)
        XCTAssertTrue(decoded.explicitWhitelistWords.isEmpty)
        XCTAssertNil(decoded.explicitWordListChangedAt)
    }

    func testRoundTripPreservesExplicitSettings() throws {
        var settings = UserSettings.default
        settings.explicitDetectionEnabled = false
        settings.explicitSensitivity = .conservative
        settings.explicitBlacklistWords = ["Banana", "banana"]
        settings.explicitWhitelistWords = ["Fuck"]
        settings.hideExplicitSongs = true
        settings.highlightExplicitLyrics = true
        let changedAt = Date(timeIntervalSince1970: 1_700_000_000)
        settings.explicitWordListChangedAt = changedAt
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertFalse(decoded.explicitDetectionEnabled)
        XCTAssertEqual(decoded.explicitSensitivity, .conservative)
        XCTAssertEqual(decoded.explicitBlacklistWords, ["banana"])
        XCTAssertEqual(decoded.explicitWhitelistWords, ["fuck"])
        XCTAssertTrue(decoded.hideExplicitSongs)
        XCTAssertTrue(decoded.highlightExplicitLyrics)
        XCTAssertEqual(decoded.explicitWordListChangedAt, changedAt)
    }
}
