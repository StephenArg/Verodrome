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

    public func download(song: Song) async {
        await downloader?.enqueue(playableId: song.remoteId, kind: .song, reason: .userDownload)
        song.cacheReason = .userDownload
        song.cacheTouchedDate = .now
        try? repository?.save()
    }

    public func cancelDownload(song: Song) async {
        await downloader?.cancel(playableId: song.remoteId)
    }

    public func downloadOrCancel(song: Song) async {
        if song.isDownloadedLocally || song.cacheReason != .none {
            await cancelDownload(song: song)
            song.cacheReason = .none
            song.relFilePath = nil
            try? repository?.save()
        } else {
            await download(song: song)
        }
    }

    // MARK: - Queue helpers

    public func playNext(song: Song) {
        kit.player?.enqueueNext([QueueItem.from(song)])
    }

    public func playNext(episode: PodcastEpisode) {
        kit.player?.enqueueNext([QueueItem.from(episode)])
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
            try? await syncer.syncPlaylistDown(id: playlist.remoteId)
        }
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
}

// Local helpers for Song download state when used from Kit.
extension Song {
    public var isDownloadedLocally: Bool { cacheReasonRaw != CacheReason.none.rawValue || relFilePath != nil }
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
