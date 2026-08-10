import Foundation

public final class BackendURLProvider: StreamURLProviding, @unchecked Sendable {
    private let backend: any BackendApi
    public init(backend: any BackendApi) { self.backend = backend }

    public func streamURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
        PlayTrace.mark("BackendURLProvider.streamURL", details: "id=\(id) bitrate=\(maxBitrate.map(String.init) ?? "nil") format=\(format)")
        let ref = PlayableRef(id: id, title: id)
        let resolved: StreamFormat? = format == .original ? nil : format
        guard let url = backend.generateStreamURL(for: ref, maxBitrate: maxBitrate, format: resolved) else {
            PlayTrace.error("generateStreamURL returned nil", details: id)
            throw BackendError.invalidURL
        }
        PlayTrace.mark("generateStreamURL OK", details: url.query ?? url.absoluteString)
        return url
    }

    public func downloadURL(forPlayableId id: String, maxBitrate: Int?, format: StreamFormat) async throws -> URL {
        let ref = PlayableRef(id: id, title: id)
        let resolved: StreamFormat? = format == .original ? nil : format
        guard let url = backend.generateDownloadURL(for: ref, maxBitrate: maxBitrate, format: resolved) else {
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

    private func key(_ id: String, _ kind: PlayableRef.Kind, quality: AudioTranscodeQuality = .original) -> String {
        "\(kind.rawValue)::\(fileName(id: id, quality: quality))"
    }

    private func fileName(id: String, quality: AudioTranscodeQuality) -> String {
        if let suffix = quality.cacheFileName {
            return "\(id).\(suffix)"
        }
        return id
    }

    public func fileURL(forPlayableId id: String, kind: PlayableRef.Kind) -> URL? {
        fileURL(forPlayableId: id, kind: kind, quality: .original)
    }

    public func fileURL(forPlayableId id: String, kind: PlayableRef.Kind, quality: AudioTranscodeQuality) -> URL? {
        let url = root
            .appendingPathComponent(kind.rawValue)
            .appendingPathComponent(fileName(id: id, quality: quality))
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func storePlayable(id: String, kind: PlayableRef.Kind, from temporaryURL: URL, reason: CacheReason) throws -> URL {
        try storePlayable(id: id, kind: kind, from: temporaryURL, reason: reason, quality: .original)
    }

    public func storePlayable(
        id: String,
        kind: PlayableRef.Kind,
        from temporaryURL: URL,
        reason: CacheReason,
        quality: AudioTranscodeQuality
    ) throws -> URL {
        let dir = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName(id: id, quality: quality))
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temporaryURL, to: dest)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var destVar = dest; try? destVar.setResourceValues(values)
        lock.withLock {
            let k = key(id, kind, quality: quality)
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
        for quality in AudioTranscodeQuality.allCases {
            if let url = fileURL(forPlayableId: id, kind: kind, quality: quality) {
                try fm.removeItem(at: url)
            }
            lock.withLock {
                meta.removeValue(forKey: key(id, kind, quality: quality))
                saveMetaLocked()
            }
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

    public func playableByteSize(id: String, kind: PlayableRef.Kind) -> Int64 {
        var total: Int64 = 0
        for quality in AudioTranscodeQuality.allCases {
            guard let url = fileURL(forPlayableId: id, kind: kind, quality: quality) else { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public func touchPlayable(id: String, kind: PlayableRef.Kind, reason: CacheReason?) {
        for quality in AudioTranscodeQuality.allCases {
            let hasFile = fileURL(forPlayableId: id, kind: kind, quality: quality) != nil
            lock.withLock {
                let k = key(id, kind, quality: quality)
                if var existing = meta[k] {
                    existing.touched = Date()
                    if let reason {
                        if reason.isUserPinnedReason || existing.reason == .none || existing.reason == .queuePrefetch {
                            existing.reason = reason
                            existing.pinned = reason.isUserPinnedReason || existing.pinned
                        }
                    }
                    meta[k] = existing
                    saveMetaLocked()
                } else if hasFile {
                    meta[k] = Meta(
                        reason: reason ?? .queuePrefetch,
                        kind: kind,
                        touched: Date(),
                        generation: 0,
                        pinned: reason?.isUserPinnedReason ?? false
                    )
                    saveMetaLocked()
                }
            }
        }
    }

    public func cacheReason(forPlayableId id: String, kind: PlayableRef.Kind) -> CacheReason {
        lock.withLock {
            for quality in AudioTranscodeQuality.allCases {
                if let reason = meta[key(id, kind, quality: quality)]?.reason, reason != .none {
                    return reason
                }
            }
            return .none
        }
    }

    public func isUserPinned(id: String, kind: PlayableRef.Kind) -> Bool {
        lock.withLock {
            for quality in AudioTranscodeQuality.allCases {
                let m = meta[key(id, kind, quality: quality)]
                if m?.pinned == true || (m?.reason.isUserPinnedReason ?? false) {
                    return true
                }
            }
            return false
        }
    }

    public func cachedPlayableIds(reason: CacheReason?) -> [(id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] {
        lock.withLock {
            var best: [String: (id: String, kind: PlayableRef.Kind, touched: Date, generation: Int)] = [:]
            for (key, value) in meta {
                if let reason, value.reason != reason { continue }
                let fileName = key.components(separatedBy: "::").last ?? key
                let playableId = AudioTranscodeQuality.playableId(fromCacheFileName: fileName)
                let entry = (playableId, value.kind, value.touched, value.generation)
                if let existing = best[playableId] {
                    // Keep the newest touch so prune logic sees one row per song.
                    if value.touched > existing.touched {
                        best[playableId] = entry
                    }
                } else {
                    best[playableId] = entry
                }
            }
            return Array(best.values)
        }
    }

    public func setQueueGeneration(id: String, kind: PlayableRef.Kind, generation: Int) {
        lock.withLock {
            for quality in AudioTranscodeQuality.allCases {
                let k = key(id, kind, quality: quality)
                guard var existing = meta[k] else { continue }
                existing.generation = generation
                meta[k] = existing
            }
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
                orphans.append((AudioTranscodeQuality.playableId(fromCacheFileName: name), kind))
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
