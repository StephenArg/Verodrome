import Alamofire
import Foundation

public final class AmpacheApi: BackendApi, @unchecked Sendable {
    private let server: AmpacheServerApi

    /// Whether sharing is switched on can only be learned by calling, and an admin can't
    /// change it without a restart, so the answer is settled once per session.
    var cachedShareCapabilities: ShareCapabilities?

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
        cachedShareCapabilities = nil
        return try await server.handshake()
    }

    public func generateStreamURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        server.streamURL(for: playable.id, maxBitrate: maxBitrate, format: format)
    }

    public func generateDownloadURL(for playable: PlayableRef, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        server.downloadURL(for: playable.id, maxBitrate: maxBitrate, format: format)
    }

    public func generateArtworkURL(for artwork: ArtworkRef, size: Int?) -> URL? {
        // Ampache often returns a fully signed image URL in `<art>` — use it directly.
        if artwork.id.hasPrefix("http://") || artwork.id.hasPrefix("https://") {
            return URL(string: artwork.id)
        }
        return server.artworkURL(for: artwork.id, kind: artwork.kind, size: size)
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

    public var sharing: ShareManaging? { self }
}

// MARK: - Sharing

extension AmpacheApi: ShareManaging {
    public func shareCapabilities() async -> ShareCapabilities {
        if let cachedShareCapabilities { return cachedShareCapabilities }

        let capabilities = await probeShareCapabilities()
        cachedShareCapabilities = capabilities
        return capabilities
    }

    private func probeShareCapabilities() async -> ShareCapabilities {
        // With sharing switched off Ampache answers `ACCESS_DENIED` / "Enable: share" to
        // every share method, listing included, so one call settles it.
        do {
            _ = try await server.getShares(limit: 1, offset: 0)
        } catch {
            return .unsupported
        }

        return ShareCapabilities(
            isSupported: true,
            // API 6 also shares podcasts, episodes, smartlists and videos, none of which
            // the app models as something you can share.
            shareableTypes: [.song, .album, .artist, .playlist],
            expiration: .wholeDays,
            // `share_create` copies the caller's own download permission, but
            // `share_edit` writes the column outright, so the choice does stick.
            download: .configurable,
            canEditExpiration: true,
            canEditDescription: true
        )
    }

    public func shares() async throws -> [ShareRef] {
        try AmpacheParsers.parseShares(data: try await server.getShares())
    }

    public func createShare(_ draft: ShareDraft) async throws -> ShareRef {
        guard let resourceId = draft.resourceIds.first else {
            throw BackendApiError.unsupportedOperation("A share needs something to point at")
        }

        let data = try await server.createShare(
            objectId: resourceId,
            objectType: draft.resourceType.ampacheObjectType,
            description: draft.description?.nilIfBlank,
            expireDays: draft.expires.map { ShareExpiry.days(until: $0) }
        )

        guard let created = try AmpacheParsers.parseShares(data: data).first else {
            throw BackendApiError.server("The server accepted the share but did not return it.")
        }

        // Creation forces the download flag to the caller's own permission, so honouring
        // the user's choice takes a follow-up edit.
        guard let wanted = draft.isDownloadable, wanted != created.isDownloadable else {
            return created
        }
        try await server.editShare(id: created.id, description: nil, allowDownload: wanted, expireDays: nil)
        return try await shares().first { $0.id == created.id } ?? created
    }

    public func updateShare(id: String, _ update: ShareUpdate) async throws {
        // Unlike Subsonic, `share_edit` defaults every omitted field to its stored value,
        // so only what actually changed needs sending.
        var expireDays: Int?
        if let requested = update.expires {
            if let date = requested {
                // The stored count is days from *creation*, not from now, so an edit has
                // to be measured against the day the share was made.
                let created = try await shares().first { $0.id == id }?.created
                expireDays = ShareExpiry.days(until: date, from: created ?? Date())
            } else {
                // Zero is Ampache's "never expires".
                expireDays = 0
            }
        }

        try await server.editShare(
            id: id,
            description: update.description,
            allowDownload: update.isDownloadable,
            expireDays: expireDays
        )
    }

    public func deleteShare(id: String) async throws {
        try await server.deleteShare(id: id)
    }
}
