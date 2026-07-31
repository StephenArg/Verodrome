import Foundation

public enum ThemePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum ArtworkDownloadSetting: String, Codable, CaseIterable, Sendable {
    case never
    case wifiOnly
    case always
}

public enum CacheReason: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case queuePrefetch = 1
    case userDownload = 2
    case autoFavorite = 3
    case playlistCache = 4
    case autoNewest = 5

    /// Files with these reasons survive queue-window pruning.
    public var isUserPinnedReason: Bool {
        switch self {
        case .userDownload, .autoFavorite, .playlistCache, .autoNewest:
            return true
        case .none, .queuePrefetch:
            return false
        }
    }
}

/// Configurable library navigator categories (tabs / sidebar).
public enum LibraryCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case artists
    case albums
    case songs
    case genres
    case directories
    case playlists
    case podcasts
    case downloads
    case favoriteSongs
    case favoriteAlbums
    case favoriteArtists
    case newestAlbums
    case recentAlbums
    case radios

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .directories: "Directories"
        case .playlists: "Playlists"
        case .podcasts: "Podcasts"
        case .downloads: "Downloads"
        case .favoriteSongs: "Favorite Songs"
        case .favoriteAlbums: "Favorite Albums"
        case .favoriteArtists: "Favorite Artists"
        case .newestAlbums: "Newest Albums"
        case .recentAlbums: "Recently Played Albums"
        case .radios: "Radios"
        }
    }

    public var systemImage: String {
        switch self {
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .directories: "folder"
        case .playlists: "list.bullet"
        case .podcasts: "headphones"
        case .downloads: "arrow.down.circle"
        case .favoriteSongs, .favoriteAlbums, .favoriteArtists: "heart.fill"
        case .newestAlbums: "sparkles"
        case .recentAlbums: "clock"
        case .radios: "dot.radiowaves.left.and.right"
        }
    }

    public static let defaultVisible: [LibraryCategory] = [
        .artists, .albums, .newestAlbums, .recentAlbums, .songs,
        .favoriteSongs, .directories, .playlists, .podcasts, .radios
    ]
}

public enum PlayerDisplayStyle: String, Codable, CaseIterable, Sendable {
    case compact
    case standard
    case expanded
}

public enum LibraryDisplayType: String, Codable, CaseIterable, Sendable {
    case grid
    case list
    case table
}

public enum HomeSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case recentlyPlayed
    case recentlyAdded
    case favorites
    case playlists
    case podcasts
    case radios
    case genres
    case randomAlbums

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .recentlyAdded: "Recently Added"
        case .favorites: "Favorites"
        case .playlists: "Playlists"
        case .podcasts: "Podcasts"
        case .radios: "Radios"
        case .genres: "Genres"
        case .randomAlbums: "Random Albums"
        }
    }
}

public enum StreamFormatPreference: String, Codable, CaseIterable, Sendable {
    case original
    case mp3
    case aac
    case opus
    case flac
}

public enum SortDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

public enum ArtistSortField: String, Codable, CaseIterable, Sendable {
    case name
    case recentlyAdded
    case playCount
}

public enum AlbumSortField: String, Codable, CaseIterable, Sendable {
    case title
    case artist
    case year
    case recentlyAdded
    case playCount
}

public enum SongSortField: String, Codable, CaseIterable, Sendable {
    case title
    case artist
    case album
    case track
    case duration
    case recentlyAdded
    case playCount
    case rating
}

public enum PlaylistSortField: String, Codable, CaseIterable, Sendable {
    case name
    case recentlyModified
    case songCount
}

public enum RemoteItemStatus: Int, Codable, CaseIterable, Sendable {
    case available = 0
    case missing = 1
    case deleted = 2
}

public enum LogLevelRaw: String, Codable, Sendable {
    case debug, info, warning, error
}
