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
    }

    // MARK: - UI-facing published properties

    @Published public var themePreference: ThemePreference = .system
    @Published public var isLibrarySynced: Bool = false
    @Published public var libraryDisplayType: LibraryDisplayType = .list
    @Published public var librarySort: LibrarySortSelection = .default
    /// Songs list only: when on, the list shows tracks that have a local file.
    @Published public var songsDownloadedOnly: Bool = false
    @Published public var playerDisplayStyle: PlayerDisplayStyle = .standard
    @Published public var showMiniLyrics: Bool = true
    /// Whether the full-screen player shows lyrics in place of the artwork.
    @Published public var showLyricsInPlayer: Bool = false
    @Published public var showRatingStars: Bool = true
    @Published public var showSongInfo: Bool = false
    @Published public var streamFormat: StreamFormatPreference = .original
    @Published public var smartQueuePrefetchEnabled: Bool = true
    @Published public var smartQueueStaleHours: Int = 18
    @Published public var cacheLimitBytes: Int64 = PlayableCacheLimit.default.rawValue
    @Published public var offlineModeEnabled: Bool = false
    @Published public var artworkDownloadSetting: ArtworkDownloadSetting = .always
    @Published public var swipeLeftAction: String = "queue"
    @Published public var swipeRightAction: String = "download"
    @Published public var developerWindowSizes: Bool = false
    @Published public var enabledHomeSections: [HomeSection] = HomeSection.allCases
    @Published public var enabledRootTabs: [RootTabItem] = RootTabItem.defaultVisible

    private struct Snapshot: Codable {
        var themePreference: ThemePreference
        var isLibrarySynced: Bool
        var libraryDisplayType: LibraryDisplayType
        var librarySort: LibrarySortSelection
        var songsDownloadedOnly: Bool
        var playerDisplayStyle: PlayerDisplayStyle
        var showMiniLyrics: Bool
        var showLyricsInPlayer: Bool
        var showRatingStars: Bool
        var showSongInfo: Bool
        var streamFormat: StreamFormatPreference
        var smartQueuePrefetchEnabled: Bool
        var smartQueueStaleHours: Int
        var cacheLimitBytes: Int64
        var offlineModeEnabled: Bool
        var artworkDownloadSetting: ArtworkDownloadSetting
        var swipeLeftAction: String
        var swipeRightAction: String
        var developerWindowSizes: Bool
        var enabledHomeSections: [HomeSection]
        var enabledRootTabs: [RootTabItem]

        init(
            themePreference: ThemePreference,
            isLibrarySynced: Bool,
            libraryDisplayType: LibraryDisplayType,
            librarySort: LibrarySortSelection,
            songsDownloadedOnly: Bool,
            playerDisplayStyle: PlayerDisplayStyle,
            showMiniLyrics: Bool,
            showLyricsInPlayer: Bool,
            showRatingStars: Bool,
            showSongInfo: Bool,
            streamFormat: StreamFormatPreference,
            smartQueuePrefetchEnabled: Bool,
            smartQueueStaleHours: Int,
            cacheLimitBytes: Int64,
            offlineModeEnabled: Bool,
            artworkDownloadSetting: ArtworkDownloadSetting,
            swipeLeftAction: String,
            swipeRightAction: String,
            developerWindowSizes: Bool,
            enabledHomeSections: [HomeSection],
            enabledRootTabs: [RootTabItem]
        ) {
            self.themePreference = themePreference
            self.isLibrarySynced = isLibrarySynced
            self.libraryDisplayType = libraryDisplayType
            self.librarySort = librarySort
            self.songsDownloadedOnly = songsDownloadedOnly
            self.playerDisplayStyle = playerDisplayStyle
            self.showMiniLyrics = showMiniLyrics
            self.showLyricsInPlayer = showLyricsInPlayer
            self.showRatingStars = showRatingStars
            self.showSongInfo = showSongInfo
            self.streamFormat = streamFormat
            self.smartQueuePrefetchEnabled = smartQueuePrefetchEnabled
            self.smartQueueStaleHours = smartQueueStaleHours
            self.cacheLimitBytes = cacheLimitBytes
            self.offlineModeEnabled = offlineModeEnabled
            self.artworkDownloadSetting = artworkDownloadSetting
            self.swipeLeftAction = swipeLeftAction
            self.swipeRightAction = swipeRightAction
            self.developerWindowSizes = developerWindowSizes
            self.enabledHomeSections = enabledHomeSections
            self.enabledRootTabs = enabledRootTabs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            themePreference = try c.decode(ThemePreference.self, forKey: .themePreference)
            isLibrarySynced = try c.decode(Bool.self, forKey: .isLibrarySynced)
            libraryDisplayType = try c.decode(LibraryDisplayType.self, forKey: .libraryDisplayType)
            librarySort = try c.decodeIfPresent(LibrarySortSelection.self, forKey: .librarySort) ?? .default
            songsDownloadedOnly = try c.decodeIfPresent(Bool.self, forKey: .songsDownloadedOnly) ?? false
            playerDisplayStyle = try c.decode(PlayerDisplayStyle.self, forKey: .playerDisplayStyle)
            showMiniLyrics = try c.decode(Bool.self, forKey: .showMiniLyrics)
            showLyricsInPlayer = try c.decodeIfPresent(Bool.self, forKey: .showLyricsInPlayer) ?? false
            showRatingStars = try c.decodeIfPresent(Bool.self, forKey: .showRatingStars) ?? true
            showSongInfo = try c.decodeIfPresent(Bool.self, forKey: .showSongInfo) ?? false
            streamFormat = try c.decode(StreamFormatPreference.self, forKey: .streamFormat)
            smartQueuePrefetchEnabled = try c.decode(Bool.self, forKey: .smartQueuePrefetchEnabled)
            smartQueueStaleHours = try c.decode(Int.self, forKey: .smartQueueStaleHours)
            cacheLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .cacheLimitBytes) ?? PlayableCacheLimit.default.rawValue
            offlineModeEnabled = try c.decode(Bool.self, forKey: .offlineModeEnabled)
            artworkDownloadSetting = try c.decode(ArtworkDownloadSetting.self, forKey: .artworkDownloadSetting)
            swipeLeftAction = try c.decode(String.self, forKey: .swipeLeftAction)
            swipeRightAction = try c.decode(String.self, forKey: .swipeRightAction)
            developerWindowSizes = try c.decode(Bool.self, forKey: .developerWindowSizes)
            enabledHomeSections = try c.decode([HomeSection].self, forKey: .enabledHomeSections)
            enabledRootTabs = RootTabItem.normalized(
                try c.decodeIfPresent([RootTabItem].self, forKey: .enabledRootTabs) ?? RootTabItem.defaultVisible
            )
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSnapshot()
        syncTypedStoresFromPublished()
    }

    public func save() {
        let snapshot = Snapshot(
            themePreference: themePreference,
            isLibrarySynced: isLibrarySynced,
            libraryDisplayType: libraryDisplayType,
            librarySort: librarySort,
            songsDownloadedOnly: songsDownloadedOnly,
            playerDisplayStyle: playerDisplayStyle,
            showMiniLyrics: showMiniLyrics,
            showLyricsInPlayer: showLyricsInPlayer,
            showRatingStars: showRatingStars,
            showSongInfo: showSongInfo,
            streamFormat: streamFormat,
            smartQueuePrefetchEnabled: smartQueuePrefetchEnabled,
            smartQueueStaleHours: smartQueueStaleHours,
            cacheLimitBytes: cacheLimitBytes,
            offlineModeEnabled: offlineModeEnabled,
            artworkDownloadSetting: artworkDownloadSetting,
            swipeLeftAction: swipeLeftAction,
            swipeRightAction: swipeRightAction,
            developerWindowSizes: developerWindowSizes,
            enabledHomeSections: enabledHomeSections,
            enabledRootTabs: RootTabItem.normalized(enabledRootTabs)
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
        user.cacheTranscodingFormat = streamFormat
        user.playerDisplayStyle = playerDisplayStyle
        user.showLyricsWhenAvailable = showMiniLyrics
        user.showLyricsInPlayer = showLyricsInPlayer
        user.showRatingStars = showRatingStars
        user.showSongInfo = showSongInfo
        user.appearanceMode = appearanceMode(from: themePreference)
        return user
    }

    public func saveUserSettings(_ settings: UserSettings) {
        save(key: Keys.userSettings, value: settings)
        offlineModeEnabled = settings.isOfflineMode
        smartQueuePrefetchEnabled = settings.smartQueuePrefetchEnabled
        smartQueueStaleHours = settings.queuePrefetchStaleHours
        cacheLimitBytes = settings.cacheLimitBytes
        streamFormat = settings.cacheTranscodingFormat
        playerDisplayStyle = settings.playerDisplayStyle
        showMiniLyrics = settings.showLyricsWhenAvailable
        showLyricsInPlayer = settings.showLyricsInPlayer
        showRatingStars = settings.showRatingStars
        showSongInfo = settings.showSongInfo
        themePreference = themePreference(from: settings.appearanceMode)
        save()
    }

    public func loadAccountSettings(for accountKey: AccountInfo.Key) -> AccountSettings {
        load(key: accountSettingsKey(for: accountKey), default: .default)
    }

    public func saveAccountSettings(_ settings: AccountSettings, for accountKey: AccountInfo.Key) {
        save(key: accountSettingsKey(for: accountKey), value: settings)
        artworkDownloadSetting = settings.artworkDownloadSetting
        enabledHomeSections = settings.homeSections
        if let first = settings.libraryDisplayTypesInUse.first {
            libraryDisplayType = first
        }
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
            playerDisplayStyle = snapshot.playerDisplayStyle
            showMiniLyrics = snapshot.showMiniLyrics
            showLyricsInPlayer = snapshot.showLyricsInPlayer
            showRatingStars = snapshot.showRatingStars
            showSongInfo = snapshot.showSongInfo
            streamFormat = snapshot.streamFormat
            smartQueuePrefetchEnabled = snapshot.smartQueuePrefetchEnabled
            smartQueueStaleHours = snapshot.smartQueueStaleHours
            cacheLimitBytes = snapshot.cacheLimitBytes
            offlineModeEnabled = snapshot.offlineModeEnabled
            artworkDownloadSetting = snapshot.artworkDownloadSetting
            swipeLeftAction = snapshot.swipeLeftAction
            swipeRightAction = snapshot.swipeRightAction
            developerWindowSizes = snapshot.developerWindowSizes
            enabledHomeSections = snapshot.enabledHomeSections
            enabledRootTabs = RootTabItem.normalized(snapshot.enabledRootTabs)
            return
        }
        let app = loadAppSettings()
        let user = load(key: Keys.userSettings, default: UserSettings.default)
        isLibrarySynced = app.isLibrarySynced
        offlineModeEnabled = user.isOfflineMode
        smartQueuePrefetchEnabled = user.smartQueuePrefetchEnabled
        smartQueueStaleHours = user.queuePrefetchStaleHours
        cacheLimitBytes = user.cacheLimitBytes
        streamFormat = user.cacheTranscodingFormat
        playerDisplayStyle = user.playerDisplayStyle
        showMiniLyrics = user.showLyricsWhenAvailable
        showLyricsInPlayer = user.showLyricsInPlayer
        showRatingStars = user.showRatingStars
        showSongInfo = user.showSongInfo
        themePreference = themePreference(from: user.appearanceMode)
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
        user.cacheTranscodingFormat = streamFormat
        user.playerDisplayStyle = playerDisplayStyle
        user.showLyricsWhenAvailable = showMiniLyrics
        user.showLyricsInPlayer = showLyricsInPlayer
        user.showRatingStars = showRatingStars
        user.showSongInfo = showSongInfo
        user.appearanceMode = appearanceMode(from: themePreference)
        save(key: Keys.userSettings, value: user)
    }

    private func appearanceMode(from theme: ThemePreference) -> AppearanceMode {
        switch theme {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    private func themePreference(from appearance: AppearanceMode) -> ThemePreference {
        switch appearance {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
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
