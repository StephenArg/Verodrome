import Alamofire
import Foundation

public final class SubsonicApi: BackendApi, @unchecked Sendable {
    public enum Mode: Sendable {
        case token
        case legacy
    }

    private let server: SubsonicServerApi
    private let mode: Mode

    public var apiType: BackendApiType {
        switch mode {
        case .token: return .subsonic
        case .legacy: return .subsonicLegacy
        }
    }

    public var isAuthenticated: Bool { server.isAuthenticated }

    public init(mode: Mode = .token, clientName: String = "Verodrome", session: Session = .default) {
        self.mode = mode
        server = SubsonicServerApi(
            authMode: mode == .token ? .token : .legacy,
            clientName: clientName,
            session: session
        )
    }

    public func authenticate(credentials: LoginCredentials) async throws {
        server.configure(credentials: credentials)
        _ = try await server.authenticate()
    }

    public func login(credentials: LoginCredentials) async throws -> ServerInfo {
        server.configure(credentials: credentials)
        return try await server.authenticate()
    }

    public func generateStreamURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        server.streamURL(for: playable.id, maxBitrate: maxBitrate, format: format)
    }

    public func generateDownloadURL(for playable: PlayableRef) -> URL? {
        server.downloadURL(for: playable.id)
    }

    public func generateArtworkURL(for artwork: ArtworkRef, size: Int?) -> URL? {
        // Podcast `originalImageUrl` and similar may already be absolute http(s) URLs.
        if artwork.id.hasPrefix("http://") || artwork.id.hasPrefix("https://") {
            return URL(string: artwork.id)
        }
        return server.coverArtURL(for: artwork.id, size: size)
    }

    public func createLibrarySyncer(ingestor: LibraryIngesting) -> LibrarySyncer {
        SubsonicLibrarySyncer(server: server, ingestor: ingestor)
    }

    public func serverInfo() async throws -> ServerInfo {
        guard isAuthenticated else { throw BackendApiError.notAuthenticated }
        let data = try await server.request(method: "ping")
        return try SubsonicParsers.parseServerInfo(data: data)
    }

    public func ping() async throws {
        try await server.ping()
    }
}
