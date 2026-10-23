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

    // MARK: - Favorites

    /// Favoriting is local only, so nothing the server sends may clear it: neither the
    /// catalog pull nor a playlist's detail pull, which rewrites its entries.
    @MainActor
    func testFavoriteSurvivesCatalogAndDetailSyncs() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        try await ingester.ingest(songs: [IngestSong(id: "s1", title: "Track")])
        try await ingester.ingest(playlists: [IngestPlaylist(id: "p1", name: "Mix", songCount: 1)])

        let main = LibraryRepository(context: storage.mainContext)
        let account = try XCTUnwrap(storage.mainContext.fetch(FetchDescriptor<Account>()).first)
        let playlist = try XCTUnwrap(main.fetchPlaylists(account: account).first)
        playlist.isFavorite = true
        playlist.favoriteOrder = 3
        try main.save()

        try await ingester.ingest(playlists: [IngestPlaylist(id: "p1", name: "Mix", songCount: 1)])
        try await ingester.ingest(playlists: [IngestPlaylist(id: "p1", name: "Mix", songCount: 1, songIds: ["s1"])])
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.isFavorite, true)
        XCTAssertEqual(try fetchPlaylist(storage, remoteId: "p1")?.favoriteOrder, 3)
    }

    /// Every list built on `fetchPlaylists` (CarPlay, Siri suggestions) puts favorites
    /// on top, each group still in name order.
    @MainActor
    func testFetchPlaylistsListsFavoritesFirst() async throws {
        let storage = PersistentStorage(inMemory: true)
        try await makeIngester(storage).ingest(playlists: [
            IngestPlaylist(id: "a", name: "Alpha"),
            IngestPlaylist(id: "b", name: "Beta"),
            IngestPlaylist(id: "c", name: "Charlie"),
            IngestPlaylist(id: "d", name: "Delta")
        ])
        let main = LibraryRepository(context: storage.mainContext)
        let account = try XCTUnwrap(storage.mainContext.fetch(FetchDescriptor<Account>()).first)
        for playlist in try main.fetchPlaylists(account: account) where ["d", "b"].contains(playlist.remoteId) {
            playlist.isFavorite = true
        }
        try main.save()

        XCTAssertEqual(try main.fetchPlaylists(account: account).map(\.name), ["Beta", "Delta", "Alpha", "Charlie"])
    }

    /// While the favorites still read A–Z, a new one takes its alphabetical place.
    @MainActor
    func testPinningSlotsIntoAscendingFavorites() async throws {
        let library = try await FavoritesLibrary(["Alpha", "Beta", "Charlie", "Delta"], ingester: makeIngester)
        try library.pin("Delta", "Beta", "Charlie")
        XCTAssertEqual(try library.favoriteNames(), ["Beta", "Charlie", "Delta"])
        try library.pin("Alpha")
        XCTAssertEqual(try library.favoriteNames(), ["Alpha", "Beta", "Charlie", "Delta"])
    }

    /// Favorites arranged Z–A stay that way.
    @MainActor
    func testPinningSlotsIntoDescendingFavorites() async throws {
        let library = try await FavoritesLibrary(["Alpha", "Beta", "Charlie", "Delta"], ingester: makeIngester)
        try library.pin("Beta", "Delta")
        try library.arrange("Delta", "Beta")
        try library.pin("Charlie")
        XCTAssertEqual(try library.favoriteNames(), ["Delta", "Charlie", "Beta"])
        try library.pin("Alpha")
        XCTAssertEqual(try library.favoriteNames(), ["Delta", "Charlie", "Beta", "Alpha"])
    }

    /// Once the favorites have been arranged out of name order, a new one goes last.
    @MainActor
    func testPinningAfterRearrangingGoesToTheBottom() async throws {
        let library = try await FavoritesLibrary(["Alpha", "Beta", "Charlie", "Delta"], ingester: makeIngester)
        try library.pin("Alpha", "Charlie", "Delta")
        try library.arrange("Charlie", "Alpha", "Delta")
        try library.pin("Beta")
        XCTAssertEqual(try library.favoriteNames(), ["Charlie", "Alpha", "Delta", "Beta"])
    }

    /// Digits sort after the letters in A–Z# and before them in #A–Z, as the list's own
    /// sorts put them; either counts as alphabetical.
    @MainActor
    func testPinningFollowsWhereFavoritesPutDigits() async throws {
        let lettersFirst = try await FavoritesLibrary(["90s", "Alpha", "Beta"], ingester: makeIngester)
        try lettersFirst.pin("Alpha", "90s")
        try lettersFirst.pin("Beta")
        XCTAssertEqual(try lettersFirst.favoriteNames(), ["Alpha", "Beta", "90s"])

        let digitsFirst = try await FavoritesLibrary(["90s", "Alpha", "Beta"], ingester: makeIngester)
        try digitsFirst.pin("Alpha", "90s")
        try digitsFirst.arrange("90s", "Alpha")
        try digitsFirst.pin("Beta")
        XCTAssertEqual(try digitsFirst.favoriteNames(), ["90s", "Alpha", "Beta"])
    }

    /// Unpinning and pinning again places the playlist by the same rule, not where it was.
    @MainActor
    func testRepinningPlacesThePlaylistAgain() async throws {
        let library = try await FavoritesLibrary(["Alpha", "Beta", "Charlie"], ingester: makeIngester)
        try library.pin("Alpha", "Beta", "Charlie")
        try library.unpin("Beta")
        try library.pin("Beta")
        XCTAssertEqual(try library.favoriteNames(), ["Alpha", "Beta", "Charlie"])

        // Taking Alpha off the bottom leaves the rest in A–Z order, so it comes back first.
        try library.arrange("Beta", "Charlie", "Alpha")
        try library.unpin("Alpha")
        try library.pin("Alpha")
        XCTAssertEqual(try library.favoriteNames(), ["Alpha", "Beta", "Charlie"])
    }
}

/// An in-memory library of playlists named for their ids, for pinning and arranging
/// favorites by name.
@MainActor
private struct FavoritesLibrary {
    let storage: PersistentStorage
    let repository: LibraryRepository
    let account: Account

    init(_ names: [String], ingester makeIngester: (PersistentStorage) -> SwiftDataLibraryIngester) async throws {
        storage = PersistentStorage(inMemory: true)
        try await makeIngester(storage).ingest(playlists: names.map { IngestPlaylist(id: $0, name: $0) })
        repository = LibraryRepository(context: storage.mainContext)
        account = try XCTUnwrap(storage.mainContext.fetch(FetchDescriptor<Account>()).first)
    }

    func pin(_ names: String...) throws {
        for name in names { try repository.setFavorite(true, for: playlist(named: name)) }
    }

    func unpin(_ names: String...) throws {
        for name in names { try repository.setFavorite(false, for: playlist(named: name)) }
    }

    func arrange(_ names: String...) throws {
        try repository.arrangeFavorites(names.map { try playlist(named: $0).compoundRemoteId })
    }

    func favoriteNames() throws -> [String] {
        try repository.fetchPlaylists(account: account).filter(\.isFavorite).map(\.name)
    }

    private func playlist(named name: String) throws -> Playlist {
        try XCTUnwrap(repository.fetchPlaylists(account: account).first { $0.name == name })
    }
}
