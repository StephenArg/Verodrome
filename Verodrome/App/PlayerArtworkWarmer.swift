import Foundation
import UIKit
import VerodromeKit

/// Decodes the covers of upcoming queue tracks into `ArtworkImageCache`.
///
/// `QueueCachePolicyManager` already pulls those files to disk, which removes the network
/// from the skip path — but the first display of a token still pays an ImageIO decode, and
/// that is the few dozen milliseconds a skip reads as a stutter. Warming here means the
/// player binds a `UIImage` that is already in memory.
@MainActor
final class PlayerArtworkWarmer {
    static let shared = PlayerArtworkWarmer()

    /// Matches the disk prefetch window, so nothing is decoded that the policy manager
    /// hasn't also arranged to have locally.
    private static let lookAhead = QueueCachePolicyManager.artworkNextKeepCount
    /// Hero for the player cover; thumbnail for the queue sheet behind it.
    private static let sizes = [ArtworkPixelSize.large, ArtworkPixelSize.thumbnail]

    private var warmTask: Task<Void, Never>?
    private var warmedWindow: [String] = []

    func warm(queue: [QueueItem], currentIndex: Int, repeatMode: RepeatMode = .off) {
        let covers = Self.upcomingCovers(queue: queue, currentIndex: currentIndex, repeatMode: repeatMode)
        // Skipping one track normally shifts the window by a single entry; re-decoding the
        // other nine on every skip would be pure waste.
        let tokens = covers.map(\.token)
        guard tokens != warmedWindow else { return }
        warmedWindow = tokens
        warmTask?.cancel()
        guard !covers.isEmpty else { return }

        warmTask = Task(priority: .utility) {
            for cover in covers {
                if Task.isCancelled { return }
                for size in Self.sizes {
                    if Task.isCancelled { return }
                    if ArtworkImageCache.shared.image(for: cover.token, size: size) != nil { continue }
                    let image = await ArtworkResolver.shared.loadImage(
                        for: cover.token,
                        kind: cover.kind,
                        size: size
                    )
                    if Task.isCancelled { return }
                    guard let image else { continue }
                    ArtworkImageCache.shared.store(image, for: cover.token, size: size)
                }
            }
        }
    }

    func stop() {
        warmTask?.cancel()
        warmTask = nil
        warmedWindow = []
    }

    /// Unique covers nearest the playhead first — current, next, previous (including a
    /// Repeat All wrap), then the rest of the lookahead. The cache is bounded, so the
    /// track about to play must never be the entry that a further-out cover evicted.
    private static func upcomingCovers(
        queue: [QueueItem],
        currentIndex: Int,
        repeatMode: RepeatMode
    ) -> [(token: String, kind: ArtworkKind)] {
        guard !queue.isEmpty else { return [] }
        let start = max(0, min(currentIndex, queue.count - 1))
        let end = min(queue.count - 1, start + lookAhead)
        let adjacent = PlayQueueHandler.peekAdjacent(
            queue: queue,
            currentIndex: currentIndex,
            repeatMode: repeatMode
        )
        var items: [QueueItem] = [queue[start]]
        if let next = adjacent.next { items.append(next) }
        if let previous = adjacent.previous { items.append(previous) }
        if start + 1 <= end {
            items.append(contentsOf: queue[(start + 1)...end])
        }
        var seen = Set<String>()
        var covers: [(token: String, kind: ArtworkKind)] = []
        for item in items {
            guard let token = item.artworkId, !token.isEmpty, seen.insert(token).inserted else { continue }
            covers.append((token, item.kind == .podcastEpisode ? .podcast : .album))
        }
        return covers
    }
}
