import Foundation
import Combine

/// Observable download progress for UI (active downloads + failures).
@MainActor
public final class DownloadCenter: ObservableObject {
    public static let shared = DownloadCenter()

    /// playableId → progress 0...1
    @Published public private(set) var activeDownloads: [String: Double] = [:]
    @Published public private(set) var failedIds: Set<String> = []
    @Published public private(set) var completedIds: Set<String> = []

    private init() {}

    public func begin(playableId: String) {
        failedIds.remove(playableId)
        completedIds.remove(playableId)
        activeDownloads[playableId] = 0
    }

    public func update(playableId: String, progress: Double) {
        activeDownloads[playableId] = min(1, max(0, progress))
    }

    public func complete(playableId: String) {
        activeDownloads.removeValue(forKey: playableId)
        failedIds.remove(playableId)
        completedIds.insert(playableId)
    }

    public func fail(playableId: String) {
        activeDownloads.removeValue(forKey: playableId)
        failedIds.insert(playableId)
    }

    public func clearActive(playableId: String) {
        activeDownloads.removeValue(forKey: playableId)
    }

    public func clearAllActive() {
        activeDownloads.removeAll()
    }

    public func clearCompleted() {
        completedIds.removeAll()
    }

    public func clearFailed() {
        failedIds.removeAll()
    }
}
