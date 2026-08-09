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
    /// The player's own render. Warming any other size would not be a hit for the hero.
    private static let size = ArtworkPixelSize.large

    private var warmTask: Task<Void, Never>?
    private var warmedWindow: [String] = []

    func warm(queue: [QueueItem], currentIndex: Int) {
        let covers = Self.upcomingCovers(queue: queue, currentIndex: currentIndex)
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
                if ArtworkImageCache.shared.image(for: cover.token, size: Self.size) != nil { continue }
                let image = await ArtworkResolver.shared.loadImage(
                    for: cover.token,
                    kind: cover.kind,
                    size: Self.size
                )
                if Task.isCancelled { return }
                guard let image else { continue }
                ArtworkImageCache.shared.store(image, for: cover.token, size: Self.size)
            }
        }
    }

    func stop() {
        warmTask?.cancel()
        warmTask = nil
        warmedWindow = []
    }

    /// Unique covers for the current track and the ones after it, nearest first — the
    /// cache is bounded, so the track about to play must never be the entry that a
    /// further-out cover evicted.
    private static func upcomingCovers(
        queue: [QueueItem],
        currentIndex: Int
    ) -> [(token: String, kind: ArtworkKind)] {
        guard !queue.isEmpty else { return [] }
        let start = max(0, min(currentIndex, queue.count - 1))
        let end = min(queue.count - 1, start + lookAhead)
        var seen = Set<String>()
        var covers: [(token: String, kind: ArtworkKind)] = []
        for item in queue[start...end] {
            guard let token = item.artworkId, !token.isEmpty, seen.insert(token).inserted else { continue }
            covers.append((token, item.kind == .podcastEpisode ? .podcast : .album))
        }
        return covers
    }
}
