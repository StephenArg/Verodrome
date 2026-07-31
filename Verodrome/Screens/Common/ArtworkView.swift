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
        // hop, no state write, no second render.
        let seeded = token.flatMap {
            ArtworkImageCache.shared.image(for: $0, size: size)
        }
        _image = State(initialValue: seeded)
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
                    ArtworkImageCache.shared.image(for: $0, size: size)
                }
                if let cached {
                    if image !== cached { image = cached }
                    loadFailed = false
                    return
                }
                if image != nil { image = nil }
                loadFailed = false
                await loadArtwork()
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
                    if showsProgress && !isThumbnail && !loadFailed && token != nil {
                        ProgressView()
                    }
                }
        }
    }

    private func loadArtwork() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let ctx = isThumbnail ? "thumb" : (size == ArtworkPixelSize.homeTile ? "home" : "art")
        guard let token, !token.isEmpty else {
            loadFailed = false
            return
        }

        // Thumbnails: briefly yield so rapid scroll can cancel before network.
        if isThumbnail {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled {
                ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
                return
            }
        }

        if let loaded = await ArtworkResolver.shared.loadImage(for: token, kind: kind, size: size) {
            if Task.isCancelled {
                ArtworkPerf.record(source: .cancel, size: size, ms: 0, context: ctx)
                return
            }
            ArtworkImageCache.shared.store(loaded, for: token, size: size)
            image = loaded
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
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 1500
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(for token: String, size: Int) -> UIImage? {
        cache.object(forKey: key(token, size))
    }

    func store(_ image: UIImage, for token: String, size: Int) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key(token, size), cost: max(cost, 1))
    }

    func removeAll() {
        cache.removeAllObjects()
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
    static let detail = 900
    static let player = 1200
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
            size: ArtworkPixelSize.player,
            showsProgress: true
        )
    }
}
