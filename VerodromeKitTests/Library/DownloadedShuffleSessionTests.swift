import XCTest
import SwiftData
@testable import VerodromeKit

@MainActor
final class DownloadedShuffleSessionTests: XCTestCase {
    private var storage: PersistentStorage!
    private var repository: LibraryRepository!
    private var account: Account!

    override func setUpWithError() throws {
        storage = PersistentStorage(inMemory: true)
        repository = LibraryRepository(storage: storage)
        account = try repository.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
    }

    override func tearDown() {
        storage = nil
        repository = nil
        account = nil
        super.tearDown()
    }

    func testDrawsOnlyTracksThatAreOnDisk() async throws {
        insertSong(id: "a", title: "On Disk", relFilePath: "music/a.mp3")
        insertSong(id: "b", title: "Streaming Only", relFilePath: nil)
        try repository.save()

        let items = try await DownloadedShuffleSession(storage: storage).next()

        XCTAssertEqual(items.map(\.playableId), ["a"])
    }

    func testCarriesTheLibraryRowsMetadata() async throws {
        let song = insertSong(id: "a", title: "Blue Line", relFilePath: "music/a.mp3")
        song.artistName = "Portico"
        song.albumTitle = "Living Fields"
        song.artworkToken = "al-55"
        song.playDuration = 214
        try repository.save()

        let items = try await DownloadedShuffleSession(storage: storage).next()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Blue Line")
        XCTAssertEqual(items[0].artistName, "Portico")
        XCTAssertEqual(items[0].albumName, "Living Fields")
        XCTAssertEqual(items[0].artworkId, "al-55")
        XCTAssertEqual(items[0].duration, 214)
    }

    /// The walk is the whole downloaded set, split up — every track once, none twice.
    func testBatchesHandEachTrackOutExactlyOnce() async throws {
        let ids = (0..<10).map { "s\($0)" }
        for id in ids { insertSong(id: id, title: id, relFilePath: "music/\(id).mp3") }
        try repository.save()

        let session = DownloadedShuffleSession(storage: storage)
        var drawn: [String] = []
        while case let batch = try await session.next(count: 3), !batch.isEmpty {
            XCTAssertLessThanOrEqual(batch.count, 3)
            drawn.append(contentsOf: batch.map(\.playableId))
        }

        XCTAssertEqual(drawn.sorted(), ids.sorted())
        let finished = await session.isFinished
        XCTAssertTrue(finished)
    }

    func testNothingDownloadedEndsTheWalkImmediately() async throws {
        insertSong(id: "a", title: "Streaming Only", relFilePath: nil)
        try repository.save()

        let items = try await DownloadedShuffleSession(storage: storage).next()

        XCTAssertTrue(items.isEmpty)
    }

    /// The order is settled on the first draw, so a download landing mid-session can't
    /// reshuffle what the user is already looking at in the queue.
    func testLaterDownloadsDoNotJoinARunningWalk() async throws {
        insertSong(id: "a", title: "First", relFilePath: "music/a.mp3")
        insertSong(id: "b", title: "Second", relFilePath: "music/b.mp3")
        try repository.save()

        let session = DownloadedShuffleSession(storage: storage)
        _ = try await session.next(count: 1)

        insertSong(id: "c", title: "Downloaded Later", relFilePath: "music/c.mp3")
        try repository.save()

        var rest: [String] = []
        while case let batch = try await session.next(count: 5), !batch.isEmpty {
            rest.append(contentsOf: batch.map(\.playableId))
        }

        XCTAssertEqual(rest.count, 1)
        XCTAssertFalse(rest.contains("c"))
    }

    @discardableResult
    private func insertSong(id: String, title: String, relFilePath: String?) -> Song {
        let song = Song(remoteId: id, title: title, account: account)
        song.relFilePath = relFilePath
        repository.context.insert(song)
        return song
    }
}
