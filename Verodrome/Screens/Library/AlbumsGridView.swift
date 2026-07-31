import SwiftUI
import VerodromeKit

struct AlbumsGridView: View {
    let albums: [Album]

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: VerodromeTheme.gridSpacing)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: VerodromeTheme.gridSpacing) {
                ForEach(albums, id: \.compoundRemoteId) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.compoundRemoteId)
                    } label: {
                        AlbumGridCell(title: album.title, subtitle: album.displayArtist, artworkURL: album.artworkToken)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}
