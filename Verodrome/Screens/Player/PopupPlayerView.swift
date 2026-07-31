import SwiftUI
import AVKit
import UIKit
import VerodromeKit

struct PopupPlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var currentSong: Song?
    @State private var bottomPanel: BottomPanel?
    @State private var artistCredits: [PlayerArtistCredit] = []
    @State private var selectedAlbumId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playerHeader
                    .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
                    .padding(.top, 36)
                    .padding(.bottom, 4)

                LargeArtworkView(
                    urlString: player.currentItem?.artworkId,
                    symbol: player.currentItem?.kind == .radio
                        ? "dot.radiowaves.left.and.right"
                        : "music.note"
                )
                .padding(.top, 24)
                // Keep dismiss-swipe local to artwork so it cannot steal
                // button / sheet gestures.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            if value.translation.height > 80, abs(value.translation.width) < 80 {
                                dismiss()
                            }
                        }
                )

                // Absorb leftover height above the metadata so title / progress /
                // transport / options stay packed toward the bottom.
                Spacer(minLength: 8)

                VStack(alignment: .leading, spacing: 6) {
                    if let song = currentSong {
                        RatingStarsView(rating: song.rating, starSize: 13, spacing: 6) { newRating in
                            Task { try? await LibraryActions.shared.setRating(song: song, rating: newRating) }
                        }
                        .frame(height: 16)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(
                                text: player.currentItem?.title ?? "Not Playing",
                                font: .title2.bold(),
                                fitAlignment: .leading
                            )

                            artistCreditsRow
                                .opacity(artistCredits.isEmpty ? 0 : 1)
                        }

                        favoriteButton
                    }

                    if !player.statusMessage.isEmpty {
                        Label(player.statusMessage, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Match artwork / seek bar width.
                .padding(.horizontal, VerodromeTheme.playerContentHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .clipped()

                PlayerControlView()
                    .frame(maxWidth: .infinity)
                    .clipped()

                bottomActionBar
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
            }
            .background(
                LinearGradient(
                    colors: [
                        (themeManager.playerTintColor ?? Color.accentColor).opacity(0.25),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            )
            .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: player.currentItem?.playableId) {
                currentSong = resolveCurrentSong()
                artistCredits = resolveArtistCredits()
            }
            .sheet(item: $bottomPanel) { panel in
                switch panel {
                case .queue:
                    NavigationStack {
                        QueueView(onDismiss: { bottomPanel = nil })
                            .navigationTitle("Queue")
                    }
                    .presentationDetents([.large])
                case .addToPlaylist:
                    if let song = currentSong {
                        PlaylistSelectorView { playlist in
                            Task { try? await LibraryActions.shared.addSongs([song], to: playlist) }
                        }
                    }
                case .equalizer:
                    NavigationStack {
                        EqualizerView()
                            .navigationTitle("Equalizer")
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) { Button("Done") { bottomPanel = nil } }
                            }
                    }
                    .presentationDetents([.large])
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .presentationCornerRadius(24)
    }

    private var albumTitle: String {
        let name = player.currentItem?.albumName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return "" }
        return name
    }

    // MARK: - Player header (dismiss / album / overflow)

    /// Custom header so it can sit a little below the top safe area instead of
    /// being pinned to it by the system navigation bar. The album title is
    /// z-centered so unequal chevron / menu widths don't shift it.
    private var playerHeader: some View {
        EquatableView(content: PlayerHeader(
            albumTitle: albumTitle,
            albumId: currentSong?.album?.compoundRemoteId,
            song: currentSong,
            onDismiss: { dismiss() },
            onOpenAlbum: { selectedAlbumId = currentSong?.album?.compoundRemoteId },
            onShare: { presentShareSheet() },
            onAddToPlaylist: { bottomPanel = .addToPlaylist },
            onOpenQueue: { bottomPanel = .queue },
            onEqualizer: { bottomPanel = .equalizer }
        ))
    }

    // MARK: - Bottom action bar (AirPlay / Share / Queue)

    private var bottomActionBar: some View {
        HStack(spacing: 28) {
            AirPlayRoutePicker()
                .frame(width: 24, height: 24)

            Spacer()

            Button {
                presentShareSheet()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }

            Button {
                bottomPanel = .queue
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Favorite

    @ViewBuilder
    private var favoriteButton: some View {
        if let song = currentSong {
            Button {
                Task { try? await LibraryActions.shared.toggleFavorite(song: song) }
            } label: {
                Image(systemName: song.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 24))
                    .foregroundStyle(song.isFavorite ? Color.accentColor : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(song.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    // MARK: - Artist credits

    @ViewBuilder
    private var artistCreditsRow: some View {
        if artistCredits.count == 1, let only = artistCredits.first {
            // Single credit — keep marquee for long names.
            if let artistID = only.artistID {
                NavigationLink {
                    ArtistDetailView(artistID: artistID)
                } label: {
                    MarqueeText(
                        text: only.name,
                        font: .subheadline,
                        speed: 24,
                        fitAlignment: .leading
                    )
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                MarqueeText(
                    text: only.name,
                    font: .subheadline,
                    speed: 24,
                    fitAlignment: .leading
                )
                .foregroundStyle(.secondary)
            }
        } else if !artistCredits.isEmpty {
            // Multiple credits — each resolved name is tappable.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(artistCredits.enumerated()), id: \.offset) { index, credit in
                        if index > 0 {
                            Text(" & ")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let artistID = credit.artistID {
                            NavigationLink {
                                ArtistDetailView(artistID: artistID)
                            } label: {
                                Text(credit.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(credit.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presentShareSheet() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(makeShareController(), animated: true)
    }

    private func makeShareController() -> UIViewController {
        var items: [Any] = []
        if let title = player.currentItem?.title, let artist = player.currentItem?.artist, !artist.isEmpty {
            items.append("\(title) — \(artist)")
        } else if let title = player.currentItem?.title {
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
        return host
    }

    private func resolveCurrentSong() -> Song? {
        guard let playableId = player.currentItem?.playableId,
              player.currentItem?.kind == .song,
              let account = try? VerodromeKit.shared.activeAccount(),
              let song = try? VerodromeKit.shared.repository()?.resolveSong(remoteId: playableId, account: account)
        else { return nil }
        return song
    }

    private func resolveArtistCredits() -> [PlayerArtistCredit] {
        let raw = currentSong?.displayArtist
            ?? player.currentItem?.artist
            ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Unknown Artist" else { return [] }

        let names = Self.splitArtistNames(trimmed)
        let primary = currentSong?.artist ?? currentSong?.album?.artist

        // Most songs have one linked artist — navigate there even if the
        // display string is a slight variant of the library name.
        if names.count == 1, let primary {
            return [PlayerArtistCredit(name: names[0], artistID: primary.compoundRemoteId)]
        }

        let catalog: [Artist] = {
            guard let account = try? VerodromeKit.shared.activeAccount(),
                  let repo = VerodromeKit.shared.repository(),
                  let artists = try? repo.fetchArtists(account: account)
            else { return [] }
            return artists
        }()

        return names.map { name in
            let id = Self.matchArtistID(named: name, preferred: primary, catalog: catalog)
            return PlayerArtistCredit(name: name, artistID: id)
        }
    }

    private static func matchArtistID(named name: String, preferred: Artist?, catalog: [Artist]) -> String? {
        if let preferred,
           preferred.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return preferred.compoundRemoteId
        }
        return catalog.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        })?.compoundRemoteId
    }

    /// Splits common multi-artist credit strings ("A & B", "A feat. B", "A, B", …).
    private static func splitArtistNames(_ raw: String) -> [String] {
        let separators = [
            " feat. ", " feat ", " featuring ", " ft. ", " ft ",
            " vs. ", " vs ", " x ", " / ", " & ", ", "
        ]
        var parts = [raw]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PlayerArtistCredit: Equatable {
    let name: String
    let artistID: String?
}

/// Header containing the dismiss chevron, centered album title, and overflow
/// menu.
private struct PlayerHeader: View, Equatable {
    let albumTitle: String
    let albumId: String?
    let song: Song?
    let onDismiss: () -> Void
    let onOpenAlbum: () -> Void
    let onShare: () -> Void
    let onAddToPlaylist: () -> Void
    let onOpenQueue: () -> Void
    let onEqualizer: () -> Void

    private let sideButtonWidth: CGFloat = 52

    var body: some View {
        ZStack {
            // Below the buttons in z-order, and inset past them, so a long title
            // can never swallow taps meant for the chevron / overflow menu.
            Button { onOpenAlbum() } label: {
                Text(albumTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .disabled(albumId == nil)
            .padding(.horizontal, sideButtonWidth + 8)

            HStack(spacing: 0) {
                Button { onDismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: sideButtonWidth, height: sideButtonWidth, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")

                Spacer(minLength: 0)

                PlayerOverflowMenuButton(
                    menuState: PlayerOverflowMenuButton.MenuState(
                        hasSong: song != nil,
                        isFavorite: song?.isFavorite == true
                    ),
                    onShare: onShare,
                    onToggleFavorite: {
                        guard let song else { return }
                        Task { try? await LibraryActions.shared.toggleFavorite(song: song) }
                    },
                    onAddToPlaylist: onAddToPlaylist,
                    onOpenQueue: onOpenQueue,
                    onEqualizer: onEqualizer
                )
                .frame(width: sideButtonWidth, height: sideButtonWidth)
                .accessibilityLabel("More options")
            }
        }
        .frame(height: sideButtonWidth)
    }

    static func == (lhs: PlayerHeader, rhs: PlayerHeader) -> Bool {
        lhs.albumTitle == rhs.albumTitle
            && lhs.albumId == rhs.albumId
            && lhs.song?.remoteId == rhs.song?.remoteId
            && lhs.song?.isFavorite == rhs.song?.isFavorite
    }
}

/// Overflow menu hosted as a `UIButton` menu. A SwiftUI `Menu` is rebuilt
/// whenever any ancestor re-renders — which the player does continuously while
/// playing — and that makes the open menu's rows visibly pulse. A `UIMenu` is a
/// static snapshot, so it stays put; it is only rebuilt when `state` changes.
private struct PlayerOverflowMenuButton: UIViewRepresentable {
    struct MenuState: Equatable {
        var hasSong: Bool
        var isFavorite: Bool
    }

    var menuState: MenuState
    var onShare: () -> Void
    var onToggleFavorite: () -> Void
    var onAddToPlaylist: () -> Void
    var onOpenQueue: () -> Void
    var onEqualizer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: "ellipsis",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
                    .applying(UIImage.SymbolConfiguration(weight: .semibold))
            ),
            for: .normal
        )
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        button.menu = context.coordinator.makeMenu(for: menuState)
        context.coordinator.renderedState = menuState
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Keep the action closures current without touching the menu, so an open
        // menu is never rebuilt underneath the user.
        context.coordinator.owner = self
        guard context.coordinator.renderedState != menuState else { return }
        context.coordinator.renderedState = menuState
        button.menu = context.coordinator.makeMenu(for: menuState)
    }

    final class Coordinator {
        var owner: PlayerOverflowMenuButton
        var renderedState: MenuState?

        init(owner: PlayerOverflowMenuButton) {
            self.owner = owner
        }

        func makeMenu(for state: MenuState) -> UIMenu {
            let share = UIAction(
                title: "Share Song",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.owner.onShare() }

            let songInfo = UIAction(
                title: "Song Info",
                image: UIImage(systemName: "info.circle"),
                attributes: .disabled
            ) { _ in }

            let favorite = UIAction(
                title: state.isFavorite ? "Unlike Song" : "Like Song",
                image: UIImage(systemName: state.isFavorite ? "heart.slash" : "heart"),
                attributes: state.hasSong ? [] : .disabled
            ) { [weak self] _ in self?.owner.onToggleFavorite() }

            let addToPlaylist = UIAction(
                title: "Add to Playlist",
                image: UIImage(systemName: "text.badge.plus"),
                attributes: state.hasSong ? [] : .disabled
            ) { [weak self] _ in self?.owner.onAddToPlaylist() }

            let addToQueue = UIAction(
                title: "Add to Queue",
                image: UIImage(systemName: "text.append"),
                attributes: .disabled
            ) { _ in }

            let openQueue = UIAction(
                title: "Open Queue",
                image: UIImage(systemName: "list.bullet")
            ) { [weak self] _ in self?.owner.onOpenQueue() }

            let lyrics = UIAction(
                title: "Lyrics On/Off",
                image: UIImage(systemName: "text.quote"),
                attributes: .disabled
            ) { _ in }

            let hideRating = UIAction(
                title: "Hide Rating Stars",
                image: UIImage(systemName: "star.slash"),
                attributes: .disabled
            ) { _ in }

            let equalizer = UIAction(
                title: "Equalizer",
                image: UIImage(systemName: "slider.vertical.3")
            ) { [weak self] _ in self?.owner.onEqualizer() }

            let sleepTimer = UIAction(
                title: "Sleep Timer",
                image: UIImage(systemName: "moon.zzz"),
                attributes: .disabled
            ) { _ in }

            return UIMenu(children: [
                UIMenu(options: .displayInline, children: [share, songInfo]),
                UIMenu(options: .displayInline, children: [favorite, addToPlaylist, addToQueue, openQueue]),
                UIMenu(options: .displayInline, children: [lyrics, hideRating, equalizer, sleepTimer])
            ])
        }
    }
}

private enum BottomPanel: Identifiable {
    case queue, equalizer, addToPlaylist
    var id: Int { hashValue }
}

// MARK: - AirPlay route picker

/// AirPlay route picker rendered as a plain SwiftUI view.
/// `AVRoutePickerView` shows the system AirPlay icon and presents the route
/// picker when tapped; we forward its intrinsic size into SwiftUI.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = tint
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
        uiView.backgroundColor = .clear
    }
}
