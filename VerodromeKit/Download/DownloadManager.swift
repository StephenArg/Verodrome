import Foundation

public actor DownloadManager: DownloadManaging {
    private let urlProvider: any StreamURLProviding
    private let cache: any PlayableFileCaching
    private let maxConcurrent: Int
    private var isOffline: Bool
    private var pending: [(String, PlayableRef.Kind, CacheReason)] = []
    private var activeCount = 0
    private var inFlight: Set<String> = []

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
            return
        }
        if inFlight.contains(playableId) || pending.contains(where: { $0.0 == playableId }) { return }
        pending.append((playableId, kind, reason))
        await pump()
    }

    public func cancel(playableId: String) async {
        pending.removeAll { $0.0 == playableId }
        inFlight.remove(playableId)
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
            inFlight.insert(id)
            Task { await self.downloadOne(id: id, kind: kind, reason: reason) }
        }
    }

    private func downloadOne(id: String, kind: PlayableRef.Kind, reason: CacheReason) async {
        defer {
            activeCount = max(0, activeCount - 1)
            inFlight.remove(id)
            Task { await self.pump() }
        }
        await MainActor.run { DownloadCenter.shared.begin(playableId: id) }
        do {
            let remote = try await urlProvider.downloadURL(forPlayableId: id, format: .original)
            let session = ProgressDownloadSession()
            let tempURL = try await session.download(from: remote) { progress in
                Task { @MainActor in
                    DownloadCenter.shared.update(playableId: id, progress: progress)
                }
            }
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
            await MainActor.run { DownloadCenter.shared.complete(playableId: id) }
        } catch {
            await MainActor.run { DownloadCenter.shared.fail(playableId: id) }
        }
    }
}
