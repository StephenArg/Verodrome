import Foundation
import SwiftData

/// Fills in the fields a random-songs response leaves off by looking each track up in
/// the local library.
public protocol ShuffleAllSongResolving: Sendable {
    func queueItems(for songs: [IngestSong]) async -> [QueueItem]
}

/// A running "Shuffle All": pulls random tracks from the backend a batch at a time and
/// never hands the same one back twice.
///
/// Only Navidrome's native API can page a random ordering, via a seed it keeps stable
/// across requests. Subsonic has no offset at all and Ampache re-draws per request, so
/// on those backends a top-up arrives full of tracks the queue already holds — the seen
/// set is what makes them usable rather than anything the endpoints offer.
public actor ShuffleAllSession {
    /// Tracks per batch. Navidrome's own web UI shuffles 500 at a time, which is also
    /// the ceiling the Subsonic spec puts on `getRandomSongs`.
    public static let defaultBatchSize = 500

    /// Consecutive draws that turn up nothing new before the walk is called finished.
    /// One is not enough: a single unlucky draw against a large library shouldn't end a
    /// session that still has plenty left to give.
    private static let emptyDrawLimit = 2

    private let provider: any RandomSongProviding
    private let resolver: (any ShuffleAllSongResolving)?
    private let ingestor: (any LibraryIngesting)?

    private var cursor: RandomSongCursor?
    private var seen: Set<String> = []
    private var finished = false

    public init(
        provider: any RandomSongProviding,
        resolver: (any ShuffleAllSongResolving)? = nil,
        ingestor: (any LibraryIngesting)? = nil
    ) {
        self.provider = provider
        self.resolver = resolver
        self.ingestor = ingestor
    }

    /// True once the backend has nothing left that this session hasn't already queued.
    public var isFinished: Bool { finished }

    public var batchSize: Int { min(Self.defaultBatchSize, provider.randomSongBatchLimit) }

    /// The next tracks this session hasn't handed out yet. Empty means the walk is over.
    public func next(count: Int? = nil) async throws -> [QueueItem] {
        guard !finished else { return [] }
        let requested = min(max(1, count ?? Self.defaultBatchSize), provider.randomSongBatchLimit)

        var fresh: [IngestSong] = []
        var emptyDraws = 0

        while fresh.isEmpty, !finished {
            let batch = try await provider.randomSongs(count: requested, after: cursor)
            cursor = batch.cursor
            finished = batch.isExhausted

            for song in batch.songs where !song.id.isEmpty {
                if seen.insert(song.id).inserted {
                    fresh.append(song)
                }
            }

            if fresh.isEmpty {
                emptyDraws += 1
                if emptyDraws >= Self.emptyDrawLimit { finished = true }
            }
        }

        guard !fresh.isEmpty else { return [] }

        // Off the critical path: these can play immediately, and the library only needs
        // the server's play counts and ratings eventually.
        if let ingestor {
            let songs = fresh
            Task.detached(priority: .utility) {
                try? await ingestor.ingest(songs: songs)
            }
        }

        guard let resolver else { return fresh.map(QueueItem.from) }
        return await resolver.queueItems(for: fresh)
    }
}

/// Resolves random-songs responses against the local library so a shuffled queue shows
/// the same artwork and names as everywhere else in the app.
///
/// This is not cosmetic on Navidrome: its native song rows carry no cover art id at all,
/// so items built straight from the response would play with blank artwork.
public struct LocalLibrarySongResolver: ShuffleAllSongResolving {
    /// Ids per `IN` clause. Kept well under SQLite's bound-variable ceiling, which is
    /// what a whole 500-track batch in one predicate would run into.
    private static let lookupChunkSize = 200

    private let storage: PersistentStorage
    private let accountKey: String?

    public init(storage: PersistentStorage = .shared, accountKey: String?) {
        self.storage = storage
        self.accountKey = accountKey
    }

    public func queueItems(for songs: [IngestSong]) async -> [QueueItem] {
        let compoundIds = songs.map {
            Song.makeCompoundRemoteId(accountKey: accountKey, remoteId: $0.id)
        }
        let chunkSize = Self.lookupChunkSize

        let known: [String: QueueItem] = (try? await storage.backgroundActor.perform { context in
            var found: [String: QueueItem] = [:]
            var start = 0
            while start < compoundIds.count {
                let chunk = Array(compoundIds[start..<min(start + chunkSize, compoundIds.count)])
                let rows = try context.fetch(
                    FetchDescriptor<Song>(
                        predicate: #Predicate<Song> { chunk.contains($0.compoundRemoteId) }
                    )
                )
                for row in rows {
                    found[row.remoteId] = QueueItem.from(row)
                }
                start += chunkSize
            }
            return found
        }) ?? [:]

        // A track the backfill hasn't reached yet still plays — the response carries
        // enough to stream it, just without the library's artwork token.
        return songs.map { known[$0.id] ?? QueueItem.from($0) }
    }
}

extension QueueItem {
    public static func from(_ song: IngestSong) -> QueueItem {
        QueueItem(
            playableId: song.id,
            kind: .song,
            title: song.title,
            artistName: song.artistName,
            albumName: song.albumName,
            duration: song.duration ?? 0,
            artworkId: song.artId
        )
    }
}
