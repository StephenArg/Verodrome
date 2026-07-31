import Foundation

public struct LoginCredentials: Sendable, Equatable {
    public var serverURL: URL
    public var username: String
    public var password: String
    /// When set, login skips auto-detection and tries this dialect first.
    public var preferredApiType: BackendApiType?

    public init(
        serverURL: URL,
        username: String,
        password: String,
        preferredApiType: BackendApiType? = nil
    ) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.preferredApiType = preferredApiType
    }

    /// Normalizes trailing slashes and ensures a usable base URL for REST endpoints.
    public var normalizedBaseURL: URL {
        var url = serverURL
        if url.path.hasSuffix("/") {
            url.deleteLastPathComponent()
        }
        return url
    }
}

extension LoginCredentials {
    public init?(serverURLString: String, username: String, password: String, preferredApiType: BackendApiType? = nil) {
        var trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), !username.isEmpty else { return nil }
        self.init(serverURL: url, username: username, password: password, preferredApiType: preferredApiType)
    }
}
