import SwiftUI
import VerodromeKit

struct AlbumsGridView: View {
    let albums: [AlbumGridSnapshot]
    var columnCount: Int = 3

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: VerodromeTheme.gridSpacing),
            count: max(columnCount, 1)
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: VerodromeTheme.gridSpacing) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.id)
                    } label: {
                        AlbumGridCell(
                            title: album.title,
                            subtitle: album.subtitle,
                            artworkURL: album.artworkToken
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}
