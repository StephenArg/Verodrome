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

/// Items that can appear in the phone tab bar / iPad sidebar.
public enum RootTabItem: String, Codable, CaseIterable, Sendable, Identifiable {
    case search
    case home
    case library
    case settings
    case artists
    case albums
    case songs
    case genres
    case playlists
    case podcasts
    case radios
    case downloads
    case directories
    case favorites

    public var id: String { rawValue }

    /// Soft cap so tab labels stay readable on phone.
    public static let maxVisible = 5

    public static let defaultVisible: [RootTabItem] = [.search, .home, .library]

    public var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .library: "Library"
        case .settings: "Settings"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .podcasts: "Podcasts"
        case .radios: "Radios"
        case .downloads: "Downloads"
        case .directories: "Directories"
        case .favorites: "Favorites"
        }
    }

    public var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house.fill"
        case .library: "square.stack.fill"
        case .settings: "gearshape.fill"
        case .artists: "person.2.fill"
        case .albums: "square.stack.fill"
        case .songs: "music.note.list"
        case .genres: "guitars.fill"
        case .playlists: "music.note.house.fill"
        case .podcasts: "mic.fill"
        case .radios: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle.fill"
        case .directories: "folder.fill"
        case .favorites: "heart.fill"
        }
    }

    /// Deduplicate, clamp to `maxVisible`, and guarantee at least one tab.
    public static func normalized(_ tabs: [RootTabItem]) -> [RootTabItem] {
        var seen = Set<RootTabItem>()
        var result: [RootTabItem] = []
        for tab in tabs where seen.insert(tab).inserted {
            result.append(tab)
            if result.count >= maxVisible { break }
        }
        return result.isEmpty ? defaultVisible : result
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

/// A user-selectable ordering for a library list.
///
/// One option drives the fetch's sort descriptors, its head-page predicate and the
/// section ordering together. Those three have to agree: the two-phase load draws a
/// limited head page first, which is only the visual top of the list if the rows the
/// store returns first are also the rows displayed first.
public enum LibrarySortOption: String, Codable, CaseIterable, Sendable, Identifiable {
    case titleAZ
    case titleZA
    case titleSymbolsFirst
    case durationLongest
    case durationShortest
    case ratingHighest
    case playsMost

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .titleAZ: "A-Z#"
        case .titleZA: "Z-A#"
        case .titleSymbolsFirst: "#A-Z"
        case .durationLongest: "Longest to shortest"
        case .durationShortest: "Shortest to longest"
        case .ratingHighest: "Rating (high to low)"
        case .playsMost: "Plays (high to low)"
        }
    }

    /// Alphabetical options get letter headers and the A–Z scrubber; the rest render
    /// as one flat list.
    public var isAlphabetical: Bool {
        switch self {
        case .titleAZ, .titleZA, .titleSymbolsFirst: true
        case .durationLongest, .durationShortest, .ratingHighest, .playsMost: false
        }
    }

    public var sortsTitleDescending: Bool { self == .titleZA }

    /// Whether the digit and punctuation sections lead the list.
    public var showsSymbolsFirst: Bool { self == .titleSymbolsFirst }

    /// The orderings every library screen offers.
    public static let titleOptions: [LibrarySortOption] = [.titleAZ, .titleZA, .titleSymbolsFirst]

    public static let albumOptions: [LibrarySortOption] = titleOptions + [.ratingHighest]

    public static let songOptions: [LibrarySortOption] =
        titleOptions + [.durationLongest, .durationShortest, .ratingHighest, .playsMost]
}

/// Per-screen sort choices. Grouped into one value so the settings snapshot needs a
/// single field rather than one per library screen.
public struct LibrarySortSelection: Codable, Sendable, Equatable {
    public var artists: LibrarySortOption
    public var albums: LibrarySortOption
    public var songs: LibrarySortOption
    public var genres: LibrarySortOption
    public var playlists: LibrarySortOption

    public init(
        artists: LibrarySortOption = .titleAZ,
        albums: LibrarySortOption = .titleAZ,
        songs: LibrarySortOption = .titleAZ,
        genres: LibrarySortOption = .titleAZ,
        playlists: LibrarySortOption = .titleAZ
    ) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
        self.genres = genres
        self.playlists = playlists
    }

    public static let `default` = LibrarySortSelection()
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
