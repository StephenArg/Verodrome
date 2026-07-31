import CryptoKit
import Foundation

public struct AccountInfo: Hashable, Codable, Sendable, Identifiable {
    public struct Key: Hashable, Codable, Sendable {
        public let serverHash: String
        public let userHash: String

        public init(serverHash: String, userHash: String) {
            self.serverHash = serverHash
            self.userHash = userHash
        }

        public var storageKey: String {
            "\(serverHash)_\(userHash)"
        }
    }

    public let key: Key
    public let serverURL: String
    public let username: String
    public let displayName: String

    public var id: String { key.storageKey }

    public init(serverURL: String, username: String, displayName: String? = nil) {
        let normalizedURL = AccountInfo.normalizeServerURL(serverURL)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.key = Key(
            serverHash: AccountInfo.sha256(normalizedURL),
            userHash: AccountInfo.sha256(normalizedUsername)
        )
        self.serverURL = normalizedURL
        self.username = normalizedUsername
        self.displayName = displayName ?? normalizedUsername
    }

    public init(key: Key, serverURL: String, username: String, displayName: String) {
        self.key = key
        self.serverURL = serverURL
        self.username = username
        self.displayName = displayName
    }

    public static func normalizeServerURL(_ urlString: String) -> String {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if !trimmed.lowercased().hasPrefix("http") {
            trimmed = "https://" + trimmed
        }
        return trimmed.lowercased()
    }

    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
