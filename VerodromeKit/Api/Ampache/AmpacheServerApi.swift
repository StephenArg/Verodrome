import Alamofire
import Foundation

/// Low-level Ampache XML API transport and session handling.
///
/// Ampache picks its dialect from the *first digit* of the `version` sent at handshake
/// (`substr($version, 0, 1)` in `ApiHandler`), and each dialect has its own method table.
/// This client speaks API 6, which is the first version to expose live streams, playlist
/// sharing, and the `podcast_*` family under stable names.
public final class AmpacheServerApi: @unchecked Sendable {
    public static let clientVersion = "600000"
    /// Ampache caps every request at 5000 rows for performance and clamps silently.
    public static let maxResultsPerRequest = 5000

    private let session: Session
    private var baseURL: URL
    private var username: String
    private var password: String

    /// The session id returned by `handshake` as `<auth>`. Ampache authenticates every
    /// later call by looking this value up directly (`Session::exists('api', $auth)`),
    /// so there is nothing to sign per request.
    public private(set) var token: String?
    public private(set) var serverVersion: String?

    public var isAuthenticated: Bool { token != nil }

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
            authenticated: false
        )

        let handshake = try AmpacheParsers.parseHandshake(data: data)
        token = handshake.token
        serverVersion = handshake.version

        return ServerInfo(
            name: "Ampache",
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
        try await request(action: "genres", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getArtists(filter: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        if let filter { params["filter"] = filter }
        return try await request(action: "artists", parameters: params)
    }

    /// `albums` filters by *name*, so narrowing to an artist needs the dedicated
    /// `artist_albums` action rather than a `filter` on the general list.
    public func getAlbums(artistId: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        guard let artistId else {
            return try await request(action: "albums", parameters: params)
        }
        params["filter"] = artistId
        return try await request(action: "artist_albums", parameters: params)
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

    public func getFlaggedSongs(limit: Int = 50, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        params["type"] = "song"
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

    /// Similar songs for song radio (`get_similar` with `type=song`).
    public func getSimilarSongs(id: String, limit: Int = 50, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: min(max(1, limit), Self.maxResultsPerRequest), offset: offset)
        params["type"] = "song"
        params["filter"] = id
        return try await request(action: "get_similar", parameters: params)
    }

    /// `include=songs` nests the track list under `<tracks>`, which saves the follow-up
    /// `album_songs` call the album screen would otherwise need.
    public func getAlbum(id: String) async throws -> Data {
        try await request(action: "album", parameters: ["filter": id, "include": "songs"])
    }

    /// `songs` filters by *title*, so an album's tracks come from `album_songs`.
    public func getSongs(albumId: String? = nil, limit: Int = 500, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        guard let albumId else {
            return try await request(action: "songs", parameters: params)
        }
        params["filter"] = albumId
        return try await request(action: "album_songs", parameters: params)
    }

    public func getSong(id: String) async throws -> Data {
        try await request(action: "song", parameters: ["filter": id])
    }

    public func getPlaylists(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "playlists", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getPlaylist(id: String) async throws -> Data {
        try await request(action: "playlist", parameters: ["filter": id])
    }

    /// The playlist object itself only carries a track *count*; the ordered entries are
    /// a separate call, and the order is what index-based removal and reordering need.
    public func getPlaylistSongs(id: String, limit: Int = AmpacheServerApi.maxResultsPerRequest, offset: Int = 0) async throws -> Data {
        var params = pageParameters(limit: limit, offset: offset)
        params["filter"] = id
        return try await request(action: "playlist_songs", parameters: params)
    }

    public func getPodcasts(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "podcasts", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func getPodcast(id: String) async throws -> Data {
        try await request(action: "podcast", parameters: ["filter": id, "include": "episodes"])
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
                "type": objectType,
                "id": objectId,
                "flag": flagged ? "1" : "0"
            ]
        )
    }

    public func setRating(objectId: String, objectType: String = "song", rating: Int) async throws {
        _ = try await request(
            action: "rate",
            parameters: [
                "type": objectType,
                "id": objectId,
                "rating": String(rating)
            ]
        )
    }

    /// Ampache's `scrobble` matches on song/artist/album *names*, which is only useful
    /// for tracks the server may not hold. `record_play` is the id-based equivalent and
    /// is what a client playing from this library wants.
    public func scrobble(songId: String, timestamp: Date, duration: TimeInterval?) async throws {
        _ = duration
        _ = try await request(
            action: "record_play",
            parameters: [
                "id": songId,
                "date": String(Int(timestamp.timeIntervalSince1970)),
                "client": "Verodrome"
            ]
        )
    }

    public func createPlaylist(name: String) async throws -> Data {
        try await request(action: "playlist_create", parameters: ["name": name, "type": "private"])
    }

    public func renamePlaylist(id: String, name: String) async throws {
        _ = try await request(action: "playlist_edit", parameters: ["filter": id, "name": name])
    }

    public func playlistAdd(playlistId: String, songId: String) async throws {
        _ = try await request(action: "playlist_add_song", parameters: ["filter": playlistId, "song": songId])
    }

    public func playlistRemove(playlistId: String, songId: String) async throws {
        _ = try await request(action: "playlist_remove_song", parameters: ["filter": playlistId, "song": songId])
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await request(action: "playlist_delete", parameters: ["filter": id])
    }

    // MARK: - Sharing

    public func getShares(limit: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(action: "shares", parameters: pageParameters(limit: limit, offset: offset))
    }

    public func createShare(objectId: String, objectType: String, description: String?, expireDays: Int?) async throws -> Data {
        var params = ["filter": objectId, "type": objectType]
        if let description, !description.isEmpty { params["description"] = description }
        if let expireDays { params["expires"] = String(expireDays) }
        return try await request(action: "share_create", parameters: params)
    }

    public func editShare(
        id: String,
        description: String?,
        allowDownload: Bool?,
        expireDays: Int?
    ) async throws {
        var params = ["filter": id]
        if let description { params["description"] = description }
        if let allowDownload { params["download"] = allowDownload ? "1" : "0" }
        if let expireDays { params["expires"] = String(expireDays) }
        _ = try await request(action: "share_edit", parameters: params)
    }

    public func deleteShare(id: String) async throws {
        _ = try await request(action: "share_delete", parameters: ["filter": id])
    }

    // MARK: - Media URLs

    public func streamURL(for songId: String, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        var params: [String: String] = ["id": songId, "type": "song"]
        // Ampache wants bits per second here, not the kbps the rest of the app speaks.
        if let maxBitrate { params["bitrate"] = String(maxBitrate * 1000) }
        if let format { params["format"] = format.rawValue }
        return try? buildURL(action: "stream", parameters: params)
    }

    public func downloadURL(for songId: String, maxBitrate: Int? = nil, format: StreamFormat? = nil) -> URL? {
        var params: [String: String] = ["id": songId, "type": "song"]
        if let format, format != .original {
            params["format"] = format.rawValue
            if let maxBitrate { params["bitrate"] = String(maxBitrate * 1000) }
        } else {
            params["format"] = StreamFormat.raw.rawValue
        }
        return try? buildURL(action: "download", parameters: params)
    }

    public func artworkURL(for objectId: String, kind: ArtworkKind, size: Int?) -> URL? {
        var params: [String: String] = ["id": objectId, "type": kind.rawValue]
        // `size` is a `WxH` string in API 6; a bare number is rejected.
        if let size { params["size"] = "\(size)x\(size)" }
        return try? buildURL(action: "get_art", parameters: params)
    }

    // MARK: - Transport

    public func request(action: String, parameters: [String: String] = [:]) async throws -> Data {
        try await rawRequest(action: action, parameters: parameters, authenticated: true)
    }

    private func rawRequest(action: String, parameters: [String: String], authenticated: Bool) async throws -> Data {
        var params = parameters
        params["action"] = action
        params["version"] = Self.clientVersion

        if authenticated {
            guard let token else { throw BackendApiError.notAuthenticated }
            params["auth"] = token
        }

        let response = await session.request(xmlEndpoint, parameters: params)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.from(status: response.response?.statusCode, message: error.localizedDescription)
        }

        guard let data = response.data, !data.isEmpty else {
            throw BackendApiError.server("Empty response for action \(action)")
        }

        try AmpacheParsers.checkForError(data: data)
        return data
    }

    private func pageParameters(limit: Int, offset: Int) -> [String: String] {
        [
            "limit": String(limit),
            "offset": String(offset)
        ]
    }

    private func buildURL(action: String, parameters: [String: String]) throws -> URL {
        guard let token else { throw BackendApiError.notAuthenticated }
        var components = URLComponents(url: xmlEndpoint, resolvingAgainstBaseURL: false)
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "action", value: action))
        items.append(URLQueryItem(name: "version", value: Self.clientVersion))
        items.append(URLQueryItem(name: "auth", value: token))
        components?.queryItems = items
        guard let url = components?.url else { throw BackendApiError.invalidURL }
        return url
    }
}
