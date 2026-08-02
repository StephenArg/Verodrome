import SwiftData
import XCTest
@testable import VerodromeKit

/// Serves canned batches and records what it was asked for. Calls are sequential, which
/// is why the unchecked conformance is safe here.
private final class StubRandomSongProvider: RandomSongProviding, @unchecked Sendable {
    let randomSongBatchLimit: Int

    private let batches: [RandomSongBatch]
    /// Served once `batches` runs out, so a test can describe a backend that keeps
    /// handing back the same tracks forever.
    private let repeating: RandomSongBatch?

    private(set) var requestedCounts: [Int] = []
    private(set) var receivedCursors: [RandomSongCursor?] = []

    var callCount: Int { requestedCounts.count }

    init(batchLimit: Int = 500, batches: [RandomSongBatch], repeating: RandomSongBatch? = nil) {
        self.randomSongBatchLimit = batchLimit
        self.batches = batches
        self.repeating = repeating
    }

    func randomSongs(count: Int, after cursor: RandomSongCursor?) async throws -> RandomSongBatch {
        let index = requestedCounts.count
        requestedCounts.append(count)
        receivedCursors.append(cursor)
        if index < batches.count { return batches[index] }
        return repeating ?? RandomSongBatch(songs: [], isExhausted: true)
    }
}

private func songs(_ ids: [String]) -> [IngestSong] {
    ids.map { IngestSong(id: $0, title: "Song \($0)", duration: 100) }
}

final class ShuffleAllSessionTests: XCTestCase {
    func testMapsResponseFieldsOntoQueueItems() async throws {
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: [
                IngestSong(
                    id: "a",
                    title: "Blue Line",
                    albumName: "Living Fields",
                    artistName: "Portico",
                    duration: 214,
                    artId: "al-55"
                )
            ])
        ])
        let session = ShuffleAllSession(provider: provider)

        let items = try await session.next()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].playableId, "a")
        XCTAssertEqual(items[0].title, "Blue Line")
        XCTAssertEqual(items[0].artistName, "Portico")
        XCTAssertEqual(items[0].albumName, "Living Fields")
        XCTAssertEqual(items[0].duration, 214)
        XCTAssertEqual(items[0].artworkId, "al-55")
        XCTAssertEqual(items[0].kind, .song)
    }

    /// Subsonic re-draws on every call, so a top-up routinely arrives holding tracks the
    /// queue already has. Handing those back would put the same song in twice.
    func testDropsTracksAlreadyHandedOut() async throws {
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: songs(["a", "b", "c"])),
            RandomSongBatch(songs: songs(["b", "c", "d", "e"]))
        ])
        let session = ShuffleAllSession(provider: provider)

        let first = try await session.next()
        let second = try await session.next()

        XCTAssertEqual(first.map(\.playableId), ["a", "b", "c"])
        XCTAssertEqual(second.map(\.playableId), ["d", "e"])
    }

    /// A single all-duplicate draw is bad luck, not the end of the library, so the
    /// session asks again rather than declaring the walk over.
    func testDrawsAgainWhenABatchIsAllDuplicates() async throws {
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: songs(["a", "b"])),
            RandomSongBatch(songs: songs(["a", "b"])),
            RandomSongBatch(songs: songs(["c"]))
        ])
        let session = ShuffleAllSession(provider: provider)

        _ = try await session.next()
        let second = try await session.next()

        XCTAssertEqual(second.map(\.playableId), ["c"])
        XCTAssertEqual(provider.callCount, 3)
        let finished = await session.isFinished
        XCTAssertFalse(finished)
    }

    /// A backend that can't page will repeat forever once the library is used up. The
    /// session has to notice and stop rather than spin.
    func testGivesUpAfterRepeatedDuplicateDraws() async throws {
        let provider = StubRandomSongProvider(
            batches: [RandomSongBatch(songs: songs(["a", "b"]))],
            repeating: RandomSongBatch(songs: songs(["a", "b"]))
        )
        let session = ShuffleAllSession(provider: provider)

        _ = try await session.next()
        let second = try await session.next()

        XCTAssertTrue(second.isEmpty)
        let finished = await session.isFinished
        XCTAssertTrue(finished)
        XCTAssertEqual(provider.callCount, 3, "one seed draw plus the two it takes to give up")
    }

    func testStopsOnceTheBackendReportsExhaustion() async throws {
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: songs(["a", "b"]), isExhausted: true)
        ])
        let session = ShuffleAllSession(provider: provider)

        let first = try await session.next()
        let second = try await session.next()

        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(provider.callCount, 1, "an exhausted walk must not ask again")
    }

    /// Navidrome's seeded paging only works if the cursor makes it back to the next
    /// request — without it every page repeats the first.
    func testCarriesTheCursorIntoTheNextRequest() async throws {
        let cursor = RandomSongCursor(seed: "seed-1", offset: 3, total: 12)
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: songs(["a", "b", "c"]), cursor: cursor),
            RandomSongBatch(songs: songs(["d"]))
        ])
        let session = ShuffleAllSession(provider: provider)

        _ = try await session.next()
        _ = try await session.next()

        XCTAssertNil(provider.receivedCursors[0])
        XCTAssertEqual(provider.receivedCursors[1], cursor)
    }

    /// Asking a backend for more than it serves just gets clamped server-side, and on
    /// Subsonic that silently truncates — better to ask for what it can give.
    func testClampsTheRequestToWhatTheBackendServes() async throws {
        let provider = StubRandomSongProvider(
            batchLimit: 20,
            batches: [RandomSongBatch(songs: songs(["a"]))]
        )
        let session = ShuffleAllSession(provider: provider)

        _ = try await session.next(count: 5000)

        XCTAssertEqual(provider.requestedCounts, [20])
    }

    func testSkipsRowsWithoutAnId() async throws {
        let provider = StubRandomSongProvider(batches: [
            RandomSongBatch(songs: [
                IngestSong(id: "", title: "Nameless"),
                IngestSong(id: "a", title: "Real")
            ])
        ])
        let session = ShuffleAllSession(provider: provider)

        let items = try await session.next()

        XCTAssertEqual(items.map(\.playableId), ["a"])
    }
}

@MainActor
final class LocalLibrarySongResolverTests: XCTestCase {
    /// Navidrome's native rows carry no cover art id, so a queue built from the response
    /// alone plays with blank artwork. The local row is where it comes from.
    func testPrefersTheLocalRowForArtworkAndNames() async throws {
        let storage = PersistentStorage(inMemory: true)
        let repository = LibraryRepository(storage: storage)
        let account = try repository.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let accountKey = account.compoundKey

        let song = Song(remoteId: "a", title: "Blue Line", account: account)
        song.artistName = "Portico"
        song.albumTitle = "Living Fields"
        song.artworkToken = "al-55"
        song.playDuration = 214
        repository.context.insert(song)
        try repository.save()

        let resolver = LocalLibrarySongResolver(storage: storage, accountKey: accountKey)
        let items = await resolver.queueItems(for: [
            IngestSong(id: "a", title: "Stale Title"),
            IngestSong(id: "b", title: "Not Synced Yet", artistName: "Beta", duration: 95)
        ])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Blue Line")
        XCTAssertEqual(items[0].artistName, "Portico")
        XCTAssertEqual(items[0].albumName, "Living Fields")
        XCTAssertEqual(items[0].artworkId, "al-55")

        // A track the sync hasn't reached still has to play, just without the artwork.
        XCTAssertEqual(items[1].playableId, "b")
        XCTAssertEqual(items[1].title, "Not Synced Yet")
        XCTAssertEqual(items[1].artistName, "Beta")
        XCTAssertNil(items[1].artworkId)
    }

    /// Ids are scoped per account, so another server's track with the same id must not
    /// bleed into the queue.
    func testIgnoresRowsBelongingToAnotherAccount() async throws {
        let storage = PersistentStorage(inMemory: true)
        let repository = LibraryRepository(storage: storage)
        let other = try repository.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://other.example", username: "someone"),
            apiType: .subsonic
        )
        let song = Song(remoteId: "a", title: "Someone Else's Track", account: other)
        song.artworkToken = "other-art"
        repository.context.insert(song)
        try repository.save()

        let resolver = LocalLibrarySongResolver(storage: storage, accountKey: "not-that-account")
        let items = await resolver.queueItems(for: [IngestSong(id: "a", title: "Mine")])

        XCTAssertEqual(items.map(\.title), ["Mine"])
        XCTAssertNil(items[0].artworkId)
    }
}
