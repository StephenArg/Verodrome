import XCTest
@testable import VerodromeKit

final class LyricsCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cache-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testStoreAndLoadRoundTrip() {
        let cache = LyricsCache(root: root)
        XCTAssertTrue(cache.store(id: "song1", text: "[00:01.00]Hello\n[00:02.00]World"))
        XCTAssertEqual(cache.load(id: "song1"), "[00:01.00]Hello\n[00:02.00]World")
    }

    func testMissingIdReturnsNil() {
        let cache = LyricsCache(root: root)
        XCTAssertNil(cache.load(id: "missing"))
    }

    func testEmptyTextIsNotStored() {
        let cache = LyricsCache(root: root)
        XCTAssertFalse(cache.store(id: "song1", text: "   \n  "))
        XCTAssertNil(cache.load(id: "song1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: "song1").path))
    }

    func testRemoveDeletesFile() {
        let cache = LyricsCache(root: root)
        XCTAssertTrue(cache.store(id: "song1", text: "Line one"))
        cache.remove(id: "song1")
        XCTAssertNil(cache.load(id: "song1"))
    }

    func testResolvePrefersDiskOverServerAndEmbedded() async {
        let cache = LyricsCache(root: root)
        cache.store(id: "song1", text: "From disk")

        var serverCalled = false
        var embeddedCalled = false
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: {
                serverCalled = true
                return "From server"
            },
            embeddedLyrics: {
                embeddedCalled = true
                return "From ID3"
            }
        )

        XCTAssertEqual(text, "From disk")
        XCTAssertFalse(serverCalled)
        XCTAssertFalse(embeddedCalled)
    }

    func testResolveWritesServerHitThroughToCache() async {
        let cache = LyricsCache(root: root)
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { "From server" },
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertEqual(text, "From server")
        XCTAssertEqual(cache.load(id: "song1"), "From server")
    }

    func testResolveFallsBackToEmbeddedAndCaches() async {
        let cache = LyricsCache(root: root)
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { nil },
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertEqual(text, "From ID3")
        XCTAssertEqual(cache.load(id: "song1"), "From ID3")
    }

    func testResolveLocalSkipsNetwork() async {
        let cache = LyricsCache(root: root)
        let text = LyricsLookup.resolveLocal(
            playableId: "song1",
            cache: cache,
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertEqual(text, "From ID3")
    }

    /// ID3 must not be cached from the local pass, or the later network lookup would see a
    /// disk hit and never reach the server / LRCLIB (which may have synced lyrics).
    func testResolveLocalDoesNotCacheEmbedded() async {
        let cache = LyricsCache(root: root)
        _ = LyricsLookup.resolveLocal(
            playableId: "song1",
            cache: cache,
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertNil(cache.load(id: "song1"))
    }

    func testResolvePrefersServerOverLrcLib() async {
        let cache = LyricsCache(root: root)
        var lrcLibCalled = false
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { "From server" },
            fetchFromLrcLib: {
                lrcLibCalled = true
                return "From LRCLIB"
            },
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertEqual(text, "From server")
        XCTAssertFalse(lrcLibCalled)
        XCTAssertEqual(cache.load(id: "song1"), "From server")
    }

    func testResolveFallsBackToLrcLibAndCaches() async {
        let cache = LyricsCache(root: root)
        var embeddedCalled = false
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { nil },
            fetchFromLrcLib: { "[00:01.00]From LRCLIB" },
            embeddedLyrics: {
                embeddedCalled = true
                return "From ID3"
            }
        )
        XCTAssertEqual(text, "[00:01.00]From LRCLIB")
        XCTAssertFalse(embeddedCalled)
        XCTAssertEqual(cache.load(id: "song1"), "[00:01.00]From LRCLIB")
    }

    func testResolveFallsThroughLrcLibMissToEmbedded() async {
        let cache = LyricsCache(root: root)
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { nil },
            fetchFromLrcLib: { nil },
            embeddedLyrics: { "From ID3" }
        )
        XCTAssertEqual(text, "From ID3")
        XCTAssertEqual(cache.load(id: "song1"), "From ID3")
    }

    func testResolveIgnoresEmptyServerAndUsesEmbedded() async {
        let cache = LyricsCache(root: root)
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: { "  \n" },
            embeddedLyrics: { "Embedded" }
        )
        XCTAssertEqual(text, "Embedded")
    }

    /// Mirrors `DownloadManager.cacheLyricsIfNeeded`: lyrics failure must not throw.
    func testBestEffortLookupSurvivesServerFailure() async {
        let cache = LyricsCache(root: root)
        let text = await LyricsLookup.resolve(
            playableId: "song1",
            cache: cache,
            fetchFromServer: {
                throw BackendError.invalidURL
            },
            embeddedLyrics: { "Recovered from tags" }
        )
        XCTAssertEqual(text, "Recovered from tags")
        XCTAssertEqual(cache.load(id: "song1"), "Recovered from tags")
    }
}
