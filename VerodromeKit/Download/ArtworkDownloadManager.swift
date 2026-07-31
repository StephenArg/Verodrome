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

    /// Limits concurrent direct network loads from `loadImage` (which bypasses the
    /// prefetch queue). Without this, ~140 Home tiles fire URLSession requests at once.
    private let maxActiveLoads = 6
    private var activeLoads = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

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
        let url = fileURL(for: artId, size: size)
        if FileManager.default.fileExists(atPath: url.path) {
            memory[key] = url
            return url
        }
        // Reuse the smallest already-cached render >= requested size (SwiftUI downscales).
        for larger in Self.standardSizes where larger >= size {
            let altKey = cacheKey(artId: artId, size: larger)
            if let cached = memory[altKey] { return cached }
            let altURL = fileURL(for: artId, size: larger)
            if FileManager.default.fileExists(atPath: altURL.path) {
                memory[altKey] = altURL
                return altURL
            }
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
        // List thumbnails must not enqueue disk prefetch — that FIFO queue starved visible cells.
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let artId, !artId.isEmpty,
              let url = await resolveURL(for: artId, kind: kind, size: size, prefetchToDisk: false) else {
            ArtworkPerf.record(source: .miss, size: size, ms: 0, context: "loadImage")
            return nil
        }
        if Task.isCancelled {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: "loadImage")
            return nil
        }
        if url.isFileURL {
            let tRead = CFAbsoluteTimeGetCurrent()
            let raw = UIImage(contentsOfFile: url.path)
            let readMs = Int(((CFAbsoluteTimeGetCurrent() - tRead) * 1000).rounded())
            guard let raw else {
                ArtworkPerf.record(source: .miss, size: size, ms: readMs, context: "diskRead")
                return nil
            }
            let tPrep = CFAbsoluteTimeGetCurrent()
            let prepared = prepare(raw, for: size)
            let prepMs = Int(((CFAbsoluteTimeGetCurrent() - tPrep) * 1000).rounded())
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(
                source: .disk,
                size: size,
                ms: totalMs,
                context: "loadImage",
                details: "read=\(readMs)ms prep=\(prepMs)ms file=\(url.lastPathComponent)"
            )
            return prepared
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
            memory[cacheKey(artId: artId, size: size)] = dest
            let tPrep = CFAbsoluteTimeGetCurrent()
            let prepared: UIImage?
            if let img = UIImage(data: data) {
                prepared = prepare(img, for: size)
            } else {
                prepared = nil
            }
            let prepMs = Int(((CFAbsoluteTimeGetCurrent() - tPrep) * 1000).rounded())
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(
                source: prepared == nil ? .miss : .network,
                size: size,
                ms: totalMs,
                context: "loadImage",
                details: "net=\(netMs)ms prep=\(prepMs)ms bytes=\(data.count)"
            )
            return prepared
        } catch {
            let totalMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            ArtworkPerf.record(source: .miss, size: size, ms: totalMs, context: "networkError")
            return nil
        }
    }

    /// Force-decodes (and optionally downscales) the image off the main thread so
    /// displaying it during scroll doesn't trigger a synchronous decode hitch.
    /// `UIImage(contentsOfFile:)` / `UIImage(data:)` return lazy images that decode
    /// on the main thread when first composited — a major scroll-lag source. Drawing
    /// through a renderer here forces decode off-main. Never upscales; caps the
    /// longest side at `target` pixels.
    private func prepare(_ image: UIImage, for target: Int) -> UIImage {
        let scale = image.scale
        let naturalW = image.size.width * scale
        let naturalH = image.size.height * scale
        let naturalMax = max(naturalW, naturalH)
        guard naturalMax > 0 else { return image }
        let cap = CGFloat(target > 0 ? target : Int(naturalMax))
        let outMax = min(naturalMax, cap) // never upscale
        let ratio = outMax / naturalMax
        let outSize = CGSize(width: naturalW * ratio, height: naturalH * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // outSize is in pixels, not points
        let renderer = UIGraphicsImageRenderer(size: outSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: outSize))
        }
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
        memory[cacheKey(artId: artId, size: 0)] = dest
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
            memory[cacheKey(artId: artId, size: size)] = dest
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
    }
}

/// Main-actor facade for SwiftUI views.
@MainActor
public final class ArtworkResolver: ObservableObject {
    public static let shared = ArtworkResolver()

    private var manager: ArtworkDownloadManager?
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

    public func loadImage(for token: String?, kind: ArtworkKind = .album, size: Int = 300) async -> UIImage? {
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
