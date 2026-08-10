import Foundation
import UIKit

public protocol ArtworkURLProviding: AnyObject, Sendable {
    func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL
}

extension BackendURLProvider: ArtworkURLProviding {}

/// Downloads and resolves artwork tokens to local file URLs (or remote URLs as fallback).
/// Cache keys include requested pixel size so thumbnails never poison player/detail art.
public actor ArtworkDownloadManager: ArtworkPrefetching {
    private let urlProvider: any ArtworkURLProviding
    private let maxConcurrent: Int
    private var pending: [(artId: String, kind: ArtworkKind, size: Int)] = []
    private var active = 0
    private var cacheDirectory: URL
    /// Cache key → file URL for every render on disk. Seeded once from a directory listing
    /// and kept current by `noteStored`, so a probe is a dictionary lookup instead of one
    /// `stat` per standard size. Every write goes through `noteStored`, so a missing key
    /// authoritatively means "not cached" — no negative cache needed.
    private var memory: [String: URL] = [:]
    private var didIndexCacheDirectory = false

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
        if localURL(for: artId, size: size) != nil { return }
        if pending.contains(where: { $0.artId == artId && $0.size == size }) { return }
        pending.append((artId, kind, size))
        await pump()
    }

    /// The biggest render any screen asks a server for, shared by the detail hero (280pt)
    /// and the player cover so both come from one download and one cached file.
    ///
    /// Covers are photographs at arm's length, and servers rarely hold anything larger, so
    /// past this the extra pixels cost download time and ~3MB of memory each without being
    /// visible. Lower this to shrink both.
    public static let largestRequestedSize = 900

    /// Standard pixel sizes, ascending. Used to fall back to an already-cached larger
    /// render when the exact requested size is missing on disk, so Home tiles can reuse
    /// hero art instead of re-downloading.
    ///
    /// Includes 1200 even though nothing requests it any more: covers cached by an earlier
    /// version still answer today's requests rather than downloading a second copy.
    private static let standardSizes = [120, 300, 450, largestRequestedSize, 1200]

    /// Reads the cache directory once per launch. A single listing replaces the repeated
    /// per-size `fileExists` sweeps that every cold cache probe used to pay.
    private func indexCacheDirectoryIfNeeded() {
        guard !didIndexCacheDirectory else { return }
        // Only mark indexed after a successful listing. A transient failure must not leave
        // the session treating a full disk cache as empty forever.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        didIndexCacheDirectory = true
        // File names are cache keys, so the listing is the lookup table.
        for file in files where memory[file.lastPathComponent] == nil {
            memory[file.lastPathComponent] = file
        }
    }

    public func localURL(for artId: String, size: Int = 300) -> URL? {
        indexCacheDirectoryIfNeeded()
        if let cached = memory[cacheKey(artId: artId, size: size)] { return cached }
        // Reuse the smallest already-cached render > requested size (SwiftUI downscales).
        for larger in Self.standardSizes where larger > size {
            if let cached = memory[cacheKey(artId: artId, size: larger)] { return cached }
        }
        // Embedded tag art is stored at size 0 and should answer any UI size request.
        if size != 0, let embedded = memory[cacheKey(artId: artId, size: 0)] {
            return embedded
        }
        return nil
    }

    /// True when this size (or a larger render) is already on disk, so the load is a local
    /// decode with no network request. Lets callers skip delays meant to guard the network.
    public func hasLocalRender(for artId: String?, size: Int) -> Bool {
        guard let artId, !artId.isEmpty else { return false }
        return localURL(for: artId, size: size) != nil
    }

    /// A *smaller* cached render, decoded so a view can show art immediately while the
    /// requested size downloads. Navigating from a list (120px) or grid (300px) into a
    /// 900px hero would otherwise sit on a placeholder for the length of a download.
    ///
    /// Returns nil when `localURL` already has this size or larger — that load is a fast
    /// disk decode, and returning here too would decode the same file twice.
    public func downgradedCachedImage(for artId: String?, size: Int) async -> UIImage? {
        guard let artId, !artId.isEmpty else { return nil }
        if localURL(for: artId, size: size) != nil { return nil }
        for smaller in Self.standardSizes.reversed() where smaller < size {
            guard let url = memory[cacheKey(artId: artId, size: smaller)] else { continue }
            // `decode` never upscales, so this stays as cheap as the smaller render.
            return await Self.decodeDownsampled(fileURL: url, target: size)?.image
        }
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
            if let decoded {
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
            // 401/HTML (or other garbage) was persisted earlier — drop it and try the network.
            removeCachedFile(at: url)
            ArtworkPerf.record(source: .miss, size: size, ms: prepMs, context: "diskPoison")
        }
        // Gate concurrent network loads so Home's many tiles don't flood URLSession.
        await acquireLoadSlot()
        defer { releaseLoadSlot() }
        if Task.isCancelled {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: "loadImage")
            return nil
        }
        do {
            let remote: URL
            if url.isFileURL {
                // Disk entry was poisoned; resolve a fresh remote URL.
                guard let fresh = try? await urlProvider.artworkURL(forArtId: artId, kind: kind, size: size) else {
                    ArtworkPerf.record(source: .miss, size: size, ms: 0, context: "loadImage")
                    return nil
                }
                remote = fresh
            } else {
                remote = url
            }
            let tNet = CFAbsoluteTimeGetCurrent()
            let (data, response) = try await URLSession.shared.data(from: remote)
            let netMs = Int(((CFAbsoluteTimeGetCurrent() - tNet) * 1000).rounded())
            if Task.isCancelled {
                ArtworkPerf.record(source: .cancel, size: size, ms: netMs, context: "network")
                return nil
            }
            guard Self.isSuccessfulImageResponse(response, data: data) else {
                ArtworkPerf.record(source: .miss, size: size, ms: netMs, context: "badResponse")
                return nil
            }
            // Decode before writing so error bodies never poison the disk cache.
            let tPrep = CFAbsoluteTimeGetCurrent()
            let prepared = await Self.decodeDownsampled(data: data, target: size)
            let prepMs = Int(((CFAbsoluteTimeGetCurrent() - tPrep) * 1000).rounded())
            guard let prepared else {
                ArtworkPerf.record(source: .miss, size: size, ms: netMs + prepMs, context: "decodeMiss")
                return nil
            }
            let dest = fileURL(for: artId, size: size)
            try? data.write(to: dest, options: .atomic)
            noteStored(artId: artId, size: size, at: dest)
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(
                source: .network,
                size: size,
                ms: totalMs,
                context: "loadImage",
                details: "net=\(netMs)ms prep=\(prepMs)ms bytes=\(data.count)"
            )
            return prepared.image
        } catch {
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(source: .miss, size: size, ms: totalMs, context: "networkError")
            return nil
        }
    }

    private static func isSuccessfulImageResponse(_ response: URLResponse, data: Data? = nil) -> Bool {
        if let data, data.isEmpty { return false }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return false
        }
        if let mime = response.mimeType?.lowercased(),
           !mime.hasPrefix("image/"),
           mime != "application/octet-stream",
           mime != "binary/octet-stream" {
            return false
        }
        return true
    }

    private func removeCachedFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if let key = memory.first(where: { $0.value == url })?.key {
            memory[key] = nil
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

    private func noteStored(artId: String, size: Int, at dest: URL) {
        memory[cacheKey(artId: artId, size: size)] = dest
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
            let (temp, response) = try await URLSession.shared.download(from: remote)
            // Reject error/HTML bodies before they become permanent cache misses.
            let attrs = try FileManager.default.attributesOfItem(atPath: temp.path)
            let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0,
                  Self.isSuccessfulImageResponse(response),
                  await Self.decodeDownsampled(fileURL: temp, target: min(size, 64)) != nil else {
                try? FileManager.default.removeItem(at: temp)
                return
            }
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
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDirectory.path) {
            try fm.removeItem(at: cacheDirectory)
        }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // The directory is empty and `memory` matches it, so no re-listing is needed.
        didIndexCacheDirectory = true
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

    /// UI can appear (and request covers) a few frames before `initialize` attaches the
    /// download manager. Wait briefly rather than treating that race as a permanent miss.
    private nonisolated func resolvedManager(timeout: Duration = .seconds(10)) async -> ArtworkDownloadManager? {
        if let manager { return manager }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            if let manager { return manager }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return manager
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
        guard let manager = await resolvedManager() else {
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
        guard let manager = await resolvedManager() else { return nil }
        return await manager.loadImage(for: token, kind: kind, size: size)
    }

    /// An already-cached smaller render, for showing art immediately while `loadImage`
    /// fetches the requested size. Never hits the network, and returns nil when the
    /// requested size is already local.
    public nonisolated func downgradedImage(for token: String?, size: Int) async -> UIImage? {
        guard let manager = await resolvedManager() else { return nil }
        return await manager.downgradedCachedImage(for: token, size: size)
    }

    /// True when `loadImage` for this size will be served from disk rather than the network.
    public nonisolated func hasLocalRender(for token: String?, size: Int) async -> Bool {
        guard let manager = await resolvedManager() else { return false }
        return await manager.hasLocalRender(for: token, size: size)
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
