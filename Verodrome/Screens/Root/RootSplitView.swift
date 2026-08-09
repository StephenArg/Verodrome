import SwiftUI
import VerodromeKit

struct RootSplitView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore
    @State private var selection: RootTabItem? = .home

    var body: some View {
        NavigationSplitView {
            List(settings.enabledRootTabs, selection: $selection) { item in
                Label(title(for: item), systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("Verodrome")
            .onAppear { ensureValidSelection() }
            .onChange(of: settings.enabledRootTabs) { _, _ in
                ensureValidSelection()
            }
        } content: {
            detailView
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: VerodromeTheme.miniPlayerHeight + 16)
                }
        } detail: {
            PlayerInspectorView()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? fallbackSelection {
        case .search:
            SearchView()
        case .home:
            HomeView()
        case .library:
            LibraryHubView()
        case .settings:
            SettingsHostView()
        case .artists:
            ArtistsView()
        case .albums:
            AlbumsView()
        case .songs:
            SongsView()
        case .genres:
            GenresView()
        case .playlists:
            PlaylistsView()
        case .podcasts:
            PodcastsView()
        case .radios:
            RadiosView()
        case .downloads:
            DownloadsView()
        case .directories:
            DirectoriesView()
        case .favorites:
            FavoritesView()
        }
    }

    private var fallbackSelection: RootTabItem {
        settings.enabledRootTabs.first ?? .home
    }

    private func ensureValidSelection() {
        let tabs = settings.enabledRootTabs
        guard !tabs.isEmpty else { return }
        // Only move selection when the active item was removed; reorder/add keep it.
        if let selection, tabs.contains(selection) { return }
        self.selection = fallbackSelection
    }

    private func title(for tab: RootTabItem) -> String {
        tab == .home ? account.homeTitle : tab.title
    }
}
