import SwiftData
import XCTest
@testable import VerodromeKit

/// The Home refresh used to request every newest album's tracks one at a time, even
/// when the full sync had already stored them. These cover the pieces that keep that
/// prefetch down to the albums that still need it.
final class NewestAlbumTracksTests: XCTestCase {
    private let info = AccountInfo(serverURL: "https://music.example", username: "vera")

    private func makeIngester(_ storage: PersistentStorage) -> SwiftDataLibraryIngester {
        SwiftDataLibraryIngester(modelContainer: storage.container, accountInfo: info, apiType: .subsonic)
    }

    private func fetchAlbum(_ storage: PersistentStorage, remoteId: String) throws -> Album? {
        let context = ModelContext(storage.container)
        return try context.fetch(FetchDescriptor<Album>()).first { $0.remoteId == remoteId }
    }

    func testMissingSkipsAlbumsThatAlreadyHaveSongs() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        try await ingester.ingest(albums: [
            IngestAlbum(id: "stored", name: "Already Synced"),
            IngestAlbum(id: "fresh", name: "Just Added"),
        ])
        try await ingester.ingest(songs: [
            IngestSong(id: "s1", title: "Track", albumId: "stored", albumName: "Already Synced"),
        ])

        let missing = try await CommonLibrarySyncer.albumIds(
            ["stored", "fresh"],
            needingTracks: .missing,
            ingestor: ingester
        )
        XCTAssertEqual(missing, ["fresh"])

        // Auto-download needs song ids for every album, stored or not.
        let all = try await CommonLibrarySyncer.albumIds(
            ["stored", "fresh"],
            needingTracks: .all,
            ingestor: ingester
        )
        XCTAssertEqual(all, ["stored", "fresh"])
    }

    /// The appliers no longer open a batch, so their writes have to be saved on their own.
    func testNewestRanksPersistAndClearPreviousRanks() async throws {
        let storage = PersistentStorage(inMemory: true)
        let ingester = makeIngester(storage)
        try await ingester.ingest(albums: [
            IngestAlbum(id: "a", name: "A"),
            IngestAlbum(id: "b", name: "B"),
        ])

        try await ingester.applyNewestAlbumRanks(["a", "b"])
        try await ingester.applyNewestAlbumRanks(["b"])

        XCTAssertEqual(try fetchAlbum(storage, remoteId: "a")?.newestIndex, 0)
        XCTAssertEqual(try fetchAlbum(storage, remoteId: "b")?.newestIndex, 1)
    }

    func testFetchEachKeepsOrderAndBoundsConcurrency() async throws {
        let tracker = InFlightTracker()
        let ids = (0..<12).map(String.init)

        let results = try await CommonLibrarySyncer.fetchEach(ids, maxConcurrent: 3) { id in
            await tracker.start()
            try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...5_000_000))
            await tracker.finish()
            return "album-\(id)"
        }

        XCTAssertEqual(results, ids.map { "album-\($0)" })
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1)
    }

    @MainActor
    func testHasAlbumsIsScopedToTheAccount() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)
        let other = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://other.example", username: "vera"),
            apiType: .subsonic
        )
        XCTAssertFalse(try repo.hasAlbums(account: account))

        _ = try repo.getOrCreateAlbum(remoteId: "a", title: "A", account: other)
        XCTAssertFalse(try repo.hasAlbums(account: account))
        XCTAssertTrue(try repo.hasAlbums(account: other))
    }
}

private actor InFlightTracker {
    private var current = 0
    private(set) var peak = 0

    func start() {
        current += 1
        peak = max(peak, current)
    }

    func finish() {
        current -= 1
    }
}
