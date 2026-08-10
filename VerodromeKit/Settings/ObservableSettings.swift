import Foundation
import Observation

@MainActor
@Observable
public final class ObservableSettings {
    public private(set) var app: AppSettings
    public private(set) var user: UserSettings
    public private(set) var account: AccountSettings

    private let store: SettingsStore
    private var activeAccountKey: AccountInfo.Key?

    public init(store: SettingsStore = .shared, accountKey: AccountInfo.Key? = nil) {
        self.store = store
        self.activeAccountKey = accountKey
        self.app = store.loadAppSettings()
        self.user = store.loadUserSettings()
        if let accountKey {
            self.account = store.loadAccountSettings(for: accountKey)
        } else {
            self.account = .default
        }
    }

    public func reload(accountKey: AccountInfo.Key?) {
        activeAccountKey = accountKey
        app = store.loadAppSettings()
        user = store.loadUserSettings()
        if let accountKey {
            account = store.loadAccountSettings(for: accountKey)
        } else {
            account = .default
        }
    }

    public func updateApp(_ transform: (inout AppSettings) -> Void) {
        var copy = app
        transform(&copy)
        app = copy
        store.saveAppSettings(copy)
    }

    public func updateUser(_ transform: (inout UserSettings) -> Void) {
        var copy = user
        let previousOfflineMode = copy.isOfflineMode
        transform(&copy)
        user = copy
        store.saveUserSettings(copy)
        if copy.isOfflineMode != previousOfflineMode {
            NotificationCenter.default.post(name: .offlineModeChanged, object: nil)
        }
    }

    public func updateAccount(_ transform: (inout AccountSettings) -> Void) {
        guard let activeAccountKey else { return }
        // Re-read before mutating: fields written straight to the store by other code
        // (the accent color, for one) are absent from this cached copy, and writing the
        // cache back would erase them.
        var copy = store.loadAccountSettings(for: activeAccountKey)
        transform(&copy)
        account = copy
        store.saveAccountSettings(copy, for: activeAccountKey)
    }

    public func setOfflineMode(_ enabled: Bool) {
        updateUser { $0.isOfflineMode = enabled }
        NotificationCenter.default.post(name: .offlineModeChanged, object: nil)
    }

    public func markLibrarySynced(version: Int) {
        updateApp {
            $0.isLibrarySynced = true
            $0.librarySyncVersion = version
        }
        NotificationCenter.default.post(name: .librarySynced, object: nil)
    }
}
