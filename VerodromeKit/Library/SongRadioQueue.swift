import Foundation

/// Builds a one-shot radio queue from a seed track and similar-song API results.
public enum SongRadioQueue {
    /// Aligns with Navidrome's Instant Mix scale (web UI often lands near ~90 tracks).
    public static let defaultSimilarCount = 100
    /// Per-seed fetch size when zipper-merging multiple radio requests.
    public static let continuationSimilarCount = 25
    /// How many tracks left before a radio-continuation top-up is requested.
    public static let continuationThreshold = 3

    /// Seed first, then similars with duplicates (including the seed) removed.
    public static func makeItems(seed: QueueItem, similar: [IngestSong]) -> [QueueItem] {
        var seen: Set<String> = [seed.playableId]
        var items = [seed]
        for song in similar where !song.id.isEmpty {
            guard seen.insert(song.id).inserted else { continue }
            items.append(QueueItem.from(song))
        }
        return items
    }

    /// Similar songs only — no seed prepend. Used when the seed is already in the queue.
    public static func makeContinuationItems(
        similar: [IngestSong],
        excluding alreadyQueued: Set<String> = []
    ) -> [QueueItem] {
        var seen = alreadyQueued
        var items: [QueueItem] = []
        for song in similar where !song.id.isEmpty {
            guard seen.insert(song.id).inserted else { continue }
            var item = QueueItem.from(song)
            item.isRadioContinuation = true
            items.append(item)
        }
        return items
    }

    /// Picks up to 3 distinct song seeds from the queue for radio continuation.
    /// With 1 song: that one seed (full-length radio). With 2: both. With 3+: random 3.
    public static func pickContinuationSeeds(from queue: [QueueItem], count: Int = 3) -> [QueueItem] {
        let songs = queue.filter { $0.kind == .song && !$0.playableId.isEmpty }
        guard !songs.isEmpty else { return [] }
        if songs.count <= count {
            // Preserve encounter order while uniquing by playableId.
            var seen = Set<String>()
            return songs.filter { seen.insert($0.playableId).inserted }
        }
        var pool = songs
        var picked: [QueueItem] = []
        var seen = Set<String>()
        while picked.count < count, !pool.isEmpty {
            let index = pool.indices.randomElement()!
            let candidate = pool.remove(at: index)
            guard seen.insert(candidate.playableId).inserted else { continue }
            picked.append(candidate)
        }
        return picked
    }

    /// Interleaves lists round-robin: a1, b1, c1, a2, b2, c2, …
    /// Skips empty slots when a list is shorter than the others.
    public static func zipperMerge(_ lists: [[QueueItem]]) -> [QueueItem] {
        guard !lists.isEmpty else { return [] }
        var result: [QueueItem] = []
        var seen = Set<String>()
        let maxCount = lists.map(\.count).max() ?? 0
        for offset in 0..<maxCount {
            for list in lists {
                guard offset < list.count else { continue }
                let item = list[offset]
                guard seen.insert(item.playableId).inserted else { continue }
                result.append(item)
            }
        }
        return result
    }

    /// IDs that must not reappear in a radio-continuation top-up.
    ///
    /// - Artist / genre queues: exclude only the playhead and everything still ahead,
    ///   plus radio-continuation rows already appended. Already-played catalog tracks
    ///   may return — similar-song results heavily overlap those large contexts.
    /// - All other origins: exclude every song currently in the queue (original behavior).
    public static func continuationExclusionIDs(
        queue: [QueueItem],
        currentIndex: Int,
        origin: QueueOrigin?
    ) -> Set<String> {
        switch origin {
        case .artist, .genre:
            var ids = Set<String>()
            for (index, item) in queue.enumerated() {
                guard !item.playableId.isEmpty else { continue }
                if item.isRadioContinuation || index >= currentIndex {
                    ids.insert(item.playableId)
                }
            }
            return ids
        case .album, .playlist, .song, .none:
            return Set(queue.map(\.playableId).filter { !$0.isEmpty })
        }
    }

    /// Builds a radio-continuation batch from parallel similar-song results.
    /// One seed → full-length list; two or three → zipper of 25-song lists.
    public static func buildContinuation(
        seedResults: [(seed: QueueItem, similar: [IngestSong])],
        excluding alreadyQueued: Set<String>
    ) -> [QueueItem] {
        guard !seedResults.isEmpty else { return [] }
        if seedResults.count == 1 {
            return makeContinuationItems(
                similar: seedResults[0].similar,
                excluding: alreadyQueued
            )
        }
        let lists = seedResults.map { pair in
            makeContinuationItems(similar: pair.similar, excluding: alreadyQueued)
        }
        // Zipper across lists; makeContinuationItems already excluded the queue, but
        // cross-list duplicates still need one more pass via zipperMerge's seen set.
        return zipperMerge(lists)
    }

    /// Backup when similar-song radio yields nothing: one shuffled list per genre,
    /// zipper-merged and deduped against `alreadyQueued`.
    public static func buildGenreContinuation(
        genreLists: [[QueueItem]],
        excluding alreadyQueued: Set<String>
    ) -> [QueueItem] {
        guard !genreLists.isEmpty else { return [] }
        let prepared = genreLists.map { list in
            var seen = alreadyQueued
            var items: [QueueItem] = []
            for item in list where item.kind == .song && !item.playableId.isEmpty {
                guard seen.insert(item.playableId).inserted else { continue }
                var copy = item
                copy.isRadioContinuation = true
                items.append(copy)
            }
            return items
        }
        return zipperMerge(prepared)
    }
}

/// Fetched radio queue ready for `PlayerViewModel.play`, or why it couldn't be built.
public enum PrepareRadioOutcome: Sendable, Equatable {
    case ready([QueueItem])
    case noSimilarSongs
    case unavailable
    case failed
}

/// Outcome of starting song radio from the UI.
public enum StartRadioResult: Sendable, Equatable {
    case started(songCount: Int)
    case noSimilarSongs
    case unavailable
    case failed

    public init(_ outcome: PrepareRadioOutcome) {
        switch outcome {
        case .ready(let items): self = .started(songCount: items.count)
        case .noSimilarSongs: self = .noSimilarSongs
        case .unavailable: self = .unavailable
        case .failed: self = .failed
        }
    }
}
