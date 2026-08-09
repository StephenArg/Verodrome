import SwiftUI
import VerodromeKit

struct MainContainerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if horizontalSizeClass == .regular {
                    RootSplitView()
                } else {
                    RootTabView()
                }
            }

            // iPhone iOS 26+: mini player lives in tabViewBottomAccessory.
            // iPad / older iOS: floating chrome bar overlay.
            if usesOverlayMiniPlayer {
                MiniPlayerContainerView()
                    .padding(.horizontal, horizontalSizeClass == .regular ? 16 : 0)
            }
        }
        .sheet(isPresented: $router.showFullPlayer) {
            PopupPlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .presentationBackgroundInteraction(.disabled)
        }
        .task {
            // Settled here rather than in the menus that need it: a context menu's
            // contents are built synchronously, so they can't wait on a round trip to
            // find out whether this server shares at all.
            await ShareActions.shared.capabilities()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountChanged)) { _ in
            // Sharing is a property of the server and the account's permissions on it.
            ShareActions.shared.reset()
            Task { await ShareActions.shared.capabilities() }
        }
    }

    private var usesOverlayMiniPlayer: Bool {
        if horizontalSizeClass == .regular { return true }
        if #available(iOS 26.1, *) { return false }
        return true
    }
}
