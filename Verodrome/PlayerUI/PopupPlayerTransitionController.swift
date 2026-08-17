import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

enum PopupPlayerTransitionController {
    static func configureSheet(_ controller: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
    }
}

/// Presents the full player from the topmost UIKit controller.
///
/// A SwiftUI `.sheet` on the root is swallowed when a nested destination already
/// has its own `.sheet` (album playlist picker, song-row actions, library editor) —
/// the same reason `ShareComposer` presents on the top view controller. Play /
/// Shuffle hit that path most often from Library → list → detail → album.
@MainActor
enum PopupPlayerPresenter {
    static func present(_ view: some View, onDismissed: @escaping () -> Void) {
        if existingHost() != nil { return }
        guard let presenter = topViewController() else { return }

        let host = PopupPlayerHostController(rootView: AnyView(view))
        host.onDismissed = onDismissed
        PopupPlayerTransitionController.configureSheet(host)

        if presenter.transitionCoordinator != nil {
            presenter.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                present(host, from: topViewController() ?? presenter)
            }
            return
        }
        present(host, from: presenter)
    }

    static func dismiss() {
        existingHost()?.dismiss(animated: true)
    }

    private static func present(_ host: UIViewController, from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else {
            presenter.presentedViewController?.present(host, animated: true)
            return
        }
        presenter.present(host, animated: true)
    }

    private static func existingHost() -> UIViewController? {
        var current = topViewController()
        while let controller = current {
            if controller is PopupPlayerHostController { return controller }
            current = controller.presentingViewController
        }
        return nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }

        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

private final class PopupPlayerHostController: UIHostingController<AnyView> {
    var onDismissed: (() -> Void)?
    private var didNotifyDismiss = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didNotifyDismiss else { return }
        // Pushed destinations inside the player don't dismiss this controller.
        guard isBeingDismissed || presentingViewController == nil else { return }
        didNotifyDismiss = true
        onDismissed?()
    }
}

/// Hosts environment objects for a UIKit-presented player. Lives on `MainContainerView`
/// so Play / Shuffle can present without going through the root SwiftUI sheet slot.
struct PopupPlayerPresentation: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var progress: PlayerProgressModel
    @EnvironmentObject private var queueList: QueueListModel
    @EnvironmentObject private var shuffleAll: ShuffleAllCoordinator
    @EnvironmentObject private var radioContinuation: RadioContinuationCoordinator
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: router.playerOpenGeneration) { _, _ in
                if router.showFullPlayer {
                    presentPlayer()
                }
            }
            .onChange(of: router.showFullPlayer) { _, show in
                if !show {
                    PopupPlayerPresenter.dismiss()
                }
            }
    }

    private func presentPlayer() {
        PopupPlayerPresenter.present(
            PopupPlayerView()
                .environmentObject(player)
                .environmentObject(router)
                .environmentObject(themeManager)
                .environmentObject(settings)
                .environmentObject(nowPlaying)
                .environmentObject(progress)
                .environmentObject(queueList)
                .environmentObject(shuffleAll)
                .environmentObject(radioContinuation)
                .environmentObject(account)
                .environmentObject(librarySync)
                .modelContext(modelContext)
                .tint(themeManager.accentColor)
        ) {
            router.playerDestinations = []
            if router.showFullPlayer {
                router.showFullPlayer = false
            }
        }
    }
}
