import XCTest
@testable import VerodromeKit

final class SubsonicParserTests: XCTestCase {
    func testArtistParser() throws {
        let data = try fixture("subsonic_artists.xml")
        let artists = try SubsonicParsers.parseArtists(data: data)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first?.name, "Alpha")
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
