import XCTest
@testable import VerodromeKit

final class ArtistTopSongsTests: XCTestCase {
    func testHidesWhenArtistHasTenOrFewerSongs() {
        let matches = (0..<8).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertTrue(ArtistTopSongs.visibleSongs(from: matches, artistSongCount: 10).isEmpty)
        XCTAssertFalse(ArtistTopSongs.shouldFetch(artistSongCount: 10))
    }

    func testHidesWhenFewerThanThreeMatches() {
        let matches = (0..<2).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertTrue(ArtistTopSongs.visibleSongs(from: matches, artistSongCount: 24).isEmpty)
    }

    func testShowsAllWhenThreeMatches() {
        let matches = (0..<3).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertEqual(
            ArtistTopSongs.visibleSongs(from: matches, artistSongCount: 24).map(\.id),
            ["s0", "s1", "s2"]
        )
    }

    func testKeepsUpToNineWhenMoreMatches() {
        let matches = (0..<14).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertEqual(
            ArtistTopSongs.visibleSongs(from: matches, artistSongCount: 24).map(\.id),
            (0..<9).map { "s\($0)" }
        )
    }

    func testCollapsedDisplayShowsFiveUntilExpanded() {
        let kept = (0..<9).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertEqual(
            ArtistTopSongs.displayedSongs(from: kept, expanded: false).map(\.id),
            (0..<5).map { "s\($0)" }
        )
        XCTAssertEqual(
            ArtistTopSongs.displayedSongs(from: kept, expanded: true).map(\.id),
            kept.map(\.id)
        )
        XCTAssertTrue(ArtistTopSongs.showsMoreControl(keptCount: kept.count))
        XCTAssertFalse(ArtistTopSongs.showsMoreControl(keptCount: 5))
        // Old caches may still hold 10; the expanded list never paints more than keptLimit.
        let stale = (0..<12).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        XCTAssertEqual(
            ArtistTopSongs.displayedSongs(from: stale, expanded: true).map(\.id),
            (0..<9).map { "s\($0)" }
        )
        XCTAssertTrue(ArtistTopSongs.listsMatch(kept, kept))
        XCTAssertFalse(ArtistTopSongs.listsMatch(kept, Array(kept.dropFirst())))
    }

    @MainActor
    func testPopularCacheRoundTripsThroughDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let songs = [
            IngestSong(id: "a", title: "Alpha", albumName: "One", duration: 120, artId: "art-a"),
            IngestSong(id: "b", title: "Beta", albumName: "Two", duration: 180, artId: "art-b")
        ]
        let warm = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        await warm.store(songs, forArtistCompoundId: "acct::artist::42")
        XCTAssertEqual(warm.cached(forArtistCompoundId: "acct::artist::42")?.map(\.id), ["a", "b"])

        let cold = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        XCTAssertNil(cold.cached(forArtistCompoundId: "acct::artist::42"))
        let loaded = await cold.load(forArtistCompoundId: "acct::artist::42")
        XCTAssertEqual(loaded?.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded?.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(loaded?.map(\.albumName), ["One", "Two"])
    }

    @MainActor
    func testPopularCacheRemoveDropsMemoryAndDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ArtistPopularSongsStore(fileURL: url)
        let cache = ArtistPopularSongsCache(store: store)
        await cache.store([IngestSong(id: "a", title: "Alpha")], forArtistCompoundId: "acct::artist::42")
        await cache.remove(forArtistCompoundId: "acct::artist::42")
        XCTAssertNil(cache.cached(forArtistCompoundId: "acct::artist::42"))

        let cold = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        let loaded = await cold.load(forArtistCompoundId: "acct::artist::42")
        XCTAssertNil(loaded)
    }

    @MainActor
    func testPopularCacheRemoveAllAndLoadAll() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ArtistPopularSongsStore(fileURL: url)
        let cache = ArtistPopularSongsCache(store: store)
        await cache.store([IngestSong(id: "a", title: "Alpha")], forArtistCompoundId: "acct::artist::1")
        await cache.store([], forArtistCompoundId: "acct::artist::empty")
        let warmCount = await cache.entryCount()
        XCTAssertEqual(warmCount, 2)

        let cold = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        await cold.loadAll()
        XCTAssertEqual(cold.cached(forArtistCompoundId: "acct::artist::1")?.map(\.id), ["a"])
        XCTAssertEqual(cold.cached(forArtistCompoundId: "acct::artist::empty"), [])

        await cache.removeAll()
        let afterRemoveCount = await cache.entryCount()
        XCTAssertEqual(afterRemoveCount, 0)
        XCTAssertNil(cache.cached(forArtistCompoundId: "acct::artist::1"))
        let after = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        let reloaded = await after.load(forArtistCompoundId: "acct::artist::1")
        XCTAssertNil(reloaded)
    }

    @MainActor
    func testPrefetchSkipsWhenCachedIncludingEmpty() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        await cache.store([], forArtistCompoundId: "acct::artist::42")
        let provider = RecordingTopSongProvider()
        provider.songs = (0..<5).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        let prefetcher = makePrefetcher(cache: cache, provider: provider)
        let fetched = await prefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertFalse(fetched)
        XCTAssertEqual(provider.calls, 0)
    }

    @MainActor
    func testPrefetchIsNoOpWhenAutoCacheIsOff() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        let provider = RecordingTopSongProvider()
        provider.songs = (0..<5).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        var settings = UserSettings.default
        settings.autoCacheArtistPopularSongs = false
        let prefetcher = makePrefetcher(cache: cache, provider: provider, settings: settings)
        let fetched = await prefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertFalse(fetched)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertNil(cache.cached(forArtistCompoundId: Self.eligibleTarget.compoundId))
    }

    @MainActor
    func testPrefetchStoresVisibleListAndEmptyWithoutSecondCall() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: url))
        let provider = RecordingTopSongProvider()
        provider.songs = (0..<5).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        let prefetcher = makePrefetcher(cache: cache, provider: provider)

        let firstFetch = await prefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertTrue(firstFetch)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(cache.cached(forArtistCompoundId: Self.eligibleTarget.compoundId)?.map(\.id), (0..<5).map { "s\($0)" })

        let secondFetch = await prefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertFalse(secondFetch)
        XCTAssertEqual(provider.calls, 1)

        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("popular-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let emptyCache = ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: emptyURL))
        provider.songs = (0..<2).map { IngestSong(id: "s\($0)", title: "T\($0)") }
        let emptyPrefetcher = makePrefetcher(cache: emptyCache, provider: provider)
        let emptyFetch = await emptyPrefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertTrue(emptyFetch)
        XCTAssertEqual(emptyCache.cached(forArtistCompoundId: Self.eligibleTarget.compoundId), [])
        let emptyAgain = await emptyPrefetcher.prefetchIfNeeded(Self.eligibleTarget)
        XCTAssertFalse(emptyAgain)
        XCTAssertEqual(provider.calls, 2)
    }

    @MainActor
    func testRevalidateSameIdsLeaveListUnchanged() {
        let first = (0..<5).map { IngestSong(id: "s\($0)", title: "A\($0)") }
        let sameIds = (0..<5).map { IngestSong(id: "s\($0)", title: "B\($0)") }
        XCTAssertTrue(ArtistTopSongs.listsMatch(first, sameIds))
        XCTAssertFalse(ArtistTopSongs.listsMatch(first, Array(first.dropLast())))
    }

    @MainActor
    func testWarmupReadsBoundedFavoritesNotTheSongTable() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let info = AccountInfo(serverURL: "https://music.example", username: "vera")
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)

        for i in 0..<30 {
            let artist = try repo.getOrCreateArtist(remoteId: "plain-\(i)", name: "Plain \(i)", account: account)
            artist.songCount = 24
            let song = try repo.getOrCreateSong(remoteId: "plain-s-\(i)", title: "Plain \(i)", account: account, artist: artist)
            song.isFavorite = false
        }
        for i in 0..<25 {
            let artist = try repo.getOrCreateArtist(remoteId: "fav-\(String(format: "%02d", i))", name: "Fav \(String(format: "%02d", i))", account: account)
            artist.songCount = 24
            let song = try repo.getOrCreateSong(remoteId: "fav-s-\(i)", title: "Fav \(String(format: "%02d", i))", account: account, artist: artist)
            song.isFavorite = true
        }
        let tooSmall = try repo.getOrCreateArtist(remoteId: "tiny", name: "Tiny", account: account)
        tooSmall.songCount = 4
        let tinySong = try repo.getOrCreateSong(remoteId: "tiny-s", title: "Aaa Tiny", account: account, artist: tooSmall)
        tinySong.isFavorite = true
        try repo.save()

        let prefetcher = ArtistPopularSongsPrefetcher(
            cache: ArtistPopularSongsCache(store: ArtistPopularSongsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("popular-warmup-\(UUID().uuidString).json"))),
            settings: { .default },
            isConnected: { true },
            provider: { () async -> (any TopSongProviding)? in nil },
            repository: { repo },
            account: { account },
            recentEntries: { [] }
        )
        let targets = prefetcher.likelyArtistTargets()
        XCTAssertEqual(targets.count, ArtistPopularSongsPrefetcher.warmupLimit)
        XCTAssertTrue(targets.allSatisfy { $0.remoteId.hasPrefix("fav-") })
        XCTAssertFalse(targets.contains { $0.remoteId == "tiny" })
        XCTAssertFalse(targets.contains { $0.remoteId.hasPrefix("plain-") })
    }

    private static let eligibleTarget = ArtistPopularPrefetchTarget(
        compoundId: "acct::artist::42",
        remoteId: "42",
        name: "Portico",
        songCount: 24
    )

    @MainActor
    private func makePrefetcher(
        cache: ArtistPopularSongsCache,
        provider: RecordingTopSongProvider,
        settings: UserSettings = .default
    ) -> ArtistPopularSongsPrefetcher {
        ArtistPopularSongsPrefetcher(
            cache: cache,
            settings: { settings },
            isConnected: { true },
            provider: { provider },
            repository: { nil },
            account: { nil },
            recentEntries: { [] }
        )
    }
}

@MainActor
private final class RecordingTopSongProvider: TopSongProviding {
    var calls = 0
    var songs: [IngestSong] = []

    func topSongs(artistId: String, artistName: String, count: Int) async throws -> [IngestSong] {
        calls += 1
        return songs
    }
}
