import Alamofire
import Foundation

/// Low-level Ampache XML API transport and request signing.
public final class AmpacheServerApi: @unchecked Sendable {
    public static let clientVersion = "440004"
    /// Ampache caps every request at 5000 rows for performance and clamps silently.
    public static let maxResultsPerRequest = 5000

    private let session: Session
    private var baseURL: URL
    private var username: String
    private var password: String

    public private(set) var token: String?
    public private(set) var apiKey: String?
    public private(set) var serverVersion: String?

    public var isAuthenticated: Bool { token != nil && apiKey != nil }

    public init(baseURL: URL = URL(string: "http://localhost")!, session: Session = .default) {
        self.baseURL = baseURL
        self.username = ""
        self.password = ""
        self.session = session
    }

    public func configure(credentials: LoginCredentials) {
        baseURL = credentials.normalizedBaseURL
        username = credentials.username
        password = credentials.password
    }

    private var xmlEndpoint: URL {
        baseURL.appendingPathComponent("server/xml.server.php")
    }

    // MARK: - Authentication

    public func handshake() async throws -> ServerInfo {
        let timestamp = CryptoHelpers.unixTimestamp()
        let passwordHash = CryptoHelpers.sha256Hex(password)
        let auth = CryptoHelpers.sha256Hex(timestamp + passwordHash)

        let data = try await rawRequest(
            action: "handshake",
            parameters: [
                "auth": auth,
                "timestamp": timestamp,
                "version": Self.clientVersion,
                "user": username
            ],
            signed: false
        )

        let handshake = try AmpacheParsers.parseHandshake(data: data)
        token = handshake.token
        apiKey = handshake.apiKey
        serverVersion = handshake.version

        return ServerInfo(
            name: handshake.serverName ?? "Ampache",
            version: handshake.version,
            apiVersion: Self.clientVersion,
            isSupported: true
        )
    }

    public func ping() async throws {
        _ = try await request(action: "ping")
    }

    // MARK: - Library reads

    public func getGenres(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "get_genres", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getArtists(filter: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        if let filter { params["filter"] = filter }
        return try await request(action: "get_artists", parameters: params)
    }

    public func getAlbums(artistId: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        if let artistId { params["filter"] = artistId }
        return try await request(action: "get_albums", parameters: params)
    }

    public func getNewestAlbums(limit: Int = 50, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        params["type"] = "album"
        params["filter"] = "newest"
        return try await request(action: "stats", parameters: params)
    }

    public func getRecentAlbums(limit: Int = 50, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        params["type"] = "album"
        params["filter"] = "recent"
        return try await request(action: "stats", parameters: params)
    }

    public func getFlaggedAlbums(limit: Int = 50, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        params["type"] = "album"
        params["filter"] = "flagged"
        return try await request(action: "stats", parameters: params)
    }

    /// Random songs from the whole library. Ampache re-draws the ordering on every
    /// request, so `offset` sizes the window rather than guaranteeing a fresh page —
    /// callers still have to drop repeats themselves.
    public func getRandomSongs(limit: Int = 1000, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: min(max(1, limit), Self.maxResultsPerRequest), offset: offset)
        params["type"] = "song"
        params["filter"] = "random"
        return try await request(action: "stats", parameters: params)
    }

    public func getAlbum(id: String) async throws -> Data {
        try await request(action: "album", parameters: ["filter": id])
    }

    public func getSongs(albumId: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        if let albumId { params["filter"] = albumId }
        return try await request(action: "get_songs", parameters: params)
    }

    public func getSong(id: String) async throws -> Data {
        try await request(action: "get_song", parameters: ["filter": id])
    }

    public func getPlaylists(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "get_playlists", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getPlaylist(id: String) async throws -> Data {
        try await request(action: "get_playlist", parameters: ["filter": id])
    }

    public func getPodcasts(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "get_podcasts", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getPodcast(id: String) async throws -> Data {
        try await request(action: "get_podcast", parameters: ["filter": id])
    }

    public func getRadios(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "live_streams", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func advancedSearch(query: String, objectType: String) async throws -> Data {
        try await request(
            action: "advanced_search",
            parameters: [
                "rule_1": "title",
                "operator_1": "match",
                "input_1": query,
                "type": objectType
            ]
        )
    }

    // MARK: - Mutations

    public func setFlag(objectId: String, objectType: String, flagged: Bool) async throws {
        _ = try await request(
            action: "flag",
            parameters: [
                "object_type": objectType,
                "object_id": objectId,
                "flag": flagged ? "1" : "0"
            ]
        )
    }

    public func setRating(objectId: String, rating: Int) async throws {
        _ = try await request(
            action: "set_rating",
            parameters: [
                "object_type": "song",
                "object_id": objectId,
                "rating": String(rating)
            ]
        )
    }

    public func scrobble(songId: String, timestamp: Date, duration: TimeInterval?) async throws {
        var params: [String: String] = [
            "id": songId,
            "date": String(Int(timestamp.timeIntervalSince1970))
        ]
        if let duration {
            params["length"] = String(Int(duration))
        }
        _ = try await request(action: "scrobble", parameters: params)
    }

    public func createPlaylist(name: String) async throws -> Data {
        try await request(action: "create_playlist", parameters: ["name": name, "type": "private"])
    }

    public func renamePlaylist(id: String, name: String) async throws {
        _ = try await request(action: "rename_playlist", parameters: ["filter": id, "name": name])
    }

    public func playlistAdd(playlistId: String, songId: String) async throws {
        _ = try await request(action: "playlist_add", parameters: ["filter": playlistId, "song": songId])
    }

    public func playlistRemove(playlistId: String, songId: String) async throws {
        _ = try await request(action: "playlist_remove", parameters: ["filter": playlistId, "song": songId])
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await request(action: "delete_playlist", parameters: ["filter": id])
    }

    // MARK: - Media URLs

    public func streamURL(for songId: String, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        buildMediaURL(action: "stream", objectId: songId, maxBitrate: maxBitrate, format: format)
    }

    public func downloadURL(for songId: String) -> URL? {
        buildMediaURL(action: "download", objectId: songId, maxBitrate: nil, format: nil)
    }

    public func artworkURL(for objectId: String, size: Int?) -> URL? {
        var params: [String: String] = ["id": objectId]
        if let size { params["size"] = String(size) }
        return try? buildSignedURL(action: "get_art", parameters: params)
    }

    // MARK: - Transport

    public func request(action: String, parameters: [String: String] = [:]) async throws -> Data {
        try await rawRequest(action: action, parameters: parameters, signed: true)
    }

    private func rawRequest(action: String, parameters: [String: String], signed: Bool) async throws -> Data {
        var params = parameters
        params["action"] = action

        if signed {
            guard isAuthenticated else { throw BackendApiError.notAuthenticated }
            params.merge(try signedParameters()) { _, new in new }
        }

        let response = await session.request(xmlEndpoint, parameters: params)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.server(error.localizedDescription)
        }

        guard let data = response.data, !data.isEmpty else {
            throw BackendApiError.server("Empty response for action \(action)")
        }

        try AmpacheParsers.checkForError(data: data)
        return data
    }

    private func signedParameters() throws -> [String: String] {
        guard let apiKey, let token else { throw BackendApiError.notAuthenticated }
        let timestamp = CryptoHelpers.unixTimestamp()
        return [
            "auth": CryptoHelpers.sha256Hex(timestamp + apiKey),
            "timestamp": timestamp,
            "token": token
        ]
    }

    private func pageParameters(limit: Int, offset: Int) -> [String: String] {
        [
            "limit": String(limit),
            "offset": String(offset)
        ]
    }

    private func buildMediaURL(action: String, objectId: String, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        var params: [String: String] = ["id": objectId]
        if let maxBitrate { params["bitrate"] = String(maxBitrate) }
        if let format { params["type"] = format.rawValue }
        return try? buildSignedURL(action: action, parameters: params)
    }

    private func buildSignedURL(action: String, parameters: [String: String]) throws -> URL {
        guard isAuthenticated else { throw BackendApiError.notAuthenticated }
        var components = URLComponents(url: xmlEndpoint, resolvingAgainstBaseURL: false)
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "action", value: action))
        for (key, value) in try signedParameters() {
            items.append(URLQueryItem(name: key, value: value))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw BackendApiError.invalidURL }
        return url
    }
}
