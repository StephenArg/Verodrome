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
            case .loading:
                LaunchLoadingView()
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
            if account.isLoggedIn {
                PreviewSeeder.purgeDemoDataIfNeeded(in: modelContext)
            } else {
                PreviewSeeder.seedIfNeeded(in: modelContext)
            }
            refreshLaunchPhase()
        }
        .onChange(of: account.isLoggedIn) { _, loggedIn in
            if loggedIn {
                PreviewSeeder.purgeDemoDataIfNeeded(in: modelContext)
            }
            refreshLaunchPhase()
        }
        .onReceive(NotificationCenter.default.publisher(for: .librarySynced)) { _ in
            settings.isLibrarySynced = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .verodromeOpenURL)) { note in
            guard let url = note.object as? URL else { return }
            Task { await DeepLinkHandler.handle(url, router: router, player: player) }
        }
    }

    private func refreshLaunchPhase() {
        // Leaving the launch check for the app happens before the first frame settles,
        // so it shouldn't fade in like a screen change: open as if it had been there.
        // Every other switch — to sign-in, sign-out, a new login — keeps the fade.
        let opensApp = router.launchPhase == .loading && account.isLoggedIn
        var transaction = Transaction()
        transaction.disablesAnimations = opensApp
        withTransaction(transaction) {
            router.resolveLaunchPhase(isLoggedIn: account.isLoggedIn)
        }
    }
}

/// Shown until the stored account has been checked. Blank like the launch screen it
/// follows; the spinner only fades in if the check is slow, so a quick one doesn't
/// flash it on the way to sign-in.
private struct LaunchLoadingView: View {
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .opacity(showsSpinner ? 1 : 0)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeIn(duration: 0.2)) {
                showsSpinner = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
