import Foundation
import UIKit
import MediaPlayer

@MainActor
public final class NowPlayingInfoCenterHandler {
    private var cachedArtwork: UIImage?
    private var cachedItemId: String?

    public init() {}

    public func update(
        item: QueueItem?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        artwork: UIImage? = nil
    ) {
        guard let item else {
            clear()
            return
        }

        if let artwork {
            cachedArtwork = artwork
            cachedItemId = item.id
        } else if cachedItemId != item.id {
            // Track changed — drop previous cover until the new one loads.
            cachedArtwork = nil
            cachedItemId = item.id
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.albumName ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)

        if let cachedArtwork {
            let image = cachedArtwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Pause/play / scrub: patch rate + elapsed only so artwork never blanks.
    public func updatePlaybackState(isPlaying: Bool, elapsed: TimeInterval) {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo, !info.isEmpty else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        // Keep existing artwork key untouched.
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func clear() {
        cachedArtwork = nil
        cachedItemId = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
