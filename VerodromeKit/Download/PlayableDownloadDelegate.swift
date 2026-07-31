import Foundation

public final class BackendURLProvider: StreamURLProviding, @unchecked Sendable {
    private let backend: any BackendApi
    public init(backend: any BackendApi) { self.backend = backend }

    public func streamURL(forPlayableId id: String, maxBitrate: Int, format: StreamFormat) async throws -> URL {
        PlayTrace.mark("BackendURLProvider.streamURL", details: "id=\(id) bitrate=\(maxBitrate)")
        let ref = PlayableRef(id: id, title: id)
        let resolved: StreamFormat? = format == .original ? nil : format
        guard let url = backend.generateStreamURL(for: ref, maxBitrate: maxBitrate, format: resolved) else {
            PlayTrace.error("generateStreamURL returned nil", details: id)
            throw BackendError.invalidURL
        }
        PlayTrace.mark("generateStreamURL OK", details: url.host ?? "?")
        return url
    }

    public func downloadURL(forPlayableId id: String, format: StreamFormat) async throws -> URL {
        let ref = PlayableRef(id: id, title: id)
        _ = format
        guard let url = backend.generateDownloadURL(for: ref) else {
            throw BackendError.invalidURL
        }
        return url
    }

    public func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
        let ref = ArtworkRef(id: artId, kind: kind)
        guard let url = backend.generateArtworkURL(for: ref, size: size) else {
            throw BackendError.invalidURL
        }
        return url
    }
}

public final class FilePlayableCache: PlayableFileCaching, @unchecked Sendable {
    private let root: URL
    private let fm = FileManager.default
    private var meta: [String: Meta] = [:]
    private let metaURL: URL

    private struct Meta: Codable {
        var reason: CacheReason
        var kind: PlayableRef.Kind
        var touched: Date
        var generation: Int
        var pinned: Bool
    }

    public init(root: URL) {
        self.root = root
        self.metaURL = root.appendingPathComponent("cache-meta.json")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        loadMeta()
    }

    private func key(_ id: String, _ kind: PlayableRef.Kind) -> String { "\(kind.rawValue)::\(id)" }

    public func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? {
        let url = root.appendingPathComponent(kind.rawValue).appendingPathComponent(id)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
        let dir = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(id)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temporaryURL, to: dest)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var destVar = dest; try? destVar.setResourceValues(values)
        meta[key(id, kind)] = Meta(reason: reason, kind: kind, touched: Date(), generation: meta[key(id, kind)]?.generation ?? 0, pinned: reason.isUserPinnedReason)
        saveMeta()
        return dest
    }

    public func deletePlayable(id: String, kind: PlayableRef.Kind) throws {
        if let url = fileURL(forPlayableId: id, kind: kind) { try fm.removeItem(at: url) }
        meta.removeValue(forKey: key(id, kind))
        saveMeta()
    }

    public func totalPlayableCacheSize() -> Int64 {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {
        let k = key(id, kind)
        if var existing = meta[k] {
            existing.touched = Date()
            if let reason {
                if reason.isUserPinnedReason || existing.reason == .none || existing.reason == .queuePrefetch {
                    existing.reason = reason
                    existing.pinned = reason.isUserPinnedReason || existing.pinned
                }
            }
            meta[k] = existing
        } else if fileURL(forPlayableId: id, kind: kind) != nil {
            meta[k] = Meta(reason: reason ?? .queuePrefetch, kind: kind, touched: Date(), generation: 0, pinned: reason?.isUserPinnedReason ?? false)
        }
        saveMeta()
    }

    public func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason {
        meta[key(id, kind)]?.reason ?? .none
    }

    public func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool {
        let m = meta[key(id, kind)]
        return m?.pinned == true || (m?.reason.isUserPinnedReason ?? false)
    }

    public func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] {
        meta.compactMap { key, value in
            if let reason, value.reason != reason { return nil }
            let cleanId = key.components(separatedBy: "::").last ?? key
            return (cleanId, value.kind, value.touched, value.generation)
        }
    }

    public func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {
        let k = key(id, kind)
        if var existing = meta[k] {
            existing.generation = generation
            meta[k] = existing
            saveMeta()
        }
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([String: Meta].self, from: data) else { return }
        meta = decoded
    }

    private func saveMeta() {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
