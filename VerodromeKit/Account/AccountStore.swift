import Foundation
import Combine

public struct StoredAccount: Codable, Equatable, Sendable {
    public var info: AccountInfo
    public var credentials: AccountCredentials

    public init(info: AccountInfo, credentials: AccountCredentials) {
        self.info = info
        self.credentials = credentials
    }
}

@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore()

    @Published public private(set) var isLoggedIn: Bool
    @Published public private(set) var credentials: AccountCredentials?
    @Published public private(set) var lastError: String?
    @Published public private(set) var detectedApiType: ApiType?
    /// Title-cased server product for Home ("Navidrome", "Ampache", …).
    @Published public private(set) var serverTypeDisplayName: String?

    /// Home tab/nav title — server product when known, otherwise `"Home"`.
    public var homeTitle: String {
        guard let name = serverTypeDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "Home"
        }
        return name
    }

    /// True when we still need a handshake/ping to learn the server product name.
    public var needsServerTypeName: Bool {
        guard let name = serverTypeDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        return name.isEmpty
    }

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let accounts = "com.verodrome.accounts"
        static let activeKey = "com.verodrome.activeAccountKey"
        static let legacyCredentials = "com.verodrome.credentials"
    }

    public init() {
        credentials = nil
        isLoggedIn = false
        lastError = nil
        detectedApiType = nil
        serverTypeDisplayName = nil
        migrateLegacyIfNeeded()
        if let key = activeAccountKey(), let stored = loadCredentials(for: key) {
            credentials = stored
            isLoggedIn = true
            serverTypeDisplayName = Self.displayName(
                for: SettingsStore.shared.loadAccountSettings(for: key).serverTypeName
            )
        }
    }

    public func rememberServerTypeName(_ rawName: String?) {
        serverTypeDisplayName = Self.displayName(for: rawName)
    }

    public static func displayName(for rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.localizedCapitalized
    }

    public func detectApiType(for urlString: String) async -> ApiType? {
        guard URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            detectedApiType = nil
            return nil
        }
        let host = URL(string: urlString)?.host?.lowercased() ?? ""
        if host.contains("navidrome") {
            detectedApiType = .subsonic
        } else if host.contains("ampache") {
            detectedApiType = .ampache
        } else {
            detectedApiType = .subsonic
        }
        return detectedApiType
    }

    public func login(serverURL: String, username: String, password: String) async throws {
        lastError = nil
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedUser.isEmpty else {
            throw AccountError.missingFields
        }
        guard let login = LoginCredentials(
            serverURLString: trimmedURL,
            username: trimmedUser,
            password: password,
            preferredApiType: detectedApiType?.backendApiType
        ) else {
            throw AccountError.invalidCredentials
        }
        _ = await detectApiType(for: trimmedURL)
        try await VerodromeKit.shared.login(credentials: login)
        refreshPublishedState()
    }

    public func logout() {
        VerodromeKit.shared.logout()
        credentials = nil
        isLoggedIn = false
        detectedApiType = nil
        serverTypeDisplayName = nil
        NotificationCenter.default.post(name: .accountChanged, object: nil)
    }

    public func activeAccountKey() -> AccountInfo.Key? {
        guard let data = defaults.data(forKey: Keys.activeKey),
              let key = try? decoder.decode(AccountInfo.Key.self, from: data) else {
            return nil
        }
        return key
    }

    public func setActiveAccount(_ info: AccountInfo?) {
        if let info, let data = try? encoder.encode(info.key) {
            defaults.set(data, forKey: Keys.activeKey)
            credentials = loadCredentials(for: info.key)
            isLoggedIn = credentials != nil
            serverTypeDisplayName = Self.displayName(
                for: SettingsStore.shared.loadAccountSettings(for: info.key).serverTypeName
            )
        } else {
            defaults.removeObject(forKey: Keys.activeKey)
            credentials = nil
            isLoggedIn = false
            serverTypeDisplayName = nil
        }
    }

    public func allAccounts() -> [StoredAccount] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let accounts = try? decoder.decode([StoredAccount].self, from: data) else {
            return []
        }
        return accounts
    }

    public func saveCredentials(_ credentials: AccountCredentials, for info: AccountInfo) throws {
        var accounts = allAccounts().filter { $0.info.key != info.key }
        accounts.append(StoredAccount(info: info, credentials: credentials))
        guard let data = try? encoder.encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
        self.credentials = credentials
        isLoggedIn = true
    }

    public func loadCredentials(for key: AccountInfo.Key) -> AccountCredentials? {
        allAccounts().first(where: { $0.info.key == key })?.credentials
    }

    public func removeAccount(_ info: AccountInfo) {
        let accounts = allAccounts().filter { $0.info.key != info.key }
        if let data = try? encoder.encode(accounts) {
            defaults.set(data, forKey: Keys.accounts)
        }
        if activeAccountKey() == info.key {
            setActiveAccount(nil)
        }
        SettingsStore.shared.removeAccountSettings(for: info.key)
        objectWillChange.send()
    }

    private func refreshPublishedState() {
        if let key = activeAccountKey() {
            credentials = loadCredentials(for: key)
            isLoggedIn = credentials != nil
            serverTypeDisplayName = Self.displayName(
                for: SettingsStore.shared.loadAccountSettings(for: key).serverTypeName
            )
        } else {
            credentials = nil
            isLoggedIn = false
            serverTypeDisplayName = nil
        }
    }

    private func migrateLegacyIfNeeded() {
        guard allAccounts().isEmpty,
              let data = defaults.data(forKey: Keys.legacyCredentials),
              let legacy = try? decoder.decode(AccountCredentials.self, from: data),
              !legacy.serverURL.isEmpty else { return }
        let info = AccountInfo(serverURL: legacy.serverURL, username: legacy.username)
        try? saveCredentials(legacy, for: info)
        setActiveAccount(info)
        defaults.removeObject(forKey: Keys.legacyCredentials)
    }
}

public enum AccountError: LocalizedError {
    case missingFields
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .missingFields: "Server URL and username are required."
        case .invalidCredentials: "Could not authenticate with the server."
        }
    }
}
