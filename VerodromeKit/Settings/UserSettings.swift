import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var isOfflineMode: Bool
    public var cacheLimitBytes: Int64
    public var streamingQualityWifi: AudioTranscodeQuality
    public var streamingQualityCellular: AudioTranscodeQuality
    public var downloadTranscodeQuality: AudioTranscodeQuality
    public var smartQueuePrefetchEnabled: Bool
    public var queuePrefetchStaleHours: Int
    /// How many upcoming queue tracks to keep in the temporary prefetch cache (0...10).
    public var queuePrefetchSongsAhead: Int
    /// How many previous queue tracks to keep in the temporary prefetch cache (0...5).
    public var queuePrefetchSongsBehind: Int
    public var scrobbleTiming: ScrobbleTiming
    public var hapticsEnabled: Bool
    public var replayGainEnabled: Bool
    public var equalizerEnabled: Bool
    public var crossfadeEnabled: Bool
    public var crossfadeDurationSeconds: Double
    public var gaplessPlaybackEnabled: Bool
    /// When the queue runs low, append similar-song radio so listening can continue.
    public var radioContinuationEnabled: Bool
    public var showLyricsWhenAvailable: Bool
    /// When the music server has no lyrics, fall back to a lookup on LRCLIB.
    public var lrcLibLyricsEnabled: Bool
    /// Whether the full-screen player shows the lyrics panel in place of the artwork.
    public var showLyricsInPlayer: Bool
    /// How long artwork stays visible before the lyrics crossfade on each track.
    public var lyricsArtworkHold: LyricsArtworkHold
    /// Whether the full-screen player takes its background from the cover's colors.
    public var changingColorsInPlayer: Bool
    public var showRatingStars: Bool
    public var showSongInfo: Bool
    /// Last.fm popular tracks on artist pages, when the library has enough of them.
    public var showArtistTopSongs: Bool
    /// Background fill of Popular lists for likely next artists and the play-queue window.
    public var autoCacheArtistPopularSongs: Bool
    public var equalizerBands: [Float]
    /// Scan lyrics for explicit language when they load.
    public var explicitDetectionEnabled: Bool
    public var explicitSensitivity: LyricsExplicitSensitivity
    public var explicitBlacklistWords: [String]
    public var explicitWhitelistWords: [String]
    /// Bumped when the preset or custom word lists change so stored ratings can go stale.
    public var explicitWordListChangedAt: Date?
    /// Hide songs confirmed explicit from catalog song lists (not albums, playlists, or the queue).
    public var hideExplicitSongs: Bool

    public init(
        isOfflineMode: Bool = false,
        cacheLimitBytes: Int64 = PlayableCacheLimit.default.rawValue,
        streamingQualityWifi: AudioTranscodeQuality = .original,
        streamingQualityCellular: AudioTranscodeQuality = .original,
        downloadTranscodeQuality: AudioTranscodeQuality = .original,
        smartQueuePrefetchEnabled: Bool = true,
        queuePrefetchStaleHours: Int = 18,
        queuePrefetchSongsAhead: Int = 5,
        queuePrefetchSongsBehind: Int = 2,
        scrobbleTiming: ScrobbleTiming = .default,
        hapticsEnabled: Bool = true,
        replayGainEnabled: Bool = false,
        equalizerEnabled: Bool = false,
        crossfadeEnabled: Bool = false,
        crossfadeDurationSeconds: Double = 3,
        gaplessPlaybackEnabled: Bool = true,
        radioContinuationEnabled: Bool = true,
        showLyricsWhenAvailable: Bool = true,
        lrcLibLyricsEnabled: Bool = true,
        showLyricsInPlayer: Bool = false,
        lyricsArtworkHold: LyricsArtworkHold = .default,
        changingColorsInPlayer: Bool = true,
        showRatingStars: Bool = true,
        showSongInfo: Bool = false,
        showArtistTopSongs: Bool = true,
        autoCacheArtistPopularSongs: Bool = true,
        equalizerBands: [Float] = Array(repeating: 0, count: 10),
        explicitDetectionEnabled: Bool = true,
        explicitSensitivity: LyricsExplicitSensitivity = .default,
        explicitBlacklistWords: [String] = [],
        explicitWhitelistWords: [String] = [],
        explicitWordListChangedAt: Date? = nil,
        hideExplicitSongs: Bool = false
    ) {
        self.isOfflineMode = isOfflineMode
        self.cacheLimitBytes = cacheLimitBytes
        self.streamingQualityWifi = streamingQualityWifi
        self.streamingQualityCellular = streamingQualityCellular
        self.downloadTranscodeQuality = downloadTranscodeQuality
        self.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
        self.queuePrefetchStaleHours = queuePrefetchStaleHours
        self.queuePrefetchSongsAhead = Self.clampedAhead(queuePrefetchSongsAhead)
        self.queuePrefetchSongsBehind = Self.clampedBehind(queuePrefetchSongsBehind)
        self.scrobbleTiming = scrobbleTiming
        self.hapticsEnabled = hapticsEnabled
        self.replayGainEnabled = replayGainEnabled
        self.equalizerEnabled = equalizerEnabled
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDurationSeconds = crossfadeDurationSeconds
        self.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        self.radioContinuationEnabled = radioContinuationEnabled
        self.showLyricsWhenAvailable = showLyricsWhenAvailable
        self.lrcLibLyricsEnabled = lrcLibLyricsEnabled
        self.showLyricsInPlayer = showLyricsInPlayer
        self.lyricsArtworkHold = lyricsArtworkHold
        self.changingColorsInPlayer = changingColorsInPlayer
        self.showRatingStars = showRatingStars
        self.showSongInfo = showSongInfo
        self.showArtistTopSongs = showArtistTopSongs
        self.autoCacheArtistPopularSongs = autoCacheArtistPopularSongs
        self.equalizerBands = equalizerBands
        self.explicitDetectionEnabled = explicitDetectionEnabled
        self.explicitSensitivity = explicitSensitivity
        self.explicitBlacklistWords = Self.normalizedWords(explicitBlacklistWords)
        self.explicitWhitelistWords = Self.normalizedWords(explicitWhitelistWords)
        self.explicitWordListChangedAt = explicitWordListChangedAt
        self.hideExplicitSongs = hideExplicitSongs
    }

    public static let `default` = UserSettings()

    public static let defaultSongsAhead = 5
    public static let defaultSongsBehind = 2
    public static let maxSongsAhead = 10
    public static let maxSongsBehind = 5

    public static func clampedAhead(_ value: Int) -> Int {
        min(max(value, 0), maxSongsAhead)
    }

    public static func clampedBehind(_ value: Int) -> Int {
        min(max(value, 0), maxSongsBehind)
    }

    public static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let folded = word
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            result.append(folded)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case isOfflineMode
        case cacheLimitBytes
        case streamingQualityWifi
        case streamingQualityCellular
        case downloadTranscodeQuality
        case smartQueuePrefetchEnabled
        case queuePrefetchStaleHours
        case queuePrefetchSongsAhead
        case queuePrefetchSongsBehind
        case scrobbleTiming
        case hapticsEnabled
        case replayGainEnabled
        case equalizerEnabled
        case crossfadeEnabled
        case crossfadeDurationSeconds
        case gaplessPlaybackEnabled
        case radioContinuationEnabled
        case showLyricsWhenAvailable
        case lrcLibLyricsEnabled
        case showLyricsInPlayer
        case lyricsArtworkHold
        case changingColorsInPlayer
        case showRatingStars
        case showSongInfo
        case showArtistTopSongs
        case autoCacheArtistPopularSongs
        case equalizerBands
        case explicitDetectionEnabled
        case explicitSensitivity
        case explicitBlacklistWords
        case explicitWhitelistWords
        case explicitWordListChangedAt
        case hideExplicitSongs
        // Legacy keys (decode-only)
        case streamingBitrateWifi
        case streamingBitrateCellular
        case cacheTranscodingFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOfflineMode = try c.decodeIfPresent(Bool.self, forKey: .isOfflineMode) ?? false
        cacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes) ?? PlayableCacheLimit.default.rawValue

        let legacyFormat = try c.decodeIfPresent(StreamFormatPreference.self, forKey: .cacheTranscodingFormat)
        let migrated = legacyFormat?.asTranscodeQuality ?? .original
        streamingQualityWifi = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .streamingQualityWifi) ?? migrated
        streamingQualityCellular = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .streamingQualityCellular) ?? migrated
        downloadTranscodeQuality = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .downloadTranscodeQuality) ?? .original
        // Ignore legacy Int bitrate keys if present.
        _ = try c.decodeIfPresent(Int.self, forKey: .streamingBitrateWifi)
        _ = try c.decodeIfPresent(Int.self, forKey: .streamingBitrateCellular)

        smartQueuePrefetchEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartQueuePrefetchEnabled) ?? true
        queuePrefetchStaleHours = try c.decodeIfPresent(Int.self, forKey: .queuePrefetchStaleHours) ?? 18
        queuePrefetchSongsAhead = Self.clampedAhead(
            try c.decodeIfPresent(Int.self, forKey: .queuePrefetchSongsAhead) ?? Self.defaultSongsAhead
        )
        queuePrefetchSongsBehind = Self.clampedBehind(
            try c.decodeIfPresent(Int.self, forKey: .queuePrefetchSongsBehind) ?? Self.defaultSongsBehind
        )
        scrobbleTiming = try c.decodeIfPresent(ScrobbleTiming.self, forKey: .scrobbleTiming) ?? .default
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        equalizerEnabled = try c.decodeIfPresent(Bool.self, forKey: .equalizerEnabled) ?? false
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeDurationSeconds) ?? 3
        gaplessPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessPlaybackEnabled) ?? true
        radioContinuationEnabled = try c.decodeIfPresent(Bool.self, forKey: .radioContinuationEnabled) ?? true
        showLyricsWhenAvailable = try c.decodeIfPresent(Bool.self, forKey: .showLyricsWhenAvailable) ?? true
        lrcLibLyricsEnabled = try c.decodeIfPresent(Bool.self, forKey: .lrcLibLyricsEnabled) ?? true
        showLyricsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .showLyricsInPlayer) ?? false
        lyricsArtworkHold = try c.decodeIfPresent(LyricsArtworkHold.self, forKey: .lyricsArtworkHold) ?? .default
        changingColorsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .changingColorsInPlayer) ?? true
        showRatingStars = try c.decodeIfPresent(Bool.self, forKey: .showRatingStars) ?? true
        showSongInfo = try c.decodeIfPresent(Bool.self, forKey: .showSongInfo) ?? false
        showArtistTopSongs = try c.decodeIfPresent(Bool.self, forKey: .showArtistTopSongs) ?? true
        autoCacheArtistPopularSongs = try c.decodeIfPresent(Bool.self, forKey: .autoCacheArtistPopularSongs) ?? true
        equalizerBands = try c.decodeIfPresent([Float].self, forKey: .equalizerBands) ?? Array(repeating: 0, count: 10)
        explicitDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .explicitDetectionEnabled) ?? true
        explicitSensitivity = try c.decodeIfPresent(LyricsExplicitSensitivity.self, forKey: .explicitSensitivity) ?? .default
        explicitBlacklistWords = Self.normalizedWords(
            try c.decodeIfPresent([String].self, forKey: .explicitBlacklistWords) ?? []
        )
        explicitWhitelistWords = Self.normalizedWords(
            try c.decodeIfPresent([String].self, forKey: .explicitWhitelistWords) ?? []
        )
        explicitWordListChangedAt = try c.decodeIfPresent(Date.self, forKey: .explicitWordListChangedAt)
        hideExplicitSongs = try c.decodeIfPresent(Bool.self, forKey: .hideExplicitSongs) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOfflineMode, forKey: .isOfflineMode)
        try c.encode(cacheLimitBytes, forKey: .cacheLimitBytes)
        try c.encode(streamingQualityWifi, forKey: .streamingQualityWifi)
        try c.encode(streamingQualityCellular, forKey: .streamingQualityCellular)
        try c.encode(downloadTranscodeQuality, forKey: .downloadTranscodeQuality)
        try c.encode(smartQueuePrefetchEnabled, forKey: .smartQueuePrefetchEnabled)
        try c.encode(queuePrefetchStaleHours, forKey: .queuePrefetchStaleHours)
        try c.encode(queuePrefetchSongsAhead, forKey: .queuePrefetchSongsAhead)
        try c.encode(queuePrefetchSongsBehind, forKey: .queuePrefetchSongsBehind)
        try c.encode(scrobbleTiming, forKey: .scrobbleTiming)
        try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try c.encode(replayGainEnabled, forKey: .replayGainEnabled)
        try c.encode(equalizerEnabled, forKey: .equalizerEnabled)
        try c.encode(crossfadeEnabled, forKey: .crossfadeEnabled)
        try c.encode(crossfadeDurationSeconds, forKey: .crossfadeDurationSeconds)
        try c.encode(gaplessPlaybackEnabled, forKey: .gaplessPlaybackEnabled)
        try c.encode(radioContinuationEnabled, forKey: .radioContinuationEnabled)
        try c.encode(showLyricsWhenAvailable, forKey: .showLyricsWhenAvailable)
        try c.encode(lrcLibLyricsEnabled, forKey: .lrcLibLyricsEnabled)
        try c.encode(showLyricsInPlayer, forKey: .showLyricsInPlayer)
        try c.encode(lyricsArtworkHold, forKey: .lyricsArtworkHold)
        try c.encode(changingColorsInPlayer, forKey: .changingColorsInPlayer)
        try c.encode(showRatingStars, forKey: .showRatingStars)
        try c.encode(showSongInfo, forKey: .showSongInfo)
        try c.encode(showArtistTopSongs, forKey: .showArtistTopSongs)
        try c.encode(autoCacheArtistPopularSongs, forKey: .autoCacheArtistPopularSongs)
        try c.encode(equalizerBands, forKey: .equalizerBands)
        try c.encode(explicitDetectionEnabled, forKey: .explicitDetectionEnabled)
        try c.encode(explicitSensitivity, forKey: .explicitSensitivity)
        try c.encode(explicitBlacklistWords, forKey: .explicitBlacklistWords)
        try c.encode(explicitWhitelistWords, forKey: .explicitWhitelistWords)
        try c.encodeIfPresent(explicitWordListChangedAt, forKey: .explicitWordListChangedAt)
        try c.encode(hideExplicitSongs, forKey: .hideExplicitSongs)
    }
}
