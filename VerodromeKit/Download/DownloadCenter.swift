import Foundation
import Combine

/// What a UI element should show for one playable's download.
public enum DownloadStatus: Equatable, Sendable {
    case none
    /// Queued behind the concurrency limit — no bytes yet.
    case pending
    /// Held back by the Wi-Fi-only setting until an unmetered connection arrives.
    case waiting
    /// 0...1. Stays at 0 until the server reports a content length.
    case downloading(Double)
    /// Some, but not all, tracks of an album/playlist are on disk.
    case partial
    /// On disk only because the player / queue prefetched it — not a keep-forever download.
    case cached
    /// Explicitly kept offline (user download, favorites, playlist cache, …).
    case downloaded
    case failed
}

/// Observable download progress for UI (queued, active, completed, failed).
@MainActor
public final class DownloadCenter: ObservableObject {
    public static let shared = DownloadCenter()

    /// Accepted by the download queue but not yet started.
    @Published public private(set) var pendingIds: Set<String> = []
    /// Automatic downloads the Wi-Fi-only setting is holding back.
    @Published public private(set) var deferredIds: Set<String> = []
    /// playableId → progress 0...1
    @Published public private(set) var activeDownloads: [String: Double] = [:]
    @Published public private(set) var failedIds: Set<String> = []
    @Published public private(set) var completedIds: Set<String> = []
    /// Bumps when a download starts, finishes, fails, or is cleared — not on progress
    /// ticks. Queue lists and other dense UIs observe this instead of `activeDownloads`
    /// so byte-level updates don't rebuild every row.
    @Published public private(set) var activityEpoch: UInt = 0

    private init() {}

    private func noteActivityChange() {
        activityEpoch &+= 1
    }

    /// A song sitting behind `DownloadManager.maxConcurrent` still needs a spinner —
    /// on a full album most tracks are here, not in `activeDownloads`.
    public func enqueued(playableId: String) {
        failedIds.remove(playableId)
        completedIds.remove(playableId)
        deferredIds.remove(playableId)
        pendingIds.insert(playableId)
        noteActivityChange()
    }

    /// Accepted, but parked until the connection allows automatic downloads.
    public func deferDownload(playableId: String) {
        failedIds.remove(playableId)
        completedIds.remove(playableId)
        pendingIds.remove(playableId)
        deferredIds.insert(playableId)
        noteActivityChange()
    }

    public func clearDeferred(playableId: String) {
        guard deferredIds.remove(playableId) != nil else { return }
        noteActivityChange()
    }

    public func begin(playableId: String) {
        failedIds.remove(playableId)
        completedIds.remove(playableId)
        pendingIds.remove(playableId)
        deferredIds.remove(playableId)
        activeDownloads[playableId] = 0
        noteActivityChange()
    }

    public func update(playableId: String, progress: Double) {
        // Progress alone must not bump `activityEpoch` — album rings still observe
        // `activeDownloads`, while list badges only care about membership changes.
        activeDownloads[playableId] = min(1, max(0, progress))
    }

    public func complete(playableId: String) {
        pendingIds.remove(playableId)
        deferredIds.remove(playableId)
        activeDownloads.removeValue(forKey: playableId)
        failedIds.remove(playableId)
        completedIds.insert(playableId)
        noteActivityChange()
    }

    public func fail(playableId: String) {
        pendingIds.remove(playableId)
        deferredIds.remove(playableId)
        activeDownloads.removeValue(forKey: playableId)
        failedIds.insert(playableId)
        noteActivityChange()
    }

    public func clearActive(playableId: String) {
        pendingIds.remove(playableId)
        deferredIds.remove(playableId)
        activeDownloads.removeValue(forKey: playableId)
        failedIds.remove(playableId)
        completedIds.remove(playableId)
        noteActivityChange()
    }

    public func clearAllActive() {
        pendingIds.removeAll()
        deferredIds.removeAll()
        activeDownloads.removeAll()
        noteActivityChange()
    }

    public func clearCompleted() {
        guard !completedIds.isEmpty else { return }
        completedIds.removeAll()
        noteActivityChange()
    }

    public func clearFailed() {
        guard !failedIds.isEmpty else { return }
        failedIds.removeAll()
        noteActivityChange()
    }

    /// Everything queued or transferring right now.
    public var workingIds: Set<String> {
        pendingIds.union(activeDownloads.keys)
    }

    /// True while the download is queued or transferring.
    public func isWorking(on playableId: String) -> Bool {
        pendingIds.contains(playableId) || activeDownloads[playableId] != nil
    }

    /// Single lookup for row/button UI. `isDownloaded` comes from the library model,
    /// which only says "downloaded" once the file has actually landed.
    ///
    /// `completedIds` is checked too so a row can flip to the downloaded glyph on the
    /// same frame the transfer ends, before SwiftData's `relFilePath` write has been
    /// observed by the view.
    public func status(for playableId: String, isDownloaded: Bool) -> DownloadStatus {
        if let progress = activeDownloads[playableId] { return .downloading(progress) }
        if pendingIds.contains(playableId) { return .pending }
        // Ranked below `downloaded` so a stale deferral can never mask a file that is
        // already on disk.
        if isDownloaded || completedIds.contains(playableId) { return .downloaded }
        if deferredIds.contains(playableId) { return .waiting }
        if failedIds.contains(playableId) { return .failed }
        return .none
    }

    /// Combined progress across a batch, 0...1. Tracks that are queued but not yet
    /// transferring count as 0 and finished ones as 1, so an album ring reflects the
    /// whole batch rather than racing ahead on the four that happen to be in flight.
    public func batchProgress(for playableIds: [String], downloadedIds: Set<String>) -> Double? {
        guard !playableIds.isEmpty else { return nil }
        guard playableIds.contains(where: { isWorking(on: $0) }) else { return nil }
        let total = playableIds.reduce(0.0) { sum, id in
            if let progress = activeDownloads[id] { return sum + progress }
            if pendingIds.contains(id) { return sum }
            return sum + (downloadedIds.contains(id) ? 1 : 0)
        }
        return total / Double(playableIds.count)
    }
}
