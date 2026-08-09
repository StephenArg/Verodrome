import SwiftUI
import VerodromeKit

struct AlbumsGridView<MenuContent: View>: View {
    let albums: [AlbumGridSnapshot]
    var columnCount: Int = 3
    var contextMenu: ((AlbumGridSnapshot) -> MenuContent)?

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
                    cell(for: album)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func cell(for album: AlbumGridSnapshot) -> some View {
        let link = NavigationLink {
            AlbumDetailView(albumID: album.id)
        } label: {
            AlbumGridCell(
                title: album.title,
                subtitle: album.subtitle,
                artworkURL: album.artworkToken
            )
        }
        .buttonStyle(.plain)

        if let contextMenu {
            link.contextMenu { contextMenu(album) }
        } else {
            link
        }
    }
}

extension AlbumsGridView where MenuContent == EmptyView {
    init(albums: [AlbumGridSnapshot], columnCount: Int = 3) {
        self.albums = albums
        self.columnCount = columnCount
        self.contextMenu = nil
    }
}
