import Foundation

/// Fallback lyrics provider backed by [LRCLIB](https://lrclib.net/docs).
///
/// Queried only after the music server has nothing, and any hit is written through the
/// same `.lrc` sidecar cache the rest of the app uses. Requests are serialized so a
/// burst of queue-prefetch lookups can't fan out into parallel calls, and a `429` /
/// `Retry-After` response pauses further requests until the window passes — LRCLIB is a
/// free, key-less service and asks clients to behave considerately.
public actor LrcLibClient {
    /// The metadata LRCLIB needs to match a track. Title and artist are required; album
    /// and duration are optional but sharpen the match (LRCLIB matches duration ±2s).
    public struct Query: Sendable {
        public let trackName: String
        public let artistName: String
        public let albumName: String?
        public let duration: TimeInterval?

        public init(trackName: String, artistName: String, albumName: String? = nil, duration: TimeInterval? = nil) {
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
        }
    }

    public static let shared = LrcLibClient()

    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String
    /// Set from a `429` response; requests short-circuit until this passes.
    private var retryAfter: Date?
    /// Chains lookups so only one LRCLIB request is ever in flight.
    private var tail: Task<String?, Never>?

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://lrclib.net")!,
        userAgent: String = LrcLibClient.defaultUserAgent()
    ) {
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    /// Returns synced LRC when available, else plain lyrics, else `nil`. Network and HTTP
    /// failures resolve to `nil` — this is a best-effort fallback and must never throw.
    public func fetchLyrics(query: Query) async -> String? {
        let trackName = query.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistName = query.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackName.isEmpty, !artistName.isEmpty else { return nil }

        let previous = tail
        let task = Task<String?, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return nil }
            return await self.performFetch(trackName: trackName, artistName: artistName, query: query)
        }
        tail = task
        return await task.value
    }

    private func performFetch(trackName: String, artistName: String, query: Query) async -> String? {
        if let retryAfter, retryAfter > Date() { return nil }

        guard let url = buildURL(trackName: trackName, artistName: artistName, query: query) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }

        if http.statusCode == 429 {
            let seconds = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 60
            retryAfter = Date().addingTimeInterval(seconds)
            return nil
        }
        guard http.statusCode == 200 else { return nil }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if decoded.instrumental == true { return nil }
        for candidate in [decoded.syncedLyrics, decoded.plainLyrics] {
            if let text = candidate, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private func buildURL(trackName: String, artistName: String, query: Query) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
        ]
        if let album = query.albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        // LRCLIB requires a whole-second duration in 1...3600; anything else is dropped
        // rather than sent as a value the server will reject.
        if let duration = query.duration {
            let seconds = Int(duration.rounded())
            if (1...3600).contains(seconds) {
                items.append(URLQueryItem(name: "duration", value: String(seconds)))
            }
        }
        components?.queryItems = items
        return components?.url
    }

    private struct Response: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    public static func defaultUserAgent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Verodrome/\(version) (https://github.com/verodrome/verodrome)"
    }
}
