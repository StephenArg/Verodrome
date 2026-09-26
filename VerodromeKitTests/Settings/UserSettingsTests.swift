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

    // MARK: - Playlist song sort

    /// Sort choices saved before playlists had their own lacked the key. A strict decode
    /// threw on that, which would have reset every other setting along with it.
    func testLibrarySortDecodesWithoutPlaylistSongs() throws {
        let json = Data("""
        {"artists": "titleZA", "albums": "recentlyAdded", "songs": "playsMost", "genres": "titleAZ", "playlists": "smartPlaylistsFirst"}
        """.utf8)
        let decoded = try JSONDecoder().decode(LibrarySortSelection.self, from: json)
        XCTAssertEqual(decoded.songs, .playsMost)
        XCTAssertEqual(decoded.albums, .recentlyAdded)
        XCTAssertEqual(decoded.playlistSongs, .oldestAdded)
    }

    func testLibrarySortRoundTripsPlaylistSongs() throws {
        var selection = LibrarySortSelection.default
        selection.playlistSongs = .recentlyAdded
        let decoded = try JSONDecoder().decode(
            LibrarySortSelection.self,
            from: JSONEncoder().encode(selection)
        )
        XCTAssertEqual(decoded, selection)
    }

    private func key(_ title: String, duration: TimeInterval = 0, rating: Int = 0, plays: Int = 0) -> PlaylistEntrySortKey {
        PlaylistEntrySortKey(sortTitle: title, duration: duration, rating: rating, playCount: plays)
    }

    /// Servers append added songs to the end, so position is the only added-order signal.
    func testPlaylistAddedOrderFollowsPosition() {
        let keys = [key("c"), key("a"), key("b")]
        XCTAssertEqual(LibrarySortOption.oldestAdded.playlistDisplayOrder(of: keys), [0, 1, 2])
        XCTAssertEqual(LibrarySortOption.recentlyAdded.playlistDisplayOrder(of: keys), [2, 1, 0])
    }

    /// Titles group like the Songs list's sections: letters, then digits, then other
    /// scripts and symbols — or those first for `#A-Z`.
    func testPlaylistTitleSortsGroupLikeTheSongsList() {
        let keys = [key("beta"), key("99 luftballons"), key("alpha"), key("кино"), key("!bang")]
        XCTAssertEqual(LibrarySortOption.titleAZ.playlistDisplayOrder(of: keys), [2, 0, 1, 3, 4])
        XCTAssertEqual(LibrarySortOption.titleZA.playlistDisplayOrder(of: keys), [0, 2, 1, 3, 4])
        XCTAssertEqual(LibrarySortOption.titleSymbolsFirst.playlistDisplayOrder(of: keys), [1, 3, 4, 2, 0])
    }

    /// Equal keys fall back to title and then position, so a reload can't reshuffle them.
    func testPlaylistValueSortsBreakTiesByTitleThenPosition() {
        let keys = [
            key("b", duration: 200, rating: 3, plays: 5),
            key("a", duration: 200, rating: 3, plays: 5),
            key("c", duration: 100, rating: 5, plays: 9),
            key("a", duration: 300, rating: 0, plays: 0),
            key("a", duration: 300, rating: 0, plays: 0)
        ]
        XCTAssertEqual(LibrarySortOption.durationLongest.playlistDisplayOrder(of: keys), [3, 4, 1, 0, 2])
        XCTAssertEqual(LibrarySortOption.durationShortest.playlistDisplayOrder(of: keys), [2, 1, 0, 3, 4])
        XCTAssertEqual(LibrarySortOption.ratingHighest.playlistDisplayOrder(of: keys), [2, 1, 0, 3, 4])
        XCTAssertEqual(LibrarySortOption.playsMost.playlistDisplayOrder(of: keys), [2, 1, 0, 3, 4])
    }

    // MARK: - Playlist row swipes

    /// Settings saved before playlists had their own swipes lack the keys. Playlists used
    /// to follow the song row swipes, so they should keep doing that — defaulting to
    /// something else would change what an existing swipe does without the user asking.
    @MainActor
    func testPlaylistSwipesInheritSongSwipesFromOlderSettings() throws {
        let suiteName = "UserSettingsTests.playlistSwipes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotKey = "com.verodrome.settings.snapshot.v1"

        let store = SettingsStore(defaults: defaults)
        store.swipeLeftAction = "favorite"
        store.swipeRightAction = "none"
        store.save()

        // Strip the new keys to stand in for a blob written by the previous version.
        var blob = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: snapshotKey))) as? [String: Any]
        )
        XCTAssertNotNil(blob.removeValue(forKey: "playlistSwipeLeftAction"))
        XCTAssertNotNil(blob.removeValue(forKey: "playlistSwipeRightAction"))
        defaults.set(try JSONSerialization.data(withJSONObject: blob), forKey: snapshotKey)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.swipeLeftAction, "favorite")
        XCTAssertEqual(reloaded.playlistSwipeLeftAction, "favorite")
        XCTAssertEqual(reloaded.playlistSwipeRightAction, "none")
    }

    @MainActor
    func testPlaylistSwipesPersistSeparatelyFromSongSwipes() throws {
        let suiteName = "UserSettingsTests.playlistSwipes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.playlistSwipeLeftAction = "remove"
        store.save()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.playlistSwipeLeftAction, "remove")
        XCTAssertEqual(reloaded.swipeLeftAction, "queue")
    }
}
