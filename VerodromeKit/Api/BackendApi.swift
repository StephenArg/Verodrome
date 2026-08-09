import Foundation

public enum BackendApiError: Error, Sendable, LocalizedError {
    case notAuthenticated
    case unsupportedOperation(String)
    case invalidURL
    case server(String)
    /// The server answered, but with a status that carries meaning of its own —
    /// Navidrome replies `501` in plain text for endpoints an admin has switched off,
    /// which is not expressible in the Subsonic error envelope.
    case http(status: Int, message: String)
    case notImplemented

    /// Builds the most specific case an HTTP failure supports.
    static func from(status: Int?, message: String) -> BackendApiError {
        guard let status else { return .server(message) }
        return status == 501 ? .notImplemented : .http(status: status, message: message)
    }

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with the server."
        case .unsupportedOperation(let detail):
            return "Unsupported operation: \(detail)"
        case .invalidURL:
            return "Could not build a valid server URL."
        case .server(let message):
            return message
        case .http(let status, let message):
            return "[\(status)] \(message)"
        case .notImplemented:
            return "This server does not support that feature."
        }
    }
}

/// High-level server API surface shared by Ampache and Subsonic backends.
public protocol BackendApi: AnyObject, Sendable {
    var apiType: BackendApiType { get }
    var isAuthenticated: Bool { get }

    /// Performs a full login handshake and stores session credentials.
    func authenticate(credentials: LoginCredentials) async throws

    /// Authenticates and returns server metadata in one step.
    func login(credentials: LoginCredentials) async throws -> ServerInfo

    func generateStreamURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL?
    func generateDownloadURL(for playable: PlayableRef) -> URL?
    func generateArtworkURL(for artwork: ArtworkRef, size: Int?) -> URL?

    func createLibrarySyncer(ingestor: LibraryIngesting) -> LibrarySyncer

    func serverInfo() async throws -> ServerInfo
    func ping() async throws

    /// Share management, when the backend speaks a dialect that offers it.
    var sharing: ShareManaging? { get }
}

public extension BackendApi {
    var sharing: ShareManaging? { nil }
}
