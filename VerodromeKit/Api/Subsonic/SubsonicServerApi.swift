import Alamofire
import Foundation

public enum SubsonicAuthMode: Sendable {
    /// `t = md5(password + salt)` with random salt per session.
    case token
    /// Legacy `p` password parameter (plain or hex-encoded per server config).
    case legacy
}

/// Low-level Subsonic REST XML client (`/rest/*.view`).
public final class SubsonicServerApi: @unchecked Sendable {
    public static let apiVersion = "1.16.1"
    /// `getRandomSongs` is capped at 500 by the spec, and servers clamp silently.
    public static let randomSongsMaxSize = 500

    private let session: Session
    private let clientName: String
    private let authMode: SubsonicAuthMode

    private var baseURL: URL
    private var username: String
    private var password: String
    private var tokenSalt: String?

    public private(set) var isAuthenticated = false

    public init(
        baseURL: URL = URL(string: "http://localhost")!,
        authMode: SubsonicAuthMode = .token,
        clientName: String = "Verodrome",
        session: Session = .default
    ) {
        self.baseURL = baseURL
        self.authMode = authMode
        self.clientName = clientName
        self.username = ""
        self.password = ""
        self.session = session
    }

    public func configure(credentials: LoginCredentials) {
        baseURL = credentials.normalizedBaseURL
        username = credentials.username
        password = credentials.password
    }

    private func restURL(method: String) -> URL {
        baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("\(method).view")
    }

    // MARK: - Authentication

    public func authenticate() async throws -> ServerInfo {
        switch authMode {
        case .token:
            tokenSalt = CryptoHelpers.randomSalt(length: 8)
        case .legacy:
            tokenSalt = nil
        }

        let data = try await request(method: "ping")
        isAuthenticated = true
        return try SubsonicParsers.parseServerInfo(data: data)
    }

    public func ping() async throws {
        _ = try await request(method: "ping")
    }

    // MARK: - Library reads

    public func getGenres() async throws -> Data {
        try await request(method: "getGenres")
    }

    public func getArtists() async throws -> Data {
        try await request(method: "getArtists")
    }

    public func getArtist(id: String) async throws -> Data {
        try await request(method: "getArtist", parameters: ["id": id])
    }

    public func getAlbumList(type: String = "alphabeticalByName", size: Int = 500, offset: Int = 0) async throws -> Data {
        try await request(
            method: "getAlbumList2",
            parameters: [
                "type": type,
                "size": String(size),
                "offset": String(offset)
            ]
        )
    }

    public func getAlbum(id: String) async throws -> Data {
        try await request(method: "getAlbum", parameters: ["id": id])
    }

    /// Random songs from the whole library. The spec caps `size` at 500 and offers no
    /// offset, so this is a ceiling rather than a page: repeated calls are independent
    /// draws that overlap.
    public func getRandomSongs(size: Int = SubsonicServerApi.randomSongsMaxSize) async throws -> Data {
        try await request(
            method: "getRandomSongs",
            parameters: ["size": String(min(max(1, size), Self.randomSongsMaxSize))]
        )
    }

    public func getSong(id: String) async throws -> Data {
        try await request(method: "getSong", parameters: ["id": id])
    }

    public func getPlaylists() async throws -> Data {
        try await request(method: "getPlaylists")
    }

    public func getPlaylist(id: String) async throws -> Data {
        try await request(method: "getPlaylist", parameters: ["id": id])
    }

    public func search3(query: String, artistCount: Int = 20, albumCount: Int = 20, songCount: Int = 20) async throws -> Data {
        try await request(
            method: "search3",
            parameters: [
                "query": query,
                "artistCount": String(artistCount),
                "albumCount": String(albumCount),
                "songCount": String(songCount)
            ]
        )
    }

    public func getPodcasts() async throws -> Data {
        try await request(method: "getPodcasts")
    }

    public func getInternetRadioStations() async throws -> Data {
        try await request(method: "getInternetRadioStations")
    }

    public func getPodcastEpisodes(id: String) async throws -> Data {
        try await request(method: "getPodcastEpisodes", parameters: ["id": id])
    }

    public func getStarred2() async throws -> Data {
        try await request(method: "getStarred2")
    }

    public func getMusicFolders() async throws -> Data {
        try await request(method: "getMusicFolders")
    }

    public func getIndexes(musicFolderId: String) async throws -> Data {
        try await request(method: "getIndexes", parameters: ["musicFolderId": musicFolderId])
    }

    public func getMusicDirectory(id: String) async throws -> Data {
        try await request(method: "getMusicDirectory", parameters: ["id": id])
    }

    // MARK: - Mutations

    /// `star`/`unstar` address ID3 albums and artists through their own parameters —
    /// passing an album under plain `id` stars the matching *directory* on servers that
    /// still keep the two namespaces apart.
    public func star(id: String, type: LibraryEntityType = .song, unstar: Bool = false) async throws {
        let method = unstar ? "unstar" : "star"
        let parameter: String
        switch type {
        case .song: parameter = "id"
        case .album: parameter = "albumId"
        case .artist: parameter = "artistId"
        }
        _ = try await request(method: method, parameters: [parameter: id])
    }

    public func setRating(id: String, rating: Int) async throws {
        _ = try await request(method: "setRating", parameters: ["id": id, "rating": String(rating)])
    }

    public func scrobble(id: String, time: Date, submission: Bool = true) async throws {
        _ = try await request(
            method: "scrobble",
            parameters: [
                "id": id,
                "time": String(Int(time.timeIntervalSince1970 * 1000)),
                "submission": submission ? "true" : "false"
            ]
        )
    }

    /// OpenSubsonic `getLyricsBySongId`, falling back to classic `getLyrics`.
    public func getLyricsBySongId(id: String) async throws -> Data {
        try await request(method: "getLyricsBySongId", parameters: ["id": id])
    }

    public func getLyrics(artist: String, title: String) async throws -> Data {
        try await request(method: "getLyrics", parameters: ["artist": artist, "title": title])
    }

    public func createPlaylist(name: String, songIds: [String] = []) async throws -> Data {
        // Subsonic takes repeated `songId=` values, not `songId[0]=`. Navidrome's
        // `Strings("songId")` only sees the bare name, so indexed keys were ignored and
        // the playlist was created empty while the client still reported success.
        try await request(
            method: "createPlaylist",
            parameters: ["name": name],
            repeating: songIds.isEmpty ? [:] : ["songId": songIds]
        )
    }

    public func updatePlaylist(id: String, name: String? = nil, songIdsToAdd: [String] = [], songIndexesToRemove: [Int] = []) async throws {
        var repeating: [String: [String]] = [:]
        if !songIdsToAdd.isEmpty { repeating["songIdToAdd"] = songIdsToAdd }
        if !songIndexesToRemove.isEmpty {
            repeating["songIndexToRemove"] = songIndexesToRemove.map(String.init)
        }
        var params: [String: String] = ["playlistId": id]
        if let name { params["name"] = name }
        _ = try await request(method: "updatePlaylist", parameters: params, repeating: repeating)
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await request(method: "deletePlaylist", parameters: ["id": id])
    }

    // MARK: - Media URLs

    public func streamURL(for songId: String, maxBitrate: Int?, format: StreamFormat?) -> URL? {
        var params: [String: String] = ["id": songId]
        if let maxBitrate { params["maxBitRate"] = String(maxBitrate) }
        if let format { params["format"] = format.rawValue }
        return try? buildURL(method: "stream", parameters: params)
    }

    public func downloadURL(for songId: String) -> URL? {
        try? buildURL(method: "download", parameters: ["id": songId])
    }

    public func coverArtURL(for coverArtId: String, size: Int?) -> URL? {
        var params: [String: String] = ["id": coverArtId]
        if let size { params["size"] = String(size) }
        return try? buildURL(method: "getCoverArt", parameters: params)
    }

    // MARK: - Transport

    public func request(
        method: String,
        parameters: [String: String] = [:],
        repeating: [String: [String]] = [:]
    ) async throws -> Data {
        let url = try buildURL(method: method, parameters: parameters, repeating: repeating)
        let response = await session.request(url)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.server(error.localizedDescription)
        }

        guard let data = response.data, !data.isEmpty else {
            throw BackendApiError.server("Empty response for \(method)")
        }

        try SubsonicParsers.checkForError(data: data)
        return data
    }

    private func buildURL(
        method: String,
        parameters: [String: String],
        repeating: [String: [String]] = [:]
    ) throws -> URL {
        var params = parameters
        params["u"] = username
        params["v"] = Self.apiVersion
        params["c"] = clientName
        params["f"] = "xml"

        switch authMode {
        case .token:
            let salt = tokenSalt ?? CryptoHelpers.randomSalt(length: 8)
            tokenSalt = salt
            params["s"] = salt
            params["t"] = CryptoHelpers.md5Hex(password + salt)
        case .legacy:
            params["p"] = password
        }

        var components = URLComponents(url: restURL(method: method), resolvingAgainstBaseURL: false)
        components?.queryItems = Self.queryItems(parameters: params, repeating: repeating)
        guard let url = components?.url else { throw BackendApiError.invalidURL }
        return url
    }

    /// Builds the query list for a Subsonic call. `repeating` is how multi-value fields
    /// like `songIdToAdd` are encoded — one query item per value, same name — which is
    /// what the Subsonic/OpenSubsonic specs and Navidrome's `Strings(...)` helper expect.
    static func queryItems(
        parameters: [String: String],
        repeating: [String: [String]] = [:]
    ) -> [URLQueryItem] {
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        for (name, values) in repeating.sorted(by: { $0.key < $1.key }) {
            for value in values {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        return items
    }
}
