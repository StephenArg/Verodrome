import Foundation
import SwiftData

/// A walk that hands a shuffled queue out a batch at a time, so the coordinator can top
/// one up without caring where the tracks come from.
public protocol ShuffleBatchSession: AnyObject, Sendable {
    /// The next tracks this session hasn't handed out yet. Empty means the walk is over.
    func next(count: Int?) async throws -> [QueueItem]
}

extension ShuffleAllSession: ShuffleBatchSession {}

/// A running "Shuffle All" restricted to the songs kept on disk.
///
/// No backend random endpoint can narrow itself to what this device has downloaded, and
/// the whole point of the downloaded filter is that it holds up with no network — so the
/// order is drawn from the local library instead.
///
/// The full order is settled on the first draw rather than re-querying per batch: it
/// makes the walk repeat-free without a seen set, and it keeps the queue stable if a
/// download finishes or is deleted while the session is still playing out.
public actor DownloadedShuffleSession: ShuffleBatchSession {
    /// Tracks per batch. Smaller than the server walk's 500 because there is no request
    /// to amortise — the next slice is a free array read.
    public static let defaultBatchSize = 200

    private let storage: PersistentStorage
    private var order: [QueueItem]?
    private var cursor = 0

    public init(storage: PersistentStorage = .shared) {
        self.storage = storage
    }

    /// True once every downloaded track has been handed out.
    public var isFinished: Bool {
        guard let order else { return false }
        return cursor >= order.count
    }

    public func next(count: Int? = nil) async throws -> [QueueItem] {
        let order = try await settledOrder()
        guard cursor < order.count else { return [] }

        let size = min(max(1, count ?? Self.defaultBatchSize), order.count - cursor)
        defer { cursor += size }
        return Array(order[cursor..<(cursor + size)])
    }

    private func settledOrder() async throws -> [QueueItem] {
        if let order { return order }
        let drawn = try await drawDownloaded()
        order = drawn
        return drawn
    }

    /// `relFilePath != nil` is the same test the downloaded filter and `isDownloadedLocally`
    /// use, so the walk covers exactly the rows the list was showing.
    private func drawDownloaded() async throws -> [QueueItem] {
        try await storage.backgroundActor.perform { context in
            let songs = try context.fetch(
                FetchDescriptor<Song>(predicate: #Predicate<Song> { $0.relFilePath != nil })
            )
            return songs.map(QueueItem.from).shuffled()
        }
    }
}
