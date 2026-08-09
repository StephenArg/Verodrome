import Foundation
import SwiftData

/// High-level library mutations for UI (favorite, rating, download, playlists).
@MainActor
public final class LibraryActions {
    public static let shared = LibraryActions()

    private var kit: VerodromeKit { .shared }
    private var syncer: (any LibrarySyncer)? { kit.activeLibrarySyncer }
    private var repository: LibraryRepository? { kit.repository() }
    private var downloader: DownloadManager? { kit.downloadManager }

    private init() {}

    // MARK: - Favorite / Rating

    public func setFavorite(song: Song, isFavorite: Bool) async throws {
        if let syncer {
            try await syncer.setFavorite(playableId: song.remoteId, isFavorite: isFavorite)
        }
        song.isFavorite = isFavorite
        song.updatedAt = .now
        try repository?.save()
    }

    public func toggleFavorite(song: Song) async throws {
        try await setFavorite(song: song, isFavorite: !song.isFavorite)
    }

    public func setRating(song: Song, rating: Int) async throws {
        let clamped = max(0, min(5, rating))
        if let syncer {
            try await syncer.setRating(playableId: song.remoteId, rating: clamped)
        }
        song.rating = clamped
        song.updatedAt = .now
        try repository?.save()
    }

    public func setFavorite(album: Album, isFavorite: Bool) async throws {
        if let syncer {
            try await syncer.setFavorite(entityId: album.remoteId, type: .album, isFavorite: isFavorite)
        }
        album.isFavorite = isFavorite
        album.updatedAt = .now
        try repository?.save()
    }

    public func toggleFavorite(album: Album) async throws {
        try await setFavorite(album: album, isFavorite: !album.isFavorite)
    }

    public func setRating(album: Album, rating: Int) async throws {
        let clamped = max(0, min(5, rating))
        if let syncer {
            try await syncer.setRating(entityId: album.remoteId, type: .album, rating: clamped)
        }
        album.rating = clamped
        album.updatedAt = .now
        try repository?.save()
    }

    /// Counts a play locally as soon as it scrobbles.
    ///
    /// Servers report `playCount` back on the next library sync, which can be hours
    /// away, and some backends never report it at all — so without this the Plays
    /// ordering sorts a column that stays at zero.
    public func recordPlay(playableId: String) {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account)
        else { return }
        song.playCount += 1
        song.lastPlayedDate = .now
        song.updatedAt = .now
        try? repository.save()
    }

    // MARK: - Download

    /// Marks the song as wanted offline and queues the transfer. `relFilePath` — and
    /// therefore `isDownloadedLocally` — is only written once the bytes land.
    ///
    /// When downloads are Wi-Fi only, the transfer waits until an unmetered connection
    /// unless `force` is true ("Download Now" on a waiting track).
    public func download(song: Song, force: Bool = false) async {
        song.cacheReason = .userDownload
        song.isUserPinned = true
        song.cacheTouchedDate = .now
        try? repository?.save()
        await downloader?.enqueue(
            playableId: song.remoteId,
            kind: .song,
            reason: .userDownload,
            force: force
        )
    }

    public func cancelDownload(song: Song) async {
        await downloader?.cancel(playableId: song.remoteId)
        song.cacheReason = .none
        song.isUserPinned = false
        try? repository?.save()
    }

    /// Cancels any transfer, deletes the cached file, and clears the library's record.
    public func removeDownload(song: Song) async {
        await downloader?.cancel(playableId: song.remoteId)
        try? kit.playableCache?.deletePlayable(id: song.remoteId, kind: .song)
        // `cancel` clears the in-flight state but not a finished one; without this the
        // row keeps the downloaded glyph from `completedIds` for the rest of the session.
        DownloadCenter.shared.clearActive(playableId: song.remoteId)
        song.cacheReason = .none
        song.isUserPinned = false
        song.relFilePath = nil
        song.cacheTouchedDate = nil
        try? repository?.save()
    }

    /// Toggle used by row menus and swipe actions: cancel while working, retry after a
    /// failure, remove once downloaded, otherwise start.
    public func downloadOrCancel(song: Song) async {
        if DownloadCenter.shared.isWorking(on: song.remoteId) {
            await cancelDownload(song: song)
        } else if DownloadCenter.shared.deferredIds.contains(song.remoteId) {
            // Waiting on Wi-Fi. Asking again means "now", not "never".
            await download(song: song, force: true)
        } else if DownloadCenter.shared.failedIds.contains(song.remoteId) {
            await download(song: song)
        } else if song.isDownloadedLocally || song.isDownloadRequested {
            await removeDownload(song: song)
        } else {
            await download(song: song)
        }
    }

    // MARK: - Bulk download

    /// Downloads every song that isn't already on disk. Songs already downloaded are
    /// re-pinned rather than re-fetched, so a partial album finishes cleanly.
    public func downloadRemaining(songs: [Song]) async {
        for song in songs where !song.isDownloadedLocally {
            await download(song: song)
        }
    }

    public func removeDownloads(songs: [Song]) async {
        for song in songs where song.isDownloadedLocally || song.isDownloadRequested {
            await removeDownload(song: song)
        }
    }

    public func cancelDownloads(songs: [Song]) async {
        let center = DownloadCenter.shared
        for song in songs
        where center.isWorking(on: song.remoteId) || center.deferredIds.contains(song.remoteId) {
            await cancelDownload(song: song)
        }
    }

    // MARK: - Playlist downloads

    /// Marks a playlist to be kept on disk, tracks and all, including any added later.
    ///
    /// Turning it off deletes the files this playlist was the reason for. Songs held for
    /// another reason — downloaded by hand, or in a second playlist that is still kept —
    /// are left alone, so untoggling one playlist can't take a download the user asked for
    /// somewhere else with it.
    public func setKeepDownloaded(_ keep: Bool, for playlist: Playlist) async {
        playlist.keepDownloaded = keep
        playlist.updatedAt = .now
        try? repository?.save()

        if keep {
            await kit.playlistDownloads?.reconcile()
            return
        }

        let songs = playlist.items.compactMap(\.song)
        await cancelDownloads(songs: songs)
        let stillWanted = songIdsKeptByDownloadedPlaylists(excluding: playlist)
        for song in songs
        where song.cacheReason == .playlistCache && !stillWanted.contains(song.remoteId) {
            await removeDownload(song: song)
        }
    }

    /// Remote ids covered by the other playlists still marked `keepDownloaded`.
    private func songIdsKeptByDownloadedPlaylists(excluding playlist: Playlist) -> Set<String> {
        guard let repository,
              let account = try? kit.activeAccount(),
              let playlists = try? repository.fetchPlaylists(account: account)
        else { return [] }
        var ids: Set<String> = []
        for other in playlists
        where other.keepDownloaded && other.compoundRemoteId != playlist.compoundRemoteId {
            for song in other.items.compactMap(\.song) {
                ids.insert(song.remoteId)
            }
        }
        return ids
    }

    /// The reason the library has on record for a song it believes is on disk, if any.
    /// Lets the orphan sweep tell a lost cache-metadata entry from a file nothing wants.
    public func recordedCacheReason(playableId: String) -> CacheReason? {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account),
              song.relFilePath != nil
        else { return nil }
        return song.cacheReason
    }

    /// Clears the library's record of a local file after the cache dropped it, so
    /// `isDownloadedLocally` can never outlive the bytes it describes.
    public func forgetLocalFile(playableId: String) {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account),
              song.relFilePath != nil
        else { return }
        song.relFilePath = nil
        song.cacheTouchedDate = nil
        if !song.isUserPinned { song.cacheReason = .none }
        try? repository.save()
    }

    // MARK: - Queue helpers

    /// Queues for a single listen: the row leaves the queue once playback moves past it.
    public func addToQueue(song: Song) {
        kit.player?.enqueueEphemeral([QueueItem.from(song)])
    }

    public func addToQueue(episode: PodcastEpisode) {
        kit.player?.enqueueEphemeral([QueueItem.from(episode)])
    }

    // MARK: - Playlists

    @discardableResult
    public func createPlaylist(name: String) async throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryRepositoryError.entityNotFound }
        guard let repository, let account = try kit.activeAccount() else {
            throw LibraryRepositoryError.accountNotFound
        }

        var remoteId = UUID().uuidString
        if let syncer {
            remoteId = try await syncer.createPlaylist(name: trimmed)
        }
        return try repository.getOrCreatePlaylist(remoteId: remoteId, name: trimmed, account: account)
    }

    public func renamePlaylist(_ playlist: Playlist, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let syncer {
            try await syncer.renamePlaylist(id: playlist.remoteId, name: trimmed)
        }
        playlist.name = trimmed
        playlist.sortName = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        playlist.updatedAt = .now
        try repository?.save()
    }

    public func addSongs(_ songs: [Song], to playlist: Playlist) async throws {
        guard !songs.isEmpty else { return }
        if let syncer {
            try await syncer.addToPlaylist(playlistId: playlist.remoteId, songIds: songs.map(\.remoteId))
        }
        var existing = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let existingIds = Set(existing.map(\.compoundRemoteId))
        for song in songs where !existingIds.contains(song.compoundRemoteId) {
            existing.append(song)
        }
        try repository?.replacePlaylistItems(playlist, with: existing)
        if let syncer {
            // Reconcile with the server. updatePlaylist used to return ok while ignoring
            // our song ids (wrong query encoding); without this pull the local rewrite
            // was the only "proof" the add worked.
            try await syncer.syncPlaylistDown(id: playlist.remoteId)
            kit.storage?.mainContext.processPendingChanges()
        }
    }

    /// Playlists the server refused to change during this run.
    ///
    /// Deliberately not persisted. It is an inference drawn from one failure, and a wrong
    /// one written to the store would keep hiding a perfectly editable playlist long after
    /// the cause was gone. Losing it at launch costs at most one repeated error message.
    public private(set) var playlistsRejectedByServer: Set<String> = []

    /// Records that the server refused to edit this playlist.
    ///
    /// An older Navidrome reports nothing that identifies a smart playlist, so a rejection
    /// is the only signal there is. Someone else's playlist is refused the same way and the
    /// two are indistinguishable from here, which is why this claims nothing beyond "this
    /// server would not accept the change".
    ///
    /// Returns true when `error` came from the server rather than the network, since a
    /// dropped connection says nothing about whether the playlist can be edited.
    @discardableResult
    public func notePlaylistEditRejected(_ playlist: Playlist, error: any Error) -> Bool {
        guard let parseError = error as? XmlParseError, case .serverError = parseError else { return false }
        playlistsRejectedByServer.insert(playlist.remoteId)
        // The membership index only counts playlists that can be edited, so this changes
        // the answer it should be giving.
        NotificationCenter.default.post(name: .playlistItemsChanged, object: nil)
        return true
    }

    /// Removes every entry for `song` from `playlist`.
    ///
    /// The server addresses entries by position, so the local order is refreshed first —
    /// acting on a stale copy would delete whatever track happens to sit at that index now.
    public func removeSong(_ song: Song, from playlist: Playlist) async throws {
        if let syncer {
            try? await syncer.syncPlaylistDown(id: playlist.remoteId)
        }
        let ordered = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let indices = ordered.indices.filter { ordered[$0].remoteId == song.remoteId }
        guard !indices.isEmpty else { return }
        try await removeSongs(at: indices, from: playlist)
    }

    public func removeSongs(at entryIndices: [Int], from playlist: Playlist) async throws {
        if let syncer {
            try await syncer.removeFromPlaylist(playlistId: playlist.remoteId, entryIndices: entryIndices)
        }
        var songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        for index in entryIndices.sorted(by: >) where songs.indices.contains(index) {
            songs.remove(at: index)
        }
        try repository?.replacePlaylistItems(playlist, with: songs)
    }

    /// Replaces the playlist's song order on the server, then mirrors it locally.
    public func reorderPlaylist(_ playlist: Playlist, songs: [Song]) async throws {
        if let syncer {
            try await syncer.reorderPlaylist(playlistId: playlist.remoteId, songIds: songs.map(\.remoteId))
        }
        try repository?.replacePlaylistItems(playlist, with: songs)
        if let syncer {
            // Reorder is clear-then-readd on both backends; pull once so we match the
            // server if it dropped a duplicate or rewrote ids.
            try? await syncer.syncPlaylistDown(id: playlist.remoteId)
            kit.storage?.mainContext.processPendingChanges()
        }
    }
}

// Local helpers for Song download state when used from Kit.
extension Song {
    /// The file is on disk. Written by `DownloadManager` only after the transfer
    /// completes, so this never reports a download that hasn't happened yet.
    public var isDownloadedLocally: Bool { relFilePath != nil }

    /// The user (or an auto-cache rule) asked for this song offline. True from the
    /// moment the download is queued, which is what a cancel/remove action keys off.
    public var isDownloadRequested: Bool { cacheReasonRaw != CacheReason.none.rawValue }
}

extension QueueItem {
    public static func from(_ song: Song) -> QueueItem {
        // Prefer denormalized fields — never fault `album`/`artist` on the play hot path.
        QueueItem(
            playableId: song.remoteId,
            kind: .song,
            title: song.title,
            artistName: song.artistName,
            albumName: song.albumTitle,
            duration: song.playDuration,
            artworkId: song.artworkToken
        )
    }

    public static func from(_ episode: PodcastEpisode) -> QueueItem {
        QueueItem(
            playableId: episode.remoteId,
            kind: .podcastEpisode,
            title: episode.title,
            artistName: episode.podcast?.title,
            albumName: episode.podcast?.title,
            duration: episode.playDuration,
            artworkId: episode.podcast?.artworkToken
        )
    }
}
