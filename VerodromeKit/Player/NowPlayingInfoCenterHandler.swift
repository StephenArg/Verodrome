import Foundation
import UIKit
import MediaPlayer

@MainActor
public final class NowPlayingInfoCenterHandler {
    private var cachedArtwork: UIImage?
    private var cachedItemId: String?
    /// Own copy of the last payload. Reading `MPNowPlayingInfoCenter.nowPlayingInfo`
    /// and writing it back drops `MPMediaItemArtwork` — CarPlay then stays blank.
    private var lastInfo: [String: Any] = [:]

    public init() {}

    public func update(
        item: QueueItem?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        rate: Float = 1,
        artwork: UIImage? = nil
    ) {
        guard let item else {
            // The player reports no item while a queue is still loading and in the gap
            // between tracks. Tearing the payload down here blanks CarPlay's Now Playing
            // and can hand the now-playing role to another app, so keep the metadata and
            // only reflect the transport state. Teardown goes through `clear()`.
            updatePlaybackState(isPlaying: isPlaying, elapsed: elapsed, rate: rate)
            return
        }

        if let artwork, let flattened = Self.flattenedBitmap(artwork) {
            cachedArtwork = flattened
            cachedItemId = item.id
        } else if cachedItemId != item.id {
            // Track changed — drop previous cover until the new one loads.
            cachedArtwork = nil
            cachedItemId = item.id
        }

        let playDuration = duration > 0 ? duration : item.duration
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title
        if let artist = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
            info[MPMediaItemPropertyAlbumArtist] = artist
        }
        if let album = item.albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if playDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playDuration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = item.id

        if let cachedArtwork, let mediaArtwork = Self.mediaArtwork(from: cachedArtwork) {
            info[MPMediaItemPropertyArtwork] = mediaArtwork
        }

        lastInfo = info
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Pause/play / scrub: patch rate + elapsed only so artwork never blanks.
    public func updatePlaybackState(isPlaying: Bool, elapsed: TimeInterval, rate: Float = 1) {
        guard !lastInfo.isEmpty else { return }
        lastInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        lastInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = lastInfo
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func clear() {
        cachedArtwork = nil
        cachedItemId = nil
        lastInfo = [:]
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// MediaRemote asks for artwork on a background queue. A MainActor-isolated
    /// request handler never returns an image to CarPlay.
    private nonisolated static func mediaArtwork(from image: UIImage) -> MPMediaItemArtwork? {
        guard let cgImage = image.cgImage else { return nil }
        let sourceSize = image.size
        guard sourceSize.width > 1, sourceSize.height > 1 else { return nil }
        let bounds = CGSize(
            width: max(sourceSize.width, 600),
            height: max(sourceSize.height, 600)
        )
        return MPMediaItemArtwork(boundsSize: bounds) { @Sendable requested in
            let side = max(max(requested.width, requested.height), 128)
            let target = CGSize(width: side, height: side)
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            return UIGraphicsImageRenderer(size: target, format: format).image { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: target))
                let source = UIImage(cgImage: cgImage)
                source.draw(in: aspectFillRect(for: sourceSize, in: target))
            }
        }
    }

    private nonisolated static func flattenedBitmap(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        if image.cgImage != nil, image.renderingMode != .alwaysTemplate {
            return image
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = max(image.scale, 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private nonisolated static func aspectFillRect(for imageSize: CGSize, in target: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = max(target.width / imageSize.width, target.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (target.width - width) / 2,
            y: (target.height - height) / 2,
            width: width,
            height: height
        )
    }
}
