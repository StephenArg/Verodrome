import SwiftUI
import VerodromeKit

struct AlbumsGridView: View {
    let albums: [AlbumGridSnapshot]

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: VerodromeTheme.gridSpacing)]

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
