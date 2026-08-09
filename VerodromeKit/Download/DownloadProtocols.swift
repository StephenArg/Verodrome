import Foundation

public protocol StreamURLProviding: AnyObject, Sendable {
    func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL
    func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL
    func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL
}

public protocol PlayableFileCaching: AnyObject, Sendable {
    func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL?
    func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL
    func deletePlayable(id: String, kind: PlayableRef.Kind) throws
    func totalPlayableCacheSize() -> Int64
    func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64
    func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?)
    func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason
    func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool
    func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)]
    func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int)
    /// Files on disk the cache has no record of, and which therefore no prune loop can
    /// reach. `minimumAge` skips files young enough to still be mid-store.
    func orphanedFiles(olderThan minimumAge: TimeInterval) -> [(id: String, kind: PlayableRef.Kind)]
}

public extension PlayableFileCaching {
    /// A cache that keeps no separate bookkeeping cannot strand a file.
    func orphanedFiles(olderThan minimumAge: TimeInterval) -> [(id: String, kind: PlayableRef.Kind)] { [] }

    func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64 {
        guard let url = fileURL(forPlayableId: id, kind: kind) else { return 0 }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

public protocol DownloadManaging: AnyObject, Sendable {
    func enqueue(playableId: String, kind: PlayableRef.Kind, reason: CacheReason, force: Bool) async
    func cancel(playableId: String) async
    func cancelAll() async
    /// Drops pending downloads of the given reason whose `playableId` is not in `keep`.
    /// Already-running downloads are left alone — they finish and the existing prune
    /// loop deletes anything that landed outside the keep window.
    func cancelPending(reason: CacheReason, except keep: Set<String>) async
    func retryFailed() async
}

public extension DownloadManaging {
    func enqueue(playableId: String, kind: PlayableRef.Kind, reason: CacheReason) async {
        await enqueue(playableId: playableId, kind: kind, reason: reason, force: false)
    }
}

/// Disk-prefetch of cover art for the queue window (player / Now Playing size).
public protocol ArtworkPrefetching: AnyObject, Sendable {
    func enqueue(artId: String, kind: ArtworkKind, size: Int) async
}
