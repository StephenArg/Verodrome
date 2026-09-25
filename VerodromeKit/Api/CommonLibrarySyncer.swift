import Foundation

/// Shared pagination and connectivity helpers for library syncers.
public enum CommonLibrarySyncer {
    public static let defaultPageSize = 500

    public struct PageRequest: Sendable {
        public let offset: Int
        public let limit: Int

        public init(offset: Int, limit: Int = defaultPageSize) {
            self.offset = offset
            self.limit = limit
        }

        public func nextPage(itemCount: Int) -> PageRequest? {
            guard itemCount >= limit else { return nil }
            return PageRequest(offset: offset + limit, limit: limit)
        }
    }

    /// Ensures network is available before performing a sync step.
    public static func requireNetwork(isConnected: Bool) throws {
        guard isConnected else {
            throw LibrarySyncerError.offline
        }
    }

    /// Paginates an async fetch closure until a page returns fewer than `limit` items.
    public static func fetchAllPages<T: Sendable>(
        pageSize: Int = defaultPageSize,
        fetch: (_ offset: Int, _ limit: Int) async throws -> [T]
    ) async throws -> [T] {
        var all: [T] = []
        var offset = 0

        while true {
            let page = try await fetch(offset, pageSize)
            all.append(contentsOf: page)
            guard page.count >= pageSize else { break }
            offset += pageSize
        }

        return all
    }

    /// How many album-detail requests a Home prefetch keeps in flight at once.
    public static let albumDetailConcurrency = 4

    /// Newest-album ids to pull tracks for, in list order. `.missing` drops albums that
    /// already have songs stored, which after a full sync is nearly all of them.
    public static func albumIds(
        _ albumIds: [String],
        needingTracks tracks: NewestAlbumTracks,
        ingestor: LibraryIngesting
    ) async throws -> [String] {
        switch tracks {
        case .all:
            return albumIds
        case .missing:
            let stored = try await ingestor.albumRemoteIdsWithSongs(albumIds)
            return albumIds.filter { !stored.contains($0) }
        }
    }

    /// Runs `fetch` for each id with at most `maxConcurrent` in flight, returning the
    /// results in the order of `ids`. The first failure cancels the rest and is rethrown.
    public static func fetchEach<T: Sendable>(
        _ ids: [String],
        maxConcurrent: Int = albumDetailConcurrency,
        fetch: @escaping @Sendable (String) async throws -> T
    ) async throws -> [T] {
        guard !ids.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: ids.count)
            var next = 0
            while next < min(max(1, maxConcurrent), ids.count) {
                let index = next
                group.addTask { (index, try await fetch(ids[index])) }
                next += 1
            }
            while let (index, value) = try await group.next() {
                results[index] = value
                if next < ids.count {
                    let index = next
                    group.addTask { (index, try await fetch(ids[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    public static func report(
        _ progress: LibrarySyncProgressHandler?,
        _ message: String,
        fraction: Double? = nil
    ) {
        progress?(LibrarySyncProgress(message: message, fraction: fraction))
    }

    public static func report(
        _ progress: LibrarySyncProgressHandler?,
        _ message: String,
        stage: LibrarySyncCatalogStage
    ) {
        report(progress, message, fraction: stage.fraction)
    }

    /// Reports the track crawl. `total` is nil until the server tells us how much
    /// there is, which leaves the bar where it was rather than guessing.
    public static func report(
        _ progress: LibrarySyncProgressHandler?,
        _ message: String,
        tracksCompleted completed: Int,
        of total: Int?
    ) {
        guard let total, total > 0 else {
            report(progress, message)
            return
        }
        report(progress, message, fraction: LibrarySyncPhase.tracks.overall(Double(completed) / Double(total)))
    }
}
