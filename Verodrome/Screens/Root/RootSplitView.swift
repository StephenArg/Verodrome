import SwiftUI
import UIKit
import VerodromeKit

struct RootSplitView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore
    @State private var selection: RootTabItem? = .home
    /// Queue / lyrics column. Closed until the trailing sidebar control opens it.
    @State private var showInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var detailPath = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(settings.enabledRootTabs, selection: $selection) { item in
                Label(title(for: item), systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("Verodrome")
            .onAppear { ensureValidSelection() }
            .onChange(of: settings.enabledRootTabs) { _, _ in
                ensureValidSelection()
            }
        } detail: {
            // Two-column split has no column after detail, so destinations must push
            // on an explicit stack. Without it, Home tiles (and every other link)
            // try to target a missing next column and do nothing.
            NavigationStack(path: $detailPath) {
                detailView
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: VerodromeTheme.miniPlayerHeight + 16)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showInspector.toggle()
                            } label: {
                                Image(systemName: "sidebar.trailing")
                            }
                            .accessibilityLabel(showInspector ? "Hide Now Playing" : "Show Now Playing")
                        }
                    }
                    .background {
                        // Pushed screens replace the root toolbar; pin the same control
                        // to the trailing edge of every navigation item past the root.
                        InspectorToggleInstaller(isPresented: $showInspector)
                    }
            }
            .inspector(isPresented: $showInspector) {
                NavigationStack {
                    PlayerInspectorView()
                        .safeAreaInset(edge: .bottom) {
                            Color.clear.frame(height: VerodromeTheme.miniPlayerHeight + 16)
                        }
                }
                .inspectorColumnWidth(min: 360, ideal: 400, max: 560)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, _ in
            detailPath = NavigationPath()
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
        case .shared:
            SharedView()
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

// MARK: - Trailing inspector toggle

/// Keeps the trailing sidebar control on screens pushed over the split view's root.
/// The root already gets it from `RootSplitView`'s toolbar; SwiftUI replaces that
/// bar on push, so this pins the same control to every subsequent navigation item.
private struct InspectorToggleInstaller: UIViewRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIView(context: Context) -> InspectorToggleSensor {
        let sensor = InspectorToggleSensor()
        sensor.coordinator = context.coordinator
        return sensor
    }

    func updateUIView(_ uiView: InspectorToggleSensor, context: Context) {
        context.coordinator.isPresented = $isPresented
        uiView.coordinator = context.coordinator
        context.coordinator.sync(from: uiView)
    }

    static func dismantleUIView(_ uiView: InspectorToggleSensor, coordinator: Coordinator) {
        uiView.coordinator = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject {
        var isPresented: Binding<Bool>
        private let marker = "verodrome.inspectorToggle"
        private var navObservation: NSKeyValueObservation?
        private weak var observedNav: UINavigationController?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func invalidate() {
            navObservation?.invalidate()
            navObservation = nil
            observedNav = nil
        }

        func sync(from view: UIView) {
            guard let nav = view.enclosingNavigationController() else { return }
            observeIfNeeded(nav)
            install(in: nav)
        }

        private func observeIfNeeded(_ nav: UINavigationController) {
            guard observedNav !== nav else { return }
            navObservation?.invalidate()
            observedNav = nav
            navObservation = nav.observe(\.viewControllers, options: [.new]) { [weak self] nav, _ in
                self?.install(in: nav)
            }
        }

        fileprivate func install(in nav: UINavigationController) {
            // Root keeps the SwiftUI toolbar item. Everything pushed on top needs a pin.
            for vc in nav.viewControllers.dropFirst() {
                install(on: vc.navigationItem)
            }
        }

        private func install(on item: UINavigationItem) {
            if let existing = item.pinnedTrailingGroup?.barButtonItems.first,
               existing.accessibilityIdentifier == marker {
                existing.accessibilityLabel = toggleAccessibilityLabel
                return
            }
            let button = UIBarButtonItem(
                image: UIImage(systemName: "sidebar.trailing"),
                style: .plain,
                target: self,
                action: #selector(toggle)
            )
            button.accessibilityIdentifier = marker
            button.accessibilityLabel = toggleAccessibilityLabel
            item.pinnedTrailingGroup = UIBarButtonItemGroup(
                barButtonItems: [button],
                representativeItem: nil
            )
        }

        private var toggleAccessibilityLabel: String {
            isPresented.wrappedValue ? "Hide Now Playing" : "Show Now Playing"
        }

        @objc private func toggle() {
            DispatchQueue.main.async { [weak self] in
                self?.isPresented.wrappedValue.toggle()
            }
        }
    }
}

private final class InspectorToggleSensor: UIView {
    weak var coordinator: InspectorToggleInstaller.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { .zero }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.sync(from: self)
    }
}

private extension UIView {
    func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let nav = current as? UINavigationController {
                return nav
            }
            if let controller = current as? UIViewController {
                if let nav = controller.navigationController {
                    return nav
                }
                if let split = controller as? UISplitViewController ?? controller.splitViewController,
                   let secondary = split.viewController(for: .secondary) {
                    if let nav = secondary as? UINavigationController { return nav }
                    if let nav = secondary.navigationController { return nav }
                    if let nav = secondary.children.compactMap({ $0 as? UINavigationController }).first {
                        return nav
                    }
                }
            }
            responder = current.next
        }
        return nil
    }
}
