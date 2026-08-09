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

/// When pinned downloads (albums, playlists, songs, auto-cache) may transfer.
/// Queue-window prefetch is exempt so playback on cellular still works.
public enum AutomaticDownloadNetwork: String, Codable, CaseIterable, Sendable {
    case wifiOnly
    case always

    public var label: String {
        switch self {
        case .wifiOnly: "Only on Wi-Fi"
        case .always: "Always"
        }
    }
}

/// Cap on playable cache size. `0` means unlimited.
public enum PlayableCacheLimit: Int64, Codable, CaseIterable, Sendable, Identifiable {
    case mb250 = 262_144_000
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824
    case gb2 = 2_147_483_648
    case gb3 = 3_221_225_472
    case gb5 = 5_368_709_120
    case gb7 = 7_516_192_768
    case gb10 = 10_737_418_240
    case gb12 = 12_884_901_888
    case gb20 = 21_474_836_480
    case unlimited = 0

    public var id: Int64 { rawValue }

    public static let `default`: PlayableCacheLimit = .gb3

    public var label: String {
        switch self {
        case .mb250: "250 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        case .gb2: "2 GB"
        case .gb3: "3 GB"
        case .gb5: "5 GB"
        case .gb7: "7 GB"
        case .gb10: "10 GB"
        case .gb12: "12 GB"
        case .gb20: "20 GB"
        case .unlimited: "Unlimited"
        }
    }
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

    /// Downloads the app started on its own, which the Wi-Fi-only setting can hold back.
    ///
    /// `queuePrefetch` is excluded: it serves playback the user just started, and holding
    /// it back on cellular would stall streaming rather than save anything they didn't ask for.
    public var isAutomaticReason: Bool {
        switch self {
        case .autoFavorite, .playlistCache, .autoNewest:
            return true
        case .none, .queuePrefetch, .userDownload:
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
    case shared

    public var id: String { rawValue }

    /// Soft cap so tab labels stay readable on phone.
    public static let maxVisible = 5

    public static let defaultVisible: [RootTabItem] = [.search, .home, .library, .downloads]

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
        case .shared: "Shared"
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
        case .shared: "square.and.arrow.up"
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

/// Configurable library hub categories.
public enum LibraryCategory: String, Codable, CaseIterable, Sendable, Identifiable {
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
    case shared

    public var id: String { rawValue }

    public var title: String {
        switch self {
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
        case .shared: "Shared"
        }
    }

    public var systemImage: String {
        switch self {
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
        case .shared: "square.and.arrow.up"
        }
    }

    /// Matches the historical hardcoded library hub order, with newer sections appended.
    public static let defaultVisible: [LibraryCategory] = [
        .artists, .albums, .songs, .genres, .playlists,
        .podcasts, .radios, .downloads, .directories, .favorites, .shared
    ]

    /// Deduplicate and guarantee at least one category.
    public static func normalized(_ categories: [LibraryCategory]) -> [LibraryCategory] {
        var seen = Set<LibraryCategory>()
        var result: [LibraryCategory] = []
        for category in categories where seen.insert(category).inserted {
            result.append(category)
        }
        return result.isEmpty ? defaultVisible : result
    }
}

public enum PlayerDisplayStyle: String, Codable, CaseIterable, Sendable {
    case compact
    case standard
    case expanded
}

public enum LibraryDisplayType: String, Codable, CaseIterable, Sendable {
    case grid3
    case grid2
    case list

    public var displayName: String {
        switch self {
        case .grid3: "Grid (3)"
        case .grid2: "Grid (2)"
        case .list: "List"
        }
    }

    public var systemImage: String {
        switch self {
        case .grid3: "square.grid.3x3"
        case .grid2: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    /// Fixed column count for grid layouts; `nil` means list.
    public var gridColumnCount: Int? {
        switch self {
        case .grid3: 3
        case .grid2: 2
        case .list: nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.grid3.rawValue, "grid": self = .grid3
        case Self.grid2.rawValue: self = .grid2
        case Self.list.rawValue, "table": self = .list
        default: self = .list
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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

    /// Maps legacy streaming-format prefs onto the MP3 bitrate quality model.
    public var asTranscodeQuality: AudioTranscodeQuality {
        switch self {
        case .mp3: .mp3_320
        case .original, .aac, .opus, .flac: .original
        }
    }
}

/// Server-side MP3 transcoding quality for lossless sources (FLAC, WAV, …).
public enum AudioTranscodeQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case mp3_320
    case mp3_256
    case mp3_192

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .mp3_320: "MP3 320 kbps"
        case .mp3_256: "MP3 256 kbps"
        case .mp3_192: "MP3 192 kbps"
        }
    }

    /// Target bitrate in kbps for Subsonic `maxBitRate` / Ampache `bitrate`.
    public var maxBitRate: Int? {
        switch self {
        case .original: nil
        case .mp3_320: 320
        case .mp3_256: 256
        case .mp3_192: 192
        }
    }

    public var streamFormat: StreamFormat? {
        switch self {
        case .original: nil
        case .mp3_320, .mp3_256, .mp3_192: .mp3
        }
    }
}

/// Decides whether a play/download request should ask the server to transcode.
public enum AudioTranscodeResolver {
    private static let losslessTokens: Set<String> = [
        "flac", "wav", "wave", "aiff", "aif", "alac", "ape", "wv", "dsf", "dff",
        "pcm", "tak", "tta", "wvc", "audio/flac", "audio/x-flac", "audio/wav",
        "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/x-alac", "audio/ape",
        "audio/x-ape", "audio/x-wavpack",
    ]

    public static func isLossless(contentType: String?) -> Bool {
        guard let raw = contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let lowered = raw.lowercased()
        if losslessTokens.contains(lowered) { return true }
        if let mimeSubtype = lowered.split(separator: "/").last,
           losslessTokens.contains(String(mimeSubtype)) || losslessTokens.contains("audio/\(mimeSubtype)") {
            return true
        }
        if let ext = lowered.split(separator: ".").last, losslessTokens.contains(String(ext)) {
            return true
        }
        return false
    }

    /// Returns API params only when quality asks for MP3 and the source is lossless.
    public static func resolve(
        quality: AudioTranscodeQuality,
        contentType: String?
    ) -> (maxBitRate: Int?, format: StreamFormat?) {
        guard quality != .original, isLossless(contentType: contentType) else {
            return (nil, nil)
        }
        return (quality.maxBitRate, quality.streamFormat)
    }
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
    /// Smart playlists A–Z#, then regular playlists A–Z#.
    case smartPlaylistsFirst

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
        case .smartPlaylistsFirst: "Smart Playlists"
        }
    }

    /// Alphabetical options get letter headers and the A–Z scrubber; the rest render
    /// as one flat list.
    public var isAlphabetical: Bool {
        switch self {
        case .titleAZ, .titleZA, .titleSymbolsFirst: true
        case .durationLongest, .durationShortest, .ratingHighest, .playsMost, .smartPlaylistsFirst:
            false
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

    /// Playlists also offer grouping smart lists ahead of regular ones.
    public static let playlistOptions: [LibrarySortOption] = titleOptions + [.smartPlaylistsFirst]
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
