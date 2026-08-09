import XCTest
import SwiftData
@testable import VerodromeKit

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    func testGetOrCreateArtist() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let info = AccountInfo(serverURL: "https://music.example", username: "vera")
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)
        let artist = try repo.getOrCreateArtist(remoteId: "1", name: "Test Artist", account: account)
        XCTAssertEqual(artist.name, "Test Artist")
        let again = try repo.getOrCreateArtist(remoteId: "1", name: "Renamed", account: account)
        XCTAssertEqual(again.persistentModelID, artist.persistentModelID)
        XCTAssertEqual(again.name, "Renamed")
    }

    /// Every route that changes what a playlist holds — catalog sync, per-playlist sync,
    /// add and remove — lands here, so this is the one place that can tell the membership
    /// index a song's playlists may have changed.
    func testReplacePlaylistItemsAnnouncesTheChange() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let info = AccountInfo(serverURL: "https://music.example", username: "vera")
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)
        let playlist = try repo.getOrCreatePlaylist(remoteId: "p1", name: "Mix", account: account)
        let song = try repo.getOrCreateSong(remoteId: "s1", title: "Track", account: account)

        expectation(forNotification: .playlistItemsChanged, object: nil)
        try repo.replacePlaylistItems(playlist, with: [song])
        waitForExpectations(timeout: 1)

        XCTAssertEqual(playlist.songCount, 1)
        XCTAssertEqual(playlist.items.first?.song?.remoteId, "s1")
    }

    /// Adding the first track to a coverless playlist is what gives the library list
    /// something to draw; without this the row stays on the generic house icon.
    func testReplacePlaylistItemsFillsMissingArtworkFromFirstSong() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let info = AccountInfo(serverURL: "https://music.example", username: "vera")
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)
        let playlist = try repo.getOrCreatePlaylist(remoteId: "p1", name: "Mix", account: account)
        let song = try repo.getOrCreateSong(remoteId: "s1", title: "Track", account: account)
        song.artworkToken = "al-99"

        try repo.replacePlaylistItems(playlist, with: [song])
        XCTAssertEqual(playlist.artworkToken, "al-99")

        // A cover the server already assigned must not be replaced by a later rewrite.
        playlist.artworkToken = "pl-custom"
        let other = try repo.getOrCreateSong(remoteId: "s2", title: "Other", account: account)
        other.artworkToken = "al-1"
        try repo.replacePlaylistItems(playlist, with: [other, song])
        XCTAssertEqual(playlist.artworkToken, "pl-custom")
    }
}
