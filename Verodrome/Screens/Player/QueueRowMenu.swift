import SwiftUI
import UIKit
import VerodromeKit

/// Trailing ellipsis menu for a queue song row.
///
/// A custom popover rather than SwiftUI `Menu` / `UIMenu`: both reserve a wide
/// minimum width that leaves a large empty strip beside short labels like these.
struct QueueRowMenu: View {
    let item: QueueItem
    let downloadStatus: DownloadStatus
    let onOpenAlbum: (String) -> Void
    let onAddToPlaylist: (Song) -> Void

    @EnvironmentObject private var player: PlayerViewModel
    @State private var song: Song?
    @State private var showMenu = false
    /// Which edge of the popover faces the ellipsis. Flips when the row sits in the
    /// lower half of the screen so the menu grows upward instead of clipping.
    @State private var arrowEdge: Edge = .top
    /// Latest global midY of the ellipsis, read when opening so the edge is settled
    /// before the popover presents.
    @State private var buttonMidY: CGFloat = 0

    private var downloadActionTitle: String {
        switch downloadStatus {
        case .pending, .downloading: return "Cancel Download"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        case .none, .partial, .cached: return "Download"
        }
    }

    private var downloadActionSymbol: String {
        switch downloadStatus {
        case .pending, .downloading: return "stop.circle"
        case .downloaded: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .none, .partial, .cached: return "arrow.down.circle"
        }
    }

    var body: some View {
        Button {
            // Below mid-screen → arrow on the popover's bottom edge (menu above).
            arrowEdge = buttonMidY > UIScreen.main.bounds.midY ? .bottom : .top
            showMenu = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: QueueRowMenuMidYKey.self,
                    value: geo.frame(in: .global).midY
                )
            }
        }
        .onPreferenceChange(QueueRowMenuMidYKey.self) { buttonMidY = $0 }
        .popover(isPresented: $showMenu, arrowEdge: arrowEdge) {
            menuContent
                .presentationCompactAdaptation(.popover)
        }
        .task(id: item.playableId) {
            song = resolveSong()
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(
                title: song?.isFavorite == true ? "Unlike" : "Like",
                systemImage: song?.isFavorite == true ? "heart.slash" : "heart",
                disabled: song == nil
            ) {
                guard let song else { return }
                Task { await ActionToast.toggleFavorite(song: song) }
            }

            menuRow(title: "Add to Queue", systemImage: "text.append") {
                player.addToQueueTemporarily([item])
            }

            menuRow(title: "Share", systemImage: "square.and.arrow.up") {
                presentSongShareSheet(title: item.title, artist: item.artist)
            }

            Divider().padding(.vertical, 4)

            if let albumId = song?.album?.compoundRemoteId {
                menuRow(title: "Go to Album", systemImage: "square.stack") {
                    onOpenAlbum(albumId)
                }
            }

            menuRow(
                title: "Add to Playlist",
                systemImage: "text.badge.plus",
                disabled: song == nil
            ) {
                guard let song else { return }
                onAddToPlaylist(song)
            }

            menuRow(
                title: downloadActionTitle,
                systemImage: downloadActionSymbol,
                disabled: song == nil
            ) {
                guard let song else { return }
                Task { await LibraryActions.shared.downloadOrCancel(song: song) }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        // Hug the longest label instead of stretching to the system menu's min width.
        .fixedSize(horizontal: true, vertical: true)
    }

    private func menuRow(
        title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showMenu = false
            // Let the popover finish dismissing before presenting a sheet / share UI.
            DispatchQueue.main.async(execute: action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.body)
            }
            .foregroundStyle(disabled ? .tertiary : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func resolveSong() -> Song? {
        guard item.kind == .song,
              let account = try? VerodromeKit.shared.activeAccount(),
              let song = try? VerodromeKit.shared.repository()?.resolveSong(
                  remoteId: item.playableId,
                  account: account
              )
        else { return nil }
        return song
    }
}

private struct QueueRowMenuMidYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Presents a system share sheet for a song title (and optional artist).
@MainActor
func presentSongShareSheet(title: String?, artist: String?) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first?.rootViewController else { return }
    var top = root
    while let presented = top.presentedViewController { top = presented }

    var items: [Any] = []
    if let title, let artist, !artist.isEmpty {
        items.append("\(title) — \(artist)")
    } else if let title, !title.isEmpty {
        items.append(title)
    }
    if items.isEmpty { items.append("Now Playing") }

    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    let host = UIViewController()
    host.modalPresentationStyle = .overFullScreen
    host.view.backgroundColor = .clear
    activity.completionWithItemsHandler = { _, _, _, _ in
        host.dismiss(animated: true)
    }
    host.present(activity, animated: true)
    top.present(host, animated: true)
}
