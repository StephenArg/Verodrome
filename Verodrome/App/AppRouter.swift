import SwiftUI

enum AppRoute: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case podcast(String)
    case genre(String)
    case song(String)
    case settings
    case search
}

enum LaunchPhase: Equatable {
    case login
    case syncing
    case main
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path = NavigationPath()
    @Published var launchPhase: LaunchPhase = .login
    @Published var showFullPlayer = false

    func resolveLaunchPhase(isLoggedIn: Bool, isLibrarySynced: Bool = true, isSyncing: Bool = false) {
        // Library sync runs in the background; never block the UI on `.syncing`.
        _ = (isLibrarySynced, isSyncing)
        launchPhase = isLoggedIn ? .main : .login
    }

    /// Brings up the full player, however it was asked for — the mini bar, or a shuffle
    /// button that wants to show the user what it just queued up.
    func openPlayer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            showFullPlayer = true
        }
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
