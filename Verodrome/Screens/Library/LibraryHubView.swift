import SwiftUI
import VerodromeKit

struct LibraryHubView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showEditor = false

    var body: some View {
        List {
            ForEach(settings.enabledLibraryCategories) { category in
                NavigationLink {
                    destination(for: category)
                } label: {
                    Label {
                        Text(category.title)
                    } icon: {
                        // Explicit accent rather than the inherited tint: popping back from
                        // a screen that retints (album/playlist artwork) leaves these icons
                        // resolving against UIKit's default blue.
                        Image(systemName: category.systemImage)
                            .foregroundStyle(themeManager.accentColor)
                    }
                    .font(.body)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Customize Library")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsHostView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                LibraryEditorView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showEditor = false }
                        }
                    }
            }
            .environmentObject(settings)
        }
    }

    @ViewBuilder
    private func destination(for category: LibraryCategory) -> some View {
        switch category {
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .playlists: PlaylistsView()
        case .podcasts: PodcastsView()
        case .radios: RadiosView()
        case .downloads: DownloadsView()
        case .directories: DirectoriesView()
        case .favorites: FavoritesView()
        case .shared: SharedView()
        }
    }
}
