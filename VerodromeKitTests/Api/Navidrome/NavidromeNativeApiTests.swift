import XCTest
@testable import VerodromeKit

final class NavidromeNativeApiTests: XCTestCase {
    func testSongDecodingMapsOntoIngestSong() throws {
        let data = try fixture("navidrome_songs.json")
        let songs = try NavidromeNativeApi.songs(from: data)

        XCTAssertEqual(songs.count, 3)

        let first = songs[0]
        XCTAssertEqual(first.id, "mf-1")
        XCTAssertEqual(first.title, "Opening")
        XCTAssertEqual(first.albumId, "al-1")
        XCTAssertEqual(first.albumName, "First Light")
        XCTAssertEqual(first.artistId, "ar-1")
        XCTAssertEqual(first.artistName, "Alpha")
        XCTAssertEqual(first.trackNumber, 1)
        XCTAssertEqual(first.discNumber, 1)
        XCTAssertEqual(first.duration ?? 0, 245.32, accuracy: 0.001)
        XCTAssertEqual(first.bitrate, 320)
        XCTAssertEqual(first.format, "mp3")
        XCTAssertEqual(first.playCount, 17)
        XCTAssertEqual(first.rating, 4)
    }

    /// Navidrome omits zero-valued annotations entirely, so a song nobody has played has
    /// no `playCount` key. That has to arrive as nil, not 0, or a bulk sync would erase a
    /// play this device scrobbled before the server accepted it.
    func testAbsentAnnotationsStayNil() throws {
        let data = try fixture("navidrome_songs.json")
        let songs = try NavidromeNativeApi.songs(from: data)

        XCTAssertNil(songs[1].playCount)
        XCTAssertNil(songs[1].rating)
    }

    /// Only id and title are guaranteed; a row missing everything else still has to map.
    func testSparseRowDecodes() throws {
        let data = try fixture("navidrome_songs.json")
        let songs = try NavidromeNativeApi.songs(from: data)

        let sparse = songs[2]
        XCTAssertEqual(sparse.id, "mf-3")
        XCTAssertEqual(sparse.title, "Untitled")
        XCTAssertNil(sparse.albumId)
        XCTAssertNil(sparse.artistId)
        XCTAssertNil(sparse.bitrate)
    }

    /// Cover art is left unset so the ingester keeps what the catalog sync stored rather
    /// than overwriting it with a guess.
    func testCoverArtIsLeftToTheCatalog() throws {
        let data = try fixture("navidrome_songs.json")
        let songs = try NavidromeNativeApi.songs(from: data)

        XCTAssertTrue(songs.allSatisfy { $0.artId == nil })
    }

    func testMalformedPayloadThrows() {
        let data = Data(#"{"songs": []}"#.utf8)
        XCTAssertThrowsError(try NavidromeNativeApi.songs(from: data))
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
