import Foundation

public enum BackendApiError: Error, Sendable, LocalizedError {
    case notAuthenticated
    case unsupportedOperation(String)
    case invalidURL
    case server(String)

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
}
