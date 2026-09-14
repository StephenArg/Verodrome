import XCTest
@testable import VerodromeKit

final class NavidromeIdAuxMigratorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-id-aux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Rewrites the queue JSON in every array field the persisted queue carries, using
    /// each item's `kind` to pick the right map. Also fixes embedded-artwork tokens
    /// alongside playable ids so they don't dangle after the file is renamed.
    func testRewritesContextQueueAcrossEveryArrayFieldAndFixesEmbeddedTokens() throws {
        let queueFile = tempRoot.appendingPathComponent("queue-alpha.json")
        let queueJson: [String: Any] = [
            "context": [
                ["playableId": "OLD-SONG-ID", "kind": "song", "artworkId": "embedded-OLD-SONG-ID", "entryId": UUID().uuidString, "title": "T", "duration": 0.0],
            ],
            "user": [
                ["playableId": "OLD-EPISODE-ID", "kind": "podcastEpisode", "entryId": UUID().uuidString, "title": "T", "duration": 0.0],
            ],
            "podcast": [
                ["playableId": "OLD-EPISODE-ID", "kind": "podcastEpisode", "entryId": UUID().uuidString, "title": "T", "duration": 0.0],
            ],
            "unshuffledContext": [
                ["playableId": "OLD-RADIO-ID", "kind": "radio", "entryId": UUID().uuidString, "title": "T", "duration": 0.0],
            ],
            "index": 0, "generation": 1,
        ]
        try JSONSerialization.data(withJSONObject: queueJson).write(to: queueFile)

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [
                .init(kind: .song, oldId: "OLD-SONG-ID", newId: "NEW-SONG-ID"),
                .init(kind: .podcastEpisode, oldId: "OLD-EPISODE-ID", newId: "NEW-EPISODE-ID"),
                .init(kind: .radio, oldId: "OLD-RADIO-ID", newId: "NEW-RADIO-ID"),
            ]
        )
        let report = try NavidromeIdAuxMigrator.apply(
            map: map, queueDirectory: tempRoot, accountKey: "alpha"
        )

        XCTAssertEqual(report.queueItemsRewritten, 4)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: queueFile)) as? [String: Any] ?? [:]
        let context = updated["context"] as? [[String: Any]] ?? []
        XCTAssertEqual(context[0]["playableId"] as? String, "NEW-SONG-ID")
        XCTAssertEqual(context[0]["artworkId"] as? String, "embedded-NEW-SONG-ID")
        let user = updated["user"] as? [[String: Any]] ?? []
        XCTAssertEqual(user[0]["playableId"] as? String, "NEW-EPISODE-ID")
        let podcast = updated["podcast"] as? [[String: Any]] ?? []
        XCTAssertEqual(podcast[0]["playableId"] as? String, "NEW-EPISODE-ID")
        let unshuffled = updated["unshuffledContext"] as? [[String: Any]] ?? []
        XCTAssertEqual(unshuffled[0]["playableId"] as? String, "NEW-RADIO-ID")
    }

    /// The user queue is a bare `[QueueItem]` — no wrapping envelope. Handled by a
    /// separate path but with the same per-item remap.
    func testRewritesUserQueueBareArray() throws {
        let userFile = tempRoot.appendingPathComponent("user-queue-alpha.json")
        let items: [[String: Any]] = [
            ["playableId": "OLD-SONG-ID", "kind": "song", "entryId": UUID().uuidString, "title": "T", "duration": 0.0],
        ]
        try JSONSerialization.data(withJSONObject: items).write(to: userFile)

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD-SONG-ID", newId: "NEW-SONG-ID")]
        )
        let report = try NavidromeIdAuxMigrator.apply(
            map: map, queueDirectory: tempRoot, accountKey: "alpha"
        )

        XCTAssertEqual(report.userQueueItemsRewritten, 1)
        let out = try JSONSerialization.jsonObject(with: Data(contentsOf: userFile)) as? [[String: Any]] ?? []
        XCTAssertEqual(out[0]["playableId"] as? String, "NEW-SONG-ID")
    }

    /// Missing queue files are a valid "empty" state and must not throw — a
    /// never-played account has neither file yet.
    func testMissingFilesAreNotAnError() throws {
        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD", newId: "NEW")]
        )
        let report = try NavidromeIdAuxMigrator.apply(
            map: map, queueDirectory: tempRoot, accountKey: "brand-new"
        )
        XCTAssertEqual(report.queueItemsRewritten, 0)
        XCTAssertEqual(report.userQueueItemsRewritten, 0)
    }
}
