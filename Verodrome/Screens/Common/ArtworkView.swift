import SwiftUI
import UIKit
import VerodromeKit

struct ArtworkView: View {
    let token: String?
    var kind: ArtworkKind = .album
    var cornerRadius: CGFloat = VerodromeTheme.artworkCornerRadius
    var symbol: String = "music.note"
    /// Requested pixel size for remote cover art (server `size` / getCoverArt).
    var size: Int = ArtworkPixelSize.grid
    /// When false, skip the loading spinner (preferred for dense lists).
    var showsProgress: Bool = true

    @State private var image: UIImage?
    @State private var loadFailed = false
    /// Set only once the art is known to be missing from disk. A cached cover still takes
    /// a moment to read and decode, and a spinner for that flashes on every reopen.
    @State private var isDownloading = false

    private var isThumbnail: Bool { size <= ArtworkPixelSize.thumbnail }

    init(
        token: String?,
        kind: ArtworkKind = .album,
        cornerRadius: CGFloat = VerodromeTheme.artworkCornerRadius,
        symbol: String = "music.note",
        size: Int = ArtworkPixelSize.grid,
        showsProgress: Bool = true
    ) {
        self.token = token
        self.kind = kind
        self.cornerRadius = cornerRadius
        self.symbol = symbol
        self.size = size
        self.showsProgress = showsProgress
        // Synchronous cache probe so cache hits render in the first pass — no async
        // hop, no state write, no second render. Any cached size will do: `task` below
        // still loads the requested one when this is only a stand-in.
        let seeded = token.flatMap {
            ArtworkImageCache.shared.bestAvailableImage(for: $0, size: size)
        }
        _image = State(initialValue: seeded?.image)
    }

    var body: some View {
        // Fixed square container — image is cropped/filled inside and never drives layout size.
        // A single `clipShape` does the cropping; adding `clipped()` on top costs a second
        // offscreen pass per cell on every scrolled frame.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                artworkContent
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: ArtworkRequestID(token: token, size: size)) {
                // `State(initialValue:)` only seeds a brand-new view identity; a reused
                // view (mini player / hero art on track change) still holds the previous
                // token's image, so re-resolve against the cache on each token change.
                let cached = token.flatMap {
                    ArtworkImageCache.shared.bestAvailableImage(for: $0, size: size)
                }
                if let cached {
                    if image !== cached.image { image = cached.image }
                    loadFailed = false
                    if cached.isExact { return }
                } else if image != nil {
                    image = nil
                }
                loadFailed = false
                isDownloading = false
                await loadArtwork(hasStandIn: cached != nil)
            }
    }

    @ViewBuilder
    private var artworkContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PlaceholderArtwork(symbol: symbol)
                .overlay {
                    if showsProgress && !isThumbnail && isDownloading && !loadFailed {
                        ProgressView()
                    }
                }
        }
    }

    private func loadArtwork(hasStandIn: Bool) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let ctx = isThumbnail ? "thumb" : (size == ArtworkPixelSize.homeTile ? "home" : "art")
        guard let token, !token.isEmpty else {
            loadFailed = false
            return
        }

        let isOnDisk = await ArtworkResolver.shared.hasLocalRender(for: token, size: size)
        if Task.isCancelled {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
            return
        }

        if !isOnDisk {
            // Thumbnails: briefly yield so rapid scroll can cancel before network. Art
            // already on disk skips this, so a reopened list fills in immediately.
            if isThumbnail {
                try? await Task.sleep(nanoseconds: 40_000_000)
                if Task.isCancelled {
                    ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
                    return
                }
            }
            // Only a download is slow enough to be worth a spinner. Reading and decoding a
            // cached cover takes a few milliseconds, and showing a spinner for that made
            // every reopened album flash one.
            isDownloading = true

            // Show whatever smaller render is on disk rather than holding a placeholder
            // for the whole download. Deliberately not stored in `ArtworkImageCache` —
            // it would take the slot the sharp render belongs in.
            if !hasStandIn, let standIn = await ArtworkResolver.shared.downgradedImage(for: token, size: size) {
                if Task.isCancelled {
                    ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
                    return
                }
                image = standIn
            }
        }

        if let loaded = await ArtworkResolver.shared.loadImage(for: token, kind: kind, size: size) {
            if Task.isCancelled {
                ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
                return
            }
            ArtworkImageCache.shared.store(loaded, for: token, size: size)
            image = loaded
            isDownloading = false
            let ms = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
            if ms >= PerfTrace.warnThresholdMs {
                PerfTrace.event("Art.uiApply.slow", details: "\(ms)ms size=\(size) ctx=\(ctx)")
            }
        } else if !Task.isCancelled {
            loadFailed = true
        } else {
            ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
        }
    }
}

/// Value-typed `.task(id:)` key, so a scrolled cell doesn't allocate an interpolated
/// String on every body evaluation just to decide whether to reload.
private struct ArtworkRequestID: Equatable {
    let token: String?
    let size: Int
}

/// In-memory decoded images so list cells do not re-decode JPEG/PNG while scrolling.
enum ArtworkImageCache {
    static let shared = ArtworkImageCacheBox()
}

final class ArtworkImageCacheBox {
    /// Split in two, because a single cache let a library scroll evict hero art: hundreds
    /// of 120px thumbnails would push out the full-size cover of the album just visited,
    /// so reopening it had to decode from disk again and flashed a placeholder.
    private let small = NSCache<NSString, UIImage>()
    private let large = NSCache<NSString, UIImage>()

    /// Renders above this are detail heroes and player covers — a handful of big images
    /// rather than a long list of small ones, so they need their own budget.
    private static let largeSizeThreshold = ArtworkPixelSize.grid

    init() {
        small.countLimit = 1500
        small.totalCostLimit = 80 * 1024 * 1024
        // ~14 covers: enough that going back to a recently opened album or playlist is a
        // first-frame hit. The cost limit is what binds, not the count.
        large.countLimit = 16
        large.totalCostLimit = 48 * 1024 * 1024
    }

    private func cache(for size: Int) -> NSCache<NSString, UIImage> {
        size > Self.largeSizeThreshold ? large : small
    }

    func image(for token: String, size: Int) -> UIImage? {
        cache(for: size).object(forKey: key(token, size))
    }

    /// The closest render already decoded for this token, at any size.
    ///
    /// Navigation almost always crosses a size boundary — a 120px list row or 300px grid
    /// cell opens a 900px hero — so an exact-size lookup misses even though a usable
    /// image is sitting in memory. `isExact` tells the caller whether it still needs to
    /// load the requested size; anything else is a stand-in shown until it arrives.
    func bestAvailableImage(for token: String, size: Int) -> (image: UIImage, isExact: Bool)? {
        if let exact = image(for: token, size: size) { return (exact, true) }
        // Prefer a larger render: downscaling looks right, upscaling looks soft.
        for larger in ArtworkPixelSize.all where larger > size {
            if let found = image(for: token, size: larger) { return (found, false) }
        }
        for smaller in ArtworkPixelSize.all.reversed() where smaller < size {
            if let found = image(for: token, size: smaller) { return (found, false) }
        }
        return nil
    }

    func store(_ image: UIImage, for token: String, size: Int) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache(for: size).setObject(image, forKey: key(token, size), cost: max(cost, 1))
    }

    func removeAll() {
        small.removeAllObjects()
        large.removeAllObjects()
    }

    private func key(_ token: String, _ size: Int) -> NSString {
        "\(token)|s\(size)" as NSString
    }
}

/// Standard remote artwork request sizes (points × scale, roughly).
enum ArtworkPixelSize {
    static let thumbnail = 120
    /// Home carousel tiles (~148pt @2x/3x).
    static let homeTile = 300
    static let grid = 450
    /// Detail hero (280pt) and the player cover, which the transport controls keep well
    /// below this on every phone.
    static let large = ArtworkDownloadManager.largestRequestedSize

    /// Ascending, so a render cached for one screen can stand in for another while the
    /// exact size loads. Includes 1200 — no longer requested, but covers cached by an
    /// earlier version are still perfectly good.
    static let all = [thumbnail, homeTile, grid, large, 1200]
}

extension ArtworkView {
    init(urlString: String?, cornerRadius: CGFloat = VerodromeTheme.artworkCornerRadius, symbol: String = "music.note") {
        self.init(
            token: urlString,
            kind: .album,
            cornerRadius: cornerRadius,
            symbol: symbol,
            size: ArtworkPixelSize.grid
        )
    }

    init(artworkToken: String?, cornerRadius: CGFloat = VerodromeTheme.artworkCornerRadius, symbol: String = "music.note") {
        self.init(
            token: artworkToken,
            kind: .album,
            cornerRadius: cornerRadius,
            symbol: symbol,
            size: ArtworkPixelSize.grid
        )
    }

    /// Compact artwork for list / mini-player rows.
    static func thumbnail(_ token: String?, symbol: String = "music.note") -> ArtworkView {
        ArtworkView(
            token: token,
            kind: .album,
            cornerRadius: VerodromeTheme.artworkCornerRadius,
            symbol: symbol,
            size: ArtworkPixelSize.thumbnail,
            showsProgress: false
        )
    }

    /// Home / album grid cells — smaller download than detail art.
    static func grid(_ token: String?, symbol: String = "music.note", cornerRadius: CGFloat = VerodromeTheme.cornerRadius) -> ArtworkView {
        ArtworkView(
            token: token,
            kind: .album,
            cornerRadius: cornerRadius,
            symbol: symbol,
            size: ArtworkPixelSize.homeTile,
            showsProgress: false
        )
    }

    /// Popup player / detail hero art — high-res to avoid blur when scaled up.
    static func hero(_ token: String?, symbol: String = "music.note", cornerRadius: CGFloat = VerodromeTheme.cornerRadius) -> ArtworkView {
        ArtworkView(
            token: token,
            kind: .album,
            cornerRadius: cornerRadius,
            symbol: symbol,
            size: ArtworkPixelSize.large,
            showsProgress: true
        )
    }
}
