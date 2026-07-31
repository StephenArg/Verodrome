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
