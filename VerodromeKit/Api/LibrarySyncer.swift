import Foundation

public enum LibrarySyncerError: Error, Sendable, LocalizedError {
    case offline
    case cancelled
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "Network is unavailable."
        case .cancelled:
            return "Sync was cancelled."
        case .server(let message):
            return message
        }
    }
}

/// Library synchronization and mutation operations for the active backend.
public protocol LibrarySyncer: Sendable {
    /// Full sync: catalog then all tracks (used by manual "Sync Now").
    func syncInitial(progress: @escaping @Sendable (String) -> Void) async throws

    /// Fast catalog: genres (when available), artists, album list, playlists, podcast channels.
    /// Wraps beginSync/finishSync so album + playlist pruning still runs.
    func syncCatalog(progress: @escaping @Sendable (String) -> Void) async throws

    /// Deep / expensive track backfill. Does not begin/finish sync (no pruning).
    func syncAllSongs(progress: @escaping @Sendable (String) -> Void) async throws

    func sync(albumId: String) async throws
    func sync(artistId: String) async throws
    func sync(playlistId: String) async throws
    func sync(podcastId: String) async throws

    /// Fetches newest albums, ingests them (with tracks when available), and returns song remote ids.
    @discardableResult
    func syncNewestAlbums(limit: Int) async throws -> [String]

    /// Fetches recently played albums from the server and updates local recent ranks for Home.
    @discardableResult
    func syncRecentAlbums(limit: Int) async throws -> [String]

    /// Refreshes favorite albums from the server (Subsonic getStarred2 / Ampache flagged).
    func syncFavoriteAlbums() async throws

    func searchArtists(query: String) async throws -> [SearchArtist]
    func searchAlbums(query: String) async throws -> [SearchAlbum]
    func searchSongs(query: String) async throws -> [SearchSong]

    func setFavorite(playableId: String, isFavorite: Bool) async throws
    func setRating(playableId: String, rating: Int) async throws

    func scrobble(playableId: String, timestamp: Date, duration: TimeInterval?) async throws
    func reportNowPlaying(playableId: String, position: TimeInterval) async throws

    func createPlaylist(name: String) async throws -> String
    func renamePlaylist(id: String, name: String) async throws
    func addToPlaylist(playlistId: String, songIds: [String]) async throws
    func removeFromPlaylist(playlistId: String, entryIndices: [Int]) async throws
    func reorderPlaylist(playlistId: String, songIds: [String]) async throws
    func syncPlaylistDown(id: String) async throws

    func syncPodcasts() async throws

    /// Refreshes the playlist catalog and returns the remote playlist ids currently on the server.
    @discardableResult
    func syncPlaylistCatalog() async throws -> [String]

    func listMusicFolders() async throws -> [RemoteMusicFolder]
    func listMusicDirectory(folderId: String?) async throws -> [DirectoryEntry]
}
