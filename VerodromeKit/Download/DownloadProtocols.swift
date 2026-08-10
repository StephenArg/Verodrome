import Foundation

public protocol StreamURLProviding: AnyObject, Sendable {
    func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL
    func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL
    func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL
}

/// Breakdown of on-disk playable audio (downloads + queue prefetch). Artwork is separate.
public struct PlayableCacheStats: Sendable, Hashable {
    /// Offline / pinned files the user (or auto-cache) asked to keep.
    public var offlineBytes: Int64
    public var offlineCount: Int
    /// Temporary queue-prefetch files the prune loop may delete.
    public var temporaryBytes: Int64
    public var temporaryCount: Int

    public init(
        offlineBytes: Int64 = 0,
        offlineCount: Int = 0,
        temporaryBytes: Int64 = 0,
        temporaryCount: Int = 0
    ) {
        self.offlineBytes = offlineBytes
        self.offlineCount = offlineCount
        self.temporaryBytes = temporaryBytes
        self.temporaryCount = temporaryCount
    }

    public static let empty = PlayableCacheStats()
}

public protocol PlayableFileCaching: AnyObject, Sendable {
    func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL?
    func fileURL(forPlayableId id: String, kind: PlayableRef.Kind, quality: AudioTranscodeQuality) -> URL?
    func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL
    func storePlayable(
        id: String,
        kind: PlayableRef.Kind,
        from temporaryURL: URL,
        reason: CacheReason,
        quality: AudioTranscodeQuality
    ) throws -> URL
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

    func fileURL(forPlayableId id: String, kind: PlayableRef.Kind, quality: AudioTranscodeQuality) -> URL? {
        quality == .original ? fileURL(forPlayableId: id, kind: kind) : nil
    }

    /// True when any quality variant (original or MP3 bitrate) is on disk.
    func hasPlayableFile(id: String, kind: PlayableRef.Kind) -> Bool {
        AudioTranscodeQuality.allCases.contains {
            fileURL(forPlayableId: id, kind: kind, quality: $0) != nil
        }
    }

    func storePlayable(
        id: String,
        kind: PlayableRef.Kind,
        from temporaryURL: URL,
        reason: CacheReason,
        quality: AudioTranscodeQuality
    ) throws -> URL {
        guard quality == .original else {
            throw BackendError.network("This cache does not store transcoded variants")
        }
        return try storePlayable(id: id, kind: kind, from: temporaryURL, reason: reason)
    }

    func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64 {
        guard let url = fileURL(forPlayableId: id, kind: kind) else { return 0 }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Sums file sizes for pinned offline music vs temporary queue-prefetch cache.
    func playableCacheStats() -> PlayableCacheStats {
        var offlineBytes: Int64 = 0
        var offlineCount = 0
        var temporaryBytes: Int64 = 0
        var temporaryCount = 0
        for entry in cachedPlayableIds(reason: nil) {
            let bytes = playableByteSize(id: entry.id, kind: entry.kind)
            if isUserPinned(id: entry.id, kind: entry.kind) {
                offlineBytes += bytes
                offlineCount += 1
            } else {
                temporaryBytes += bytes
                temporaryCount += 1
            }
        }
        return PlayableCacheStats(
            offlineBytes: offlineBytes,
            offlineCount: offlineCount,
            temporaryBytes: temporaryBytes,
            temporaryCount: temporaryCount
        )
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
