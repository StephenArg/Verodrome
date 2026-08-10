import SwiftUI
import UIKit
import VerodromeKit

/// Small bottom confirmation for like / queue / playlist actions. Hosted in its own
/// window so it appears above the player and queue sheets.
@MainActor
enum ActionToast {
    static func show(_ message: String) {
        Haptics.impact()
        ActionToastCenter.shared.show(message)
    }

    static func songLiked(_ liked: Bool) {
        show(liked ? "Liked" : "Unliked")
    }

    static func addedToQueue() {
        show("Added to Queue")
    }

    static func addedToPlaylist(_ name: String? = nil) {
        if let name, !name.isEmpty {
            show("Added to \(name)")
        } else {
            show("Added to Playlist")
        }
    }

    /// Toggles favorite and confirms with Liked / Unliked.
    static func toggleFavorite(song: Song) async {
        let liking = !song.isFavorite
        try? await LibraryActions.shared.toggleFavorite(song: song)
        songLiked(liking)
    }
}

@MainActor
private final class ActionToastCenter {
    static let shared = ActionToastCenter()

    private var window: PassthroughWindow?
    private var host: UIHostingController<ActionToastBanner>?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String) {
        hideTask?.cancel()
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let banner = ActionToastBanner(message: message, visible: true)
        if let host {
            host.rootView = banner
        } else {
            let host = UIHostingController(rootView: banner)
            host.view.backgroundColor = .clear
            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            window.isHidden = false
            self.host = host
            self.window = window
        }
        window?.isHidden = false

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.host?.rootView = ActionToastBanner(message: message, visible: false)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.window?.isHidden = true
        }
    }
}

private struct ActionToastBanner: View {
    let message: String
    var visible: Bool

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 12)
                .animation(.easeOut(duration: 0.22), value: visible)
                // Sit above the mini player when it is showing; still fine in the
                // full-player sheet where that chrome is hidden.
                .padding(.bottom, VerodromeTheme.miniPlayerHeight + 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Forwards every touch so the toast never blocks the controls underneath.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}
