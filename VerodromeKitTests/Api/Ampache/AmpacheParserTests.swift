import XCTest
@testable import VerodromeKit

final class AmpacheParserTests: XCTestCase {
    func testArtistParser() throws {
        let data = try fixture("ampache_artists.xml")
        let artists = try AmpacheParsers.parseArtists(data: data)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists[0].id, "10")
        XCTAssertEqual(artists[0].albumCount, 3)
        XCTAssertEqual(artists[0].songCount, 42)
        XCTAssertEqual(artists[1].albumCount, 1)
        XCTAssertEqual(artists[1].songCount, 8)
    }

    func testGenreParser() throws {
        let data = try fixture("ampache_genres.xml")
        let genres = try AmpacheParsers.parseGenres(data: data)
        XCTAssertEqual(genres.count, 2)
        XCTAssertEqual(genres[0].id, "6")
        XCTAssertEqual(genres[0].name, "Dance")
        XCTAssertEqual(genres[0].albumCount, 1)
        XCTAssertEqual(genres[0].songCount, 11)
        XCTAssertEqual(genres[1].name, "Dark Ambient")
        XCTAssertEqual(genres[1].albumCount, 2)
        XCTAssertEqual(genres[1].songCount, 8)
    }

    /// Plays and rating drive the Songs list's sort options, so they have to survive
    /// parsing. Absent values must stay nil rather than becoming 0, or a response
    /// without them wipes what an earlier sync stored.
    func testSongParserReadsPlayCountAndRating() throws {
        let data = try fixture("ampache_songs.xml")
        let songs = try AmpacheParsers.parseSongs(data: data)
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(songs[0].playCount, 17)
        XCTAssertEqual(songs[0].rating, 4)
        // `preciserating` stands in when `rating` is missing; `averagerating` never does.
        XCTAssertNil(songs[1].playCount)
        XCTAssertEqual(songs[1].rating, 3)
        XCTAssertNil(songs[2].playCount)
        XCTAssertNil(songs[2].rating)
    }

    /// The song crawl sizes its progress bar from the collection total the server
    /// repeats on every page.
    func testTotalCountParser() throws {
        XCTAssertEqual(try AmpacheParsers.parseTotalCount(data: try fixture("ampache_genres.xml")), 2)
        XCTAssertNil(try AmpacheParsers.parseTotalCount(data: try fixture("ampache_artists.xml")))
    }

    func testSongLyricsParser() throws {
        let data = try fixture("ampache_song_lyrics.xml")
        let lyrics = try AmpacheParsers.parseSongLyrics(data: data)
        XCTAssertEqual(lyrics, "Ampache line one\nAmpache line two")
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
