import SwiftUI
import AVKit
import UIKit
import VerodromeKit

struct PopupPlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var downloadCenter = DownloadCenter.shared
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
                    .layoutPriority(1)

                heroPanel
                    .padding(.top, 24)

                // Everything below the cover carries a layout priority so it is
                // measured first and keeps its full height; the artwork then takes
                // whatever is left. Without this the cover claims its ideal square
                // and the transport controls are pushed past the bottom edge.
                VStack(alignment: .leading, spacing: 6) {
                    if settings.showRatingStars || settings.showSongInfo {
                        HStack(alignment: .center, spacing: 12) {
                            if settings.showRatingStars, let song = currentSong {
                                RatingStarsView(rating: song.rating, starSize: 13, spacing: 6) { newRating in
                                    Task { try? await LibraryActions.shared.setRating(song: song, rating: newRating) }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Spacer(minLength: 0)

                            if settings.showSongInfo, let song = currentSong, let info = songInfoText(for: song) {
                                Text(info)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(
                                text: player.currentItem?.title ?? "Not Playing",
                                font: .title2.bold(),
                                fitAlignment: .leading
                            )

                            artistCreditsRow
                                .opacity(artistCredits.isEmpty && downloadStatus == .none ? 0 : 1)
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
                .animation(.easeInOut(duration: 0.2), value: settings.showRatingStars)
                .animation(.easeInOut(duration: 0.2), value: settings.showSongInfo)
                .layoutPriority(1)

                PlayerControlView()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                bottomActionBar
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .layoutPriority(1)
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
                if settings.showLyricsInPlayer { player.requestLyrics() }
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
                            Task {
                                try? await LibraryActions.shared.addSongs([song], to: playlist)
                                ActionToast.addedToPlaylist(playlist.name)
                            }
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

    // MARK: - Hero panel (artwork / lyrics)

    /// A track only has lyrics once the lookup has actually produced text.
    private var lyricsAvailable: Bool { !player.lyrics.isEmpty }

    /// Lyrics take over the hero slot only when the user asked for them *and* this
    /// track has some; otherwise the artwork stays put.
    private var showingLyrics: Bool { settings.showLyricsInPlayer && lyricsAvailable }

    /// Artwork and lyrics are crossfaded rather than swapped, so `LargeArtworkView`
    /// stays mounted and keeps feeding the background tint while lyrics are up.
    private var heroPanel: some View {
        ZStack {
            LargeArtworkView(
                urlString: player.currentItem?.artworkId,
                symbol: player.currentItem?.kind == .radio
                    ? "dot.radiowaves.left.and.right"
                    : "music.note"
            )
            .opacity(showingLyrics ? 0 : 1)
            .allowsHitTesting(!showingLyrics)
            // Keep dismiss-swipe local to artwork so it cannot steal
            // button / sheet gestures — or fight lyrics scrolling.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        if value.translation.height > 80, abs(value.translation.width) < 80 {
                            dismiss()
                        }
                    }
            )

            // Only mounted while the user wants lyrics, so the playback clock isn't
            // redrawing an invisible lyric list four times a second.
            if settings.showLyricsInPlayer {
                SyncedLyricsView()
                    .opacity(showingLyrics ? 1 : 0)
                    .allowsHitTesting(showingLyrics)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: showingLyrics)
    }

    private var lyricsButtonTint: Color {
        // Accent while the preference is on — including tracks with no lyrics, so the
        // control still reads as active and can be used to turn lyrics off.
        // Same `themeManager.accentColor` as the active speed control (not `.accentColor`,
        // which can diverge from the themed tint in this presentation).
        if settings.showLyricsInPlayer { return themeManager.accentColor }
        return lyricsAvailable ? .primary : Color.secondary.opacity(0.4)
    }

    /// Can open lyrics when text exists, or close the preference even when it doesn't.
    private var lyricsToggleEnabled: Bool {
        lyricsAvailable || settings.showLyricsInPlayer
    }

    private func toggleLyrics() {
        withAnimation(.easeInOut(duration: 0.25)) {
            settings.showLyricsInPlayer.toggle()
        }
        settings.save()
        if settings.showLyricsInPlayer { player.requestLyrics() }
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
            downloadStatus: overflowDownloadStatus,
            showRatingStars: settings.showRatingStars,
            showSongInfo: settings.showSongInfo,
            showLyrics: settings.showLyricsInPlayer,
            hasLyrics: lyricsAvailable,
            playbackSpeed: player.playbackSpeed,
            speedMenuEnabled: player.currentItem?.isLiveStream != true,
            onDismiss: { dismiss() },
            onOpenAlbum: { selectedAlbumId = currentSong?.album?.compoundRemoteId },
            onShare: { presentShareSheet() },
            onAddToPlaylist: { bottomPanel = .addToPlaylist },
            onOpenQueue: { bottomPanel = .queue },
            onEqualizer: { bottomPanel = .equalizer },
            onSetPlaybackSpeed: { player.setPlaybackSpeed($0) },
            onToggleRatingStars: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings.showRatingStars.toggle()
                }
                settings.save()
            },
            onToggleSongInfo: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settings.showSongInfo.toggle()
                }
                settings.save()
            },
            onToggleLyrics: { toggleLyrics() }
        ))
    }

    /// Download state of the playing track, or `.none` when the queue item isn't a
    /// library song (radio, for instance).
    private var downloadStatus: DownloadStatus {
        guard let song = currentSong else { return .none }
        return downloadCenter.status(for: song.remoteId, isDownloaded: song.isDownloadedLocally)
    }

    /// The overflow menu only needs to know *that* a download is running, not how far
    /// along it is. Feeding it the live fraction would rebuild the `UIMenu` on every
    /// progress callback — the exact churn the UIKit menu exists to avoid.
    private var overflowDownloadStatus: DownloadStatus {
        if case .downloading = downloadStatus { return .downloading(0) }
        return downloadStatus
    }

    /// Compact file-type + bitrate label shown opposite the rating stars.
    private func songInfoText(for song: Song) -> String? {
        var parts: [String] = []
        if let format = fileTypeLabel(for: song.contentType) {
            parts.append(format)
        }
        if let bitrate = song.bitrate, bitrate > 0 {
            let kbps = bitrate >= 1000 ? bitrate / 1000 : bitrate
            parts.append("\(kbps) kbps")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func fileTypeLabel(for contentType: String?) -> String? {
        guard let raw = contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let token: String
        if let slash = raw.lastIndex(of: "/") {
            token = String(raw[raw.index(after: slash)...])
        } else {
            token = raw
        }
        switch token.lowercased() {
        case "mpeg", "mpga": return "MP3"
        case "mp4", "x-m4a", "m4a": return "M4A"
        case "x-flac", "flac": return "FLAC"
        case "ogg", "vorbis", "x-vorbis": return "OGG"
        case "opus", "x-opus": return "OPUS"
        case "wav", "x-wav": return "WAV"
        case "aiff", "x-aiff": return "AIFF"
        case "aac", "x-aac": return "AAC"
        default: return token.uppercased()
        }
    }

    // MARK: - Bottom action bar (AirPlay / Lyrics / Speed / Share / Queue)

    private var bottomActionBar: some View {
        HStack(spacing: 28) {
            AirPlayRoutePicker()
                .frame(width: 24, height: 24)

            Button {
                toggleLyrics()
            } label: {
                Image(systemName: "text.quote")
                    .font(.title3)
                    .foregroundStyle(lyricsButtonTint)
            }
            .disabled(!lyricsToggleEnabled)
            .accessibilityLabel(settings.showLyricsInPlayer ? "Show Artwork" : "Show Lyrics")

            PlaybackSpeedMenuButton(
                playbackSpeed: player.playbackSpeed,
                isEnabled: player.currentItem?.isLiveStream != true,
                accentColor: themeManager.accentColor,
                onSelect: { player.setPlaybackSpeed($0) }
            )
            .frame(width: 24, height: 24)
            .accessibilityLabel("Playback Speed")

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
                Task { await ActionToast.toggleFavorite(song: song) }
            } label: {
                Image(systemName: song.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 24))
                    .foregroundStyle(song.isFavorite ? themeManager.accentColor : Color.primary)
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
        HStack(spacing: 6) {
            // Decorative only — download / remove lives in the overflow menu.
            if currentSong != nil {
                DownloadStatusIcon(status: downloadStatus, size: 14, tint: themeManager.accentColor)
                    .accessibilityLabel(downloadAccessibilityLabel)
            }

            artistCreditsContent
        }
    }

    private var downloadAccessibilityLabel: String {
        switch downloadStatus {
        case .pending: return "Waiting to download"
        case .downloading: return "Downloading"
        case .partial: return "Partially downloaded"
        case .cached: return "Cached"
        case .downloaded: return "Downloaded"
        case .failed: return "Download failed"
        case .none: return ""
        }
    }

    @ViewBuilder
    private var artistCreditsContent: some View {
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
        presentSongShareSheet(
            title: player.currentItem?.title,
            artist: player.currentItem?.artist
        )
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
    let downloadStatus: DownloadStatus
    let showRatingStars: Bool
    let showSongInfo: Bool
    let showLyrics: Bool
    let hasLyrics: Bool
    let playbackSpeed: Float
    let speedMenuEnabled: Bool
    let onDismiss: () -> Void
    let onOpenAlbum: () -> Void
    let onShare: () -> Void
    let onAddToPlaylist: () -> Void
    let onOpenQueue: () -> Void
    let onEqualizer: () -> Void
    let onSetPlaybackSpeed: (Float) -> Void
    let onToggleRatingStars: () -> Void
    let onToggleSongInfo: () -> Void
    let onToggleLyrics: () -> Void

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
                        isFavorite: song?.isFavorite == true,
                        downloadStatus: downloadStatus,
                        showRatingStars: showRatingStars,
                        showSongInfo: showSongInfo,
                        showLyrics: showLyrics,
                        hasLyrics: hasLyrics,
                        playbackSpeed: playbackSpeed,
                        speedMenuEnabled: speedMenuEnabled
                    ),
                    onShare: onShare,
                    onToggleFavorite: {
                        guard let song else { return }
                        Task { await ActionToast.toggleFavorite(song: song) }
                    },
                    onDownload: {
                        guard let song else { return }
                        Task { await LibraryActions.shared.downloadOrCancel(song: song) }
                    },
                    onAddToPlaylist: onAddToPlaylist,
                    onOpenQueue: onOpenQueue,
                    onEqualizer: onEqualizer,
                    onSetPlaybackSpeed: onSetPlaybackSpeed,
                    onToggleRatingStars: onToggleRatingStars,
                    onToggleSongInfo: onToggleSongInfo,
                    onToggleLyrics: onToggleLyrics
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
            && lhs.downloadStatus == rhs.downloadStatus
            && lhs.showRatingStars == rhs.showRatingStars
            && lhs.showSongInfo == rhs.showSongInfo
            && lhs.showLyrics == rhs.showLyrics
            && lhs.hasLyrics == rhs.hasLyrics
            && PlaybackSpeed.isEqual(lhs.playbackSpeed, rhs.playbackSpeed)
            && lhs.speedMenuEnabled == rhs.speedMenuEnabled
    }
}

/// Overflow menu as a custom popover. System `UIMenu` clips near the top of the
/// player and forces a scrollbar; this sizes to its content so every row is visible.
/// Kept outside a SwiftUI `Menu` so continuous player re-renders cannot pulse rows.
private struct PlayerOverflowMenuButton: View {
    struct MenuState: Equatable {
        var hasSong: Bool
        var isFavorite: Bool
        var downloadStatus: DownloadStatus
        var showRatingStars: Bool
        var showSongInfo: Bool
        var showLyrics: Bool
        var hasLyrics: Bool
        var playbackSpeed: Float
        var speedMenuEnabled: Bool

        static func == (lhs: MenuState, rhs: MenuState) -> Bool {
            lhs.hasSong == rhs.hasSong
                && lhs.isFavorite == rhs.isFavorite
                && lhs.downloadStatus == rhs.downloadStatus
                && lhs.showRatingStars == rhs.showRatingStars
                && lhs.showSongInfo == rhs.showSongInfo
                && lhs.showLyrics == rhs.showLyrics
                && lhs.hasLyrics == rhs.hasLyrics
                && PlaybackSpeed.isEqual(lhs.playbackSpeed, rhs.playbackSpeed)
                && lhs.speedMenuEnabled == rhs.speedMenuEnabled
        }
    }

    var menuState: MenuState
    var onShare: () -> Void
    var onToggleFavorite: () -> Void
    var onDownload: () -> Void
    var onAddToPlaylist: () -> Void
    var onOpenQueue: () -> Void
    var onEqualizer: () -> Void
    var onSetPlaybackSpeed: (Float) -> Void
    var onToggleRatingStars: () -> Void
    var onToggleSongInfo: () -> Void
    var onToggleLyrics: () -> Void

    @State private var showMenu = false
    @State private var showingSpeedOptions = false

    var body: some View {
        Button {
            showingSpeedOptions = false
            showMenu = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            Group {
                if showingSpeedOptions {
                    speedOptionsContent
                } else {
                    mainMenuContent
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .fixedSize(horizontal: true, vertical: true)
            .presentationCompactAdaptation(.popover)
            .onDisappear { showingSpeedOptions = false }
        }
    }

    private var mainMenuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(title: "Share Song", systemImage: "square.and.arrow.up", action: onShare)

            Divider().padding(.vertical, 4)

            menuRow(
                title: menuState.isFavorite ? "Unlike Song" : "Like Song",
                systemImage: menuState.isFavorite ? "heart.slash" : "heart",
                disabled: !menuState.hasSong,
                action: onToggleFavorite
            )
            menuRow(
                title: Self.downloadTitle(for: menuState.downloadStatus),
                systemImage: Self.downloadSymbol(for: menuState.downloadStatus),
                disabled: !menuState.hasSong,
                action: onDownload
            )
            menuRow(
                title: "Add to Playlist",
                systemImage: "text.badge.plus",
                disabled: !menuState.hasSong,
                action: onAddToPlaylist
            )
            menuRow(title: "Add to Queue", systemImage: "text.append", disabled: true) {}
            menuRow(title: "Open Queue", systemImage: "list.bullet", action: onOpenQueue)

            Divider().padding(.vertical, 4)

            menuRow(
                title: menuState.showLyrics ? "Show Artwork" : "Show Lyrics",
                systemImage: menuState.showLyrics ? "photo" : "text.quote",
                disabled: !(menuState.hasLyrics || menuState.showLyrics),
                action: onToggleLyrics
            )
            menuRow(
                title: menuState.showRatingStars ? "Hide Rating Stars" : "Show Rating Stars",
                systemImage: menuState.showRatingStars ? "star.slash" : "star",
                action: onToggleRatingStars
            )
            menuRow(
                title: menuState.showSongInfo ? "Hide Song Info" : "Show Song Info",
                systemImage: menuState.showSongInfo ? "info.circle.fill" : "info.circle",
                action: onToggleSongInfo
            )
            menuRow(title: "Equalizer", systemImage: "slider.vertical.3", action: onEqualizer)
            menuRow(title: "Sleep Timer", systemImage: "moon.zzz", disabled: true) {}
            Button {
                showingSpeedOptions = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.body)
                        .frame(width: 20, alignment: .center)
                    Text("Playback Speed")
                        .font(.body)
                    Spacer(minLength: 12)
                    Text(PlaybackSpeed.label(for: menuState.playbackSpeed))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(menuState.speedMenuEnabled ? .primary : .tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!menuState.speedMenuEnabled)
        }
    }

    private var speedOptionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showingSpeedOptions = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 20, alignment: .center)
                    Text("Playback Speed")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            ForEach(Array(PlaybackSpeed.options.enumerated()), id: \.offset) { _, rate in
                Button {
                    showMenu = false
                    onSetPlaybackSpeed(rate)
                } label: {
                    HStack(spacing: 12) {
                        Text(PlaybackSpeed.label(for: rate))
                            .font(.body)
                            .frame(minWidth: 48, alignment: .leading)
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .opacity(PlaybackSpeed.isEqual(rate, menuState.playbackSpeed) ? 1 : 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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

    private static func downloadTitle(for status: DownloadStatus) -> String {
        switch status {
        case .pending, .downloading: return "Cancel Download"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        case .none, .partial, .cached: return "Download Song"
        }
    }

    private static func downloadSymbol(for status: DownloadStatus) -> String {
        switch status {
        case .pending, .downloading: return "stop.circle"
        case .downloaded: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .none, .partial, .cached: return "arrow.down.circle"
        }
    }
}

/// Bottom-bar speed control. Custom popover (not `UIMenu`) so all rates fit without
/// scrolling when the control sits near the bottom edge of the screen.
private struct PlaybackSpeedMenuButton: View {
    var playbackSpeed: Float
    var isEnabled: Bool
    /// Same accent the lyrics button uses when active.
    var accentColor: Color
    var onSelect: (Float) -> Void

    @State private var showMenu = false

    private var iconColor: Color {
        guard isEnabled else { return Color.secondary.opacity(0.4) }
        return PlaybackSpeed.isEqual(playbackSpeed, 1) ? .primary : accentColor
    }

    var body: some View {
        Button {
            showMenu = true
        } label: {
            // `timer` renders taller than neighbors at `.title3`.
            Image(systemName: "timer")
                .font(.system(size: 17))
                .foregroundStyle(iconColor)
        }
        .disabled(!isEnabled)
        // Grow upward from the bottom bar so the full list is on-screen.
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(PlaybackSpeed.options.enumerated()), id: \.offset) { _, rate in
                    Button {
                        showMenu = false
                        onSelect(rate)
                    } label: {
                        HStack(spacing: 12) {
                            Text(PlaybackSpeed.label(for: rate))
                                .font(.body)
                                .frame(minWidth: 48, alignment: .leading)
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .opacity(PlaybackSpeed.isEqual(rate, playbackSpeed) ? 1 : 0)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            // Hug content so all seven rates show without a scroll view.
            .fixedSize(horizontal: true, vertical: true)
            .presentationCompactAdaptation(.popover)
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
