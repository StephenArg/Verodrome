import SwiftUI
import UIKit
import VerodromeKit

/// Resolves a library `Song` for a queue row's playable id.
@MainActor
enum QueueSongLibrary {
    static func resolveSong(for item: QueueItem) -> Song? {
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

/// Long-press menu for a queue song row — same choices as `QueueRowMenu`.
struct QueueSongContextMenu: View {
    let item: QueueItem
    let downloadStatus: DownloadStatus
    let onOpenAlbum: (String) -> Void
    let onOpenArtist: (String) -> Void
    let onAddToPlaylist: (Song) -> Void

    @EnvironmentObject private var queueList: QueueListModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter

    private var song: Song? { QueueSongLibrary.resolveSong(for: item) }

    var body: some View {
        Button {
            guard let song else { return }
            Task { await ActionToast.toggleFavorite(song: song) }
        } label: {
            Label(
                song?.isFavorite == true ? "Unlike" : "Like",
                systemImage: song?.isFavorite == true ? "heart.slash" : "heart"
            )
        }
        .disabled(song == nil)

        Button {
            queueList.addToQueueTemporarily([item])
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Button {
            Task { await ActionToast.startRadio(seed: item, player: player, router: router) }
        } label: {
            Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
        }
        .disabled(item.kind != .song || player.isStartingRadio)

        Button {
            presentNowPlayingShare(item: item)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if let albumId = song?.album?.compoundRemoteId {
            Button {
                onOpenAlbum(albumId)
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }

        if let artistId = song?.artist?.compoundRemoteId {
            Button {
                onOpenArtist(artistId)
            } label: {
                Label("Go to Artist", systemImage: "person.fill")
            }
        }

        Button {
            guard let song else { return }
            onAddToPlaylist(song)
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(song == nil)

        Button {
            guard let song else { return }
            Task { await LibraryActions.shared.downloadOrCancel(song: song) }
        } label: {
            Label(downloadActionTitle, systemImage: downloadActionSymbol)
        }
        .disabled(song == nil)
    }

    private var downloadActionTitle: String {
        switch downloadStatus {
        case .pending, .downloading: return "Cancel Download"
        case .waiting: return "Download Now"
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
        case .none, .waiting, .partial, .cached: return "arrow.down.circle"
        }
    }
}

/// Trailing ellipsis menu for a queue song row.
///
/// A custom popover rather than SwiftUI `Menu` / `UIMenu`: both reserve a wide
/// minimum width that leaves a large empty strip beside short labels like these.
struct QueueRowMenu: View {
    let item: QueueItem
    let downloadStatus: DownloadStatus
    let onOpenAlbum: (String) -> Void
    let onOpenArtist: (String) -> Void
    let onAddToPlaylist: (Song) -> Void

    @EnvironmentObject private var queueList: QueueListModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @State private var buttonGlobalFrame: CGRect = .zero
    @State private var popoverArrowEdge: Edge = .top
    @State private var menuPresentation: QueueRowMenuPresentation?

    private var downloadActionTitle: String {
        switch downloadStatus {
        case .pending, .downloading: return "Cancel Download"
        case .waiting: return "Download Now"
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
        case .none, .waiting, .partial, .cached: return "arrow.down.circle"
        }
    }

    var body: some View {
        Button {
            let song = resolveSong()
            popoverArrowEdge = preferredArrowEdge(for: buttonGlobalFrame)
            // Present on the next turn so `arrowEdge` is settled before UIKit reads it.
            DispatchQueue.main.async {
                menuPresentation = QueueRowMenuPresentation(song: song)
            }
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
                Color.clear
                    .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                        buttonGlobalFrame = frame
                    }
            }
        }
        .popover(item: $menuPresentation, arrowEdge: popoverArrowEdge) { presentation in
            menuContent(song: presentation.song)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// `.top` grows the menu below the ellipsis; `.bottom` grows it above.
    private func preferredArrowEdge(for frame: CGRect) -> Edge {
        guard frame != .zero else { return .top }
        let screenHeight = UIScreen.main.bounds.height
        let estimatedMenuHeight: CGFloat = 360
        let spaceBelow = screenHeight - frame.maxY
        let spaceAbove = frame.minY
        if spaceBelow >= estimatedMenuHeight { return .top }
        if spaceAbove >= estimatedMenuHeight { return .bottom }
        return spaceBelow >= spaceAbove ? .top : .bottom
    }

    private func menuContent(song: Song?) -> some View {
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
                queueList.addToQueueTemporarily([item])
            }

            menuRow(
                title: "Start Radio",
                systemImage: "dot.radiowaves.left.and.right",
                disabled: item.kind != .song || player.isStartingRadio
            ) {
                Task { await ActionToast.startRadio(seed: item, player: player, router: router) }
            }

            menuRow(title: "Share", systemImage: "square.and.arrow.up") {
                presentNowPlayingShare(item: item)
            }

            Divider().padding(.vertical, 4)

            if let albumId = song?.album?.compoundRemoteId {
                menuRow(title: "Go to Album", systemImage: "square.stack") {
                    onOpenAlbum(albumId)
                }
            }

            if let artistId = song?.artist?.compoundRemoteId {
                menuRow(title: "Go to Artist", systemImage: "person.fill") {
                    onOpenArtist(artistId)
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
            menuPresentation = nil
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
        QueueSongLibrary.resolveSong(for: item)
    }
}

private struct QueueRowMenuPresentation: Identifiable {
    let id = UUID()
    let song: Song?
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
