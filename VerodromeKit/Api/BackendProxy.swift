import Foundation

/// Auto-detecting facade that tries Subsonic (token), Ampache, and Subsonic legacy auth.
public final class BackendProxy: BackendApi, @unchecked Sendable {
    private let ampache: AmpacheApi
    private let subsonicToken: SubsonicApi
    private let subsonicLegacy: SubsonicApi
    private var activeApi: BackendApi?

    public var apiType: BackendApiType { activeApi?.apiType ?? .notDetected }
    public var isAuthenticated: Bool { activeApi?.isAuthenticated ?? false }

    public init(clientName: String = "Verodrome") {
        ampache = AmpacheApi()
        subsonicToken = SubsonicApi(mode: .token, clientName: clientName)
        subsonicLegacy = SubsonicApi(mode: .legacy, clientName: clientName)
    }

    public func authenticate(credentials: LoginCredentials) async throws {
        _ = try await login(credentials: credentials)
    }

    public func login(credentials: LoginCredentials) async throws -> ServerInfo {
        let candidates = orderedCandidates(for: credentials.preferredApiType)
        var lastError: Error?

        for api in candidates {
            do {
                let info = try await api.login(credentials: credentials)
                activeApi = api
                return info
            } catch {
                lastError = error
            }
        }

        activeApi = nil
        throw lastError ?? BackendApiError.server("Could not detect a compatible music server API.")
    }

    public func generateStreamURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        activeApi?.generateStreamURL(for: playable, maxBitrate: maxBitrate, format: format)
    }

    public func generateDownloadURL(for playable: PlayableRef) -> URL? {
        activeApi?.generateDownloadURL(for: playable)
    }

    public func generateArtworkURL(for artwork: ArtworkRef, size: Int?) -> URL? {
        activeApi?.generateArtworkURL(for: artwork, size: size)
    }

    public func createLibrarySyncer(ingestor: LibraryIngesting) -> LibrarySyncer {
        guard let activeApi else {
            fatalError("BackendProxy.createLibrarySyncer called before successful login")
        }
        return activeApi.createLibrarySyncer(ingestor: ingestor)
    }

    public func serverInfo() async throws -> ServerInfo {
        try await requireActive().serverInfo()
    }

    public func ping() async throws {
        try await requireActive().ping()
    }

    public func logout() {
        activeApi = nil
    }

    private func requireActive() throws -> BackendApi {
        guard let activeApi else { throw BackendApiError.notAuthenticated }
        return activeApi
    }

    private func orderedCandidates(for preference: BackendApiType?) -> [BackendApi] {
        switch preference {
        case .ampache:
            return [ampache]
        case .subsonic:
            return [subsonicToken, subsonicLegacy]
        case .subsonicLegacy:
            return [subsonicLegacy, subsonicToken]
        case .notDetected, nil:
            return [subsonicToken, ampache, subsonicLegacy]
        }
    }
}
