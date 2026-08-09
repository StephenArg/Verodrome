import Foundation

public protocol ScrobbleUploading: AnyObject, Sendable {
    func uploadScrobble(id: String, at date: Date, duration: TimeInterval?) async throws
}

@MainActor
public final class ScrobbleSyncer {
    private let uploader: any ScrobbleUploading
    private var pending: [(String, Date, TimeInterval?)] = []
    private var armedItemId: String?
    private var hasScrobbledCurrent = false

    /// Called the moment a play qualifies, before and regardless of the upload, so an
    /// offline listen still counts locally.
    public var onScrobble: (@MainActor (String) -> Void)?

    public init(uploader: any ScrobbleUploading) { self.uploader = uploader }

    public func trackProgress(item: QueueItem?, elapsed: TimeInterval, duration: TimeInterval) {
        guard let item, duration > 0 else { return }
        if armedItemId != item.playableId {
            armedItemId = item.playableId
            hasScrobbledCurrent = false
        }
        guard !hasScrobbledCurrent else { return }
        if elapsed >= duration * 0.5 || elapsed >= 4 * 60 {
            hasScrobbledCurrent = true
            pending.append((item.playableId, Date(), duration))
            onScrobble?(item.playableId)
            Task { await flush() }
        }
    }

    public func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        var remaining: [(String, Date, TimeInterval?)] = []
        for (index, item) in batch.enumerated() {
            do {
                try await uploader.uploadScrobble(id: item.0, at: item.1, duration: item.2)
            } catch {
                // Keep the failed scrobble and everything after it — a network blip
                // should not erase plays that never left the device.
                remaining.append(contentsOf: batch[index...])
                break
            }
        }
        if !remaining.isEmpty {
            pending.insert(contentsOf: remaining, at: 0)
        }
    }
}

public final class LibrarySyncerScrobbleUploader: ScrobbleUploading, @unchecked Sendable {
    private let syncer: any LibrarySyncer
    public init(syncer: any LibrarySyncer) { self.syncer = syncer }

    public func uploadScrobble(id: String, at date: Date, duration: TimeInterval?) async throws {
        try await syncer.scrobble(playableId: id, timestamp: date, duration: duration)
    }
}
