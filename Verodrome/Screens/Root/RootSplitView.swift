import SwiftUI

struct RootSplitView: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case home, search, library, settings

        var id: String { rawValue }

        var title: String {
            rawValue.capitalized
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .search: "magnifyingglass"
            case .library: "square.stack.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("Verodrome")
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
        switch selection ?? .home {
        case .home:
            HomeView()
        case .search:
            SearchView()
        case .library:
            LibraryHubView()
        case .settings:
            SettingsHostView()
        }
    }
}
