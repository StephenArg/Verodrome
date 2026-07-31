import Foundation
import SwiftData

/// Best-effort pruning of local entities that no longer appear in a remote id set.
@MainActor
public enum LibraryPruner {
    /// Removes albums (and their uncached songs) whose remote ids are absent from `remoteAlbumIds`.
    /// Skips songs that are downloaded or user-pinned.
    public static func pruneAlbums(
        account: Account,
        keepingRemoteIds remoteAlbumIds: Set<String>,
        context: ModelContext
    ) throws -> Int {
        let accountID = account.persistentModelID
        let albums = try context.fetch(FetchDescriptor<Album>()).filter {
            $0.account?.persistentModelID == accountID
        }
        var removed = 0
        for album in albums where !remoteAlbumIds.contains(album.remoteId) {
            let keepSongs = album.songs.filter { $0.relFilePath != nil || $0.isUserPinned || $0.cacheReason == .userDownload }
            if !keepSongs.isEmpty { continue }
            for song in album.songs {
                context.delete(song)
            }
            context.delete(album)
            removed += 1
        }
        if removed > 0 { try context.save() }
        return removed
    }

    /// Removes playlists whose remote ids are absent from `remotePlaylistIds`.
    public static func prunePlaylists(
        account: Account,
        keepingRemoteIds remotePlaylistIds: Set<String>,
        context: ModelContext
    ) throws -> Int {
        let accountID = account.persistentModelID
        let playlists = try context.fetch(FetchDescriptor<Playlist>()).filter {
            $0.account?.persistentModelID == accountID
        }
        var removed = 0
        for playlist in playlists where !remotePlaylistIds.contains(playlist.remoteId) {
            context.delete(playlist)
            removed += 1
        }
        if removed > 0 { try context.save() }
        return removed
    }
}
