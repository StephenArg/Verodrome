import XCTest
@testable import VerodromeKit

final class AmpacheParserTests: XCTestCase {
    func testArtistParser() throws {
        let data = try fixture("ampache_artists.xml")
        let artists = try AmpacheParsers.parseArtists(data: data)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists[0].id, "10")
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
