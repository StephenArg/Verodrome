import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var isOfflineMode: Bool
    public var cacheLimitBytes: Int64
    public var streamingQualityWifi: AudioTranscodeQuality
    public var streamingQualityCellular: AudioTranscodeQuality
    public var downloadTranscodeQuality: AudioTranscodeQuality
    public var smartQueuePrefetchEnabled: Bool
    public var queuePrefetchStaleHours: Int
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
    /// Whether the full-screen player shows the lyrics panel in place of the artwork.
    public var showLyricsInPlayer: Bool
    /// How long artwork stays visible before the lyrics crossfade on each track.
    public var lyricsArtworkHold: LyricsArtworkHold
    /// Whether the full-screen player takes its background from the cover's colors.
    public var changingColorsInPlayer: Bool
    public var showRatingStars: Bool
    public var showSongInfo: Bool
    public var equalizerBands: [Float]

    public init(
        isOfflineMode: Bool = false,
        cacheLimitBytes: Int64 = PlayableCacheLimit.default.rawValue,
        streamingQualityWifi: AudioTranscodeQuality = .original,
        streamingQualityCellular: AudioTranscodeQuality = .original,
        downloadTranscodeQuality: AudioTranscodeQuality = .original,
        smartQueuePrefetchEnabled: Bool = true,
        queuePrefetchStaleHours: Int = 18,
        scrobbleTiming: ScrobbleTiming = .default,
        hapticsEnabled: Bool = true,
        replayGainEnabled: Bool = false,
        equalizerEnabled: Bool = false,
        crossfadeEnabled: Bool = false,
        crossfadeDurationSeconds: Double = 3,
        gaplessPlaybackEnabled: Bool = true,
        radioContinuationEnabled: Bool = true,
        showLyricsWhenAvailable: Bool = true,
        showLyricsInPlayer: Bool = false,
        lyricsArtworkHold: LyricsArtworkHold = .default,
        changingColorsInPlayer: Bool = true,
        showRatingStars: Bool = true,
        showSongInfo: Bool = false,
        equalizerBands: [Float] = Array(repeating: 0, count: 10)
    ) {
        self.isOfflineMode = isOfflineMode
        self.cacheLimitBytes = cacheLimitBytes
        self.streamingQualityWifi = streamingQualityWifi
        self.streamingQualityCellular = streamingQualityCellular
        self.downloadTranscodeQuality = downloadTranscodeQuality
        self.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
        self.queuePrefetchStaleHours = queuePrefetchStaleHours
        self.scrobbleTiming = scrobbleTiming
        self.hapticsEnabled = hapticsEnabled
        self.replayGainEnabled = replayGainEnabled
        self.equalizerEnabled = equalizerEnabled
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDurationSeconds = crossfadeDurationSeconds
        self.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        self.radioContinuationEnabled = radioContinuationEnabled
        self.showLyricsWhenAvailable = showLyricsWhenAvailable
        self.showLyricsInPlayer = showLyricsInPlayer
        self.lyricsArtworkHold = lyricsArtworkHold
        self.changingColorsInPlayer = changingColorsInPlayer
        self.showRatingStars = showRatingStars
        self.showSongInfo = showSongInfo
        self.equalizerBands = equalizerBands
    }

    public static let `default` = UserSettings()

    private enum CodingKeys: String, CodingKey {
        case isOfflineMode
        case cacheLimitBytes
        case streamingQualityWifi
        case streamingQualityCellular
        case downloadTranscodeQuality
        case smartQueuePrefetchEnabled
        case queuePrefetchStaleHours
        case scrobbleTiming
        case hapticsEnabled
        case replayGainEnabled
        case equalizerEnabled
        case crossfadeEnabled
        case crossfadeDurationSeconds
        case gaplessPlaybackEnabled
        case radioContinuationEnabled
        case showLyricsWhenAvailable
        case showLyricsInPlayer
        case lyricsArtworkHold
        case changingColorsInPlayer
        case showRatingStars
        case showSongInfo
        case equalizerBands
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
        scrobbleTiming = try c.decodeIfPresent(ScrobbleTiming.self, forKey: .scrobbleTiming) ?? .default
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        equalizerEnabled = try c.decodeIfPresent(Bool.self, forKey: .equalizerEnabled) ?? false
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeDurationSeconds) ?? 3
        gaplessPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessPlaybackEnabled) ?? true
        radioContinuationEnabled = try c.decodeIfPresent(Bool.self, forKey: .radioContinuationEnabled) ?? true
        showLyricsWhenAvailable = try c.decodeIfPresent(Bool.self, forKey: .showLyricsWhenAvailable) ?? true
        showLyricsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .showLyricsInPlayer) ?? false
        lyricsArtworkHold = try c.decodeIfPresent(LyricsArtworkHold.self, forKey: .lyricsArtworkHold) ?? .default
        changingColorsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .changingColorsInPlayer) ?? true
        showRatingStars = try c.decodeIfPresent(Bool.self, forKey: .showRatingStars) ?? true
        showSongInfo = try c.decodeIfPresent(Bool.self, forKey: .showSongInfo) ?? false
        equalizerBands = try c.decodeIfPresent([Float].self, forKey: .equalizerBands) ?? Array(repeating: 0, count: 10)
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
        try c.encode(scrobbleTiming, forKey: .scrobbleTiming)
        try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try c.encode(replayGainEnabled, forKey: .replayGainEnabled)
        try c.encode(equalizerEnabled, forKey: .equalizerEnabled)
        try c.encode(crossfadeEnabled, forKey: .crossfadeEnabled)
        try c.encode(crossfadeDurationSeconds, forKey: .crossfadeDurationSeconds)
        try c.encode(gaplessPlaybackEnabled, forKey: .gaplessPlaybackEnabled)
        try c.encode(radioContinuationEnabled, forKey: .radioContinuationEnabled)
        try c.encode(showLyricsWhenAvailable, forKey: .showLyricsWhenAvailable)
        try c.encode(showLyricsInPlayer, forKey: .showLyricsInPlayer)
        try c.encode(lyricsArtworkHold, forKey: .lyricsArtworkHold)
        try c.encode(changingColorsInPlayer, forKey: .changingColorsInPlayer)
        try c.encode(showRatingStars, forKey: .showRatingStars)
        try c.encode(showSongInfo, forKey: .showSongInfo)
        try c.encode(equalizerBands, forKey: .equalizerBands)
    }
}
