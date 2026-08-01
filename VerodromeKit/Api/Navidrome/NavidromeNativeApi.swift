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
        guard let token else { throw BackendApiError.notAuthenticated }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent("song"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "_start", value: String(offset)),
            URLQueryItem(name: "_end", value: String(offset + limit)),
            URLQueryItem(name: "_sort", value: "title"),
            URLQueryItem(name: "_order", value: "ASC")
        ]
        guard let url = components?.url else { throw BackendApiError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")

        let response = await session.request(request)
            .validate(statusCode: 200..<300)
            .serializingData()
            .response

        if let error = response.error {
            throw BackendApiError.server(error.localizedDescription)
        }
        guard let data = response.data else {
            throw BackendApiError.server("Empty response from /api/song")
        }

        if let refreshed = response.response?.value(forHTTPHeaderField: "X-ND-Authorization") {
            self.token = refreshed.replacingOccurrences(of: "Bearer ", with: "")
        }

        let total = response.response
            .flatMap { $0.value(forHTTPHeaderField: "X-Total-Count") }
            .flatMap(Int.init)

        return NavidromeSongPage(songs: try Self.songs(from: data), total: total)
    }

    /// Split out from the request so the mapping can be tested against a captured payload.
    static func songs(from data: Data) throws -> [IngestSong] {
        let decoder = JSONDecoder()
        let rows = try decoder.decode([NativeSong].self, from: data)
        return rows.map(\.ingested)
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
