import SwiftUI
import VerodromeKit

enum RootTab: String, CaseIterable, Identifiable {
    case search
    case home
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .library: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house.fill"
        case .library: "square.stack.fill"
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var selection: RootTab = .home

    var body: some View {
        tabRoot
            .onChange(of: selection) { _, tab in
                PerfTrace.event("Tab.select", details: tab.rawValue)
            }
    }

    @ViewBuilder
    private var tabRoot: some View {
        let tabs = TabView(selection: $selection) {
            ForEach(RootTab.allCases) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.symbol)
                    }
                    .tag(tab)
            }
        }

        if #available(iOS 26.1, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: player.currentItem != nil) {
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
    private func tabContent(for tab: RootTab) -> some View {
        switch tab {
        case .search:
            NavigationStack { SearchView() }
        case .home:
            NavigationStack { HomeView() }
        case .library:
            NavigationStack { LibraryHubView() }
        }
    }
}
