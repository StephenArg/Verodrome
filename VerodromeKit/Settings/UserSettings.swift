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
    public var allowCellularDownloads: Bool
    public var confirmBeforeDeletingDownloads: Bool
    public var equalizerBands: [Float]

    public init(
        isOfflineMode: Bool = false,
        cacheLimitBytes: Int64 = 5_368_709_120,
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
        self.allowCellularDownloads = allowCellularDownloads
        self.confirmBeforeDeletingDownloads = confirmBeforeDeletingDownloads
        self.equalizerBands = equalizerBands
    }

    public static let `default` = UserSettings()
}
