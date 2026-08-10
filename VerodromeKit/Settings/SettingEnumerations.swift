import Foundation

public enum ThemePreference: String, Codable, CaseIterable, Sendable {
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

/// How far into a track a play has to get before it is reported to the server.
///
/// The threshold is also what marks the play locally, so `never` leaves both the server
/// and this device's play counts untouched.
public enum ScrobbleTiming: String, Codable, CaseIterable, Sendable, Identifiable {
    case never
    case onStart
    case quarter
    /// Half the track or four minutes, whichever comes first (the Last.fm rule).
    case standard
    case threeQuarters
    case onFinish

    public var id: String { rawValue }

    public static let `default`: ScrobbleTiming = .standard

    public var displayName: String {
        switch self {
        case .never: "Never"
        case .onStart: "When Playback Starts"
        case .quarter: "At 25%"
        case .standard: "Halfway or 4 Minutes"
        case .threeQuarters: "At 75%"
        case .onFinish: "When the Track Ends"
        }
    }

    /// Elapsed time at which a play of `duration` qualifies, or `nil` to never report.
    public func threshold(forDuration duration: TimeInterval) -> TimeInterval? {
        switch self {
        case .never: nil
        case .onStart: 0
        case .quarter: duration * 0.25
        // Playback usually advances to the next track before the clock reaches the full
        // duration, so "the end" has to be a shade early or it would never be reached.
        case .onFinish: max(0, duration - 1)
        case .standard: min(duration * 0.5, 4 * 60)
        case .threeQuarters: duration * 0.75
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

public enum LibraryDisplayType: String, Codable, CaseIterable, Sendable {
    case grid3
    case grid3NoText
    case grid2
    case grid2NoText
    case list

    public var displayName: String {
        switch self {
        case .grid3: "Grid (3)"
        case .grid3NoText: "Grid (3) - No text"
        case .grid2: "Grid (2)"
        case .grid2NoText: "Grid (2) - No text"
        case .list: "List"
        }
    }

    public var systemImage: String {
        switch self {
        case .grid3: "square.grid.3x3"
        case .grid3NoText: "square.grid.3x3.fill"
        case .grid2: "square.grid.2x2"
        case .grid2NoText: "square.grid.2x2.fill"
        case .list: "list.bullet"
        }
    }

    /// Fixed column count for grid layouts; `nil` means list.
    public var gridColumnCount: Int? {
        switch self {
        case .grid3, .grid3NoText: 3
        case .grid2, .grid2NoText: 2
        case .list: nil
        }
    }

    /// Whether album grid cells show title and artist under the artwork.
    public var showsGridText: Bool {
        switch self {
        case .grid3, .grid2: true
        case .grid3NoText, .grid2NoText, .list: false
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.grid3.rawValue, "grid": self = .grid3
        case Self.grid3NoText.rawValue: self = .grid3NoText
        case Self.grid2.rawValue: self = .grid2
        case Self.grid2NoText.rawValue: self = .grid2NoText
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

    /// On-disk name suffix so original and MP3 variants can coexist in the playable cache.
    public var cacheFileName: String? {
        switch self {
        case .original: nil
        case .mp3_320: "mp3.320"
        case .mp3_256: "mp3.256"
        case .mp3_192: "mp3.192"
        }
    }

    public static func from(format: StreamFormat, maxBitrate: Int?) -> AudioTranscodeQuality {
        guard format == .mp3, let maxBitrate else { return .original }
        switch maxBitrate {
        case 320: return .mp3_320
        case 256: return .mp3_256
        case 192: return .mp3_192
        default:
            if maxBitrate >= 288 { return .mp3_320 }
            if maxBitrate >= 224 { return .mp3_256 }
            return .mp3_192
        }
    }

    /// Strips a known quality suffix from a cache file name, returning the playable id.
    public static func playableId(fromCacheFileName name: String) -> String {
        for quality in allCases where quality != .original {
            if let suffix = quality.cacheFileName, name.hasSuffix(".\(suffix)") {
                return String(name.dropLast(suffix.count + 1))
            }
        }
        return name
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

    private static let lossyTokens: Set<String> = [
        "mp3", "mpeg", "mpga", "aac", "mp4", "m4a", "x-m4a", "opus", "x-opus",
        "ogg", "vorbis", "x-vorbis", "wma", "x-ms-wma",
        "audio/mpeg", "audio/mp3", "audio/aac", "audio/mp4", "audio/x-m4a",
        "audio/ogg", "audio/opus", "audio/vorbis",
    ]

    public static func isLossless(contentType: String?) -> Bool {
        matches(contentType, tokens: losslessTokens)
    }

    public static func isKnownLossy(contentType: String?) -> Bool {
        matches(contentType, tokens: lossyTokens)
    }

    /// Returns API params when the user chose an MP3 quality.
    ///
    /// Known lossy sources are left alone so we do not re-encode MP3/AAC/Opus.
    /// Lossless *and* unknown formats (missing library metadata) request a transcode —
    /// the server knows the real codec and must not be blocked by a nil local `contentType`.
    public static func resolve(
        quality: AudioTranscodeQuality,
        contentType: String?
    ) -> (maxBitRate: Int?, format: StreamFormat?) {
        guard quality != .original else { return (nil, nil) }
        if isKnownLossy(contentType: contentType) { return (nil, nil) }
        return (quality.maxBitRate, quality.streamFormat)
    }

    /// On-disk quality key for a completed transfer. Lossy sources (and `.original`)
    /// land under `.original`; only an actual MP3 request uses the bitrate suffix.
    public static func storageQuality(
        requested: AudioTranscodeQuality,
        contentType: String?
    ) -> AudioTranscodeQuality {
        resolve(quality: requested, contentType: contentType).format == nil ? .original : requested
    }

    private static func matches(_ contentType: String?, tokens: Set<String>) -> Bool {
        guard let raw = contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let lowered = raw.lowercased()
        if tokens.contains(lowered) { return true }
        if let mimeSubtype = lowered.split(separator: "/").last {
            let subtype = String(mimeSubtype)
            if tokens.contains(subtype) || tokens.contains("audio/\(subtype)") { return true }
        }
        if let ext = lowered.split(separator: ".").last, tokens.contains(String(ext)) {
            return true
        }
        return false
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
    /// Albums ranked by the server's newest list (`Album.newestIndex`, 1 = newest).
    case recentlyAdded
    /// Stable pseudo-random order for the current shuffle seed.
    case random

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
        case .recentlyAdded: "Recently Added"
        case .random: "Random"
        }
    }

    /// Alphabetical options get letter headers and the A–Z scrubber; the rest render
    /// as one flat list.
    public var isAlphabetical: Bool {
        switch self {
        case .titleAZ, .titleZA, .titleSymbolsFirst: true
        case .durationLongest, .durationShortest, .ratingHighest, .playsMost,
             .smartPlaylistsFirst, .recentlyAdded, .random:
            false
        }
    }

    /// Whether a limited head fetch is a true prefix of the final display order.
    /// Random shuffles the full set in memory, so a capped fetch would be wrong.
    public var supportsHeadPage: Bool { self != .random }

    public var sortsTitleDescending: Bool { self == .titleZA }

    /// Whether the digit and punctuation sections lead the list.
    public var showsSymbolsFirst: Bool { self == .titleSymbolsFirst }

    /// The orderings every library screen offers.
    public static let titleOptions: [LibrarySortOption] = [.titleAZ, .titleZA, .titleSymbolsFirst]

    public static let albumOptions: [LibrarySortOption] =
        titleOptions + [.ratingHighest, .recentlyAdded, .random]

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

public enum RemoteItemStatus: Int, Codable, CaseIterable, Sendable {
    case available = 0
    case missing = 1
    case deleted = 2
}

public enum LogLevelRaw: String, Codable, Sendable {
    case debug, info, warning, error
}
