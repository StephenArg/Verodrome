import XCTest
@testable import VerodromeKit

final class LibraryMutationOutboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerodromeOutbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testFavoriteCoalescesToLastWrite() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.setFavorite(entityId: "s1", type: .song, isFavorite: true))
        await outbox.enqueue(.setFavorite(entityId: "s1", type: .song, isFavorite: false))
        await outbox.enqueue(.setFavorite(entityId: "s2", type: .song, isFavorite: true))

        let pending = await outbox.all()
        XCTAssertEqual(pending, [
            .setFavorite(entityId: "s1", type: .song, isFavorite: false),
            .setFavorite(entityId: "s2", type: .song, isFavorite: true),
        ])
    }

    func testRatingCoalescesPerEntity() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.setRating(entityId: "a1", type: .album, rating: 3))
        await outbox.enqueue(.setRating(entityId: "a1", type: .album, rating: 5))

        let pending = await outbox.all()
        XCTAssertEqual(pending, [
            .setRating(entityId: "a1", type: .album, rating: 5),
        ])
    }

    func testPlaylistEditsKeepOrder() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.addToPlaylist(playlistId: "p1", songIds: ["s1"]))
        await outbox.enqueue(.removeFromPlaylist(playlistId: "p1", songIds: ["s2"]))
        await outbox.enqueue(.addToPlaylist(playlistId: "p1", songIds: ["s3"]))

        let pending = await outbox.all()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending[0], .addToPlaylist(playlistId: "p1", songIds: ["s1"]))
        XCTAssertEqual(pending[1], .removeFromPlaylist(playlistId: "p1", songIds: ["s2"]))
        XCTAssertEqual(pending[2], .addToPlaylist(playlistId: "p1", songIds: ["s3"]))
    }

    func testRemapRewritesPlaylistIds() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.createPlaylist(localId: "local", name: "Mine"))
        await outbox.enqueue(.addToPlaylist(playlistId: "local", songIds: ["s1"]))
        await outbox.enqueue(.renamePlaylist(playlistId: "local", name: "Yours"))

        await outbox.remapPlaylistId(from: "local", to: "server-9")

        let pending = await outbox.all()
        XCTAssertEqual(pending, [
            .createPlaylist(localId: "server-9", name: "Mine"),
            .addToPlaylist(playlistId: "server-9", songIds: ["s1"]),
            .renamePlaylist(playlistId: "server-9", name: "Yours"),
        ])
    }

    func testPersistsAcrossInstances() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.setFavorite(entityId: "s1", type: .song, isFavorite: true))
        await outbox.enqueue(.reorderPlaylist(playlistId: "p1", songIds: ["a", "b"]))

        let reloaded = LibraryMutationOutbox(directory: directory, accountKey: "account")
        let pending = await reloaded.all()
        XCTAssertEqual(pending, [
            .setFavorite(entityId: "s1", type: .song, isFavorite: true),
            .reorderPlaylist(playlistId: "p1", songIds: ["a", "b"]),
        ])
    }

    func testAccountsKeepSeparateQueues() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "first")
        await outbox.enqueue(.setFavorite(entityId: "s1", type: .song, isFavorite: true))

        await outbox.setAccount("second")
        let second = await outbox.all()
        XCTAssertTrue(second.isEmpty)

        await outbox.enqueue(.setRating(entityId: "s2", type: .song, rating: 4))
        await outbox.setAccount("first")
        let first = await outbox.all()
        XCTAssertEqual(first, [
            .setFavorite(entityId: "s1", type: .song, isFavorite: true),
        ])
    }

    func testRetriableNetworkErrors() {
        XCTAssertTrue(LibraryMutationSyncer.isRetriableNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(LibraryMutationSyncer.isRetriableNetworkError(LibrarySyncerError.offline))
        XCTAssertTrue(LibraryMutationSyncer.isRetriableNetworkError(BackendError.network("timeout")))
        XCTAssertFalse(LibraryMutationSyncer.isRetriableNetworkError(
            XmlParseError.serverError(code: 50, message: "denied")
        ))
    }

    func testPendingSongMetadataDetectsFavoriteAndRating() async {
        let outbox = LibraryMutationOutbox(directory: directory, accountKey: "account")
        await outbox.enqueue(.setFavorite(entityId: "s1", type: .song, isFavorite: true))
        let s1Pending = await outbox.hasPendingSongMetadata(songId: "s1")
        let s2Clear = await outbox.hasPendingSongMetadata(songId: "s2")
        XCTAssertTrue(s1Pending)
        XCTAssertFalse(s2Clear)

        await outbox.replaceAll([.setRating(entityId: "s2", type: .song, rating: 4)])
        let s2Pending = await outbox.hasPendingSongMetadata(songId: "s2")
        let s1Clear = await outbox.hasPendingSongMetadata(songId: "s1")
        XCTAssertTrue(s2Pending)
        XCTAssertFalse(s1Clear)
    }
}
