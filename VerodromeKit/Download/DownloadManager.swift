import Foundation

public actor DownloadManager: DownloadManaging {
    private let urlProvider: any StreamURLProviding
    private let cache: any PlayableFileCaching
    private let maxConcurrent: Int
    private var isOffline: Bool
    private var pending: [(String, PlayableRef.Kind, CacheReason)] = []
    private var activeCount = 0
    /// Transfers running right now, and the reason each is being kept for. The reason can
    /// change mid-transfer when the user downloads a track a prefetch already started.
    private var inFlight: [String: CacheReason] = [:]

    public init(
        urlProvider: any StreamURLProviding,
        cache: any PlayableFileCaching,
        maxConcurrent: Int = 4,
        isOffline: Bool = false
    ) {
        self.urlProvider = urlProvider
        self.cache = cache
        self.maxConcurrent = maxConcurrent
        self.isOffline = isOffline
    }

    public func setOffline(_ offline: Bool) async {
        isOffline = offline
        if offline { await cancelAll() }
    }

    public func enqueue(playableId: String, kind: PlayableRef.Kind, reason: CacheReason) async {
        if isOffline { return }
        if cache.fileURL(forPlayableId: playableId, kind: kind) != nil {
            cache.touchPlayable(id: playableId, kind: kind, reason: reason)
            // The file is already here but the library may not know it — a queue
            // prefetch that later gets pinned, or a cache written before this ran.
            await recordCompletion(id: playableId, kind: kind, reason: reason)
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
        inFlight.removeValue(forKey: playableId)
        await MainActor.run {
            DownloadCenter.shared.clearActive(playableId: playableId)
        }
    }

    public func cancelAll() async {
        pending.removeAll()
        inFlight.removeAll()
        activeCount = 0
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
            let remote = try await urlProvider.downloadURL(forPlayableId: id, format: .original)
            let session = ProgressDownloadSession()
            let tempURL = try await session.download(from: remote) { progress in
                guard reportsProgress else { return }
                Task { @MainActor in
                    DownloadCenter.shared.update(playableId: id, progress: progress)
                }
            }
            // Re-read the reason: the user may have asked for this track while the
            // prefetch that started it was still transferring.
            let reason = inFlight[id] ?? requestedReason
            _ = try cache.storePlayable(id: id, kind: kind, from: tempURL, reason: reason)
            if let localURL = cache.fileURL(forPlayableId: id, kind: kind) {
                let extracted = EmbeddedTagExtractor.extract(from: localURL)
                if let artData = extracted.artworkData {
                    let artId = "embedded-\(id)"
                    if let artManager = await MainActor.run(body: { VerodromeKit.shared.artworkDownloadManager }) {
                        await artManager.storeEmbeddedArtwork(artId: artId, data: artData)
                    }
                    await MainActor.run {
                        if let account = try? VerodromeKit.shared.activeAccount(),
                           let song = try? VerodromeKit.shared.repository()?.resolveSong(remoteId: id, account: account),
                           song.album?.artworkToken == nil || song.album?.artworkToken?.isEmpty == true {
                            song.album?.artworkToken = artId
                            try? VerodromeKit.shared.repository()?.save()
                        }
                    }
                }
            }
            await recordCompletion(id: id, kind: kind, reason: reason)
            if reason.isUserPinnedReason {
                await MainActor.run { DownloadCenter.shared.complete(playableId: id) }
            }
        } catch {
            if (inFlight[id] ?? requestedReason).isUserPinnedReason {
                await MainActor.run { DownloadCenter.shared.fail(playableId: id) }
            }
        }
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
        guard kind == .song, let fileURL = cache.fileURL(forPlayableId: id, kind: kind) else { return }
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
