import UIKit
import VerodromeKit

enum CarPlayArtwork {
    static let placeholder: UIImage = {
        UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        ) ?? UIImage()
    }()

    /// Stay under `ArtworkDownloadManager`'s six in-flight downloads.
    static let maxConcurrentLoads = 6

    /// Square cover so Home image-grid columns have a real tile before art loads.
    /// A symbol-only image is not a grid cell — CarPlay then falls back to list rows.
    static func tilePlaceholder(size: CGFloat = CGFloat(ArtworkPixelSize.grid)) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.secondarySystemFill.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            let symbol = UIImage(
                systemName: "music.note",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.32, weight: .medium)
            )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            if let symbol {
                let rect = CGRect(
                    x: (size - symbol.size.width) / 2,
                    y: (size - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                symbol.draw(in: rect)
            }
        }
    }

    static func symbol(_ name: String) -> UIImage {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        ) ?? placeholder
    }

    /// Library shortcut rows: white glyph on a light rounded tile so CarPlay
    /// does not template-tint a bare SF Symbol black.
    static func libraryRowIcon(_ systemName: String, circular: Bool = false, size: CGFloat = 90) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: canvas)
            UIColor(red: 0.76, green: 0.71, blue: 0.73, alpha: 1).setFill()
            if circular {
                UIBezierPath(ovalIn: rect).fill()
            } else {
                UIBezierPath(roundedRect: rect, cornerRadius: size * 0.22).fill()
            }
            let symbol = UIImage(
                systemName: systemName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.38, weight: .regular)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                let maxSide = size * 0.48
                let scale = min(maxSide / max(symbol.size.width, 1), maxSide / max(symbol.size.height, 1))
                let drawSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(
                    in: CGRect(
                        x: (size - drawSize.width) / 2,
                        y: (size - drawSize.height) / 2,
                        width: drawSize.width,
                        height: drawSize.height
                    )
                )
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    static func libraryCategoryIcon(_ category: LibraryCategory) -> UIImage {
        switch category {
        case .playlists: libraryRowIcon("music.note")
        case .artists: libraryRowIcon("person.fill", circular: true)
        case .albums: libraryRowIcon("opticaldisc")
        case .podcasts: libraryRowIcon("mic")
        case .favorites: libraryRowIcon("heart")
        case .downloads: libraryRowIcon("arrow.down")
        case .songs: libraryRowIcon("music.note.list")
        case .genres: libraryRowIcon("guitars")
        case .radios: libraryRowIcon("dot.radiowaves.left.and.right")
        case .directories: libraryRowIcon("folder")
        case .shared: libraryRowIcon("square.and.arrow.up")
        }
    }

    /// Nav-bar glyphs must be template images or CarPlay drops the button.
    static func barSymbol(_ name: String, pointSize: CGFloat = 22) -> UIImage {
        let image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        ) ?? symbol(name)
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Trailing membership mark on a CarPlay playlist row.
    static func playlistMembershipAccessory(isMember: Bool) -> UIImage {
        let name = isMember ? "checkmark.circle.fill" : "circle"
        let image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        ) ?? placeholder
        let color: UIColor = isMember ? .systemGreen : .secondaryLabel
        return image.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// Now Playing add-to-playlist control: plus when the song is in no lists,
    /// a circle with a punched-out check when it is in at least one.
    /// Template, not `isSelected` — CarPlay paints a gray plate behind selected buttons.
    static func nowPlayingPlaylistSymbol(isInPlaylist: Bool) -> UIImage {
        isInPlaylist ? playlistMembershipCheckSymbol() : barSymbol("plus")
    }

    /// Filled circle with the checkmark erased, so the Now Playing chrome shows through.
    /// A template SF Symbol does not punch holes — draw the check as an opaque stroke.
    private static func playlistMembershipCheckSymbol(size: CGFloat = 48) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let circle = CGRect(origin: .zero, size: canvas).insetBy(dx: size * 0.05, dy: size * 0.05)
            UIColor.black.setFill()
            UIBezierPath(ovalIn: circle).fill()

            let cg = ctx.cgContext
            cg.setBlendMode(.destinationOut)
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(size * 0.13)
            cg.move(to: CGPoint(x: size * 0.28, y: size * 0.52))
            cg.addLine(to: CGPoint(x: size * 0.43, y: size * 0.67))
            cg.addLine(to: CGPoint(x: size * 0.73, y: size * 0.33))
            cg.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Exact or larger decoded render already in `ArtworkImageCache`.
    static func cachedImage(token: String?, size: Int) -> UIImage? {
        guard let token, !token.isEmpty else { return nil }
        if let exact = ArtworkImageCache.shared.image(for: token, size: size) {
            return exact
        }
        for larger in ArtworkPixelSize.all where larger > size {
            if let found = ArtworkImageCache.shared.image(for: token, size: larger) {
                return found
            }
        }
        return nil
    }

    static func cachedOrPlaceholder(
        token: String?,
        size: Int = ArtworkPixelSize.grid
    ) -> UIImage {
        cachedImage(token: token, size: size) ?? tilePlaceholder(size: CGFloat(size))
    }

    static func load(
        token: String?,
        kind: ArtworkKind = .album,
        size: Int = ArtworkPixelSize.thumbnail
    ) async -> UIImage? {
        guard let token, !token.isEmpty else { return nil }
        if let cached = cachedImage(token: token, size: size) {
            return cached
        }
        let image = await ArtworkResolver.shared.loadImage(for: token, kind: kind, size: size)
        if let image {
            ArtworkImageCache.shared.store(image, for: token, size: size)
        }
        return image
    }

    static func loadOrPlaceholder(
        token: String?,
        kind: ArtworkKind = .album,
        size: Int = ArtworkPixelSize.thumbnail
    ) async -> UIImage {
        await load(token: token, kind: kind, size: size) ?? tilePlaceholder(size: CGFloat(size))
    }

    /// Cache hits first, then download/decode misses with a bounded task group.
    static func loadCovers(
        _ requests: [(token: String?, kind: ArtworkKind)],
        size: Int = ArtworkPixelSize.grid
    ) async -> [UIImage] {
        var images = requests.map { cachedOrPlaceholder(token: $0.token, size: size) }
        let missIndices = requests.indices.filter { index in
            guard let token = requests[index].token, !token.isEmpty else { return false }
            return cachedImage(token: token, size: size) == nil
        }
        guard !missIndices.isEmpty else { return images }

        await withTaskGroup(of: (Int, UIImage).self) { group in
            var iterator = missIndices.makeIterator()
            func enqueue() {
                guard let index = iterator.next() else { return }
                let request = requests[index]
                group.addTask {
                    let image = await loadOrPlaceholder(
                        token: request.token,
                        kind: request.kind,
                        size: size
                    )
                    return (index, image)
                }
            }
            for _ in 0..<min(maxConcurrentLoads, missIndices.count) {
                enqueue()
            }
            for await (index, image) in group {
                images[index] = image
                enqueue()
            }
        }
        return images
    }

    static func prefetch(_ requests: [CarPlayArtworkRequest]) async {
        let pending = requests.filter { cachedImage(token: $0.token, size: $0.size) == nil }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func enqueue() {
                while let request = iterator.next() {
                    if cachedImage(token: request.token, size: request.size) != nil {
                        continue
                    }
                    group.addTask {
                        _ = await load(token: request.token, kind: request.kind, size: request.size)
                    }
                    return
                }
            }
            for _ in 0..<min(maxConcurrentLoads, pending.count) {
                enqueue()
            }
            for await _ in group {
                enqueue()
            }
        }
    }
}

struct CarPlayArtworkRequest: Hashable, Sendable {
    let token: String
    let kind: ArtworkKind
    let size: Int
}
