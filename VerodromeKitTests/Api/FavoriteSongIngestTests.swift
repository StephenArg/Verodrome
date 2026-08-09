import SwiftData
import XCTest
@testable import VerodromeKit

/// Song hearts used to be write-only locally. An unlike done on the server left the
/// heart stuck until this reconcile path cleared it.
final class FavoriteSongIngestTests: XCTestCase {
    private func makeIngester(_ storage: PersistentStorage) -> SwiftDataLibraryIngester {
        SwiftDataLibraryIngester(
            modelContainer: storage.container,
            accountInfo: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
    }

    private func fetchSong(_ storage: PersistentStorage, remoteId: String) throws -> Song? {
        let context = ModelContext(storage.container)
        return try context.fetch(FetchDescriptor<Song>()).first { $0.remoteId == remoteId }
    }

    func testApplyFavoriteSongsClearsUnstarredLocalLikes() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)

        try await ingester.ingest(songs: [
            IngestSong(id: "kept", title: "Still Starred"),
            IngestSong(id: "dropped", title: "Unliked On Server"),
        ])

        // Seed the stuck local state the bug describes.
        let context = ModelContext(storage.container)
        let songs = try context.fetch(FetchDescriptor<Song>())
        for song in songs { song.isFavorite = true }
        try context.save()

        try await ingester.applyFavoriteSongs(["kept"])

        XCTAssertEqual(try fetchSong(storage, remoteId: "kept")?.isFavorite, true)
        XCTAssertEqual(try fetchSong(storage, remoteId: "dropped")?.isFavorite, false)
    }

    func testApplyFavoriteSongsMarksNewlyStarredSongs() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)

        try await ingester.ingest(songs: [
            IngestSong(id: "fresh", title: "Just Starred"),
        ])
        XCTAssertEqual(try fetchSong(storage, remoteId: "fresh")?.isFavorite, false)

        try await ingester.applyFavoriteSongs(["fresh"])
        XCTAssertEqual(try fetchSong(storage, remoteId: "fresh")?.isFavorite, true)
    }
}
