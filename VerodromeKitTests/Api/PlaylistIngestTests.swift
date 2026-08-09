import SwiftData
import XCTest
@testable import VerodromeKit

/// Whether a playlist can be added to decides whether it appears in the add-to-playlist
/// sheet at all, so getting it wrong silently removes the feature.
final class PlaylistIngestTests: XCTestCase {
    private func makeIngester(_ storage: PersistentStorage) -> SwiftDataLibraryIngester {
        SwiftDataLibraryIngester(
            modelContainer: storage.container,
            // Lowercased on the way in, unlike the spelling a server reports back.
            accountInfo: AccountInfo(serverURL: "https://music.example", username: "Vera"),
            apiType: .subsonic
        )
    }

    private func fetchPlaylist(_ storage: PersistentStorage, remoteId: String) throws -> Playlist? {
        let context = ModelContext(storage.container)
        return try context.fetch(FetchDescriptor<Playlist>()).first { $0.remoteId == remoteId }
    }

    /// The server states its own canonical username, which needn't match the casing the
    /// account was created with. Inferring "not yours, so not editable" from that mismatch
    /// hid every playlist the user owned.
    func testOwnerSpellingDoesNotDecideEditability() async throws {
        let storage = PersistentStorage(inMemory: true)
        try await makeIngester(storage).ingest(playlists: [
            IngestPlaylist(id: "p1", name: "Road Trip", songCount: 3, owner: "Vera")
        ])

        let playlist = try XCTUnwrap(fetchPlaylist(storage, remoteId: "p1"))
        XCTAssertTrue(playlist.isEditable)
        XCTAssertFalse(playlist.isSmart)
    }

    func testReadOnlyAndSmartPlaylistsAreNotEditable() async throws {
        let storage = PersistentStorage(inMemory: true)
        try await makeIngester(storage).ingest(playlists: [
            IngestPlaylist(id: "shared", name: "Shared Mix", owner: "someone_else", isReadOnly: true),
            IngestPlaylist(id: "smart_1", name: "Highest Rated", isSmart: true)
        ])

        let shared = try XCTUnwrap(fetchPlaylist(storage, remoteId: "shared"))
        XCTAssertFalse(shared.isEditable)
        XCTAssertFalse(shared.isSmart)

        let smart = try XCTUnwrap(fetchPlaylist(storage, remoteId: "smart_1"))
        XCTAssertFalse(smart.isEditable)
        XCTAssertTrue(smart.isSmart)
    }

    /// Editability is re-derived from every response rather than only ever tightened. A
    /// version that only tightened turned one bad reading into a playlist that could never
    /// be added to again.
    func testEditabilityRecoversWhenTheServerStopsReportingReadOnly() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)

        try await ingester.ingest(playlists: [IngestPlaylist(id: "p1", name: "Mix", isReadOnly: true)])
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.isEditable, false)

        try await ingester.ingest(playlists: [IngestPlaylist(id: "p1", name: "Mix")])
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.isEditable, true)
    }
}
