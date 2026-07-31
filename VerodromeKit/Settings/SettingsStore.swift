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
    @Published public var playerDisplayStyle: PlayerDisplayStyle = .standard
    @Published public var showMiniLyrics: Bool = true
    @Published public var streamFormat: StreamFormatPreference = .original
    @Published public var smartQueuePrefetchEnabled: Bool = true
    @Published public var smartQueueStaleHours: Int = 18
    @Published public var offlineModeEnabled: Bool = false
    @Published public var artworkDownloadSetting: ArtworkDownloadSetting = .wifiOnly
    @Published public var swipeLeftAction: String = "queue"
    @Published public var swipeRightAction: String = "download"
    @Published public var developerWindowSizes: Bool = false
    @Published public var enabledHomeSections: [HomeSection] = HomeSection.allCases

    private struct Snapshot: Codable {
        var themePreference: ThemePreference
        var isLibrarySynced: Bool
        var libraryDisplayType: LibraryDisplayType
        var playerDisplayStyle: PlayerDisplayStyle
        var showMiniLyrics: Bool
        var streamFormat: StreamFormatPreference
        var smartQueuePrefetchEnabled: Bool
        var smartQueueStaleHours: Int
        var offlineModeEnabled: Bool
        var artworkDownloadSetting: ArtworkDownloadSetting
        var swipeLeftAction: String
        var swipeRightAction: String
        var developerWindowSizes: Bool
        var enabledHomeSections: [HomeSection]
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
            playerDisplayStyle: playerDisplayStyle,
            showMiniLyrics: showMiniLyrics,
            streamFormat: streamFormat,
            smartQueuePrefetchEnabled: smartQueuePrefetchEnabled,
            smartQueueStaleHours: smartQueueStaleHours,
            offlineModeEnabled: offlineModeEnabled,
            artworkDownloadSetting: artworkDownloadSetting,
            swipeLeftAction: swipeLeftAction,
            swipeRightAction: swipeRightAction,
            developerWindowSizes: developerWindowSizes,
            enabledHomeSections: enabledHomeSections
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
        user.cacheTranscodingFormat = streamFormat
        user.playerDisplayStyle = playerDisplayStyle
        user.showLyricsWhenAvailable = showMiniLyrics
        user.appearanceMode = appearanceMode(from: themePreference)
        return user
    }

    public func saveUserSettings(_ settings: UserSettings) {
        save(key: Keys.userSettings, value: settings)
        offlineModeEnabled = settings.isOfflineMode
        smartQueuePrefetchEnabled = settings.smartQueuePrefetchEnabled
        smartQueueStaleHours = settings.queuePrefetchStaleHours
        streamFormat = settings.cacheTranscodingFormat
        playerDisplayStyle = settings.playerDisplayStyle
        showMiniLyrics = settings.showLyricsWhenAvailable
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
            playerDisplayStyle = snapshot.playerDisplayStyle
            showMiniLyrics = snapshot.showMiniLyrics
            streamFormat = snapshot.streamFormat
            smartQueuePrefetchEnabled = snapshot.smartQueuePrefetchEnabled
            smartQueueStaleHours = snapshot.smartQueueStaleHours
            offlineModeEnabled = snapshot.offlineModeEnabled
            artworkDownloadSetting = snapshot.artworkDownloadSetting
            swipeLeftAction = snapshot.swipeLeftAction
            swipeRightAction = snapshot.swipeRightAction
            developerWindowSizes = snapshot.developerWindowSizes
            enabledHomeSections = snapshot.enabledHomeSections
            return
        }
        let app = loadAppSettings()
        let user = load(key: Keys.userSettings, default: UserSettings.default)
        isLibrarySynced = app.isLibrarySynced
        offlineModeEnabled = user.isOfflineMode
        smartQueuePrefetchEnabled = user.smartQueuePrefetchEnabled
        smartQueueStaleHours = user.queuePrefetchStaleHours
        streamFormat = user.cacheTranscodingFormat
        playerDisplayStyle = user.playerDisplayStyle
        showMiniLyrics = user.showLyricsWhenAvailable
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
        user.cacheTranscodingFormat = streamFormat
        user.playerDisplayStyle = playerDisplayStyle
        user.showLyricsWhenAvailable = showMiniLyrics
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
