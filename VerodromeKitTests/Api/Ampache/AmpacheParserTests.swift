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
