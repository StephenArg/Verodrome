import XCTest
@testable import VerodromeKit

/// `setMembership` is what lets the playlist sheet flip a row the moment it's tapped and
/// settle with the server afterwards. These cover the cases that make that hard: a write
/// that fails, and a row tapped again before its write is back.
@MainActor
final class PlaylistMembershipIndexTests: XCTestCase {
    /// Stands in for the server: records each write and holds it until the test answers.
    @MainActor
    private final class FakeServer {
        private(set) var writes: [Bool] = []
        private var unanswered: [CheckedContinuation<Void, Error>] = []

        func write(_ isMember: Bool) async throws {
            writes.append(isMember)
            try await withCheckedThrowingContinuation { unanswered.append($0) }
        }

        func answer(failing: Bool = false) {
            let next = unanswered.removeFirst()
            if failing {
                next.resume(throwing: RejectedWrite())
            } else {
                next.resume()
            }
        }
    }

    private struct RejectedWrite: Error {}

    private let songId = "song-1"
    private let playlistId = "playlist-1"

    private var index: PlaylistMembershipIndex { .shared }
    private var isMember: Bool { index.isMember(songId: songId, playlistId: playlistId) }

    override func setUp() async throws {
        try await super.setUp()
        index.reset()
    }

    override func tearDown() async throws {
        index.reset()
        try await super.tearDown()
    }

    func testChangeShowsBeforeTheServerAnswers() async throws {
        let server = FakeServer()
        let add = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }
        XCTAssertTrue(isMember)

        server.answer()
        let isLatest = try await add.value
        XCTAssertTrue(isLatest)
        XCTAssertTrue(isMember)
    }

    func testFailedWritePutsTheOldAnswerBackAndThrows() async {
        let server = FakeServer()
        let add = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }

        server.answer(failing: true)
        do {
            _ = try await add.value
            XCTFail("The caller has to hear about the failure to warn about it")
        } catch {}
        XCTAssertFalse(isMember)
    }

    func testSecondTapWaitsForTheFirstWriteThenUndoesIt() async throws {
        let server = FakeServer()
        let add = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }
        let remove = toggle(to: false, on: server)
        await settle { !isMember }
        XCTAssertEqual(server.writes, [true], "The removal must not race the add it's undoing")

        server.answer()
        let addIsLatest = try await add.value
        XCTAssertFalse(addIsLatest)
        await settle { server.writes.count == 2 }
        XCTAssertEqual(server.writes, [true, false])
        XCTAssertFalse(isMember)

        server.answer()
        let removeIsLatest = try await remove.value
        XCTAssertTrue(removeIsLatest)
        XCTAssertFalse(isMember)
    }

    func testFailureOfAnOvertakenWriteIsNotReported() async throws {
        let server = FakeServer()
        let add = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }
        let remove = toggle(to: false, on: server)
        await settle { !isMember }

        server.answer(failing: true)
        let addIsLatest = try await add.value
        XCTAssertFalse(addIsLatest)
        let removeIsLatest = try await remove.value
        XCTAssertTrue(removeIsLatest)
        XCTAssertEqual(server.writes, [true], "The add never landed, so there was nothing to remove")
        XCTAssertFalse(isMember)
    }

    func testLatestFailurePutsBackWhatTheServerLastHad() async throws {
        let server = FakeServer()
        let add = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }
        let remove = toggle(to: false, on: server)
        await settle { !isMember }

        server.answer()
        _ = try await add.value
        await settle { server.writes.count == 2 }
        server.answer(failing: true)
        do {
            _ = try await remove.value
            XCTFail("The removal failed and nothing has overtaken it")
        } catch {}
        XCTAssertTrue(isMember, "The add went through, so the song is still in the playlist")
    }

    func testTapsQueuedBehindAWriteCollapseToTheLast() async throws {
        let server = FakeServer()
        let first = toggle(to: true, on: server)
        await settle { server.writes.count == 1 }
        let second = toggle(to: false, on: server)
        await settle { !isMember }
        let third = toggle(to: true, on: server)
        await settle { isMember }

        server.answer()
        let results = try await [first.value, second.value, third.value]
        XCTAssertEqual(results, [false, false, true])
        XCTAssertEqual(server.writes, [true], "The server already has what the last tap asked for")
        XCTAssertTrue(isMember)
    }

    // MARK: - Helpers

    private func toggle(to isMember: Bool, on server: FakeServer) -> Task<Bool, Error> {
        Task {
            try await index.setMembership(songId: songId, playlistId: playlistId, isMember: isMember) {
                try await server.write(isMember)
            }
        }
    }

    /// Lets the toggles' tasks run until `condition` holds; everything here is on the
    /// main actor, so yielding is all they need.
    private func settle(until condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 1_000 {
            await Task.yield()
            attempts += 1
        }
        XCTAssertTrue(condition(), "Timed out waiting for the toggles to get there")
    }
}
