import Foundation
import Combine

/// Observable app settings used by SwiftUI screens and Kit consumers.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private enum Keys {
        static let snapshot = "com.verodrome.settings.snapshot.v1"
        static let appSettings = "com.verodrome.settings.app"
        static let userSettings = "com.verodrome.settings.user"
        static let accountSettingsPrefix = "com.verodrome.settings.account."
        static let didAddSharedCategory = "com.verodrome.settings.migration.sharedCategory"
    }

    // MARK: - UI-facing published properties

    @Published public var themePreference: ThemePreference = .system
    @Published public var isLibrarySynced: Bool = false
    @Published public var libraryDisplayType: LibraryDisplayType = .list
    @Published public var librarySort: LibrarySortSelection = .default
    /// Songs list only: when on, the list shows tracks that have a local file.
    @Published public var songsDownloadedOnly: Bool = false
    @Published public var showMiniLyrics: Bool = true
    /// Whether the full-screen player shows lyrics in place of the artwork.
    @Published public var showLyricsInPlayer: Bool = false
    /// Whether the full-screen player is washed with the current cover's color.
    @Published public var changingColorsInPlayer: Bool = true
    @Published public var showRatingStars: Bool = true
    @Published public var showSongInfo: Bool = false
    @Published public var streamingQualityWifi: AudioTranscodeQuality = .original
    @Published public var streamingQualityCellular: AudioTranscodeQuality = .original
    @Published public var downloadTranscodeQuality: AudioTranscodeQuality = .original
    @Published public var smartQueuePrefetchEnabled: Bool = true
    @Published public var smartQueueStaleHours: Int = 18
    @Published public var cacheLimitBytes: Int64 = PlayableCacheLimit.default.rawValue
    @Published public var gaplessPlaybackEnabled: Bool = true
    @Published public var crossfadeEnabled: Bool = false
    @Published public var crossfadeDurationSeconds: Double = 3
    @Published public var replayGainEnabled: Bool = false
    @Published public var scrobbleTiming: ScrobbleTiming = .default
    @Published public var offlineModeEnabled: Bool = false
    @Published public var artworkDownloadSetting: ArtworkDownloadSetting = .always
    /// When pinned downloads may transfer. Queue prefetch is never held by this.
    @Published public var automaticDownloadNetwork: AutomaticDownloadNetwork = .wifiOnly
    @Published public var swipeLeftAction: String = "queue"
    @Published public var swipeRightAction: String = "download"
    @Published public var hapticsEnabled: Bool = true
    @Published public var developerWindowSizes: Bool = false
    @Published public var enabledHomeSections: [HomeSection] = HomeSection.allCases
    @Published public var enabledRootTabs: [RootTabItem] = RootTabItem.defaultVisible
    @Published public var enabledLibraryCategories: [LibraryCategory] = LibraryCategory.defaultVisible

    private struct Snapshot: Codable {
        var themePreference: ThemePreference
        var isLibrarySynced: Bool
        var libraryDisplayType: LibraryDisplayType
        var librarySort: LibrarySortSelection
        var songsDownloadedOnly: Bool
        var showMiniLyrics: Bool
        var showLyricsInPlayer: Bool
        var changingColorsInPlayer: Bool
        var showRatingStars: Bool
        var showSongInfo: Bool
        var streamingQualityWifi: AudioTranscodeQuality
        var streamingQualityCellular: AudioTranscodeQuality
        var downloadTranscodeQuality: AudioTranscodeQuality
        var smartQueuePrefetchEnabled: Bool
        var smartQueueStaleHours: Int
        var cacheLimitBytes: Int64
        var gaplessPlaybackEnabled: Bool
        var crossfadeEnabled: Bool
        var crossfadeDurationSeconds: Double
        var replayGainEnabled: Bool
        var scrobbleTiming: ScrobbleTiming
        var offlineModeEnabled: Bool
        var artworkDownloadSetting: ArtworkDownloadSetting
        var automaticDownloadNetwork: AutomaticDownloadNetwork
        var swipeLeftAction: String
        var swipeRightAction: String
        var hapticsEnabled: Bool
        var developerWindowSizes: Bool
        var enabledHomeSections: [HomeSection]
        var enabledRootTabs: [RootTabItem]
        var enabledLibraryCategories: [LibraryCategory]

        init(
            themePreference: ThemePreference,
            isLibrarySynced: Bool,
            libraryDisplayType: LibraryDisplayType,
            librarySort: LibrarySortSelection,
            songsDownloadedOnly: Bool,
            showMiniLyrics: Bool,
            showLyricsInPlayer: Bool,
            changingColorsInPlayer: Bool,
            showRatingStars: Bool,
            showSongInfo: Bool,
            streamingQualityWifi: AudioTranscodeQuality,
            streamingQualityCellular: AudioTranscodeQuality,
            downloadTranscodeQuality: AudioTranscodeQuality,
            smartQueuePrefetchEnabled: Bool,
            smartQueueStaleHours: Int,
            cacheLimitBytes: Int64,
            gaplessPlaybackEnabled: Bool,
            crossfadeEnabled: Bool,
            crossfadeDurationSeconds: Double,
            replayGainEnabled: Bool,
            scrobbleTiming: ScrobbleTiming,
            offlineModeEnabled: Bool,
            artworkDownloadSetting: ArtworkDownloadSetting,
            automaticDownloadNetwork: AutomaticDownloadNetwork,
            swipeLeftAction: String,
            swipeRightAction: String,
            hapticsEnabled: Bool,
            developerWindowSizes: Bool,
            enabledHomeSections: [HomeSection],
            enabledRootTabs: [RootTabItem],
            enabledLibraryCategories: [LibraryCategory]
        ) {
            self.themePreference = themePreference
            self.isLibrarySynced = isLibrarySynced
            self.libraryDisplayType = libraryDisplayType
            self.librarySort = librarySort
            self.songsDownloadedOnly = songsDownloadedOnly
            self.showMiniLyrics = showMiniLyrics
            self.showLyricsInPlayer = showLyricsInPlayer
            self.changingColorsInPlayer = changingColorsInPlayer
            self.showRatingStars = showRatingStars
            self.showSongInfo = showSongInfo
            self.streamingQualityWifi = streamingQualityWifi
            self.streamingQualityCellular = streamingQualityCellular
            self.downloadTranscodeQuality = downloadTranscodeQuality
            self.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
            self.smartQueueStaleHours = smartQueueStaleHours
            self.cacheLimitBytes = cacheLimitBytes
            self.gaplessPlaybackEnabled = gaplessPlaybackEnabled
            self.crossfadeEnabled = crossfadeEnabled
            self.crossfadeDurationSeconds = crossfadeDurationSeconds
            self.replayGainEnabled = replayGainEnabled
            self.scrobbleTiming = scrobbleTiming
            self.offlineModeEnabled = offlineModeEnabled
            self.artworkDownloadSetting = artworkDownloadSetting
            self.automaticDownloadNetwork = automaticDownloadNetwork
            self.swipeLeftAction = swipeLeftAction
            self.swipeRightAction = swipeRightAction
            self.hapticsEnabled = hapticsEnabled
            self.developerWindowSizes = developerWindowSizes
            self.enabledHomeSections = enabledHomeSections
            self.enabledRootTabs = enabledRootTabs
            self.enabledLibraryCategories = enabledLibraryCategories
        }

        private enum CodingKeys: String, CodingKey {
            case themePreference
            case isLibrarySynced
            case libraryDisplayType
            case librarySort
            case songsDownloadedOnly
            case showMiniLyrics
            case showLyricsInPlayer
            case changingColorsInPlayer
            case showRatingStars
            case showSongInfo
            case streamingQualityWifi
            case streamingQualityCellular
            case downloadTranscodeQuality
            case smartQueuePrefetchEnabled
            case smartQueueStaleHours
            case cacheLimitBytes
            case gaplessPlaybackEnabled
            case crossfadeEnabled
            case crossfadeDurationSeconds
            case replayGainEnabled
            case scrobbleTiming
            case offlineModeEnabled
            case artworkDownloadSetting
            case automaticDownloadNetwork
            case swipeLeftAction
            case swipeRightAction
            case hapticsEnabled
            case developerWindowSizes
            case enabledHomeSections
            case enabledRootTabs
            case enabledLibraryCategories
            case streamFormat // legacy
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            themePreference = try c.decode(ThemePreference.self, forKey: .themePreference)
            isLibrarySynced = try c.decode(Bool.self, forKey: .isLibrarySynced)
            libraryDisplayType = try c.decode(LibraryDisplayType.self, forKey: .libraryDisplayType)
            librarySort = try c.decodeIfPresent(LibrarySortSelection.self, forKey: .librarySort) ?? .default
            songsDownloadedOnly = try c.decodeIfPresent(Bool.self, forKey: .songsDownloadedOnly) ?? false
            showMiniLyrics = try c.decode(Bool.self, forKey: .showMiniLyrics)
            showLyricsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .showLyricsInPlayer) ?? false
            changingColorsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .changingColorsInPlayer) ?? true
            showRatingStars = try c.decodeIfPresent(Bool.self, forKey: .showRatingStars) ?? true
            showSongInfo = try c.decodeIfPresent(Bool.self, forKey: .showSongInfo) ?? false
            let legacyFormat = try c.decodeIfPresent(StreamFormatPreference.self, forKey: .streamFormat)
            let migrated = legacyFormat?.asTranscodeQuality ?? .original
            streamingQualityWifi = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .streamingQualityWifi) ?? migrated
            streamingQualityCellular = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .streamingQualityCellular) ?? migrated
            downloadTranscodeQuality = try c.decodeIfPresent(AudioTranscodeQuality.self, forKey: .downloadTranscodeQuality) ?? .original
            smartQueuePrefetchEnabled = try c.decode(Bool.self, forKey: .smartQueuePrefetchEnabled)
            smartQueueStaleHours = try c.decode(Int.self, forKey: .smartQueueStaleHours)
            cacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes) ?? PlayableCacheLimit.default.rawValue
            gaplessPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .gaplessPlaybackEnabled) ?? true
            crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
            crossfadeDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeDurationSeconds) ?? 3
            replayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayGainEnabled) ?? false
            scrobbleTiming = try c.decodeIfPresent(ScrobbleTiming.self, forKey: .scrobbleTiming) ?? .default
            offlineModeEnabled = try c.decode(Bool.self, forKey: .offlineModeEnabled)
            artworkDownloadSetting = try c.decode(ArtworkDownloadSetting.self, forKey: .artworkDownloadSetting)
            automaticDownloadNetwork = try c.decodeIfPresent(
                AutomaticDownloadNetwork.self,
                forKey: .automaticDownloadNetwork
            ) ?? .wifiOnly
            swipeLeftAction = try c.decode(String.self, forKey: .swipeLeftAction)
            swipeRightAction = try c.decode(String.self, forKey: .swipeRightAction)
            hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
            developerWindowSizes = try c.decode(Bool.self, forKey: .developerWindowSizes)
            enabledHomeSections = try c.decode([HomeSection].self, forKey: .enabledHomeSections)
            enabledRootTabs = RootTabItem.normalized(
                try c.decodeIfPresent([RootTabItem].self, forKey: .enabledRootTabs) ?? RootTabItem.defaultVisible
            )
            enabledLibraryCategories = LibraryCategory.normalized(
                try c.decodeIfPresent([LibraryCategory].self, forKey: .enabledLibraryCategories)
                    ?? LibraryCategory.defaultVisible
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(themePreference, forKey: .themePreference)
            try c.encode(isLibrarySynced, forKey: .isLibrarySynced)
            try c.encode(libraryDisplayType, forKey: .libraryDisplayType)
            try c.encode(librarySort, forKey: .librarySort)
            try c.encode(songsDownloadedOnly, forKey: .songsDownloadedOnly)
            try c.encode(showMiniLyrics, forKey: .showMiniLyrics)
            try c.encode(showLyricsInPlayer, forKey: .showLyricsInPlayer)
            try c.encode(changingColorsInPlayer, forKey: .changingColorsInPlayer)
            try c.encode(showRatingStars, forKey: .showRatingStars)
            try c.encode(showSongInfo, forKey: .showSongInfo)
            try c.encode(streamingQualityWifi, forKey: .streamingQualityWifi)
            try c.encode(streamingQualityCellular, forKey: .streamingQualityCellular)
            try c.encode(downloadTranscodeQuality, forKey: .downloadTranscodeQuality)
            try c.encode(smartQueuePrefetchEnabled, forKey: .smartQueuePrefetchEnabled)
            try c.encode(smartQueueStaleHours, forKey: .smartQueueStaleHours)
            try c.encode(cacheLimitBytes, forKey: .cacheLimitBytes)
            try c.encode(gaplessPlaybackEnabled, forKey: .gaplessPlaybackEnabled)
            try c.encode(crossfadeEnabled, forKey: .crossfadeEnabled)
            try c.encode(crossfadeDurationSeconds, forKey: .crossfadeDurationSeconds)
            try c.encode(replayGainEnabled, forKey: .replayGainEnabled)
            try c.encode(scrobbleTiming, forKey: .scrobbleTiming)
            try c.encode(offlineModeEnabled, forKey: .offlineModeEnabled)
            try c.encode(artworkDownloadSetting, forKey: .artworkDownloadSetting)
            try c.encode(automaticDownloadNetwork, forKey: .automaticDownloadNetwork)
            try c.encode(swipeLeftAction, forKey: .swipeLeftAction)
            try c.encode(swipeRightAction, forKey: .swipeRightAction)
            try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
            try c.encode(developerWindowSizes, forKey: .developerWindowSizes)
            try c.encode(enabledHomeSections, forKey: .enabledHomeSections)
            try c.encode(enabledRootTabs, forKey: .enabledRootTabs)
            try c.encode(enabledLibraryCategories, forKey: .enabledLibraryCategories)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSnapshot()
        addSharedCategoryOnce()
        syncTypedStoresFromPublished()
    }

    /// The visible library categories are persisted as a list, so an install that
    /// predates a new section never sees it. The flag is what makes this a one-off:
    /// someone who removes Shared on purpose should not get it back next launch.
    private func addSharedCategoryOnce() {
        guard !defaults.bool(forKey: Keys.didAddSharedCategory) else { return }
        defaults.set(true, forKey: Keys.didAddSharedCategory)

        guard !enabledLibraryCategories.contains(.shared) else { return }
        enabledLibraryCategories.append(.shared)
        save()
    }

    public func save() {
        let snapshot = Snapshot(
            themePreference: themePreference,
            isLibrarySynced: isLibrarySynced,
            libraryDisplayType: libraryDisplayType,
            librarySort: librarySort,
            songsDownloadedOnly: songsDownloadedOnly,
            showMiniLyrics: showMiniLyrics,
            showLyricsInPlayer: showLyricsInPlayer,
            changingColorsInPlayer: changingColorsInPlayer,
            showRatingStars: showRatingStars,
            showSongInfo: showSongInfo,
            streamingQualityWifi: streamingQualityWifi,
            streamingQualityCellular: streamingQualityCellular,
            downloadTranscodeQuality: downloadTranscodeQuality,
            smartQueuePrefetchEnabled: smartQueuePrefetchEnabled,
            smartQueueStaleHours: smartQueueStaleHours,
            cacheLimitBytes: cacheLimitBytes,
            gaplessPlaybackEnabled: gaplessPlaybackEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDurationSeconds: crossfadeDurationSeconds,
            replayGainEnabled: replayGainEnabled,
            scrobbleTiming: scrobbleTiming,
            offlineModeEnabled: offlineModeEnabled,
            artworkDownloadSetting: artworkDownloadSetting,
            automaticDownloadNetwork: automaticDownloadNetwork,
            swipeLeftAction: swipeLeftAction,
            swipeRightAction: swipeRightAction,
            hapticsEnabled: hapticsEnabled,
            developerWindowSizes: developerWindowSizes,
            enabledHomeSections: enabledHomeSections,
            enabledRootTabs: RootTabItem.normalized(enabledRootTabs),
            enabledLibraryCategories: LibraryCategory.normalized(enabledLibraryCategories)
        )
        save(key: Keys.snapshot, value: snapshot)
        syncTypedStoresFromPublished()
        if offlineModeEnabled != loadUserSettings().isOfflineMode {
            NotificationCenter.default.post(name: .offlineModeChanged, object: nil)
        }
    }

    // MARK: - Typed settings used by Kit internals

    public func loadAppSettings() -> AppSettings {
        load(key: Keys.appSettings, default: .default)
    }

    public func saveAppSettings(_ settings: AppSettings) {
        save(key: Keys.appSettings, value: settings)
        if isLibrarySynced != settings.isLibrarySynced {
            isLibrarySynced = settings.isLibrarySynced
        }
    }

    public func loadUserSettings() -> UserSettings {
        var user = load(key: Keys.userSettings, default: UserSettings.default)
        user.isOfflineMode = offlineModeEnabled
        user.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
        user.queuePrefetchStaleHours = smartQueueStaleHours
        user.cacheLimitBytes = cacheLimitBytes
        user.streamingQualityWifi = streamingQualityWifi
        user.streamingQualityCellular = streamingQualityCellular
        user.downloadTranscodeQuality = downloadTranscodeQuality
        user.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        user.crossfadeEnabled = crossfadeEnabled
        user.crossfadeDurationSeconds = crossfadeDurationSeconds
        user.replayGainEnabled = replayGainEnabled
        user.scrobbleTiming = scrobbleTiming
        user.hapticsEnabled = hapticsEnabled
        user.showLyricsWhenAvailable = showMiniLyrics
        user.showLyricsInPlayer = showLyricsInPlayer
        user.changingColorsInPlayer = changingColorsInPlayer
        user.showRatingStars = showRatingStars
        user.showSongInfo = showSongInfo
        return user
    }

    public func saveUserSettings(_ settings: UserSettings) {
        save(key: Keys.userSettings, value: settings)
        offlineModeEnabled = settings.isOfflineMode
        smartQueuePrefetchEnabled = settings.smartQueuePrefetchEnabled
        smartQueueStaleHours = settings.queuePrefetchStaleHours
        cacheLimitBytes = settings.cacheLimitBytes
        streamingQualityWifi = settings.streamingQualityWifi
        streamingQualityCellular = settings.streamingQualityCellular
        downloadTranscodeQuality = settings.downloadTranscodeQuality
        gaplessPlaybackEnabled = settings.gaplessPlaybackEnabled
        crossfadeEnabled = settings.crossfadeEnabled
        crossfadeDurationSeconds = settings.crossfadeDurationSeconds
        replayGainEnabled = settings.replayGainEnabled
        scrobbleTiming = settings.scrobbleTiming
        hapticsEnabled = settings.hapticsEnabled
        showMiniLyrics = settings.showLyricsWhenAvailable
        showLyricsInPlayer = settings.showLyricsInPlayer
        changingColorsInPlayer = settings.changingColorsInPlayer
        showRatingStars = settings.showRatingStars
        showSongInfo = settings.showSongInfo
        save()
    }

    public func loadAccountSettings(for accountKey: AccountInfo.Key) -> AccountSettings {
        load(key: accountSettingsKey(for: accountKey), default: .default)
    }

    public func saveAccountSettings(_ settings: AccountSettings, for accountKey: AccountInfo.Key) {
        save(key: accountSettingsKey(for: accountKey), value: settings)
        artworkDownloadSetting = settings.artworkDownloadSetting
        enabledHomeSections = settings.homeSections
    }

    public func removeAccountSettings(for accountKey: AccountInfo.Key) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: accountSettingsKey(for: accountKey))
    }

    private func accountSettingsKey(for accountKey: AccountInfo.Key) -> String {
        Keys.accountSettingsPrefix + accountKey.storageKey
    }

    private func loadSnapshot() {
        if let snapshot: Snapshot = loadOptional(key: Keys.snapshot) {
            themePreference = snapshot.themePreference
            isLibrarySynced = snapshot.isLibrarySynced
            libraryDisplayType = snapshot.libraryDisplayType
            librarySort = snapshot.librarySort
            songsDownloadedOnly = snapshot.songsDownloadedOnly
            showMiniLyrics = snapshot.showMiniLyrics
            showLyricsInPlayer = snapshot.showLyricsInPlayer
            changingColorsInPlayer = snapshot.changingColorsInPlayer
            showRatingStars = snapshot.showRatingStars
            showSongInfo = snapshot.showSongInfo
            streamingQualityWifi = snapshot.streamingQualityWifi
            streamingQualityCellular = snapshot.streamingQualityCellular
            downloadTranscodeQuality = snapshot.downloadTranscodeQuality
            smartQueuePrefetchEnabled = snapshot.smartQueuePrefetchEnabled
            smartQueueStaleHours = snapshot.smartQueueStaleHours
            cacheLimitBytes = snapshot.cacheLimitBytes
            gaplessPlaybackEnabled = snapshot.gaplessPlaybackEnabled
            crossfadeEnabled = snapshot.crossfadeEnabled
            crossfadeDurationSeconds = snapshot.crossfadeDurationSeconds
            replayGainEnabled = snapshot.replayGainEnabled
            scrobbleTiming = snapshot.scrobbleTiming
            offlineModeEnabled = snapshot.offlineModeEnabled
            artworkDownloadSetting = snapshot.artworkDownloadSetting
            automaticDownloadNetwork = snapshot.automaticDownloadNetwork
            swipeLeftAction = snapshot.swipeLeftAction
            swipeRightAction = snapshot.swipeRightAction
            hapticsEnabled = snapshot.hapticsEnabled
            developerWindowSizes = snapshot.developerWindowSizes
            enabledHomeSections = snapshot.enabledHomeSections
            enabledRootTabs = RootTabItem.normalized(snapshot.enabledRootTabs)
            enabledLibraryCategories = LibraryCategory.normalized(snapshot.enabledLibraryCategories)
            return
        }
        let app = loadAppSettings()
        let user = load(key: Keys.userSettings, default: UserSettings.default)
        isLibrarySynced = app.isLibrarySynced
        offlineModeEnabled = user.isOfflineMode
        smartQueuePrefetchEnabled = user.smartQueuePrefetchEnabled
        smartQueueStaleHours = user.queuePrefetchStaleHours
        cacheLimitBytes = user.cacheLimitBytes
        streamingQualityWifi = user.streamingQualityWifi
        streamingQualityCellular = user.streamingQualityCellular
        downloadTranscodeQuality = user.downloadTranscodeQuality
        gaplessPlaybackEnabled = user.gaplessPlaybackEnabled
        crossfadeEnabled = user.crossfadeEnabled
        crossfadeDurationSeconds = user.crossfadeDurationSeconds
        replayGainEnabled = user.replayGainEnabled
        scrobbleTiming = user.scrobbleTiming
        hapticsEnabled = user.hapticsEnabled
        showMiniLyrics = user.showLyricsWhenAvailable
        showLyricsInPlayer = user.showLyricsInPlayer
        changingColorsInPlayer = user.changingColorsInPlayer
        showRatingStars = user.showRatingStars
        showSongInfo = user.showSongInfo
    }

    private func syncTypedStoresFromPublished() {
        var app = loadAppSettings()
        app.isLibrarySynced = isLibrarySynced
        save(key: Keys.appSettings, value: app)

        var user = load(key: Keys.userSettings, default: UserSettings.default)
        user.isOfflineMode = offlineModeEnabled
        user.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
        user.queuePrefetchStaleHours = smartQueueStaleHours
        user.cacheLimitBytes = cacheLimitBytes
        user.streamingQualityWifi = streamingQualityWifi
        user.streamingQualityCellular = streamingQualityCellular
        user.downloadTranscodeQuality = downloadTranscodeQuality
        user.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        user.crossfadeEnabled = crossfadeEnabled
        user.crossfadeDurationSeconds = crossfadeDurationSeconds
        user.replayGainEnabled = replayGainEnabled
        user.scrobbleTiming = scrobbleTiming
        user.hapticsEnabled = hapticsEnabled
        user.showLyricsWhenAvailable = showMiniLyrics
        user.showLyricsInPlayer = showLyricsInPlayer
        user.changingColorsInPlayer = changingColorsInPlayer
        user.showRatingStars = showRatingStars
        user.showSongInfo = showSongInfo
        save(key: Keys.userSettings, value: user)
    }

    private func load<T: Codable>(key: String, default defaultValue: T) -> T {
        loadOptional(key: key) ?? defaultValue
    }

    private func loadOptional<T: Codable>(key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Codable>(key: String, value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
