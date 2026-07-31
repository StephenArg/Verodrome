import SwiftUI

struct AlbumGridCell: View {
    let title: String
    let subtitle: String
    var artworkURL: String? = nil
    var symbol: String = "music.note"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView.grid(artworkURL, symbol: symbol)
                .frame(maxWidth: .infinity)
                // Soft shadow — radius 8 forces expensive offscreen passes per tile while scrolling.
                .shadow(color: .black.opacity(0.10), radius: 3, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
