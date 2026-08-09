import Foundation
import SwiftData

/// Keeps playlists marked `keepDownloaded` in step with what's on disk.
///
/// The work is a reconcile rather than a diff of "what was just added". Playlist
/// membership is rewritten wholesale on every sync — `LibraryRepository.replacePlaylistItems`
/// deletes and recreates every row — so there is no reliable "added" event to hang a
/// download off. Comparing what the playlists want against what the library holds is
/// idempotent instead: it survives a missed notification or a kill between sync and
/// download, and cleans up after a removal in the same pass that handles an addition.
@MainActor
public final class PlaylistDownloadCoordinator {
    private let downloader: DownloadManager
    private let syncerProvider: @MainActor () -> (any LibrarySyncer)?
    private let repositoryProvider: @MainActor () -> LibraryRepository?
    private let accountProvider: @MainActor () -> Account?
    private let removeDownload: @MainActor (Song) async -> Void

    private var reconcileTask: Task<Void, Never>?
    private var isReconciling = false

    public init(
        downloader: DownloadManager,
        syncerProvider: @escaping @MainActor () -> (any LibrarySyncer)? = { nil },
        repositoryProvider: @escaping @MainActor () -> LibraryRepository? = {
            VerodromeKit.shared.repository()
        },
        accountProvider: @escaping @MainActor () -> Account? = {
            try? VerodromeKit.shared.activeAccount()
        },
        removeDownload: @escaping @MainActor (Song) async -> Void = {
            await LibraryActions.shared.removeDownload(song: $0)
        }
    ) {
        self.downloader = downloader
        self.syncerProvider = syncerProvider
        self.repositoryProvider = repositoryProvider
        self.accountProvider = accountProvider
        self.removeDownload = removeDownload

        let center = NotificationCenter.default
        center.addObserver(forName: .playlistItemsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconcile() }
        }
        center.addObserver(forName: .accountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelScheduledReconcile() }
        }
    }

    // MARK: - Scheduling

    /// Reconciles shortly after the current burst of changes settles.
    ///
    /// A catalog sync rewrites every playlist in turn and posts once per playlist;
    /// reconciling on each would re-walk the whole library that many times.
    public func scheduleReconcile() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconcileTask = nil
            await self.reconcile()
        }
    }

    private func cancelScheduledReconcile() {
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    // MARK: - Reconcile

    /// Brings local files in line with the playlists marked `keepDownloaded`: queues
    /// anything missing, and drops files kept only for a playlist that no longer wants them.
    public func reconcile() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        guard let repository = repositoryProvider(),
              let account = accountProvider(),
              let playlists = try? repository.fetchPlaylists(account: account)
        else { return }

        var wantedSongIds: Set<String> = []
        for playlist in playlists where playlist.keepDownloaded {
            for song in playlist.items.compactMap(\.song) {
                wantedSongIds.insert(song.remoteId)
                guard !song.isDownloadedLocally else { continue }
                await enqueue(song: song, repository: repository)
            }
        }

        await dropOrphanedPlaylistDownloads(
            keeping: wantedSongIds,
            account: account,
            repository: repository
        )
    }

    /// Pulls the current track list for every downloaded playlist, then reconciles.
    ///
    /// The catalog endpoints (`getPlaylists`, Ampache's `playlists`) usually answer with
    /// metadata and no track ids, so a background sync on its own never learns that a song
    /// was added. Without this pull the reconcile would compare against a stale local list
    /// and find nothing to do.
    public func refreshAndReconcile() async {
        if let syncer = syncerProvider(),
           let repository = repositoryProvider(),
           let account = accountProvider(),
           let playlists = try? repository.fetchPlaylists(account: account) {
            for playlist in playlists where playlist.keepDownloaded {
                try? await syncer.syncPlaylistDown(id: playlist.remoteId)
            }
            repository.context.processPendingChanges()
        }
        await reconcile()
    }

    /// Re-queues downloads the library still wants but has no file for.
    ///
    /// The pending queue lives in `DownloadManager`, which is memory only. It needs no
    /// store of its own: a song already records the intent (`cacheReasonRaw`) apart from
    /// the completion (`relFilePath`), so anything wanted without a file is exactly a
    /// download that was interrupted or is still waiting for Wi-Fi.
    public func resumePending() async {
        guard let repository = repositoryProvider(), let account = accountProvider() else { return }
        let none = CacheReason.none.rawValue
        let descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.relFilePath == nil && $0.cacheReasonRaw != none }
        )
        guard let songs = try? repository.context.fetch(descriptor) else { return }
        let accountID = account.persistentModelID
        for song in songs where song.account?.persistentModelID == accountID {
            await downloader.enqueue(playableId: song.remoteId, kind: .song, reason: song.cacheReason)
        }
    }

    // MARK: - Helpers

    /// Marks a song as wanted for a downloaded playlist and queues it. A song already kept
    /// for another reason — downloaded by hand, a favorite — keeps that reason, so turning
    /// the playlist off later can tell which files it is entitled to delete.
    private func enqueue(song: Song, repository: LibraryRepository) async {
        if song.cacheReason == .none {
            song.cacheReason = .playlistCache
            song.isUserPinned = true
            song.cacheTouchedDate = .now
            try? repository.save()
        }
        await downloader.enqueue(playableId: song.remoteId, kind: .song, reason: song.cacheReason)
    }

    /// Deletes files held only by `playlistCache` for songs no downloaded playlist claims
    /// any more — a track dropped from the playlist upstream, or a playlist whose flag was
    /// turned off while the app wasn't running.
    private func dropOrphanedPlaylistDownloads(
        keeping wantedSongIds: Set<String>,
        account: Account,
        repository: LibraryRepository
    ) async {
        let playlistCache = CacheReason.playlistCache.rawValue
        let descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.cacheReasonRaw == playlistCache }
        )
        guard let songs = try? repository.context.fetch(descriptor) else { return }
        let accountID = account.persistentModelID
        for song in songs
        where song.account?.persistentModelID == accountID && !wantedSongIds.contains(song.remoteId) {
            await removeDownload(song)
        }
    }
}
