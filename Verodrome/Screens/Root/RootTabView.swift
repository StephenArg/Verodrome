import SwiftUI
import VerodromeKit

struct RootTabView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore
    @State private var selection: RootTabItem = .home

    var body: some View {
        tabRoot
            .onAppear { ensureValidSelection() }
            .onChange(of: settings.enabledRootTabs) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: selection) { _, tab in
                PerfTrace.event("Tab.select", details: tab.rawValue)
            }
    }

    @ViewBuilder
    private var tabRoot: some View {
        // Keep a stable TabView identity so add/remove/reorder only updates the
        // tab bar — NavigationStacks and the selected tab stay put.
        let tabs = TabView(selection: $selection) {
            ForEach(settings.enabledRootTabs) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(title(for: tab), systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }

        if #available(iOS 26.1, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: nowPlaying.currentItem != nil) {
                    MiniPlayerBar(drawsChrome: false)
                }
        } else {
            tabs
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: VerodromeTheme.miniPlayerHeight + 16)
                }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: RootTabItem) -> some View {
        NavigationStack {
            switch tab {
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
    }

    private func ensureValidSelection() {
        let tabs = settings.enabledRootTabs
        guard !tabs.isEmpty else { return }
        // Only move selection when the active tab was removed; reorder/add keep it.
        if !tabs.contains(selection) {
            selection = tabs[0]
        }
    }

    private func title(for tab: RootTabItem) -> String {
        tab == .home ? account.homeTitle : tab.title
    }
}
