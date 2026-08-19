import Foundation
import VerodromeKit

/// Prefetches the covers CarPlay is about to show into `ArtworkImageCache`.
///
/// Home installs placeholder tiles on the first frame. Warming the same windows
/// `makeHomeSectionsLoaded` uses — plus Recents rows and the current queue — means
/// the in-place `updateSections` can attach real art without waiting on decode.
@MainActor
final class CarPlayArtworkWarmer {
    static let shared = CarPlayArtworkWarmer()

    private var warmTask: Task<Void, Never>?

    func start(catalog: CarPlayCatalog, onReady: @escaping @MainActor () async -> Void) {
        let requests = Self.deduped(catalog.artworkWarmRequests() + Self.queueRequests())
        warmTask?.cancel()
        guard !requests.isEmpty else {
            warmTask = Task { await onReady() }
            return
        }

        warmTask = Task(priority: .utility) {
            await CarPlayArtwork.prefetch(requests)
            guard !Task.isCancelled else { return }
            await onReady()
        }
    }

    func stop() {
        warmTask?.cancel()
        warmTask = nil
    }

    /// Current track plus the same lookahead `PlayerArtworkWarmer` decodes for the phone.
    private static func queueRequests() -> [CarPlayArtworkRequest] {
        guard let player = VerodromeKit.shared.player, !player.queue.isEmpty else { return [] }
        let queue = player.queue
        let start = max(0, min(player.currentIndex, queue.count - 1))
        let end = min(queue.count - 1, start + QueueCachePolicyManager.artworkNextKeepCount)
        var seen = Set<String>()
        var requests: [CarPlayArtworkRequest] = []
        for item in queue[start...end] {
            guard let token = item.artworkId, !token.isEmpty, seen.insert(token).inserted else {
                continue
            }
            let kind: ArtworkKind = item.kind == .podcastEpisode ? .podcast : .album
            requests.append(
                CarPlayArtworkRequest(token: token, kind: kind, size: ArtworkPixelSize.thumbnail)
            )
        }
        return requests
    }

    private static func deduped(_ requests: [CarPlayArtworkRequest]) -> [CarPlayArtworkRequest] {
        var seen = Set<CarPlayArtworkRequest>()
        return requests.filter { seen.insert($0).inserted }
    }
}
