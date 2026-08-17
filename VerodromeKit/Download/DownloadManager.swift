import Foundation

public actor DownloadManager: DownloadManaging {
    private let urlProvider: any StreamURLProviding
    private let cache: any PlayableFileCaching
    private let maxConcurrent: Int
    /// Optional override for tests; production looks up the song's `contentType` in the library.
    private let contentTypeProvider: (@Sendable (String, PlayableRef.Kind) async -> String?)?
    private var isOffline: Bool
    private var pending: [(String, PlayableRef.Kind, CacheReason)] = []
    /// Downloads held back until the network policy allows them. Kept apart from
    /// `pending` so a metered connection can't starve the queue: these never reach
    /// `pump()` until `setNetworkPolicy` releases them.
    private var deferred: [(String, PlayableRef.Kind, CacheReason)] = []
    private var wifiOnly = true
    /// Starts false so Wi‑Fi-only downloads wait until `DownloadNetworkPolicy` has
    /// confirmed an unmetered path. Starting true would race the first cellular
    /// enqueue past the gate before the path monitor answered.
    private var isUnmetered = false
    private var activeCount = 0
    /// Transfers running right now, and the reason each is being kept for. The reason can
    /// change mid-transfer when the user downloads a track a prefetch already started.
    private var inFlight: [String: CacheReason] = [:]
    /// Live URL sessions for in-flight transfers so `cancelAll` can tear them down.
    private var sessions: [String: ProgressDownloadSession] = [:]

    public init(
        urlProvider: any StreamURLProviding,
        cache: any PlayableFileCaching,
        maxConcurrent: Int = 4,
        isOffline: Bool = false,
        contentTypeProvider: (@Sendable (String, PlayableRef.Kind) async -> String?)? = nil
    ) {
        self.urlProvider = urlProvider
        self.cache = cache
        self.maxConcurrent = maxConcurrent
        self.isOffline = isOffline
        self.contentTypeProvider = contentTypeProvider
    }

    public func setOffline(_ offline: Bool) async {
        isOffline = offline
        if offline { await cancelAll() }
    }

    /// Sets whether downloads may run right now, and releases anything that was waiting
    /// on the answer. Queue-window prefetch is never held by this policy.
    public func setNetworkPolicy(wifiOnlyAutomatic: Bool, isUnmetered: Bool) async {
        self.wifiOnly = wifiOnlyAutomatic
        self.isUnmetered = isUnmetered
        guard allowsDownloads, !deferred.isEmpty else { return }
        let released = deferred
        deferred.removeAll()
        for entry in released where !pending.contains(where: { $0.0 == entry.0 }) && inFlight[entry.0] == nil {
            pending.append(entry)
            await MainActor.run { DownloadCenter.shared.enqueued(playableId: entry.0) }
        }
        await pump()
    }

    /// Downloads still waiting on Wi-Fi, for tests and diagnostics.
    public var deferredIds: [String] { deferred.map(\.0) }

    private var allowsDownloads: Bool { !wifiOnly || isUnmetered }

    /// Queues a download. When Wi-Fi-only is on and the connection is metered, pinned
    /// downloads wait with a gray glyph until Wi-Fi returns — unless `force` is set, which
    /// is what a "Download Now" tap on a waiting track uses.
    public func enqueue(
        playableId: String,
        kind: PlayableRef.Kind,
        reason: CacheReason,
        force: Bool = false
    ) async {
        if isOffline { return }
        // Must match `downloadOne`'s storage key: lossy tracks requested as MP3 still
        // land under `.original`. Checking the setting quality alone re-downloads the
        // whole keep window on every queue advance.
        let storedQuality = await storageQuality(for: playableId, kind: kind, reason: reason)
        if let existingURL = cache.fileURL(forPlayableId: playableId, kind: kind, quality: storedQuality) {
            cache.touchPlayable(id: playableId, kind: kind, reason: reason)
            // The file is already here but the library may not know it — a queue
            // prefetch that later gets pinned, or a cache written before this ran.
            await recordCompletion(id: playableId, kind: kind, reason: reason)
            // Audio may have landed before lyrics caching existed (or while prefetch
            // skipped lyrics). Fill the sidecar without re-downloading the track.
            if kind == .song {
                await cacheLyricsIfNeeded(
                    id: playableId,
                    embedded: EmbeddedTagExtractor.lyrics(from: existingURL)
                )
            }
            return
        }
        // A prefetch of this track may already be queued or running. Upgrade it rather
        // than drop the request: an explicit download arriving mid-prefetch would
        // otherwise be swallowed and never recorded as a download at all.
        if let running = inFlight[playableId] {
            if reason.isUserPinnedReason, !running.isUserPinnedReason {
                inFlight[playableId] = reason
                await MainActor.run { DownloadCenter.shared.enqueued(playableId: playableId) }
            }
            return
        }
        if let index = pending.firstIndex(where: { $0.0 == playableId }) {
            if reason.isUserPinnedReason, !pending[index].2.isUserPinnedReason {
                pending[index].2 = reason
                await MainActor.run { DownloadCenter.shared.enqueued(playableId: playableId) }
            }
            return
        }
        // Prefetch serves playback already under way — holding it would stall the player.
        let shouldDefer = !force && reason.isUserPinnedReason && !allowsDownloads
        if let index = deferred.firstIndex(where: { $0.0 == playableId }) {
            if shouldDefer { return }
            deferred.remove(at: index)
            await MainActor.run { DownloadCenter.shared.clearDeferred(playableId: playableId) }
        } else if shouldDefer {
            deferred.append((playableId, kind, reason))
            await MainActor.run { DownloadCenter.shared.deferDownload(playableId: playableId) }
            return
        }
        pending.append((playableId, kind, reason))
        // A user download of a whole album leaves most tracks waiting behind
        // `maxConcurrent`; without this they would show no state at all until they start.
        if reason.isUserPinnedReason {
            await MainActor.run { DownloadCenter.shared.enqueued(playableId: playableId) }
        }
        await pump()
    }

    public func cancel(playableId: String) async {
        pending.removeAll { $0.0 == playableId }
        deferred.removeAll { $0.0 == playableId }
        inFlight.removeValue(forKey: playableId)
        sessions.removeValue(forKey: playableId)?.cancel()
        await MainActor.run {
            DownloadCenter.shared.clearActive(playableId: playableId)
        }
    }

    public func cancelAll() async {
        pending.removeAll()
        deferred.removeAll()
        inFlight.removeAll()
        activeCount = 0
        let activeSessions = sessions
        sessions.removeAll()
        for session in activeSessions.values {
            session.cancel()
        }
        await MainActor.run {
            DownloadCenter.shared.clearAllActive()
        }
    }

    public func cancelPending(reason: CacheReason, except keep: Set<String>) async {
        pending.removeAll { $0.2 == reason && !keep.contains($0.0) }
    }

    public func retryFailed() async {
        let failed = await MainActor.run { () -> Set<String> in
            let ids = DownloadCenter.shared.failedIds
            DownloadCenter.shared.clearFailed()
            return ids
        }
        for id in failed {
            await enqueue(playableId: id, kind: .song, reason: .userDownload)
        }
        await pump()
    }

    private func pump() async {
        while activeCount < maxConcurrent, !pending.isEmpty, !isOffline {
            let (id, kind, reason) = pending.removeFirst()
            activeCount += 1
            inFlight[id] = reason
            Task { await self.downloadOne(id: id, kind: kind, reason: reason) }
        }
    }

    private func downloadOne(id: String, kind: PlayableRef.Kind, reason requestedReason: CacheReason) async {
        defer {
            activeCount = max(0, activeCount - 1)
            inFlight.removeValue(forKey: id)
            Task { await self.pump() }
        }
        // `DownloadCenter` is the UI's view of downloads the user asked for. A queue
        // prefetch reported here puts a progress ring on whatever rows happen to be on
        // screen and an entry in the Downloads list's In Progress section.
        let reportsProgress = requestedReason.isUserPinnedReason
        if reportsProgress {
            await MainActor.run { DownloadCenter.shared.begin(playableId: id) }
        }
        do {
            let quality = await downloadQuality(for: requestedReason)
            let contentType = await songContentType(for: id, kind: kind)
            let resolved = AudioTranscodeResolver.resolve(quality: quality, contentType: contentType)
            let remote = try await urlProvider.downloadURL(
                forPlayableId: id,
                maxBitrate: resolved.maxBitRate,
                format: resolved.format ?? .original
            )
            let session = ProgressDownloadSession()
            sessions[id] = session
            defer { sessions[id] = nil }
            let tempURL = try await session.download(from: remote) { progress in
                guard reportsProgress else { return }
                Task { @MainActor in
                    DownloadCenter.shared.update(playableId: id, progress: progress)
                }
            }
            // Re-read the reason: the user may have asked for this track while the
            // prefetch that started it was still transferring.
            let reason = inFlight[id] ?? requestedReason
            // Store under the quality that was actually fetched so playback can seek
            // the matching local file without hitting the live stream again.
            let storedQuality = AudioTranscodeResolver.storageQuality(
                requested: quality,
                contentType: contentType
            )
            _ = try cache.storePlayable(
                id: id,
                kind: kind,
                from: tempURL,
                reason: reason,
                quality: storedQuality
            )
            if let localURL = cache.fileURL(forPlayableId: id, kind: kind, quality: storedQuality) {
                let extracted = EmbeddedTagExtractor.extract(from: localURL)
                if let artData = extracted.artworkData {
                    let artId = "embedded-\(id)"
                    if let artManager = await MainActor.run(body: { VerodromeKit.shared.artworkDownloadManager }) {
                        await artManager.storeEmbeddedArtwork(artId: artId, data: artData)
                    }
                    await MainActor.run {
                        if let account = try? VerodromeKit.shared.activeAccount(),
                           let song = try? VerodromeKit.shared.repository()?.resolveSong(remoteId: id, account: account) {
                            if song.artworkToken == nil || song.artworkToken?.isEmpty == true {
                                song.artworkToken = artId
                            }
                            if song.album?.artworkToken == nil || song.album?.artworkToken?.isEmpty == true {
                                song.album?.artworkToken = artId
                            }
                            try? VerodromeKit.shared.repository()?.save()
                        }
                    }
                }
                // Queue-window tracks and pinned downloads both need a lyrics sidecar so
                // playback can show lyrics offline / without another server round-trip.
                if kind == .song {
                    await cacheLyricsIfNeeded(id: id, embedded: extracted.lyrics)
                }
            }
            await recordCompletion(id: id, kind: kind, reason: reason)
            if reason.isUserPinnedReason {
                await MainActor.run { DownloadCenter.shared.complete(playableId: id) }
            }
        } catch is CancellationError {
            // Cancelled by offline mode / terminate — leave UI cleared by cancelAll.
        } catch {
            if (inFlight[id] ?? requestedReason).isUserPinnedReason {
                await MainActor.run { DownloadCenter.shared.fail(playableId: id) }
            }
        }
    }

    private func downloadQuality(for reason: CacheReason) async -> AudioTranscodeQuality {
        await MainActor.run {
            let store = SettingsStore.shared
            // Queue prefetch should match what playback will ask for, so seeks hit disk.
            if reason == .queuePrefetch {
                return NetworkMonitor.shared.isExpensive
                    ? store.streamingQualityCellular
                    : store.streamingQualityWifi
            }
            return store.downloadTranscodeQuality
        }
    }

    private func storageQuality(
        for id: String,
        kind: PlayableRef.Kind,
        reason: CacheReason
    ) async -> AudioTranscodeQuality {
        let quality = await downloadQuality(for: reason)
        let contentType = await songContentType(for: id, kind: kind)
        return AudioTranscodeResolver.storageQuality(requested: quality, contentType: contentType)
    }

    private func songContentType(for id: String, kind: PlayableRef.Kind) async -> String? {
        if let contentTypeProvider {
            return await contentTypeProvider(id, kind)
        }
        guard kind == .song else { return nil }
        return await MainActor.run {
            guard let repository = VerodromeKit.shared.repository(),
                  let account = try? VerodromeKit.shared.activeAccount(),
                  let song = try? repository.resolveSong(remoteId: id, account: account)
            else { return nil }
            return song.contentType
        }
    }

    /// Best-effort lyrics sidecar for a song on disk (prefetch or pinned). Failures never fail the download.
    private func cacheLyricsIfNeeded(id: String, embedded: String?) async {
        let lyricsCache = await MainActor.run { VerodromeKit.shared.lyricsCache }
        guard let lyricsCache else { return }
        if lyricsCache.load(id: id) != nil { return }

        let syncer = await MainActor.run {
            VerodromeKit.shared.activeLibrarySyncer as? (any LyricsProviding)
        }
        _ = await LyricsLookup.resolve(
            playableId: id,
            cache: lyricsCache,
            fetchFromServer: syncer.map { provider in
                { try await provider.fetchLyrics(playableId: id) }
            },
            embeddedLyrics: { embedded }
        )
    }

    /// Records the landed file on the library model. `relFilePath` is what the rest of
    /// the app reads as "downloaded", so it must only be written once bytes are on disk.
    ///
    /// Only pinned reasons are recorded. A queue prefetch is a temporary cache the
    /// policy manager can delete at any time, so writing it here would show the track
    /// as downloaded in the Downloads list and every row glyph — and `isDownloadRequested`
    /// would make the row's button offer to *remove* a download the user never asked for.
    /// The prefetch's own bookkeeping lives in the cache's metadata, which is what the
    /// prune loops read.
    private func recordCompletion(id: String, kind: PlayableRef.Kind, reason: CacheReason) async {
        guard reason.isUserPinnedReason else { return }
        guard kind == .song else { return }
        let fileURL = AudioTranscodeQuality.allCases.lazy
            .compactMap { self.cache.fileURL(forPlayableId: id, kind: kind, quality: $0) }
            .first
        guard let fileURL else { return }
        let relPath = "\(kind.rawValue)/\(id)"
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        await MainActor.run {
            guard let repository = VerodromeKit.shared.repository(),
                  let account = try? VerodromeKit.shared.activeAccount(),
                  let song = try? repository.resolveSong(remoteId: id, account: account)
            else { return }
            song.relFilePath = relPath
            song.size = song.size ?? size
            song.cacheTouchedDate = .now
            song.cacheReason = reason
            song.isUserPinned = true
            try? repository.save()
        }
    }
}
