import Foundation

/// Builds a one-shot radio queue from a seed track and similar-song API results.
public enum SongRadioQueue {
    /// Aligns with Navidrome's Instant Mix scale (web UI often lands near ~90 tracks).
    public static let defaultSimilarCount = 100
    /// Per-seed fetch size when zipper-merging multiple radio requests.
    public static let continuationSimilarCount = 25
    /// Artist / genre catalogs need larger similar draws — small batches vanish after
    /// dedupe against a long context.
    public static let artistGenreSimilarCount = 100
    /// How many tracks left before a radio-continuation top-up is requested.
    public static let continuationThreshold = 3
    /// Artist / genre queues top up earlier so sparse similar results still accumulate.
    public static let artistGenreContinuationThreshold = 8
    /// Prefer at least this many new rows per top-up; pad with other-artist genre matches if short.
    public static let minContinuationBatch = 40
    /// Extra seeds for artist / genre so zipper draws cover more of the catalog.
    public static let artistGenreSeedCount = 5

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

    /// Picks distinct song seeds from the queue for radio continuation.
    /// Prefers radio-continuation rows when present so later top-ups branch outward
    /// from the mix already building, then fills from the original context.
    public static func pickContinuationSeeds(from queue: [QueueItem], count: Int = 3) -> [QueueItem] {
        let songs = queue.filter { $0.kind == .song && !$0.playableId.isEmpty }
        guard !songs.isEmpty else { return [] }
        if songs.count <= count {
            // Preserve encounter order while uniquing by playableId.
            var seen = Set<String>()
            return songs.filter { seen.insert($0.playableId).inserted }
        }

        var radioPool = songs.filter(\.isRadioContinuation)
        var originalPool = songs.filter { !$0.isRadioContinuation }
        var picked: [QueueItem] = []
        var seen = Set<String>()

        func draw(from pool: inout [QueueItem], upTo target: Int) {
            while picked.count < target, !pool.isEmpty {
                let index = pool.indices.randomElement()!
                let candidate = pool.remove(at: index)
                guard seen.insert(candidate.playableId).inserted else { continue }
                picked.append(candidate)
            }
        }

        // Aim for most seeds from the radio tail when it has enough tracks.
        let radioTarget = radioPool.isEmpty
            ? 0
            : min(radioPool.count, max(1, (count * 2 + 2) / 3))
        draw(from: &radioPool, upTo: radioTarget)
        draw(from: &originalPool, upTo: count)
        draw(from: &radioPool, upTo: count)
        return picked
    }

    public static func continuationSeedCount(for origin: QueueOrigin?) -> Int {
        switch origin {
        case .artist, .genre: return artistGenreSeedCount
        case .album, .playlist, .song, .none: return 3
        }
    }

    public static func continuationThreshold(for origin: QueueOrigin?) -> Int {
        switch origin {
        case .artist, .genre: return artistGenreContinuationThreshold
        case .album, .playlist, .song, .none: return continuationThreshold
        }
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

    /// IDs that must not reappear in a radio-continuation top-up — every song
    /// already in the queue (played or still ahead).
    public static func continuationExclusionIDs(
        queue: [QueueItem],
        currentIndex: Int,
        origin: QueueOrigin?
    ) -> Set<String> {
        _ = currentIndex
        _ = origin
        return Set(queue.map(\.playableId).filter { !$0.isEmpty })
    }

    /// Drops tracks credited to `artistName` so artist-queue radio stays on related
    /// artists instead of recycling the same catalog.
    public static func excludingArtist(_ items: [QueueItem], named artistName: String) -> [QueueItem] {
        let target = normalizedArtistKey(artistName)
        guard !target.isEmpty else { return items }
        return items.filter { normalizedArtistKey($0.artistName) != target }
    }

    public static func normalizedArtistKey(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
