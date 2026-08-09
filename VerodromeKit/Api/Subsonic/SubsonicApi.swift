import Alamofire
import Foundation

public final class SubsonicApi: BackendApi, @unchecked Sendable {
    public enum Mode: Sendable {
        case token
        case legacy
    }

    private let server: SubsonicServerApi
    private let mode: Mode

    /// Kept from the last successful ping so the track backfill can tell whether this
    /// server is a Navidrome, which has a much cheaper bulk endpoint than Subsonic.
    private var credentials: LoginCredentials?
    private var serverType: String?

    /// Probing sharing costs a round trip and the answer only changes when an admin
    /// restarts the server, so it is settled once per session.
    var cachedShareCapabilities: ShareCapabilities?

    /// Unlike the syncer's short-lived client, this one is kept so its JWT survives
    /// between share operations.
    private var retainedNative: NavidromeNativeApi?

    var native: NavidromeNativeApi? {
        if let retainedNative { return retainedNative }
        retainedNative = makeNativeApi()
        return retainedNative
    }

    private var isNavidrome: Bool { serverType?.caseInsensitiveCompare("navidrome") == .orderedSame }

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
        _ = try await login(credentials: credentials)
    }

    public func login(credentials: LoginCredentials) async throws -> ServerInfo {
        server.configure(credentials: credentials)
        let info = try await server.authenticate()
        self.credentials = credentials
        serverType = info.name
        retainedNative = nil
        cachedShareCapabilities = nil
        return info
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
        SubsonicLibrarySyncer(server: server, ingestor: ingestor, native: makeNativeApi())
    }

    /// Only built for Navidrome, and only ever used for the track backfill.
    private func makeNativeApi() -> NavidromeNativeApi? {
        guard isNavidrome, let credentials else { return nil }
        return NavidromeNativeApi(
            baseURL: credentials.normalizedBaseURL,
            username: credentials.username,
            password: credentials.password
        )
    }

    public func serverInfo() async throws -> ServerInfo {
        guard isAuthenticated else { throw BackendApiError.notAuthenticated }
        let data = try await server.request(method: "ping")
        return try SubsonicParsers.parseServerInfo(data: data)
    }

    public func ping() async throws {
        try await server.ping()
    }

    public var sharing: ShareManaging? { self }
}

// MARK: - Sharing

extension SubsonicApi: ShareManaging {
    /// Probed once and remembered, because the answer costs a round trip and cannot
    /// change without the admin restarting the server.
    public func shareCapabilities() async -> ShareCapabilities {
        if let cachedShareCapabilities { return cachedShareCapabilities }

        let capabilities = await probeShareCapabilities()
        cachedShareCapabilities = capabilities
        return capabilities
    }

    private func probeShareCapabilities() async -> ShareCapabilities {
        // Listing is the cheapest call that fails the same way creating would: Navidrome
        // answers 501 when sharing is off, other servers reject the unknown method.
        do {
            _ = try await server.getShares()
        } catch {
            return .unsupported
        }

        guard isNavidrome else {
            // The spec only sanctions song and album ids, and says nothing about
            // downloads at any version.
            return ShareCapabilities(
                isSupported: true,
                shareableTypes: [.song, .album],
                expiration: .absolute,
                download: .unsupported,
                canEditExpiration: true,
                canEditDescription: true
            )
        }

        // Navidrome shares artists and playlists too, and stores a download flag — but
        // only its native API can see or set it, so the toggle depends on that reaching.
        let nativeReachable = await navidromeShares() != nil
        return ShareCapabilities(
            isSupported: true,
            shareableTypes: [.song, .album, .artist, .playlist],
            expiration: .absolute,
            download: nativeReachable ? .configurable : .unsupported,
            canEditExpiration: true,
            canEditDescription: true
        )
    }

    public func shares() async throws -> [ShareRef] {
        let shares = try SubsonicParsers.parseShares(data: try await server.getShares())
        return await mergingNativeDetail(into: shares)
    }

    public func createShare(_ draft: ShareDraft) async throws -> ShareRef {
        let data = try await server.createShare(
            ids: draft.resourceIds,
            description: draft.description?.nilIfBlank,
            expiresAtMilliseconds: draft.expires.map(ShareExpiry.epochMilliseconds)
        )

        guard let created = try SubsonicParsers.parseShares(data: data).first else {
            throw BackendApiError.server("The server accepted the share but did not return it.")
        }

        // Downloading is a Navidrome-only column, so it needs a second, native write.
        if let isDownloadable = draft.isDownloadable, await shareCapabilities().download.isConfigurable {
            try? await native?.updateShare(
                id: created.id,
                description: created.description ?? draft.description?.nilIfBlank ?? "",
                downloadable: isDownloadable,
                expiresAt: draft.expires
            )
            return await mergingNativeDetail(into: [created]).first ?? created
        }

        return created
    }

    public func updateShare(id: String, _ update: ShareUpdate) async throws {
        let existing = try await shares().first { $0.id == id }

        // Both dialects treat `description` as the new value rather than a patch, so the
        // current one is resent whenever the caller isn't changing it.
        let description = update.description ?? existing?.description ?? ""
        let expires: Date?
        if let requested = update.expires {
            expires = requested
        } else {
            expires = existing?.expires
        }

        try await server.updateShare(
            id: id,
            description: description,
            // Zero is how the protocol says to clear an expiry.
            expiresAtMilliseconds: expires.map(ShareExpiry.epochMilliseconds) ?? 0
        )

        if let isDownloadable = update.isDownloadable, await shareCapabilities().download.isConfigurable {
            try await native?.updateShare(
                id: id,
                description: description,
                downloadable: isDownloadable,
                expiresAt: expires
            )
        }
    }

    public func deleteShare(id: String) async throws {
        try await server.deleteShare(id: id)
    }

    /// Fills in the two things Subsonic can't say — the download flag and what the share
    /// points at. A native failure leaves the Subsonic answer untouched rather than
    /// failing the whole listing.
    private func mergingNativeDetail(into shares: [ShareRef]) async -> [ShareRef] {
        guard let rows = await navidromeShares() else { return shares }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return shares.map { share in
            guard let row = byId[share.id] else { return share }
            return ShareRef(
                id: share.id,
                url: share.url,
                description: share.description ?? row.description?.nilIfBlank,
                contentsLabel: row.contents?.nilIfBlank ?? share.contentsLabel,
                resourceType: row.shareResourceType ?? share.resourceType,
                owner: share.owner,
                created: share.created,
                expires: share.expires ?? row.expiresAt,
                lastVisited: share.lastVisited,
                visitCount: share.visitCount,
                isDownloadable: row.downloadable,
                entryCount: share.entryCount
            )
        }
    }

    /// Nil whenever the native API isn't there or won't answer, which is the signal for
    /// every caller to carry on without it.
    private func navidromeShares() async -> [NavidromeShare]? {
        guard let native else { return nil }
        if !native.isAuthenticated {
            guard (try? await native.authenticate()) != nil else { return nil }
        }
        return try? await native.shares()
    }
}
