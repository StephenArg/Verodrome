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

    /// Catalog rows carry a count but no entries. Rewriting items from that would
    /// empty a playlist the user had already opened.
    func testCatalogIngestLeavesCachedItemsAlone() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        try await ingester.ingest(songs: [IngestSong(id: "s1", title: "Track")])
        try await ingester.ingest(playlists: [
            IngestPlaylist(id: "p1", name: "Mix", songCount: 1, songIds: ["s1"])
        ])
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.items.count, 1)

        try await ingester.ingest(playlists: [
            IngestPlaylist(id: "p1", name: "Mix", songCount: 9)
        ])

        let playlist = try XCTUnwrap(fetchPlaylist(storage, remoteId: "p1"))
        XCTAssertEqual(playlist.items.count, 1)
        XCTAssertEqual(playlist.items.first?.song?.remoteId, "s1")
        XCTAssertEqual(playlist.songCount, 1)
    }

    /// A detail pull with no entries is how an emptied playlist arrives. Treating that
    /// the same as a catalog row left the last cached song on screen.
    func testDetailIngestWithNoSongsClearsCachedItems() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        try await ingester.ingest(songs: [IngestSong(id: "s1", title: "Track")])
        try await ingester.ingest(playlists: [
            IngestPlaylist(id: "p1", name: "Mix", songCount: 1, songIds: ["s1"])
        ])
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.items.count, 1)

        try await ingester.ingest(playlists: [
            IngestPlaylist(id: "p1", name: "Mix", songCount: 0, songIds: [])
        ])

        let playlist = try XCTUnwrap(fetchPlaylist(storage, remoteId: "p1"))
        XCTAssertTrue(playlist.items.isEmpty)
        XCTAssertEqual(playlist.songCount, 0)
    }

    /// Adding a song to a playlist writes the entry on the main context, then pulls the
    /// playlist, which the ingester rewrites on its own context. The main context never
    /// saw the ingester's rows, and adding the same song to the next playlist saved its
    /// stale list of them back — cutting the earlier playlists' entries loose from the
    /// song, so ticking several playlists in the add-to-playlist sheet left only the last.
    @MainActor
    func testAddingASongToSeveralPlaylistsKeepsEveryEntry() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        let ids = ["A", "B", "C"]
        try await ingester.ingest(songs: [IngestSong(id: "x", title: "New"), IngestSong(id: "s", title: "Shared")]
            + ids.map { IngestSong(id: "\($0)1", title: $0) })
        try await ingester.ingest(playlists: ids.map {
            IngestPlaylist(id: $0, name: $0, songCount: 2, songIds: ["\($0)1", "s"])
        })

        let main = LibraryRepository(context: storage.mainContext)
        let account = try XCTUnwrap(storage.mainContext.fetch(FetchDescriptor<Account>()).first)
        let song = try XCTUnwrap(main.resolveSong(remoteId: "x", account: account))
        for id in ids {
            // What `LibraryActions.addSongs` does: a local write, then a pull.
            let playlist = try XCTUnwrap(main.fetchPlaylists(account: account).first { $0.remoteId == id })
            try main.replacePlaylistItems(playlist, with: main.orderedSongs(of: playlist) + [song])
            try await ingester.ingest(playlists: [
                IngestPlaylist(id: id, name: id, songCount: 3, songIds: ["\(id)1", "s", "x"])
            ])
        }

        let items = try ModelContext(storage.container).fetch(FetchDescriptor<PlaylistItem>())
        XCTAssertFalse(items.contains { $0.song == nil })
        for songId in ["x", "s"] {
            let holding = Set(items.filter { $0.song?.remoteId == songId }.compactMap { $0.playlist?.remoteId })
            XCTAssertEqual(holding, Set(ids), "playlists holding \(songId)")
        }
    }
}
