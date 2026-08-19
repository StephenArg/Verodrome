import XCTest
@testable import VerodromeKit

@MainActor
final class RecentQueueStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RecentQueueStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRecordsMostRecentFirst() {
        let store = makeStore()
        store.record(album(id: "a", title: "First"))
        store.record(playlist(id: "p", title: "Mix"))
        store.record(album(id: "b", title: "Latest"))

        XCTAssertEqual(store.entries.map(\.title), ["Latest", "Mix", "First"])
        XCTAssertEqual(store.entries.map(\.kind), [.album, .playlist, .album])
    }

    func testDuplicateMovesExistingRowToFront() {
        let store = makeStore()
        store.record(album(id: "a", title: "Alpha"))
        store.record(album(id: "b", title: "Beta"))
        store.record(album(id: "a", title: "Alpha"))

        XCTAssertEqual(store.entries.map(\.compoundRemoteId), ["a", "b"])
        XCTAssertEqual(store.entries.count, 2)
    }

    func testAlbumAndPlaylistWithSameIdStayDistinct() {
        let store = makeStore()
        store.record(album(id: "same", title: "Album"))
        store.record(playlist(id: "same", title: "Playlist"))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.kind), [.playlist, .album])
    }

    func testCapsAtTwenty() {
        let store = makeStore()
        for index in 1...25 {
            store.record(album(id: "\(index)", title: "Album \(index)"))
        }

        XCTAssertEqual(store.entries.count, 20)
        XCTAssertEqual(store.entries.first?.compoundRemoteId, "25")
        XCTAssertEqual(store.entries.last?.compoundRemoteId, "6")
        XCTAssertFalse(store.entries.contains { $0.compoundRemoteId == "5" })
    }

    func testPersistsAndReloadsPerAccount() {
        let store = makeStore(account: "one")
        store.record(album(id: "a", title: "Kept"))

        let reloaded = makeStore(account: "one")
        XCTAssertEqual(reloaded.entries.map(\.title), ["Kept"])

        let other = makeStore(account: "two")
        XCTAssertTrue(other.entries.isEmpty)
    }

    func testIgnoresEmptyIdentity() {
        let store = makeStore()
        store.record(album(id: "   ", title: "Blank"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    private func makeStore(account: String = "test") -> RecentQueueStore {
        RecentQueueStore(defaults: defaults, accountKey: { account })
    }

    private func album(id: String, title: String) -> RecentQueueEntry {
        RecentQueueEntry(kind: .album, compoundRemoteId: id, title: title)
    }

    private func playlist(id: String, title: String) -> RecentQueueEntry {
        RecentQueueEntry(kind: .playlist, compoundRemoteId: id, title: title)
    }
}
