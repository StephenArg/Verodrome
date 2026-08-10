import Foundation

/// Builds a one-shot radio queue from a seed track and similar-song API results.
public enum SongRadioQueue {
    /// Aligns with Navidrome's Instant Mix scale (web UI often lands near ~90 tracks).
    public static let defaultSimilarCount = 100

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
