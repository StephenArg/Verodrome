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

enum PlayerDestination: Hashable {
    case album(String)
    case artist(String)
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path = NavigationPath()
    @Published var launchPhase: LaunchPhase = .login
    @Published var showFullPlayer = false
    /// Destinations pushed on the full player (artist name, album title, …).
    @Published var playerDestinations: [PlayerDestination] = []
    /// Bumped on every `openPlayer()` so a stuck `showFullPlayer == true` still retries.
    @Published var playerOpenGeneration = 0

    func resolveLaunchPhase(isLoggedIn: Bool, isLibrarySynced: Bool = true, isSyncing: Bool = false) {
        // Library sync runs in the background; never block the UI on `.syncing`.
        _ = (isLibrarySynced, isSyncing)
        launchPhase = isLoggedIn ? .main : .login
    }

    /// Brings up the full player, however it was asked for — the mini bar, or a shuffle
    /// button that wants to show the user what it just queued up.
    func openPlayer() {
        // Pop first so Play / Shuffle from an artist or album opened *inside*
        // the player returns to now playing instead of staying on that detail.
        playerDestinations = []
        // Next turn so a first-time present isn't cancelled by `play()` inserting
        // the mini player in the same transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showFullPlayer = true
            self.playerOpenGeneration += 1
        }
    }

    func pushPlayer(_ destination: PlayerDestination) {
        var next = playerDestinations
        next.append(destination)
        playerDestinations = next
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
