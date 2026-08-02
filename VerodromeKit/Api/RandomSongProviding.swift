import Foundation

/// Where the next batch of a random walk picks up.
///
/// Only Navidrome's native API can actually pin a random ordering and page through it.
/// Subsonic reshuffles on every call and has no offset at all, and Ampache reshuffles
/// per request even though it accepts one — so on those backends the cursor is a hint
/// for sizing the next request, not a promise that the batch won't repeat tracks.
public struct RandomSongCursor: Sendable, Equatable {
    /// Server-side seed that keeps a paginated random ordering stable across requests.
    public let seed: String?
    public let offset: Int
    /// How many rows the walk can yield in total, when the backend reports it.
    public let total: Int?

    public init(seed: String? = nil, offset: Int, total: Int? = nil) {
        self.seed = seed
        self.offset = offset
        self.total = total
    }
}

public struct RandomSongBatch: Sendable {
    public let songs: [IngestSong]
    /// Nil when the backend can't page a random walk, in which case the next call is an
    /// independent draw that will overlap with what the caller already has.
    public let cursor: RandomSongCursor?
    /// True once the backend has served everything it can and further calls only repeat.
    public let isExhausted: Bool

    public init(songs: [IngestSong], cursor: RandomSongCursor? = nil, isExhausted: Bool = false) {
        self.songs = songs
        self.cursor = cursor
        self.isExhausted = isExhausted
    }
}

/// Backends that can hand back random songs without the client reading the whole library.
public protocol RandomSongProviding: AnyObject, Sendable {
    /// Largest batch this backend will return in one request. Asking for more is clamped
    /// server-side, so callers should size their requests against it.
    var randomSongBatchLimit: Int { get }

    func randomSongs(count: Int, after cursor: RandomSongCursor?) async throws -> RandomSongBatch
}
