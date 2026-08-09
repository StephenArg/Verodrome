import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var isOfflineMode: Bool
    public var cacheLimitBytes: Int64
    public var streamingBitrateWifi: Int
    public var streamingBitrateCellular: Int
    public var cacheTranscodingFormat: StreamFormatPreference
    public var smartQueuePrefetchEnabled: Bool
    public var queuePrefetchStaleHours: Int
    public var appearanceMode: AppearanceMode
    public var hapticsEnabled: Bool
    public var replayGainEnabled: Bool
    public var equalizerEnabled: Bool
    public var playerDisplayStyle: PlayerDisplayStyle
    public var crossfadeEnabled: Bool
    public var crossfadeDurationSeconds: Double
    public var gaplessPlaybackEnabled: Bool
    public var showLyricsWhenAvailable: Bool
    /// Whether the full-screen player shows the lyrics panel in place of the artwork.
    public var showLyricsInPlayer: Bool
    /// Whether the full-screen player takes its background from the cover's colors.
    public var changingColorsInPlayer: Bool
    public var showRatingStars: Bool
    public var showSongInfo: Bool
    public var allowCellularDownloads: Bool
    public var confirmBeforeDeletingDownloads: Bool
    public var equalizerBands: [Float]

    public init(
        isOfflineMode: Bool = false,
        cacheLimitBytes: Int64 = PlayableCacheLimit.default.rawValue,
        streamingBitrateWifi: Int = 320,
        streamingBitrateCellular: Int = 192,
        cacheTranscodingFormat: StreamFormatPreference = .original,
        smartQueuePrefetchEnabled: Bool = true,
        queuePrefetchStaleHours: Int = 18,
        appearanceMode: AppearanceMode = .system,
        hapticsEnabled: Bool = true,
        replayGainEnabled: Bool = false,
        equalizerEnabled: Bool = false,
        playerDisplayStyle: PlayerDisplayStyle = .standard,
        crossfadeEnabled: Bool = false,
        crossfadeDurationSeconds: Double = 3,
        gaplessPlaybackEnabled: Bool = true,
        showLyricsWhenAvailable: Bool = true,
        showLyricsInPlayer: Bool = false,
        changingColorsInPlayer: Bool = true,
        showRatingStars: Bool = true,
        showSongInfo: Bool = false,
        allowCellularDownloads: Bool = false,
        confirmBeforeDeletingDownloads: Bool = true,
        equalizerBands: [Float] = Array(repeating: 0, count: 10)
    ) {
        self.isOfflineMode = isOfflineMode
        self.cacheLimitBytes = cacheLimitBytes
        self.streamingBitrateWifi = streamingBitrateWifi
        self.streamingBitrateCellular = streamingBitrateCellular
        self.cacheTranscodingFormat = cacheTranscodingFormat
        self.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
        self.queuePrefetchStaleHours = queuePrefetchStaleHours
        self.appearanceMode = appearanceMode
        self.hapticsEnabled = hapticsEnabled
        self.replayGainEnabled = replayGainEnabled
        self.equalizerEnabled = equalizerEnabled
        self.playerDisplayStyle = playerDisplayStyle
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDurationSeconds = crossfadeDurationSeconds
        self.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        self.showLyricsWhenAvailable = showLyricsWhenAvailable
        self.showLyricsInPlayer = showLyricsInPlayer
        self.changingColorsInPlayer = changingColorsInPlayer
        self.showRatingStars = showRatingStars
        self.showSongInfo = showSongInfo
        self.allowCellularDownloads = allowCellularDownloads
        self.confirmBeforeDeletingDownloads = confirmBeforeDeletingDownloads
        self.equalizerBands = equalizerBands
    }

    public static let `default` = UserSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOfflineMode = try c.decodeIfPresent(Bool.self, forKey: .isOfflineMode) ?? false
        cacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes) ?? PlayableCacheLimit.default.rawValue
        streamingBitrateWifi = try c.decodeIfPresent(Int.self, forKey: .streamingBitrateWifi) ?? 320
        streamingBitrateCellular = try c.decodeIfPresent(Int.self, forKey: .streamingBitrateCellular) ?? 192
        cacheTranscodingFormat = try c.decodeIfPresent(StreamFormatPreference.self, forKey: .cacheTranscodingFormat) ?? .original
        smartQueuePrefetchEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartQueuePrefetchEnabled) ?? true
        queuePrefetchStaleHours = try c.decodeIfPresent(Int.self, forKey: .queuePrefetchStaleHours) ?? 18
        appearanceMode = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
        equalizerEnabled = try c.decodeIfPresent(Bool.self, forKey: .equalizerEnabled) ?? false
        playerDisplayStyle = try c.decodeIfPresent(PlayerDisplayStyle.self, forKey: .playerDisplayStyle) ?? .standard
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeDurationSeconds) ?? 3
        gaplessPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessPlaybackEnabled) ?? true
        showLyricsWhenAvailable = try c.decodeIfPresent(Bool.self, forKey: .showLyricsWhenAvailable) ?? true
        showLyricsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .showLyricsInPlayer) ?? false
        changingColorsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .changingColorsInPlayer) ?? true
        showRatingStars = try c.decodeIfPresent(Bool.self, forKey: .showRatingStars) ?? true
        showSongInfo = try c.decodeIfPresent(Bool.self, forKey: .showSongInfo) ?? false
        allowCellularDownloads = try c.decodeIfPresent(Bool.self, forKey: .allowCellularDownloads) ?? false
        confirmBeforeDeletingDownloads = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDeletingDownloads) ?? true
        equalizerBands = try c.decodeIfPresent([Float].self, forKey: .equalizerBands) ?? Array(repeating: 0, count: 10)
    }
}
