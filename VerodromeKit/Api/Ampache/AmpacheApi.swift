import Alamofire
import Foundation

public final class AmpacheApi: BackendApi, @unchecked Sendable {
    private let server: AmpacheServerApi

    public var apiType: BackendApiType { .ampache }
    public var isAuthenticated: Bool { server.isAuthenticated }

    public init(session: Session = .default) {
        server = AmpacheServerApi(session: session)
    }

    public func authenticate(credentials: LoginCredentials) async throws {
        server.configure(credentials: credentials)
        _ = try await server.handshake()
    }

    public func login(credentials: LoginCredentials) async throws -> ServerInfo {
        server.configure(credentials: credentials)
        return try await server.handshake()
    }

    public func generateStreamURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        server.streamURL(for: playable.id, maxBitrate: maxBitrate, format: format)
    }

    public func generateDownloadURL(for playable: PlayableRef) -> URL? {
        server.downloadURL(for: playable.id)
    }

    public func generateArtworkURL(for artwork: ArtworkRef, size: Int?) -> URL? {
        // Ampache often returns a fully signed image URL in `<art>` — use it directly.
        if artwork.id.hasPrefix("http://") || artwork.id.hasPrefix("https://") {
            return URL(string: artwork.id)
        }
        return server.artworkURL(for: artwork.id, size: size)
    }

    public func createLibrarySyncer(ingestor: LibraryIngesting) -> LibrarySyncer {
        AmpacheLibrarySyncer(server: server, ingestor: ingestor)
    }

    public func serverInfo() async throws -> ServerInfo {
        guard isAuthenticated else { throw BackendApiError.notAuthenticated }
        return ServerInfo(
            name: "Ampache",
            version: server.serverVersion ?? "unknown",
            apiVersion: AmpacheServerApi.clientVersion
        )
    }

    public func ping() async throws {
        try await server.ping()
    }
}
