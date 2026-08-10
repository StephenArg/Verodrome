import SwiftUI
import UIKit
import VerodromeKit

/// Opens the share composer from anywhere.
///
/// Share actions live in context menus, in the popup player, and in list rows — several
/// of which are already inside a sheet, where attaching another `.sheet` at the root does
/// nothing. Presenting on the topmost view controller is what the existing system share
/// sheet does for the same reason.
@MainActor
enum ShareComposer {
    static func present(_ subject: ShareSubject, onChange: (() -> Void)? = nil) {
        present(mode: .create(subject), onChange: onChange)
    }

    static func presentEditor(for share: ShareRef, onChange: (() -> Void)? = nil) {
        present(mode: .edit(share), onChange: onChange)
    }

    private static func present(mode: ShareComposerView.Mode, onChange: (() -> Void)?) {
        guard let top = topViewController() else { return }

        // Filled in below, once the controller it has to dismiss exists.
        var dismiss: () -> Void = {}
        let view = ShareComposerView(
            mode: mode,
            onChange: onChange,
            onClose: { dismiss() }
        )

        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        dismiss = { [weak host] in host?.dismiss(animated: true) }
        top.present(host, animated: true)
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

/// The player's Share action, which has to work whatever the server is.
///
/// When the backend can mint links this opens the composer; otherwise it falls back to
/// the plain system share sheet with the track's name, which is all the player could ever
/// offer before.
@MainActor
func presentNowPlayingShare(item: QueueItem?) {
    guard let item else { return }
    let title = item.title
    let artist = item.artist

    Task {
        guard item.kind == .song, await ShareActions.shared.canShare(.song) else {
            presentSongShareSheet(title: title, artist: artist)
            return
        }
        ShareComposer.present(
            ShareSubject(
                resourceType: .song,
                resourceIds: [item.playableId],
                title: title,
                subtitle: artist,
                artwork: item.artworkId.map { ArtworkRef(id: $0, kind: .album) }
            )
        )
    }
}

extension ShareSubject {
    static func song(_ song: Song) -> ShareSubject {
        ShareSubject(
            resourceType: .song,
            resourceIds: [song.remoteId],
            title: song.title,
            subtitle: song.displayArtist,
            artwork: song.displayArtworkToken.map { ArtworkRef(id: $0, kind: .album) }
        )
    }
}

// MARK: - Menu entry point

/// A "Share…" menu button that only appears when the server can share this kind of thing.
///
/// Capabilities are established the first time any share menu is built, so the button is
/// absent for one menu opening on a server that turns out not to support sharing, and
/// correct from then on. Showing an option that always fails would be worse.
struct ShareMenuButton: View {
    let subject: ShareSubject
    var title: String = "Share…"

    @State private var isAvailable: Bool

    init(subject: ShareSubject, title: String = "Share…") {
        self.subject = subject
        self.title = title
        // Optimistic until proven otherwise: a server that supports sharing shouldn't
        // have the button pop in a moment after the menu opens.
        _isAvailable = State(
            initialValue: ShareActions.shared.knownCapabilities?.canShare(subject.resourceType) ?? true
        )
    }

    var body: some View {
        Group {
            if isAvailable {
                Button {
                    ShareComposer.present(subject)
                } label: {
                    Label(title, systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            isAvailable = await ShareActions.shared.canShare(subject.resourceType)
        }
    }
}
