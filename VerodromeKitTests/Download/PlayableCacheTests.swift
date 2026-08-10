import XCTest
@testable import VerodromeKit

final class PlayableCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("playable-cache-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A file to hand to `storePlayable`, which moves rather than copies.
    private func makeTempFile(_ contents: String = "audio") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAPrefetchIsStoredUnpinnedAndAUserDownloadIsPinned() throws {
        let cache = FilePlayableCache(root: root)

        _ = try cache.storePlayable(id: "temp", kind: .song, from: try makeTempFile(), reason: .queuePrefetch)
        _ = try cache.storePlayable(id: "kept", kind: .song, from: try makeTempFile(), reason: .userDownload)

        XCTAssertFalse(cache.isUserPinned(id: "temp", kind: .song))
        XCTAssertTrue(cache.isUserPinned(id: "kept", kind: .song))
        XCTAssertEqual(cache.cachedPlayableIds(reason: .queuePrefetch).map(\.id), ["temp"])
    }

    func testPlayableCacheStatsSplitsOfflineAndTemporaryBytes() throws {
        let cache = FilePlayableCache(root: root)
        _ = try cache.storePlayable(
            id: "temp",
            kind: .song,
            from: try makeTempFile(String(repeating: "t", count: 40)),
            reason: .queuePrefetch
        )
        _ = try cache.storePlayable(
            id: "kept",
            kind: .song,
            from: try makeTempFile(String(repeating: "k", count: 80)),
            reason: .userDownload
        )

        let stats = cache.playableCacheStats()
        XCTAssertEqual(stats.offlineCount, 1)
        XCTAssertEqual(stats.temporaryCount, 1)
        XCTAssertEqual(stats.offlineBytes, 80)
        XCTAssertEqual(stats.temporaryBytes, 40)
    }

    /// The prune loops only see what the metadata knows about, so a file it lost track of
    /// would stay on disk for good. Files young enough to still be mid-store are skipped.
    func testOrphanedFilesReportsUntrackedFilesPastTheGracePeriod() throws {
        let cache = FilePlayableCache(root: root)
        _ = try cache.storePlayable(id: "tracked", kind: .song, from: try makeTempFile(), reason: .queuePrefetch)

        let songs = root.appendingPathComponent(PlayableRef.Kind.song.rawValue, isDirectory: true)
        let stranded = songs.appendingPathComponent("stranded")
        try "audio".write(to: stranded, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            cache.orphanedFiles(olderThan: 300).isEmpty,
            "a file this recent could be a transfer that has not recorded itself yet"
        )

        var values = URLResourceValues()
        values.contentModificationDate = Date().addingTimeInterval(-600)
        var aged = stranded
        try aged.setResourceValues(values)

        let orphans = cache.orphanedFiles(olderThan: 300)
        XCTAssertEqual(orphans.map(\.id), ["stranded"])
        XCTAssertEqual(orphans.first?.kind, .song)
    }

    func testTranscodedVariantUsesQualitySpecificPathAndCoexistsWithOriginal() throws {
        let cache = FilePlayableCache(root: root)
        _ = try cache.storePlayable(
            id: "song1",
            kind: .song,
            from: try makeTempFile("flac"),
            reason: .queuePrefetch,
            quality: .original
        )
        _ = try cache.storePlayable(
            id: "song1",
            kind: .song,
            from: try makeTempFile("mp3"),
            reason: .queuePrefetch,
            quality: .mp3_320
        )

        let original = cache.fileURL(forPlayableId: "song1", kind: .song, quality: .original)
        let mp3 = cache.fileURL(forPlayableId: "song1", kind: .song, quality: .mp3_320)
        XCTAssertNotNil(original)
        XCTAssertNotNil(mp3)
        XCTAssertEqual(mp3?.lastPathComponent, "song1.mp3.320")
        XCTAssertEqual(cache.playableByteSize(id: "song1", kind: .song), 7) // "flac" + "mp3"
        XCTAssertEqual(cache.cachedPlayableIds(reason: .queuePrefetch).map(\.id), ["song1"])
        XCTAssertTrue(cache.hasPlayableFile(id: "song1", kind: .song))

        try cache.deletePlayable(id: "song1", kind: .song)
        XCTAssertNil(cache.fileURL(forPlayableId: "song1", kind: .song, quality: .original))
        XCTAssertNil(cache.fileURL(forPlayableId: "song1", kind: .song, quality: .mp3_320))
        XCTAssertFalse(cache.hasPlayableFile(id: "song1", kind: .song))
    }

    func testHasPlayableFileSeesTranscodedVariantAlone() throws {
        let cache = FilePlayableCache(root: root)
        _ = try cache.storePlayable(
            id: "only-mp3",
            kind: .song,
            from: try makeTempFile("mp3"),
            reason: .queuePrefetch,
            quality: .mp3_256
        )
        XCTAssertNil(cache.fileURL(forPlayableId: "only-mp3", kind: .song))
        XCTAssertTrue(cache.hasPlayableFile(id: "only-mp3", kind: .song))
    }

    func testOrphanedTranscodedVariantReportsBarePlayableId() throws {
        let cache = FilePlayableCache(root: root)
        let songs = root.appendingPathComponent(PlayableRef.Kind.song.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: songs, withIntermediateDirectories: true)
        let stranded = songs.appendingPathComponent("abc.mp3.256")
        try "audio".write(to: stranded, atomically: true, encoding: .utf8)

        var values = URLResourceValues()
        values.contentModificationDate = Date().addingTimeInterval(-600)
        var aged = stranded
        try aged.setResourceValues(values)

        let orphans = cache.orphanedFiles(olderThan: 300)
        XCTAssertEqual(orphans.map(\.id), ["abc"])
    }

    /// `meta` is written from the main actor and from inside the `DownloadManager` actor.
    /// A dropped entry is exactly how a cached file becomes unreachable to every prune.
    func testConcurrentStoresKeepEveryMetadataEntry() throws {
        let cache = FilePlayableCache(root: root)
        let count = 60
        let temps = try (0..<count).map { _ in try makeTempFile() }

        DispatchQueue.concurrentPerform(iterations: count) { index in
            _ = try? cache.storePlayable(
                id: "s\(index)",
                kind: .song,
                from: temps[index],
                reason: .queuePrefetch
            )
            cache.touchPlayable(id: "s\(index)", kind: .song, reason: .queuePrefetch)
            cache.setQueueGeneration(id: "s\(index)", kind: .song, generation: index)
        }

        XCTAssertEqual(cache.cachedPlayableIds(reason: .queuePrefetch).count, count)
        XCTAssertTrue(cache.orphanedFiles(olderThan: 0).isEmpty, "every stored file should be tracked")

        // The metadata is also what survives a relaunch, so it has to be on disk intact.
        let reopened = FilePlayableCache(root: root)
        XCTAssertEqual(reopened.cachedPlayableIds(reason: .queuePrefetch).count, count)
    }
}
