import SwiftUI

struct AlbumGridCell: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    var symbol: String = "music.note"
    /// When false, only the cover is shown (compact “no text” album grids).
    var showsText: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: showsText ? 8 : 0) {
            ArtworkView.grid(artworkURL, symbol: symbol)
                .frame(maxWidth: .infinity)

            if showsText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Keep the text column from growing past the artwork width so
                // long titles truncate instead of stretching the grid cell.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
