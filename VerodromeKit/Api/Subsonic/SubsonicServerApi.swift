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

    public func star(id: String, unstar: Bool = false) async throws {
        let method = unstar ? "unstar" : "star"
        _ = try await request(method: method, parameters: ["id": id])
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
        var params: [String: String] = ["name": name]
        for (index, songId) in songIds.enumerated() {
            params["songId[\(index)]"] = songId
        }
        return try await request(method: "createPlaylist", parameters: params)
    }

    public func updatePlaylist(id: String, name: String? = nil, songIdsToAdd: [String] = [], songIndexesToRemove: [Int] = []) async throws {
        var params: [String: String] = ["playlistId": id]
        if let name { params["name"] = name }
        for (index, songId) in songIdsToAdd.enumerated() {
            params["songIdToAdd[\(index)]"] = songId
        }
        for (index, songIndex) in songIndexesToRemove.enumerated() {
            params["songIndexToRemove[\(index)]"] = String(songIndex)
        }
        _ = try await request(method: "updatePlaylist", parameters: params)
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

    public func request(method: String, parameters: [String: String] = [:]) async throws -> Data {
        let url = try buildURL(method: method, parameters: parameters)
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

    private func buildURL(method: String, parameters: [String: String]) throws -> URL {
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
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw BackendApiError.invalidURL }
        return url
    }
}
