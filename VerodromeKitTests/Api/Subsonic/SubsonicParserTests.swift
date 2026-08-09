import XCTest
@testable import VerodromeKit

final class SubsonicParserTests: XCTestCase {
    func testArtistParser() throws {
        let data = try fixture("subsonic_artists.xml")
        let artists = try SubsonicParsers.parseArtists(data: data)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first?.name, "Alpha")
        XCTAssertEqual(artists[0].albumCount, 2)
        XCTAssertEqual(artists[0].songCount, 24)
        XCTAssertEqual(artists[1].albumCount, 1)
        XCTAssertNil(artists[1].songCount)
    }

    func testGenreParser() throws {
        let data = try fixture("subsonic_genres.xml")
        let genres = try SubsonicParsers.parseGenres(data: data)
        XCTAssertEqual(genres.count, 2)
        XCTAssertEqual(genres[0].name, "Electronic")
        XCTAssertEqual(genres[0].albumCount, 2)
        XCTAssertEqual(genres[0].songCount, 12)
        XCTAssertEqual(genres[1].name, "Ambient")
        XCTAssertEqual(genres[1].albumCount, 1)
        XCTAssertEqual(genres[1].songCount, 4)
    }

    /// Subsonic proper says nothing about smart playlists, so the OpenSubsonic `readonly`
    /// and `validUntil` attributes are the only way to keep them out of the add-to-playlist
    /// list before the server rejects the attempt. `readonly` also covers playlists someone
    /// else owns, which is why it is tracked separately from smartness.
    func testPlaylistParserReadsReadonlyAndValidUntil() throws {
        let data = try fixture("subsonic_playlists.xml")
        let playlists = try SubsonicParsers.parsePlaylists(data: data)
        XCTAssertEqual(playlists.count, 3)

        XCTAssertEqual(playlists[0].name, "Road Trip")
        XCTAssertEqual(playlists[0].songCount, 24)
        XCTAssertFalse(playlists[0].isReadOnly)
        XCTAssertFalse(playlists[0].isSmart)

        // A regenerating list: readonly, and dated by when the server will rebuild it.
        XCTAssertTrue(playlists[1].isReadOnly)
        XCTAssertTrue(playlists[1].isSmart)

        // Someone else's ordinary playlist: readonly, but not smart.
        XCTAssertTrue(playlists[2].isReadOnly)
        XCTAssertFalse(playlists[2].isSmart)
        XCTAssertEqual(playlists[2].owner, "someone_else")
    }

    /// Plays and rating drive the Songs and Albums sort options, so they have to survive
    /// parsing. Absent values must stay nil rather than becoming 0, or a response
    /// without them wipes what an earlier sync stored.
    func testAlbumDetailParserReadsPlayCountAndRating() throws {
        let data = try fixture("subsonic_album_detail.xml")
        let (albums, songs) = try SubsonicParsers.parseAlbumDetail(data: data)
        XCTAssertEqual(albums.first?.rating, 5)
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(songs[0].playCount, 17)
        XCTAssertEqual(songs[0].rating, 4)
        XCTAssertNil(songs[1].playCount)
        XCTAssertNil(songs[1].rating)
        // Most servers send "3", a few send "3.0", which `Int(_:)` alone rejects.
        XCTAssertEqual(songs[2].rating, 3)
    }

    /// `getRandomSongs` returns a flat list under its own element, and unlike album
    /// detail there is no parent node to fall back on — every song states its own album.
    func testSongListParserReadsFlatRandomSongs() throws {
        let songs = try SubsonicParsers.parseSongList(data: fixture("subsonic_random_songs.xml"))
        XCTAssertEqual(songs.map(\.id), ["331", "412", "507"])
        XCTAssertEqual(songs.map(\.albumId), ["55", "56", "57"])
        XCTAssertEqual(songs.map(\.artId), ["al-55", "al-56", "al-57"])
        XCTAssertEqual(songs[0].artistName, "Portico")
        XCTAssertEqual(songs[0].playCount, 17)
        XCTAssertNil(songs[1].playCount)
        XCTAssertEqual(songs[2].rating, 3)
    }

    /// Songs nested in an album detail response leave off what the parent already says,
    /// so they have to inherit the album's id and cover art rather than come back bare.
    func testAlbumDetailSongsInheritTheAlbum() throws {
        let (_, songs) = try SubsonicParsers.parseAlbumDetail(data: fixture("subsonic_album_detail.xml"))
        XCTAssertTrue(songs.allSatisfy { $0.albumId == "55" })
        XCTAssertTrue(songs.allSatisfy { $0.albumName == "Living Fields" })
        XCTAssertTrue(songs.allSatisfy { $0.artId == "al-55" })
    }

    func testPingStatus() throws {
        let data = try fixture("subsonic_ping.xml")
        XCTAssertNoThrow(try SubsonicParsers.checkForError(data: data))
        let info = try SubsonicParsers.parseServerInfo(data: data)
        XCTAssertFalse(info.version.isEmpty)
    }

    func testLyricsParser() throws {
        let data = try fixture("subsonic_lyrics.xml")
        let lyrics = try SubsonicParsers.parseLyrics(data: data)
        XCTAssertEqual(lyrics, "Line one of the song\nLine two of the song")
    }

    func testStructuredLyricsParserEmitsLrcTimestamps() throws {
        let data = try fixture("subsonic_synced_lyrics.xml")
        let lyrics = try SubsonicParsers.parseLyrics(data: data)
        XCTAssertEqual(lyrics, "[00:00.00]First line\n[00:12.34]Second line\n[01:05.50]Third line")
    }

    func testMusicDirectoryParser() throws {
        let data = try fixture("subsonic_music_directory.xml")
        let entries = try SubsonicParsers.parseMusicDirectory(data: data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .folder)
        XCTAssertEqual(entries[1].kind, .song)
        XCTAssertEqual(entries[1].duration, 240)
        XCTAssertEqual(entries[1].artistName, "Alpha")
    }

    func testStarred2ParserReadsAlbumsAndSongs() throws {
        let data = try fixture("subsonic_starred2.xml")
        let albums = try SubsonicParsers.parseStarredAlbums(data: data)
        let songs = try SubsonicParsers.parseStarredSongs(data: data)
        XCTAssertEqual(albums.map(\.id), ["al1"])
        XCTAssertEqual(songs.map(\.id), ["s1", "s2"])
        XCTAssertEqual(songs[0].title, "Still Starred")
    }

    func testGetSongParserReadsStarredAndRating() throws {
        let liked = try XCTUnwrap(SubsonicParsers.parseSong(data: fixture("subsonic_song_starred.xml")))
        XCTAssertEqual(liked.isFavorite, true)
        XCTAssertEqual(liked.rating, 5)

        let unliked = try XCTUnwrap(SubsonicParsers.parseSong(data: fixture("subsonic_song_unstarred.xml")))
        XCTAssertEqual(unliked.isFavorite, false)
        XCTAssertEqual(unliked.rating, 0)
    }

    /// The server type decides whether the track sync can use Navidrome's bulk endpoint
    /// instead of crawling every album, and it arrives as a root attribute — a ping
    /// response has no child elements to read it from.
    func testServerInfoParserReadsRootAttributes() throws {
        let navidrome = try SubsonicParsers.parseServerInfo(data: fixture("subsonic_ping_navidrome.xml"))
        XCTAssertEqual(navidrome.name, "navidrome")
        XCTAssertEqual(navidrome.version, "0.61.2 (aa84e645)")
        XCTAssertEqual(navidrome.apiVersion, "1.16.1")
    }

    /// Servers that report no type at all still have to parse.
    func testServerInfoParserFallsBackWithoutAType() throws {
        let plain = try SubsonicParsers.parseServerInfo(data: fixture("subsonic_ping.xml"))
        XCTAssertEqual(plain.name, "Subsonic")
        XCTAssertEqual(plain.version, "1.16.1")
    }

    private func fixture(_ name: String) throws -> Data {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: path)
    }
}
