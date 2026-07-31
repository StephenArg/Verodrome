import SwiftUI
import SwiftData
import VerodromeKit

struct RootLaunchView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @EnvironmentObject private var player: PlayerViewModel
    @StateObject private var router = AppRouter()

    var body: some View {
        Group {
            switch router.launchPhase {
            case .login:
                LoginView()
            case .syncing, .main:
                // `.syncing` is unused for gating; sync runs in-background with a banner.
                MainContainerView()
                    .environmentObject(router)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.launchPhase)
        .onAppear {
            PreviewSeeder.seedIfNeeded(in: modelContext)
            refreshLaunchPhase()
        }
        .onChange(of: account.isLoggedIn) { _, _ in refreshLaunchPhase() }
        .onReceive(NotificationCenter.default.publisher(for: .librarySynced)) { _ in
            settings.isLibrarySynced = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .verodromeOpenURL)) { note in
            guard let url = note.object as? URL else { return }
            Task { await DeepLinkHandler.handle(url, router: router, player: player) }
        }
    }

    private func refreshLaunchPhase() {
        router.resolveLaunchPhase(isLoggedIn: account.isLoggedIn)
    }
}
