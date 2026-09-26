import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

/// Which swipe setting a row follows.
enum SongRowSwipes {
    /// Song rows everywhere outside a playlist's own track list.
    case library
    /// A playlist's own rows, which can also offer Remove. `onRemove` is nil while the
    /// entry can't be removed — the playlist isn't editable, or another removal is still
    /// in flight — and the Remove swipe is left off.
    case playlist(onRemove: (() -> Void)?)
}

/// Shared song row menus, swipe actions, and playlist sheet wiring.
struct SongActionsModifier: ViewModifier {
    let song: Song
    var swipes: SongRowSwipes = .library
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @State private var showPlaylistSelector = false
    @State private var selectedAlbumId: String?
    @State private var selectedArtistId: String?

    private var downloadStatus: DownloadStatus {
        downloadCenter.status(for: song.remoteId, isDownloaded: song.isDownloadedLocally)
    }

    private var isDownloadWorking: Bool {
        switch downloadStatus {
        case .pending, .downloading: return true
        default: return false
        }
    }

    private var downloadActionTitle: String {
        switch downloadStatus {
        case .pending, .downloading: return "Cancel Download"
        // Tapping a waiting track downloads it now instead of holding out for Wi-Fi.
        case .waiting: return "Download Now"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        // Cached is still free to promote to a keep-forever download.
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

    func body(content: Content) -> some View {
        content
            // Not `.contextMenu`: see `CellContextMenu`.
            .background(CellContextMenu(menu: makeMenu))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipeButtons(for: swipeLeftAction)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                swipeButtons(for: swipeRightAction)
            }
            .sheet(isPresented: $showPlaylistSelector) {
                PlaylistSelectorView { playlist in
                    Task {
                        try? await LibraryActions.shared.addSongs([song], to: playlist)
                        ActionToast.addedToPlaylist(playlist.name)
                    }
                }
            }
            .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
            .navigationDestination(item: $selectedArtistId) { ArtistDetailView(artistID: $0) }
    }

    /// Same layout as the Songs list's long-press menu: acting on the song, then going
    /// somewhere with it. Built when the menu opens, so it reflects the song as it is then.
    private func makeMenu() -> UIMenu {
        var acting: [UIMenuElement] = [
            UIAction(
                title: song.isFavorite ? "Unlike" : "Like",
                image: UIImage(systemName: song.isFavorite ? "heart.slash" : "heart")
            ) { _ in
                Task { await ActionToast.toggleFavorite(song: song) }
            },
            SongMenuItems.rate(for: song),
            UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { _ in
                player.addToQueueTemporarily([QueueItem.from(song)])
            },
            UIAction(
                title: "Start Radio",
                image: UIImage(systemName: "dot.radiowaves.left.and.right"),
                attributes: player.isStartingRadio ? .disabled : []
            ) { _ in
                Task { await ActionToast.startRadio(song: song, player: player, router: router) }
            }
        ]
        // Same availability rule as `ShareMenuButton`: shown unless the server is known
        // not to support sharing songs.
        let shareSubject = ShareSubject.song(song)
        if ShareActions.shared.knownCapabilities?.canShare(shareSubject.resourceType) ?? true {
            acting.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                ShareComposer.present(shareSubject)
            })
        }

        var going: [UIMenuElement] = []
        if song.album?.compoundRemoteId != nil {
            going.append(UIAction(title: "Go to Album", image: UIImage(systemName: "square.stack")) { _ in
                openAlbum()
            })
        }
        if song.artist?.compoundRemoteId != nil {
            going.append(UIAction(title: "Go to Artist", image: UIImage(systemName: "person.fill")) { _ in
                openArtist()
            })
        }
        going.append(UIAction(title: "Add to Playlist", image: UIImage(systemName: "text.badge.plus")) { _ in
            showPlaylistSelector = true
        })
        going.append(UIAction(title: downloadActionTitle, image: UIImage(systemName: downloadActionSymbol)) { _ in
            Task { await LibraryActions.shared.downloadOrCancel(song: song) }
        })

        return UIMenu(children: [
            UIMenu(options: .displayInline, children: acting),
            UIMenu(options: .displayInline, children: going)
        ])
    }

    private func openAlbum() {
        guard let albumId = song.album?.compoundRemoteId else { return }
        if router.showFullPlayer {
            router.pushPlayer(.album(albumId))
        } else {
            selectedAlbumId = albumId
        }
    }

    private func openArtist() {
        guard let artistId = song.artist?.compoundRemoteId else { return }
        if router.showFullPlayer {
            router.pushPlayer(.artist(artistId))
        } else {
            selectedArtistId = artistId
        }
    }

    private var swipeLeftAction: String {
        if case .playlist = swipes { return settings.playlistSwipeLeftAction }
        return settings.swipeLeftAction
    }

    private var swipeRightAction: String {
        if case .playlist = swipes { return settings.playlistSwipeRightAction }
        return settings.swipeRightAction
    }

    private var removeAction: (() -> Void)? {
        if case .playlist(let onRemove) = swipes { return onRemove }
        return nil
    }

    @ViewBuilder
    private func swipeButtons(for action: String) -> some View {
        switch action {
        case "queue":
            Button {
                player.addToQueueTemporarily([QueueItem.from(song)])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.indigo)
        case "download":
            Button {
                Task { await LibraryActions.shared.downloadOrCancel(song: song) }
            } label: {
                Label(
                    downloadStatus == .none ? "Download" : (isDownloadWorking ? "Cancel" : "Remove"),
                    systemImage: "arrow.down.circle"
                )
            }
            .tint(.blue)
        case "favorite":
            Button {
                Task { await ActionToast.toggleFavorite(song: song) }
            } label: {
                Label("Favorite", systemImage: "heart")
            }
            .tint(themeManager.accentColor)
        case "remove":
            if let removeAction {
                // Destructive so the row slides out with the swipe rather than snapping
                // back first; the list drops the entry in the same pass.
                Button(role: .destructive, action: removeAction) {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        default:
            EmptyView()
        }
    }
}

extension View {
    func songActions(_ song: Song) -> some View {
        modifier(SongActionsModifier(song: song))
    }

    /// A row in a playlist's own track list: swipes follow Playlist Row Swipes, whose
    /// Remove calls `onRemove`.
    func playlistSongActions(_ song: Song, onRemove: (() -> Void)?) -> some View {
        modifier(SongActionsModifier(song: song, swipes: .playlist(onRemove: onRemove)))
    }

    /// Resolves the song by compound id, then attaches the shared long-press / swipe menu.
    /// Used by snapshot-backed lists (Search) that don't hold a live `Song` in the row.
    func songActions(compoundRemoteId: String) -> some View {
        modifier(DeferredSongActionsModifier(compoundRemoteId: compoundRemoteId))
    }
}

/// Loads a `Song` once, then forwards to `SongActionsModifier`.
private struct DeferredSongActionsModifier: ViewModifier {
    let compoundRemoteId: String
    @Environment(\.modelContext) private var modelContext
    @State private var song: Song?

    func body(content: Content) -> some View {
        Group {
            if let song {
                content.songActions(song)
            } else {
                content
            }
        }
        .task(id: compoundRemoteId) {
            let id = compoundRemoteId
            var descriptor = FetchDescriptor<Song>(
                predicate: #Predicate<Song> { $0.compoundRemoteId == id }
            )
            descriptor.fetchLimit = 1
            song = try? modelContext.fetch(descriptor).first
        }
    }
}

// MARK: - Shared menu items

/// Menu pieces shared by the song menus built in UIKit (here and the Songs list).
enum SongMenuItems {
    static func rate(for song: Song?) -> UIMenuElement {
        guard let song else {
            return UIAction(title: "Rate", image: UIImage(systemName: "star"), attributes: .disabled) { _ in }
        }
        let choices = (0...5).map { stars in
            UIAction(
                title: stars == 0 ? "Clear Rating" : String(repeating: "★", count: stars),
                image: UIImage(systemName: stars == 0 ? "star.slash" : (song.rating == stars ? "checkmark" : "star"))
            ) { _ in
                Task { try? await LibraryActions.shared.setRating(song: song, rating: stars) }
            }
        }
        return UIMenu(
            title: song.rating > 0 ? "Rated \(song.rating)/5" : "Rate",
            image: UIImage(systemName: song.rating > 0 ? "star.fill" : "star"),
            children: choices
        )
    }
}

// MARK: - UIKit long-press menu

/// Gives the list cell around this view a long-press menu built in UIKit.
///
/// Used in place of SwiftUI's `.contextMenu`, which on iOS 27 always gets an "Ask Siri"
/// item appended with no way to leave it out. Menus UIKit builds from the app's own
/// `UIMenu` don't get it — the Songs list's never has. The interaction goes on the cell
/// rather than on a view of its own, so taps still reach the row's button and swipes still
/// reach the list. Outside a `List` there is no cell, and so no menu.
struct CellContextMenu: UIViewRepresentable {
    let menu: () -> UIMenu

    func makeUIView(context: Context) -> CellContextMenuAnchor {
        let anchor = CellContextMenuAnchor()
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: CellContextMenuAnchor, context: Context) {
        anchor.menu = menu
    }

    static func dismantleUIView(_ anchor: CellContextMenuAnchor, coordinator: ()) {
        anchor.detach()
    }
}

/// Finds its cell once it's in the view hierarchy and points the cell's menu at this row.
final class CellContextMenuAnchor: UIView {
    var menu: (() -> UIMenu)?
    private weak var router: CellContextMenuRouter?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UICollectionViewCell || view is UITableViewCell) {
            ancestor = view.superview
        }
        guard let cell = ancestor else { return }
        let router = CellContextMenuRouter.installed(on: cell)
        router.anchor = self
        self.router = router
    }

    func detach() {
        if router?.anchor === self { router?.anchor = nil }
        router = nil
    }
}

/// One per cell, retained by the cell. Cells are reused from row to row, so the interaction
/// stays where it is and asks whichever row claimed the cell most recently.
private final class CellContextMenuRouter: NSObject, UIContextMenuInteractionDelegate {
    weak var anchor: CellContextMenuAnchor?
    private static var associationKey: UInt8 = 0

    /// How much of the row's own padding the lifted outline gives up, top and bottom.
    private static let outlineTrim: CGFloat = 6
    /// Never trimmed closer than this to the row's content.
    private static let minimumPadding: CGFloat = 6
    /// Matches the system's lifted-row corners.
    private static let cornerRadius: CGFloat = 12

    static func installed(on cell: UIView) -> CellContextMenuRouter {
        if let existing = objc_getAssociatedObject(cell, &associationKey) as? CellContextMenuRouter {
            return existing
        }
        let router = CellContextMenuRouter()
        cell.addInteraction(UIContextMenuInteraction(delegate: router))
        objc_setAssociatedObject(cell, &associationKey, router, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return router
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = anchor?.menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        liftedRow(for: interaction)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        liftedRow(for: interaction)
    }

    /// The row as it lifts, outlined a little inside the cell.
    ///
    /// UIKit sets the menu a fixed distance from this outline and has no other way to
    /// bring it closer, so trimming the row's own padding is what moves the menu up. It
    /// also gives the lifted row a platter to sit on: song rows have clear backgrounds,
    /// and the default outline lifted nothing visible.
    private func liftedRow(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
        guard let cell = interaction.view, cell.window != nil else { return nil }
        var outline = cell.bounds
        if let anchor, anchor.isDescendant(of: cell) {
            let content = anchor.convert(anchor.bounds, to: cell)
            let padding = min(content.minY - outline.minY, outline.maxY - content.maxY)
            let trim = max(0, min(Self.outlineTrim, padding - Self.minimumPadding))
            outline = outline.insetBy(dx: 0, dy: trim)
        }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: outline, cornerRadius: Self.cornerRadius)
        return UITargetedPreview(view: cell, parameters: parameters)
    }
}
