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
        // Absolute URLs (Ampache signed art, podcast images) don't need a session.
        if artId.hasPrefix("http://") || artId.hasPrefix("https://"),
           let absolute = URL(string: artId) {
            return absolute
        }
        // Cold launch shows the library before `ensureActiveLibrarySyncer` finishes login.
        // Panels request covers immediately; without waiting they get a hard miss and never
        // retry, so the grid stays blank until the user opens an album (which loads later).
        guard await waitUntilAuthenticated() else {
            throw BackendError.notAuthenticated
        }
        let ref = ArtworkRef(id: artId, kind: kind)
        guard let url = backend.generateArtworkURL(for: ref, size: size) else {
            throw BackendError.invalidURL
        }
        return url
    }

    /// Suspends until the backend has an authenticated API, or the timeout elapses.
    private func waitUntilAuthenticated(timeout: Duration = .seconds(30)) async -> Bool {
        if backend.isAuthenticated { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if backend.isAuthenticated { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return backend.isAuthenticated
    }
}

public final class FilePlayableCache: PlayableFileCaching, @unchecked Sendable {
    private let root: URL
    private let fm = FileManager.default
    private var meta: [String: Meta] = [:]
    private let metaURL: URL
    /// `meta` is written from the main actor (the queue cache policy) and from inside the
    /// `DownloadManager` actor (a transfer landing). Without this, a lost entry leaves a
    /// file on disk that neither prune loop can see, because both iterate `meta`.
    private let lock = NSLock()

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
        lock.withLock { loadMetaLocked() }
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
        lock.withLock {
            let k = key(id, kind)
            meta[k] = Meta(
                reason: reason,
                kind: kind,
                touched: Date(),
                generation: meta[k]?.generation ?? 0,
                pinned: reason.isUserPinnedReason
            )
            saveMetaLocked()
        }
        return dest
    }

    public func deletePlayable(id: String, kind: PlayableRef.Kind) throws {
        if let url = fileURL(forPlayableId: id, kind: kind) { try fm.removeItem(at: url) }
        lock.withLock {
            meta.removeValue(forKey: key(id, kind))
            saveMetaLocked()
        }
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
        let hasFile = fileURL(forPlayableId: id, kind: kind) != nil
        lock.withLock {
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
            } else if hasFile {
                meta[k] = Meta(reason: reason ?? .queuePrefetch, kind: kind, touched: Date(), generation: 0, pinned: reason?.isUserPinnedReason ?? false)
            }
            saveMetaLocked()
        }
    }

    public func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason {
        lock.withLock { meta[key(id, kind)]?.reason ?? .none }
    }

    public func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool {
        lock.withLock {
            let m = meta[key(id, kind)]
            return m?.pinned == true || (m?.reason.isUserPinnedReason ?? false)
        }
    }

    public func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] {
        lock.withLock {
            meta.compactMap { key, value in
                if let reason, value.reason != reason { return nil }
                let cleanId = key.components(separatedBy: "::").last ?? key
                return (cleanId, value.kind, value.touched, value.generation)
            }
        }
    }

    public func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {
        lock.withLock {
            let k = key(id, kind)
            guard var existing = meta[k] else { return }
            existing.generation = generation
            meta[k] = existing
            saveMetaLocked()
        }
    }

    public func orphanedFiles(olderThan minimumAge: TimeInterval) -> [(id: String, kind: PlayableRef.Kind)] {
        let known = lock.withLock { Set(meta.keys) }
        let cutoff = Date().addingTimeInterval(-minimumAge)
        var orphans: [(id: String, kind: PlayableRef.Kind)] = []
        for kind in PlayableRef.Kind.allCases {
            let dir = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where !known.contains(key(name, kind)) {
                // `storePlayable` moves the file into place before taking the lock, so a
                // transfer that just landed looks orphaned for an instant.
                let url = dir.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified < cutoff else { continue }
                orphans.append((name, kind))
            }
        }
        return orphans
    }

    private func loadMetaLocked() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([String: Meta].self, from: data) else { return }
        meta = decoded
    }

    private func saveMetaLocked() {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
