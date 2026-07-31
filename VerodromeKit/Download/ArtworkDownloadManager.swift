import Foundation
import UIKit

public protocol ArtworkURLProviding: AnyObject, Sendable {
    func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL
}

extension BackendURLProvider: ArtworkURLProviding {}

/// Downloads and resolves artwork tokens to local file URLs (or remote URLs as fallback).
/// Cache keys include requested pixel size so thumbnails never poison player/detail art.
public actor ArtworkDownloadManager {
    private let urlProvider: any ArtworkURLProviding
    private let maxConcurrent: Int
    private var pending: [(artId: String, kind: ArtworkKind, size: Int)] = []
    private var active = 0
    private var cacheDirectory: URL
    private var memory: [String: URL] = [:]
    /// Cache keys already proven absent from disk, so repeated scroll-ins skip the stat sweep.
    private var knownMisses: Set<String> = []

    /// Limits concurrent direct network loads from `loadImage` (which bypasses the
    /// prefetch queue). Without this, ~140 Home tiles fire URLSession requests at once.
    private let maxActiveLoads = 6
    private var activeLoads = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Coalesces identical requests from tiles that show the same artwork in different
    /// Home sections. Without this, each view decodes the same file independently.
    private var inFlightImages: [String: Task<UIImage?, Never>] = [:]

    public init(urlProvider: any ArtworkURLProviding, cacheDirectory: URL, maxConcurrent: Int = 2) {
        self.urlProvider = urlProvider
        self.cacheDirectory = cacheDirectory
        self.maxConcurrent = maxConcurrent
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func enqueue(artId: String, kind: ArtworkKind = .album, size: Int = 300) async {
        let key = cacheKey(artId: artId, size: size)
        if localURL(for: artId, size: size) != nil { return }
        if pending.contains(where: { $0.artId == artId && $0.size == size }) { return }
        pending.append((artId, kind, size))
        _ = key
        await pump()
    }

    /// Standard pixel sizes used across the app, ascending. Used to fall back to an
    /// already-cached larger render when the exact requested size is missing on disk,
    /// so Home tiles can reuse player/grid art instead of re-downloading.
    private static let standardSizes = [120, 300, 450, 900, 1200]

    public func localURL(for artId: String, size: Int = 300) -> URL? {
        let key = cacheKey(artId: artId, size: size)
        if let cached = memory[key] { return cached }
        // Without this, a token that isn't on disk re-runs the whole stat sweep below
        // every time its tile scrolls back into view.
        if knownMisses.contains(key) { return nil }
        let url = fileURL(for: artId, size: size)
        if FileManager.default.fileExists(atPath: url.path) {
            memory[key] = url
            return url
        }
        // Reuse the smallest already-cached render > requested size (SwiftUI downscales).
        for larger in Self.standardSizes where larger > size {
            let altKey = cacheKey(artId: artId, size: larger)
            if let cached = memory[altKey] { return cached }
            let altURL = fileURL(for: artId, size: larger)
            if FileManager.default.fileExists(atPath: altURL.path) {
                memory[altKey] = altURL
                return altURL
            }
        }
        knownMisses.insert(key)
        return nil
    }

    /// Prefers a cached file for this size; otherwise returns the signed remote URL.
    /// When `prefetchToDisk` is true, also enqueues a background disk cache download
    /// (list thumbnails should pass false to avoid double-downloading with AsyncImage).
    public func resolveURL(
        for artId: String?,
        kind: ArtworkKind = .album,
        size: Int = 300,
        prefetchToDisk: Bool = true
    ) async -> URL? {
        guard let artId, !artId.isEmpty else { return nil }
        if let local = localURL(for: artId, size: size) { return local }
        do {
            let remote = try await urlProvider.artworkURL(forArtId: artId, kind: kind, size: size)
            if prefetchToDisk {
                await enqueue(artId: artId, kind: kind, size: size)
            }
            return remote
        } catch {
            return nil
        }
    }

    public func loadImage(for artId: String?, kind: ArtworkKind = .album, size: Int = 300) async -> UIImage? {
        guard let artId, !artId.isEmpty else {
            ArtworkPerf.record(source: .miss, size: size, ms: 0, context: "loadImage")
            return nil
        }
        let key = "\(artId)|\(kind.rawValue)|\(size)"
        if let existing = inFlightImages[key] {
            return await existing.value
        }
        let task = Task {
            await self.loadImageUncached(for: artId, kind: kind, size: size)
        }
        inFlightImages[key] = task
        let image = await task.value
        inFlightImages[key] = nil
        return image
    }

    private func loadImageUncached(for artId: String, kind: ArtworkKind, size: Int) async -> UIImage? {
        // List thumbnails must not enqueue disk prefetch — that FIFO queue starved visible cells.
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let url = await resolveURL(for: artId, kind: kind, size: size, prefetchToDisk: false) else {
            ArtworkPerf.record(source: .miss, size: size, ms: 0, context: "loadImage")
            return nil
        }
        if Task.isCancelled {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: "loadImage")
            return nil
        }
        if url.isFileURL {
            let tPrep = CFAbsoluteTimeGetCurrent()
            let decoded = await Self.decodeDownsampled(fileURL: url, target: size)
            let prepMs = Int(((CFAbsoluteTimeGetCurrent() - tPrep) * 1000).rounded())
            guard let decoded else {
                ArtworkPerf.record(source: .miss, size: size, ms: prepMs, context: "diskRead")
                return nil
            }
            // `localURL` may hand back a larger already-cached render, so track what the
            // file actually contained versus what we asked for.
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(
                source: .disk,
                size: size,
                ms: totalMs,
                context: "loadImage",
                details: "prep=\(prepMs)ms src=\(decoded.sourcePixels)px want=\(size)px file=\(url.lastPathComponent)"
            )
            return decoded.image
        }
        // Gate concurrent network loads so Home's many tiles don't flood URLSession.
        await acquireLoadSlot()
        defer { releaseLoadSlot() }
        if Task.isCancelled {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: "loadImage")
            return nil
        }
        do {
            let tNet = CFAbsoluteTimeGetCurrent()
            let (data, _) = try await URLSession.shared.data(from: url)
            let netMs = Int(((CFAbsoluteTimeGetCurrent() - tNet) * 1000).rounded())
            if Task.isCancelled {
                ArtworkPerf.record(source: .cancel, size: size, ms: netMs, context: "network")
                return nil
            }
            // Persist to disk so the next visit hits the file cache instead of the network.
            let dest = fileURL(for: artId, size: size)
            try? data.write(to: dest, options: .atomic)
            noteStored(artId: artId, size: size, at: dest)
            // Decode off the actor, straight to the size we need.
            let tPrep = CFAbsoluteTimeGetCurrent()
            let prepared = await Self.decodeDownsampled(data: data, target: size)
            let prepMs = Int(((CFAbsoluteTimeGetCurrent() - tPrep) * 1000).rounded())
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(
                source: prepared == nil ? .miss : .network,
                size: size,
                ms: totalMs,
                context: "loadImage",
                details: "net=\(netMs)ms prep=\(prepMs)ms bytes=\(data.count)"
            )
            return prepared?.image
        } catch {
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(source: .miss, size: size, ms: totalMs, context: "networkError")
            return nil
        }
    }

    struct DecodedArtwork: Sendable {
        let image: UIImage
        /// Longest side of the file on disk, before downsampling.
        let sourcePixels: Int
    }

    private static func decodeDownsampled(fileURL: URL, target: Int) async -> DecodedArtwork? {
        await ImageDecodeLimiter.shared.run {
            guard let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            return Self.decode(source: source, target: target)
        }
    }

    private static func decodeDownsampled(data: Data, target: Int) async -> DecodedArtwork? {
        await ImageDecodeLimiter.shared.run {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            return Self.decode(source: source, target: target)
        }
    }

    /// Decodes straight to the requested pixel size in one ImageIO pass.
    ///
    /// The previous approach fully decoded the file into a `UIImage` and then redrew it
    /// through a `UIGraphicsImageRenderer` to shrink it. That decodes every pixel of a
    /// possibly-1024px file just to throw most of them away, and it took ~1s per image
    /// once several ran at once. `CGImageSourceCreateThumbnailAtIndex` decodes at the
    /// target size directly, and `ShouldCacheImmediately` forces the work to happen here
    /// rather than lazily on the main thread the first time SwiftUI composites the cell.
    private static func decode(source: CGImageSource, target: Int) -> DecodedArtwork? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let sourcePixels = max(width, height)

        // Never upscale: a smaller cached render stays as-is.
        let maxPixel = sourcePixels > 0 ? min(target, sourcePixels) : target
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return DecodedArtwork(
            image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            sourcePixels: sourcePixels
        )
    }

    private func acquireLoadSlot() async {
        if activeLoads < maxActiveLoads {
            activeLoads += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadWaiters.append(c)
        }
    }

    private func releaseLoadSlot() {
        if let next = loadWaiters.first {
            loadWaiters.removeFirst()
            next.resume() // hand the slot directly to the next waiter
        } else {
            activeLoads = max(0, activeLoads - 1)
        }
    }

    /// Stores raw image bytes extracted from an audio file's embedded tags.
    public func storeEmbeddedArtwork(artId: String, data: Data) {
        let dest = fileURL(for: artId, size: 0)
        try? data.write(to: dest, options: .atomic)
        noteStored(artId: artId, size: 0, at: dest)
    }

    /// Records a freshly cached file and drops the negative cache, since a new render can
    /// satisfy a smaller size that previously missed via the larger-size fallback.
    private func noteStored(artId: String, size: Int, at dest: URL) {
        memory[cacheKey(artId: artId, size: size)] = dest
        knownMisses.removeAll(keepingCapacity: true)
    }

    private func cacheKey(artId: String, size: Int) -> String {
        "\(sanitize(artId))_s\(size)"
    }

    private func sanitize(_ artId: String) -> String {
        artId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
    }

    private func fileURL(for artId: String, size: Int) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(artId: artId, size: size))
    }

    private func pump() async {
        while active < maxConcurrent, !pending.isEmpty {
            let item = pending.removeFirst()
            active += 1
            Task { await self.download(artId: item.artId, kind: item.kind, size: item.size) }
        }
    }

    private func download(artId: String, kind: ArtworkKind, size: Int) async {
        defer {
            active = max(0, active - 1)
            Task { await self.pump() }
        }
        do {
            let remote = try await urlProvider.artworkURL(forArtId: artId, kind: kind, size: size)
            let (temp, _) = try await URLSession.shared.download(from: remote)
            let dest = fileURL(for: artId, size: size)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
            noteStored(artId: artId, size: size, at: dest)
        } catch {}
    }

    // MARK: - Cache maintenance

    public struct CacheStats: Sendable, Hashable {
        public let fileCount: Int
        public let totalBytes: Int64

        public init(fileCount: Int, totalBytes: Int64) {
            self.fileCount = fileCount
            self.totalBytes = totalBytes
        }
    }

    public func cacheStats() -> CacheStats {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CacheStats(fileCount: 0, totalBytes: 0)
        }

        var count = 0
        var bytes: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        return CacheStats(fileCount: count, totalBytes: bytes)
    }

    public func clearCache() throws {
        pending.removeAll()
        memory.removeAll()
        knownMisses.removeAll()
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDirectory.path) {
            try fm.removeItem(at: cacheDirectory)
        }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

/// Bounds how many image decodes run at once.
///
/// Decoding is CPU work behind ImageIO's internal locks, so firing one unbounded
/// `Task.detached` per visible cell doesn't decode faster — it just makes every image wait
/// for all the others. Measured: ten concurrent decodes each took ~1s wall clock, while the
/// same decode in isolation takes ~2ms. A small window keeps per-image latency low and
/// leaves cores free for the main thread.
actor ImageDecodeLimiter {
    /// Enough width to use several cores, narrow enough that a burst can't saturate them.
    /// A single slot is worse than it sounds: an individual decode is only a few ms, so a
    /// backlog of thirty requests turns into seconds of queueing for the last one.
    static let shared = ImageDecodeLimiter(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable @escaping () -> T?) async -> T? {
        await acquire()
        defer { release() }
        // Detached so the decode runs off this actor (and off the caller's actor), letting
        // the artwork manager service other requests while pixels are being produced.
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

/// Main-actor facade for SwiftUI views.
@MainActor
public final class ArtworkResolver: ObservableObject {
    public static let shared = ArtworkResolver()

    /// Assigned once during app setup, before any view can request artwork, then only
    /// read. Kept nonisolated so `loadImage` never hops the main actor.
    nonisolated(unsafe) private var manager: ArtworkDownloadManager?
    private var memory: [String: URL] = [:]

    public init() {}

    public func attach(manager: ArtworkDownloadManager) {
        self.manager = manager
    }

    private func memoryKey(token: String, size: Int) -> String {
        "\(token)|s\(size)"
    }

    /// Synchronous memory probe for a specific pixel size — safe from SwiftUI without awaiting.
    public func cachedURL(for token: String?, size: Int = 300) -> URL? {
        guard let token, !token.isEmpty else { return nil }
        return memory[memoryKey(token: token, size: size)]
    }

    public func resolvedURL(
        for token: String?,
        kind: ArtworkKind = .album,
        size: Int = 300,
        prefetchToDisk: Bool = true
    ) async -> URL? {
        guard let token, !token.isEmpty else { return nil }
        let key = memoryKey(token: token, size: size)
        if let cached = memory[key] { return cached }
        guard let manager else {
            return URL(string: token)
        }
        if let url = await manager.resolveURL(for: token, kind: kind, size: size, prefetchToDisk: prefetchToDisk) {
            memory[key] = url
            return url
        }
        let embedded = "embedded-\(token)"
        if let url = await manager.localURL(for: embedded, size: 0) {
            memory[key] = url
            return url
        }
        return nil
    }

    /// Nonisolated: a scrolling carousel resolves many images at once, and hopping the
    /// main actor on the way in and out queued that work behind the scroll itself.
    public nonisolated func loadImage(
        for token: String?,
        kind: ArtworkKind = .album,
        size: Int = 300
    ) async -> UIImage? {
        guard let manager else { return nil }
        return await manager.loadImage(for: token, kind: kind, size: size)
    }

    public func diskCacheStats() async -> ArtworkDownloadManager.CacheStats {
        guard let manager else {
            return ArtworkDownloadManager.CacheStats(fileCount: 0, totalBytes: 0)
        }
        return await manager.cacheStats()
    }

    public func clearCaches() async throws {
        memory.removeAll()
        guard let manager else { return }
        try await manager.clearCache()
    }
}
