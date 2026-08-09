import XCTest
@testable import VerodromeKit

/// Subsonic playlist mutations take *repeated* query parameters (`songIdToAdd=a&songIdToAdd=b`).
/// Indexed names like `songIdToAdd[0]` are a different key; Navidrome ignores them and still
/// returns status=ok, which is how the client used to report a successful add that never
/// landed on the server.
final class SubsonicPlaylistMutationTests: XCTestCase {
    func testPlaylistMutationQueryItemsUseRepeatedNames() {
        let items = SubsonicServerApi.queryItems(
            parameters: ["playlistId": "pl-1", "name": "Mix"],
            repeating: [
                "songIdToAdd": ["s1", "s2"],
                "songIndexToRemove": ["0"]
            ]
        )

        let grouped = Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
        XCTAssertEqual(grouped["playlistId"], ["pl-1"])
        XCTAssertEqual(grouped["name"], ["Mix"])
        XCTAssertEqual(grouped["songIdToAdd"], ["s1", "s2"])
        XCTAssertEqual(grouped["songIndexToRemove"], ["0"])
        XCTAssertNil(grouped["songIdToAdd[0]"])
        XCTAssertNil(grouped["songIdToAdd[1]"])
    }

    func testCreatePlaylistQueryItemsRepeatSongId() {
        let items = SubsonicServerApi.queryItems(
            parameters: ["name": "Road Trip"],
            repeating: ["songId": ["a", "b", "c"]]
        )
        let songIds = items.filter { $0.name == "songId" }.compactMap(\.value)
        XCTAssertEqual(songIds, ["a", "b", "c"])
        XCTAssertFalse(items.contains { $0.name.hasPrefix("songId[") })
    }
}
