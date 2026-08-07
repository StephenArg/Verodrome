import XCTest
@testable import VerodromeKit

final class FilePlayerQueueStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL.temporaryQueueDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private static func snapshot(ids: [String], position: TimeInterval = 0) -> PersistedPlayerQueue {
        PersistedPlayerQueue(
            context: ids.map { QueueItem(playableId: $0, title: "Song \($0)") },
            index: 0,
            playbackPosition: position
        )
    }

    func testSavedQueueReadsBackWithEveryFieldIntact() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        var snapshot = Self.snapshot(ids: ["1", "2", "3"], position: 61.5)
        snapshot.index = 2
        snapshot.repeatMode = .all
        snapshot.shuffleMode = .on
        snapshot.playerMode = .podcast

        await store.saveQueue(snapshot)

        let loaded = await store.loadQueue()
        XCTAssertEqual(loaded, snapshot)
    }

    /// Playable ids only mean something against the library they came from, so one
    /// account's queue must never be handed to another.
    func testEachAccountKeepsItsOwnQueue() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "first")
        await store.saveQueue(Self.snapshot(ids: ["first-song"]))

        await store.setAccount("second")
        let secondAccountQueue = await store.loadQueue()
        XCTAssertNil(secondAccountQueue, "the second account starts with no queue")

        await store.saveQueue(Self.snapshot(ids: ["second-song"]))
        await store.setAccount("first")
        let loaded = await store.loadQueue()
        XCTAssertEqual(loaded?.context.map(\.playableId), ["first-song"])
    }

    func testWithoutAnAccountNothingIsStored() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: nil)

        await store.saveQueue(Self.snapshot(ids: ["1"]))

        let loaded = await store.loadQueue()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testClearingForgetsTheStoredQueue() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        await store.saveQueue(Self.snapshot(ids: ["1"]))
        await store.saveUserQueue([QueueItem(playableId: "u", title: "Queued")])

        await store.clearQueue()

        let loaded = await store.loadQueue()
        XCTAssertNil(loaded)
        let user = await store.loadUserQueue()
        XCTAssertTrue(user.isEmpty)
    }

    /// Adding to the queue must be able to update this file without touching the context.
    func testUserQueueIsStoredSeparatelyFromContext() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        await store.saveQueue(Self.snapshot(ids: ["1", "2", "3"]))

        let queued = [
            QueueItem(playableId: "a", title: "A", isUserQueued: true, isEphemeral: true),
            QueueItem(playableId: "b", title: "B", isUserQueued: true, isEphemeral: true)
        ]
        await store.saveUserQueue(queued)

        let context = await store.loadQueue()
        XCTAssertEqual(context?.context.map(\.playableId), ["1", "2", "3"])
        XCTAssertEqual(context?.user, [], "context file must not embed the Added-to-Queue run")
        let user = await store.loadUserQueue()
        XCTAssertEqual(user.map(\.playableId), ["a", "b"])
        XCTAssertTrue(user.allSatisfy(\.isEphemeral))
    }

    func testSavingAnEmptyUserQueueRemovesTheSideFile() async {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        await store.saveUserQueue([QueueItem(playableId: "a", title: "A", isUserQueued: true)])
        await store.saveUserQueue([])

        let user = await store.loadUserQueue()
        XCTAssertTrue(user.isEmpty)
        let fileURL = directory.appendingPathComponent("user-queue-account.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A queue written by a build that has since changed shape should cost the user their
    /// queue, not every launch from here on.
    func testAnUnreadableQueueIsDiscarded() async throws {
        let store = FilePlayerQueueStore(directory: directory, accountKey: "account")
        await store.saveQueue(Self.snapshot(ids: ["1"]))
        let fileURL = directory.appendingPathComponent("queue-account.json")
        try Data("not json".utf8).write(to: fileURL)

        let loaded = await store.loadQueue()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

extension URL {
    static func temporaryQueueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VerodromeQueueTests-\(UUID().uuidString)", isDirectory: true)
    }
}

extension XCTestCase {
    /// Queue writes are handed to a background task, so a test has to let the stored file
    /// catch up with the edit that triggered it.
    @discardableResult
    func awaitStoredQueue(
        in store: FilePlayerQueueStore,
        timeout: TimeInterval = 2,
        until isReady: (PersistedPlayerQueue?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> PersistedPlayerQueue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await store.loadQueue()
            if isReady(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The stored queue never reached the expected state", file: file, line: line)
        return nil
    }

    @discardableResult
    func awaitStoredUserQueue(
        in store: FilePlayerQueueStore,
        timeout: TimeInterval = 2,
        until isReady: ([QueueItem]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [QueueItem] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let items = await store.loadUserQueue()
            if isReady(items) { return items }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The stored Added-to-Queue list never reached the expected state", file: file, line: line)
        return []
    }
}
