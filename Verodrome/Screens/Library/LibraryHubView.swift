import SwiftUI

struct LibraryHubView: View {
    private let categories: [(title: String, symbol: String, destination: AnyView)] = [
        ("Artists", "person.2.fill", AnyView(ArtistsView())),
        ("Albums", "square.stack.fill", AnyView(AlbumsView())),
        ("Songs", "music.note.list", AnyView(SongsView())),
        ("Genres", "guitars.fill", AnyView(GenresView())),
        ("Playlists", "music.note.house.fill", AnyView(PlaylistsView())),
        ("Podcasts", "mic.fill", AnyView(PodcastsView())),
        ("Radios", "dot.radiowaves.left.and.right", AnyView(RadiosView())),
        ("Downloads", "arrow.down.circle.fill", AnyView(DownloadsView())),
        ("Directories", "folder.fill", AnyView(DirectoriesView())),
        ("Favorites", "heart.fill", AnyView(FavoritesView()))
    ]

    var body: some View {
        List {
            ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                NavigationLink {
                    category.destination
                } label: {
                    Label(category.title, systemImage: category.symbol)
                        .font(.body)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsHostView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }
}
