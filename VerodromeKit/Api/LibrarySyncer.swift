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

/// A step in a library sync: what's happening, and how far along the whole sync is.
public struct LibrarySyncProgress: Sendable, Equatable {
    public let message: String
    /// Position across the entire sync, 0...1. Nil when the current step can't size
    /// itself — a skipped phase, or an ingest count arriving mid-crawl.
    public let fraction: Double?

    public init(message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction
    }
}

public typealias LibrarySyncProgressHandler = @Sendable (LibrarySyncProgress) -> Void

/// The two halves of a full sync, and the share of the progress bar each one owns.
///
/// The catalog is a handful of paginated list calls; the track crawl is a request per
/// album (Subsonic) or per page of songs (Ampache) across the whole library, so it
/// dominates the wall clock even though the catalog has more named stages.
public enum LibrarySyncPhase: Sendable {
    case catalog
    case tracks

    var start: Double {
        switch self {
        case .catalog: 0
        case .tracks: 0.15
        }
    }

    var end: Double {
        switch self {
        case .catalog: 0.15
        case .tracks: 1
        }
    }

    /// Maps a 0...1 position within this phase onto the overall bar.
    public func overall(_ positionInPhase: Double) -> Double {
        start + (end - start) * max(0, min(1, positionInPhase))
    }
}

/// Catalog steps, in the order both backends run them.
///
/// Neither backend can know a step's row count before paging through it, so the
/// catalog's share of the bar advances a step at a time rather than a row at a time.
public enum LibrarySyncCatalogStage: Int, Sendable, CaseIterable {
    case genres
    case artists
    case albums
    case playlists
    case podcasts
    case radios

    /// Where this step begins on the overall bar.
    public var fraction: Double {
        LibrarySyncPhase.catalog.overall(Double(rawValue) / Double(Self.allCases.count))
    }
}

/// Library synchronization and mutation operations for the active backend.
public protocol LibrarySyncer: Sendable {
    /// Full sync: catalog then all tracks (used by manual "Sync Now").
    func syncInitial(progress: @escaping LibrarySyncProgressHandler) async throws

    /// Fast catalog: genres (when available), artists, album list, playlists, podcast channels.
    /// Wraps beginSync/finishSync so album + playlist pruning still runs.
    func syncCatalog(progress: @escaping LibrarySyncProgressHandler) async throws

    /// Deep / expensive track backfill. Does not begin/finish sync (no pruning).
    func syncAllSongs(progress: @escaping LibrarySyncProgressHandler) async throws

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
