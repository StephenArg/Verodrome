import UIKit
import VerodromeKit

enum CarPlayArtwork {
    static let placeholder: UIImage = {
        UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        ) ?? UIImage()
    }()

    /// Square cover so Home image-grid columns have a real tile before art loads.
    /// A symbol-only image is not a grid cell — CarPlay then falls back to list rows.
    static func tilePlaceholder(size: CGFloat = 180) -> UIImage {
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

    /// Nav-bar glyphs must be template images or CarPlay drops the button.
    static func barSymbol(_ name: String) -> UIImage {
        let image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
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
    /// filled check when it is in at least one (CarPlay tints `isSelected` green).
    static func nowPlayingPlaylistSymbol(isInPlaylist: Bool) -> UIImage {
        barSymbol(isInPlaylist ? "checkmark.circle.fill" : "plus")
    }

    static func load(token: String?, kind: ArtworkKind = .album, size: Int = 180) async -> UIImage? {
        await VerodromeKit.shared.artworkDownloadManager?.loadImage(for: token, kind: kind, size: size)
    }

    static func loadOrPlaceholder(token: String?, kind: ArtworkKind = .album, size: Int = 180) async -> UIImage {
        await load(token: token, kind: kind, size: size) ?? tilePlaceholder(size: CGFloat(size))
    }
}
