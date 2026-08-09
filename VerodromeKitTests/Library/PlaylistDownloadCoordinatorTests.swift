import XCTest
import SwiftData
@testable import VerodromeKit

@MainActor
final class PlaylistDownloadCoordinatorTests: XCTestCase {
    /// Records what the coordinator asked for without touching the network.
    private final class RecordingURLProvider: StreamURLProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _requested: [String] = []

        var requested: [String] { lock.withLock { _requested } }

        func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            lock.withLock { _requested.append(id) }
            throw BackendError.invalidURL
        }

        func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
            throw BackendError.invalidURL
        }

        func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
            throw BackendError.invalidURL
        }
    }

    private final class EmptyCache: PlayableFileCaching, @unchecked Sendable {
        func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? { nil }
        func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
            URL(fileURLWithPath: "/tmp/\(id)")
        }
        func deletePlayable(id: String, kind: PlayableRef.Kind) throws {}
        func totalPlayableCacheSize() -> Int64 { 0 }
        func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {}
        func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason { .none }
        func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool { false }
        func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] { [] }
        func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {}
    }

    private var storage: PersistentStorage!
    private var repository: LibraryRepository!
    private var account: Account!
    private var removed: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        storage = PersistentStorage(inMemory: true)
        repository = LibraryRepository(storage: storage)
        account = try repository.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        removed = []
        DownloadCenter.shared.clearAllActive()
        DownloadCenter.shared.clearCompleted()
        DownloadCenter.shared.clearFailed()
    }

    private func makeCoordinator(
        downloader: DownloadManager
    ) async -> PlaylistDownloadCoordinator {
        // Most tests assert transfers start; open the gate unless a case overrides it.
        await downloader.setNetworkPolicy(wifiOnlyAutomatic: true, isUnmetered: true)
        return PlaylistDownloadCoordinator(
            downloader: downloader,
            repositoryProvider: { [weak self] in self?.repository },
            accountProvider: { [weak self] in self?.account },
            removeDownload: { [weak self] song in
                self?.removed.append(song.remoteId)
                song.cacheReason = .none
                song.isUserPinned = false
                song.relFilePath = nil
                try? self?.repository.save()
            }
        )
    }

    private func makePlaylist(_ id: String, songs: [Song], keepDownloaded: Bool) throws -> Playlist {
        let playlist = try repository.getOrCreatePlaylist(remoteId: id, name: id, account: account)
        playlist.keepDownloaded = keepDownloaded
        try repository.replacePlaylistItems(playlist, with: songs)
        return playlist
    }

    private func makeSong(_ id: String) throws -> Song {
        try repository.getOrCreateSong(remoteId: id, title: id, account: account)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - Downloading what a playlist gained

    /// The point of the feature: a song that appeared in a downloaded playlist is fetched
    /// without the user opening the playlist or asking again.
    func testASongAddedToADownloadedPlaylistIsQueued() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let first = try makeSong("s1")
        let playlist = try makePlaylist("p1", songs: [first], keepDownloaded: true)
        await coordinator.reconcile()

        let added = try makeSong("s2")
        try repository.replacePlaylistItems(playlist, with: [first, added])
        await coordinator.reconcile()

        await waitUntil("the added song to be fetched") { provider.requested.contains("s2") }
        XCTAssertEqual(added.cacheReason, .playlistCache)
        XCTAssertTrue(added.isUserPinned)
    }

    func testAPlaylistThatIsNotKeptDownloadsNothing() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let song = try makeSong("s1")
        _ = try makePlaylist("p1", songs: [song], keepDownloaded: false)

        await coordinator.reconcile()

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.requested, [])
        XCTAssertEqual(song.cacheReason, .none)
    }

    /// A song downloaded by hand keeps that reason, which is what lets the cleanup below
    /// tell "the playlist wanted this" from "the user did".
    func testAManuallyDownloadedSongKeepsItsOwnReason() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let song = try makeSong("s1")
        song.cacheReason = .userDownload
        song.isUserPinned = true
        _ = try makePlaylist("p1", songs: [song], keepDownloaded: true)

        await coordinator.reconcile()

        XCTAssertEqual(song.cacheReason, .userDownload)
    }

    // MARK: - Cleaning up

    func testASongDroppedFromADownloadedPlaylistLosesItsDownload() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let kept = try makeSong("s1")
        let dropped = try makeSong("s2")
        let playlist = try makePlaylist("p1", songs: [kept, dropped], keepDownloaded: true)
        await coordinator.reconcile()

        try repository.replacePlaylistItems(playlist, with: [kept])
        await coordinator.reconcile()

        XCTAssertEqual(removed, ["s2"])
    }

    func testACleanupLeavesAManualDownloadAlone() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let song = try makeSong("s1")
        song.cacheReason = .userDownload
        song.isUserPinned = true
        let playlist = try makePlaylist("p1", songs: [song], keepDownloaded: true)
        await coordinator.reconcile()

        try repository.replacePlaylistItems(playlist, with: [])
        await coordinator.reconcile()

        XCTAssertEqual(removed, [], "the user asked for this file, not the playlist")
    }

    /// Two downloaded playlists can share a track. Removing it from one must not take the
    /// file the other still wants.
    func testASongHeldByASecondDownloadedPlaylistSurvives() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let shared = try makeSong("s1")
        let first = try makePlaylist("p1", songs: [shared], keepDownloaded: true)
        _ = try makePlaylist("p2", songs: [shared], keepDownloaded: true)
        await coordinator.reconcile()

        try repository.replacePlaylistItems(first, with: [])
        await coordinator.reconcile()

        XCTAssertEqual(removed, [])
        XCTAssertEqual(shared.cacheReason, .playlistCache)
    }

    // MARK: - Resuming across launches

    /// The queue is memory only, so what survives a relaunch is the library's record of
    /// intent: a reason with no file behind it.
    func testResumePendingRequeuesWantedSongsWithNoFile() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)

        let interrupted = try makeSong("s1")
        interrupted.cacheReason = .playlistCache
        interrupted.isUserPinned = true

        let finished = try makeSong("s2")
        finished.cacheReason = .userDownload
        finished.relFilePath = "song/s2"

        let untouched = try makeSong("s3")
        try repository.save()

        await coordinator.resumePending()

        await waitUntil("the interrupted download to resume") { provider.requested.contains("s1") }
        XCTAssertFalse(provider.requested.contains("s2"), "this one already has its file")
        XCTAssertFalse(provider.requested.contains(untouched.remoteId))
    }

    func testResumePendingKeepsDownloadsWaitingWhenTheConnectionIsMetered() async throws {
        let provider = RecordingURLProvider()
        let downloader = DownloadManager(urlProvider: provider, cache: EmptyCache())
        let coordinator = await makeCoordinator(downloader: downloader)
        await downloader.setNetworkPolicy(wifiOnlyAutomatic: true, isUnmetered: false)

        let song = try makeSong("s1")
        song.cacheReason = .playlistCache
        song.isUserPinned = true
        try repository.save()

        await coordinator.resumePending()

        let deferred = await downloader.deferredIds
        XCTAssertEqual(provider.requested, [])
        XCTAssertEqual(deferred, ["s1"])
        XCTAssertEqual(DownloadCenter.shared.status(for: "s1", isDownloaded: false), .waiting)
    }
}
