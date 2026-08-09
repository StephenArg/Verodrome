import Alamofire
import Foundation

/// Client for Navidrome's *native* JSON API — the one its own web UI uses, not Subsonic.
///
/// It exists here for a single reason: `/api/song` returns complete song rows in bulk,
/// so a whole library arrives in a handful of requests where the Subsonic path needs one
/// `getAlbum` per album. On a 12k-song library that is roughly a hundred round trips
/// instead of thirteen hundred.
///
/// Navidrome's maintainers describe this API as undocumented, unstable, and subject to
/// change without warning, and a future UI rewrite is expected to replace it. So nothing
/// the app depends on goes through here — only the track backfill, which always has the
/// album crawl to fall back to.
public final class NavidromeNativeApi: @unchecked Sendable {
    private let session: Session
    private let baseURL: URL
    private let username: String
    private let password: String

    /// JWT from `/auth/login`. Navidrome reissues it on every response, so it's replaced
    /// as we go rather than left to expire mid-crawl.
    private var token: String?

    public init(baseURL: URL, username: String, password: String, session: Session = .default) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    public var isAuthenticated: Bool { token != nil }

    // MARK: - Authentication

    public func authenticate() async throws {
        let url = baseURL.appendingPathComponent("auth").appendingPathComponent("login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password]
        )

        let response = await session.request(request)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.server(error.localizedDescription)
        }
        guard let data = response.data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = payload["token"] as? String, !token.isEmpty else {
            throw BackendApiError.server("Navidrome login returned no token")
        }
        self.token = token
    }

    // MARK: - Songs

    /// One page of songs, ordered by title so paging stays stable across requests.
    public func songs(offset: Int, limit: Int) async throws -> NavidromeSongPage {
        try await page(offset: offset, limit: limit, sort: "title")
    }

    /// One page of a random ordering. The seed is what makes this pageable: without it
    /// the server reshuffles per request and consecutive pages would overlap. Navidrome
    /// keeps this path seeded precisely so its own web UI can scroll a random list.
    public func randomSongs(seed: String, offset: Int, limit: Int) async throws -> NavidromeSongPage {
        try await page(offset: offset, limit: limit, sort: "random", seed: seed)
    }

    private func page(offset: Int, limit: Int, sort: String, seed: String? = nil) async throws -> NavidromeSongPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent("song"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "_start", value: String(offset)),
            URLQueryItem(name: "_end", value: String(offset + limit)),
            URLQueryItem(name: "_sort", value: sort),
            URLQueryItem(name: "_order", value: "ASC")
        ]
        if let seed {
            queryItems.append(URLQueryItem(name: "seed", value: seed))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw BackendApiError.invalidURL }

        let result = try await perform(URLRequest(url: url))
        let total = result.headers["X-Total-Count"].flatMap(Int.init)
        return NavidromeSongPage(songs: try Self.songs(from: result.data), total: total)
    }

    /// Split out from the request so the mapping can be tested against a captured payload.
    static func songs(from data: Data) throws -> [IngestSong] {
        let decoder = JSONDecoder()
        let rows = try decoder.decode([NativeSong].self, from: data)
        return rows.map(\.ingested)
    }

    // MARK: - Shares

    /// Every share the account owns, including the `downloadable` flag and resource type
    /// that the Subsonic endpoints don't expose.
    public func shares(limit: Int = 200) async throws -> [NavidromeShare] {
        var components = URLComponents(url: shareURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "_start", value: "0"),
            URLQueryItem(name: "_end", value: String(limit)),
            URLQueryItem(name: "_sort", value: "createdAt"),
            URLQueryItem(name: "_order", value: "DESC")
        ]
        guard let url = components?.url else { throw BackendApiError.invalidURL }

        let result = try await perform(URLRequest(url: url))
        return try Self.shares(from: result.data)
    }

    /// Navidrome's update always rewrites `description` and `downloadable`, so both are
    /// sent every time — leaving either out blanks the stored value.
    public func updateShare(id: String, description: String, downloadable: Bool, expiresAt: Date?) async throws {
        var body: [String: Any] = [
            "description": description,
            "downloadable": downloadable
        ]
        // A zero expiry is skipped server-side rather than clearing the column, so there
        // is no point sending one.
        if let expiresAt {
            body["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt)
        }

        var request = URLRequest(url: shareURL().appendingPathComponent(id))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    static func shares(from data: Data) throws -> [NavidromeShare] {
        try JSONDecoder().decode([NavidromeShare].self, from: data)
    }

    private func shareURL() -> URL {
        baseURL.appendingPathComponent("api").appendingPathComponent("share")
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> (data: Data, headers: [String: String]) {
        guard let token else { throw BackendApiError.notAuthenticated }

        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")

        let response = await session.request(authorized)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.from(status: response.response?.statusCode, message: error.localizedDescription)
        }
        guard let data = response.data else {
            throw BackendApiError.server("Empty response from \(request.url?.path ?? "the native API")")
        }

        // Navidrome reissues the JWT on every response; taking it keeps a long crawl
        // from expiring halfway through.
        if let refreshed = response.response?.value(forHTTPHeaderField: "X-ND-Authorization") {
            self.token = refreshed.replacingOccurrences(of: "Bearer ", with: "")
        }

        var headers: [String: String] = [:]
        if let fields = response.response?.allHeaderFields as? [String: String] {
            headers = fields
        }
        return (data, headers)
    }
}

/// A row from `/api/share`, which is the only place Navidrome states whether a share
/// allows downloads and what kind of thing it points at.
public struct NavidromeShare: Decodable, Sendable {
    public let id: String
    public let description: String?
    public let downloadable: Bool
    public let resourceType: String?
    public let contents: String?
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, description, downloadable, resourceType, contents, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable) ?? false
        resourceType = try container.decodeIfPresent(String.self, forKey: .resourceType)
        contents = try container.decodeIfPresent(String.self, forKey: .contents)

        if let raw = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else {
            expiresAt = nil
        }
    }

    /// Navidrome stores a single track share as `media_file`.
    public var shareResourceType: ShareResourceType? {
        switch resourceType {
        case "album": return .album
        case "artist": return .artist
        case "playlist": return .playlist
        case "media_file", "song": return .song
        default: return nil
        }
    }
}

public struct NavidromeSongPage: Sendable {
    public let songs: [IngestSong]
    /// From the `X-Total-Count` header, which is how the web UI sizes its scrollbar.
    public let total: Int?
}

/// A row from `/api/song`.
///
/// Everything is optional except the identity fields: Go omits zero values, so a song
/// nobody has played or rated simply has no `playCount` or `rating` key at all.
private struct NativeSong: Decodable {
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double?
    let bitRate: Int?
    let suffix: String?
    let playCount: Int?
    let rating: Int?

    var ingested: IngestSong {
        IngestSong(
            id: id,
            title: title,
            albumId: albumId,
            albumName: album,
            artistId: artistId,
            artistName: artist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            // No cover art id in the native row. Leaving it nil makes the ingester keep
            // whatever the catalog sync stored, and otherwise inherit the album's.
            artId: nil,
            bitrate: bitRate,
            format: suffix,
            // Absent means the value is zero on the server, but it's mapped to nil so the
            // ingester leaves the stored count alone. A play scrobbled on this device but
            // not yet accepted by the server would otherwise be erased by the next sync.
            playCount: playCount,
            rating: rating
        )
    }
}
