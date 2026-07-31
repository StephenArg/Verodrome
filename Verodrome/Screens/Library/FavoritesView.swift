import SwiftUI
import SwiftData
import VerodromeKit

struct FavoritesView: View {
    @Query(sort: \Song.title) private var allSongs: [Song]
    @Query(sort: \Album.title) private var allAlbums: [Album]

    private var favoriteSongs: [Song] { allSongs.filter(\.isFavorite) }
    private var favoriteAlbums: [Album] { allAlbums.filter(\.isFavorite) }

    var body: some View {
        List {
            if !favoriteAlbums.isEmpty {
                Section("Albums") {
                    ForEach(favoriteAlbums, id: \.compoundRemoteId) { album in
                        NavigationLink {
                            AlbumDetailView(albumID: album.compoundRemoteId)
                        } label: {
                            EntityRow(title: album.title, subtitle: album.displayArtist, artworkURL: album.artworkToken)
                        }
                    }
                }
            }

            Section("Songs") {
                if favoriteSongs.isEmpty && favoriteAlbums.isEmpty {
                    Text("Mark items as favorites to see them here.").foregroundStyle(.secondary)
                } else {
                    ForEach(favoriteSongs, id: \.compoundRemoteId) { song in
                        EntityRow(title: song.title, subtitle: song.displayArtist, artworkURL: song.album?.artworkToken)
                    }
                }
            }
        }
        .navigationTitle("Favorites")
    }
}
