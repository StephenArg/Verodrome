import XCTest
@testable import VerodromeKit

final class NavidromeIdFileMigratorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-id-file-migrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// A downloaded track exists in every quality variant Verodrome supports; one map
    /// entry should rename all four of them in a single directory pass.
    func testRenamesAudioFileAcrossEveryQualityVariant() throws {
        let playablesRoot = tempRoot.appendingPathComponent("VerodromePlayables")
        let songDir = playablesRoot.appendingPathComponent("song")
        try FileManager.default.createDirectory(at: songDir, withIntermediateDirectories: true)
        for suffix in ["", ".mp3.320", ".mp3.256", ".mp3.192"] {
            let name = "OLD-ID\(suffix)"
            try Data("audio".utf8).write(to: songDir.appendingPathComponent(name))
        }

        let map = NavidromeIdMap(
            toVersion: "0.64.0",
            fromVersion: nil,
            createdAt: .now,
            applied: false,
            entries: [.init(kind: .song, oldId: "OLD-ID", newId: "NEW-ID")]
        )
        let report = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: playablesRoot,
            lyricsRoot: nil,
            artworkRoot: nil
        )

        XCTAssertEqual(report.audioFilesRenamed, 4)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: songDir.path))
        XCTAssertEqual(names, Set(["NEW-ID", "NEW-ID.mp3.320", "NEW-ID.mp3.256", "NEW-ID.mp3.192"]))
    }

    /// cache-meta.json keys are `{kind}::{fileName}` where fileName embeds the ID; the
    /// migration must rewrite only the ID portion and leave every other value intact.
    func testRewritesCacheMetaKeysPreservingValues() throws {
        let playablesRoot = tempRoot.appendingPathComponent("VerodromePlayables")
        try FileManager.default.createDirectory(at: playablesRoot, withIntermediateDirectories: true)
        let meta: [String: [String: Any]] = [
            "song::OLD-ID": ["reason": 1, "kind": "song", "touched": "2026-01-01T00:00:00Z", "generation": 3, "pinned": true],
            "song::OLD-ID.mp3.320": ["reason": 2, "kind": "song", "touched": "2026-01-02T00:00:00Z", "generation": 4, "pinned": false],
            // Unrelated entry must survive untouched.
            "song::UNRELATED": ["reason": 0, "kind": "song", "touched": "2026-01-01T00:00:00Z", "generation": 1, "pinned": false],
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: playablesRoot.appendingPathComponent("cache-meta.json"))

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD-ID", newId: "NEW-ID")]
        )
        let report = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: playablesRoot,
            lyricsRoot: nil,
            artworkRoot: nil
        )

        XCTAssertEqual(report.metaKeysRewritten, 2)
        let outData = try Data(contentsOf: playablesRoot.appendingPathComponent("cache-meta.json"))
        let out = try JSONSerialization.jsonObject(with: outData) as? [String: [String: Any]] ?? [:]
        XCTAssertNotNil(out["song::NEW-ID"])
        XCTAssertNotNil(out["song::NEW-ID.mp3.320"])
        XCTAssertNotNil(out["song::UNRELATED"])
        XCTAssertNil(out["song::OLD-ID"])
        XCTAssertNil(out["song::OLD-ID.mp3.320"])
        XCTAssertEqual(out["song::NEW-ID"]?["reason"] as? Int, 1)
        XCTAssertEqual(out["song::NEW-ID"]?["generation"] as? Int, 3)
    }

    /// Lyrics sidecars are `{id}.lrc`; a matching map entry moves them.
    func testRenamesLyricsSidecars() throws {
        let lyricsRoot = tempRoot.appendingPathComponent("VerodromeLyrics")
        try FileManager.default.createDirectory(at: lyricsRoot, withIntermediateDirectories: true)
        try Data("lyrics".utf8).write(to: lyricsRoot.appendingPathComponent("OLD-ID.lrc"))

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD-ID", newId: "NEW-ID")]
        )
        let report = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: tempRoot,
            lyricsRoot: lyricsRoot,
            artworkRoot: nil
        )

        XCTAssertEqual(report.lyricsSidecarsRenamed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lyricsRoot.appendingPathComponent("NEW-ID.lrc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lyricsRoot.appendingPathComponent("OLD-ID.lrc").path))
    }

    /// Embedded artwork files are `embedded-{id}_s{size}`; only the ID moves.
    func testRenamesEmbeddedArtworkPreservingSizeSuffix() throws {
        let artworkRoot = tempRoot.appendingPathComponent("VerodromeArtwork")
        try FileManager.default.createDirectory(at: artworkRoot, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: artworkRoot.appendingPathComponent("embedded-OLD-ID_s0"))

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD-ID", newId: "NEW-ID")]
        )
        let report = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: tempRoot,
            lyricsRoot: nil,
            artworkRoot: artworkRoot
        )

        XCTAssertEqual(report.embeddedArtworkRenamed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkRoot.appendingPathComponent("embedded-NEW-ID_s0").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkRoot.appendingPathComponent("embedded-OLD-ID_s0").path))
    }

    /// A resumed run must not overwrite the destination when it already exists — that
    /// would replace a possibly-correct canonical file with a stale variant. The source
    /// is discarded instead.
    func testSkipsWhenDestinationAlreadyExistsAndDiscardsSource() throws {
        let playablesRoot = tempRoot.appendingPathComponent("VerodromePlayables")
        let songDir = playablesRoot.appendingPathComponent("song")
        try FileManager.default.createDirectory(at: songDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: songDir.appendingPathComponent("OLD-ID"))
        try Data("current".utf8).write(to: songDir.appendingPathComponent("NEW-ID"))

        let map = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: nil, createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD-ID", newId: "NEW-ID")]
        )
        let report = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: playablesRoot,
            lyricsRoot: nil,
            artworkRoot: nil
        )

        XCTAssertEqual(report.audioFilesCollided, 1)
        let destContents = try String(contentsOf: songDir.appendingPathComponent("NEW-ID"), encoding: .utf8)
        XCTAssertEqual(destContents, "current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: songDir.appendingPathComponent("OLD-ID").path))
    }
}
