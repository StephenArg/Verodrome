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

    /// Matches the timer icon: accent when Random or non-1×, otherwise primary.
    private var playbackSpeedLabelColor: Color {
        if player.currentItem?.isLiveStream == true {
            return Color.secondary.opacity(0.4)
        }
        if player.isRandomPlaybackSpeed { return themeManager.accentColor }
        return PlaybackSpeed.isEqual(player.playbackSpeed, 1)
            ? .primary
            : themeManager.accentColor
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
            isRandomPlaybackSpeed: player.isRandomPlaybackSpeed,
            speedMenuEnabled: player.currentItem?.isLiveStream != true,
            sleepTimerDeadline: player.sleepTimerDeadline,
            onDismiss: { dismiss() },
            onOpenAlbum: { selectedAlbumId = currentSong?.album?.compoundRemoteId },
            onShare: { presentShareSheet() },
            onAddToPlaylist: { bottomPanel = .addToPlaylist },
            onOpenQueue: { bottomPanel = .queue },
            onEqualizer: { bottomPanel = .equalizer },
            onSetPlaybackSpeed: { player.setPlaybackSpeed($0) },
            onSetPlaybackSpeedRandom: { player.setPlaybackSpeedRandom() },
            onStartSleepTimer: { player.startSleepTimer(hours: $0, minutes: $1) },
            onCancelSleepTimer: { player.cancelSleepTimer() },
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

    // MARK: - Bottom action bar (AirPlay / Lyrics / Speed / Sleep / Share / Queue)

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

            HStack(spacing: 6) {
                PlaybackSpeedMenuButton(
                    playbackSpeed: player.playbackSpeed,
                    isRandomPlaybackSpeed: player.isRandomPlaybackSpeed,
                    isEnabled: player.currentItem?.isLiveStream != true,
                    accentColor: themeManager.accentColor,
                    onSelect: { player.setPlaybackSpeed($0) },
                    onSelectRandom: { player.setPlaybackSpeedRandom() }
                )
                .frame(width: 24, height: 24)
                .accessibilityLabel("Playback Speed")

                if player.isRandomPlaybackSpeed
                    || !PlaybackSpeed.isEqual(player.playbackSpeed, 1)
                {
                    Text(PlaybackSpeed.label(for: player.playbackSpeed))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(playbackSpeedLabelColor)
                        .accessibilityLabel("Current speed \(PlaybackSpeed.label(for: player.playbackSpeed))")
                }
            }

            Spacer()

            if let deadline = player.sleepTimerDeadline {
                SleepTimerChip(
                    deadline: deadline,
                    accentColor: themeManager.accentColor,
                    onStart: { player.startSleepTimer(hours: $0, minutes: $1) },
                    onCancel: { player.cancelSleepTimer() }
                )
            }

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
    let isRandomPlaybackSpeed: Bool
    let speedMenuEnabled: Bool
    let sleepTimerDeadline: Date?
    let onDismiss: () -> Void
    let onOpenAlbum: () -> Void
    let onShare: () -> Void
    let onAddToPlaylist: () -> Void
    let onOpenQueue: () -> Void
    let onEqualizer: () -> Void
    let onSetPlaybackSpeed: (Float) -> Void
    let onSetPlaybackSpeedRandom: () -> Void
    let onStartSleepTimer: (Int, Int) -> Void
    let onCancelSleepTimer: () -> Void
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
                        isRandomPlaybackSpeed: isRandomPlaybackSpeed,
                        speedMenuEnabled: speedMenuEnabled,
                        sleepTimerDeadline: sleepTimerDeadline
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
                    onSetPlaybackSpeedRandom: onSetPlaybackSpeedRandom,
                    onStartSleepTimer: onStartSleepTimer,
                    onCancelSleepTimer: onCancelSleepTimer,
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
            && lhs.isRandomPlaybackSpeed == rhs.isRandomPlaybackSpeed
            && lhs.speedMenuEnabled == rhs.speedMenuEnabled
            && lhs.sleepTimerDeadline == rhs.sleepTimerDeadline
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
        var isRandomPlaybackSpeed: Bool
        var speedMenuEnabled: Bool
        var sleepTimerDeadline: Date?

        static func == (lhs: MenuState, rhs: MenuState) -> Bool {
            lhs.hasSong == rhs.hasSong
                && lhs.isFavorite == rhs.isFavorite
                && lhs.downloadStatus == rhs.downloadStatus
                && lhs.showRatingStars == rhs.showRatingStars
                && lhs.showSongInfo == rhs.showSongInfo
                && lhs.showLyrics == rhs.showLyrics
                && lhs.hasLyrics == rhs.hasLyrics
                && PlaybackSpeed.isEqual(lhs.playbackSpeed, rhs.playbackSpeed)
                && lhs.isRandomPlaybackSpeed == rhs.isRandomPlaybackSpeed
                && lhs.speedMenuEnabled == rhs.speedMenuEnabled
                && lhs.sleepTimerDeadline == rhs.sleepTimerDeadline
        }
    }

    private enum Submenu {
        case none
        case speed
        case sleepTimer
    }

    var menuState: MenuState
    var onShare: () -> Void
    var onToggleFavorite: () -> Void
    var onDownload: () -> Void
    var onAddToPlaylist: () -> Void
    var onOpenQueue: () -> Void
    var onEqualizer: () -> Void
    var onSetPlaybackSpeed: (Float) -> Void
    var onSetPlaybackSpeedRandom: () -> Void
    var onStartSleepTimer: (Int, Int) -> Void
    var onCancelSleepTimer: () -> Void
    var onToggleRatingStars: () -> Void
    var onToggleSongInfo: () -> Void
    var onToggleLyrics: () -> Void

    @State private var showMenu = false
    @State private var submenu: Submenu = .none

    private var sleepTimerTrailingLabel: String {
        guard let deadline = menuState.sleepTimerDeadline else { return "Off" }
        return SleepTimer.label(remaining: deadline.timeIntervalSinceNow)
    }

    var body: some View {
        Button {
            submenu = .none
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
                switch submenu {
                case .speed:
                    speedOptionsContent
                case .sleepTimer:
                    SleepTimerPanel(
                        deadline: menuState.sleepTimerDeadline,
                        onStart: { hours, minutes in
                            showMenu = false
                            onStartSleepTimer(hours, minutes)
                        },
                        onCancel: {
                            showMenu = false
                            onCancelSleepTimer()
                        },
                        onBack: { submenu = .none }
                    )
                case .none:
                    mainMenuContent
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .fixedSize(horizontal: true, vertical: true)
            .presentationCompactAdaptation(.popover)
            .onDisappear { submenu = .none }
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
            Button {
                submenu = .sleepTimer
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.body)
                        .frame(width: 20, alignment: .center)
                    Text("Sleep Timer")
                        .font(.body)
                    Spacer(minLength: 12)
                    Text(sleepTimerTrailingLabel)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                submenu = .speed
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.body)
                        .frame(width: 20, alignment: .center)
                    Text("Playback Speed")
                        .font(.body)
                    Spacer(minLength: 12)
                    Text(
                        menuState.isRandomPlaybackSpeed
                            ? PlaybackSpeed.randomMenuLabel
                            : PlaybackSpeed.label(for: menuState.playbackSpeed)
                    )
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
                submenu = .none
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            Button {
                showMenu = false
                onSetPlaybackSpeedRandom()
            } label: {
                HStack(spacing: 12) {
                    Text(PlaybackSpeed.randomMenuLabel)
                        .font(.body)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: 16)
                    if menuState.isRandomPlaybackSpeed {
                        Text(PlaybackSpeed.label(for: menuState.playbackSpeed))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 16)
                        .opacity(menuState.isRandomPlaybackSpeed ? 1 : 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(Array(PlaybackSpeed.options.enumerated()), id: \.offset) { _, rate in
                let selected = !menuState.isRandomPlaybackSpeed
                    && PlaybackSpeed.isEqual(rate, menuState.playbackSpeed)
                Button {
                    showMenu = false
                    onSetPlaybackSpeed(rate)
                } label: {
                    HStack(spacing: 12) {
                        Text(PlaybackSpeed.label(for: rate))
                            .font(.body)
                            .lineLimit(1)
                            .frame(minWidth: 56, alignment: .leading)
                        Spacer(minLength: 16)
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 16)
                            .opacity(selected ? 1 : 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // Wide enough for "Random" + rolled rate + checkmark on one line.
        .frame(minWidth: 220)
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

/// Bottom-bar speed control. Popover hosts a discrete custom slider:
/// `Random — 0.8x — · — 1x — · — 1.5x — · — 2x`
private struct PlaybackSpeedMenuButton: View {
    var playbackSpeed: Float
    var isRandomPlaybackSpeed: Bool
    var isEnabled: Bool
    /// Same accent the lyrics button uses when active.
    var accentColor: Color
    var onSelect: (Float) -> Void
    var onSelectRandom: () -> Void

    @State private var showMenu = false
    /// 0 = Random; 1...n = `sliderRates`.
    @State private var selectedIndex = 0
    @State private var isDragging = false

    /// Fixed stops on the slider (ascending), after Random.
    private static let sliderRates: [Float] = [0.8, 0.9, 1, 1.25, 1.5, 1.75, 2]
    private var stepCount: Int { Self.sliderRates.count + 1 }

    private static let restingThumbSize: CGFloat = 9
    private static let draggingThumbSize: CGFloat = 15
    private static let trackHeight: CGFloat = 3

    private var iconColor: Color {
        guard isEnabled else { return Color.secondary.opacity(0.4) }
        if isRandomPlaybackSpeed { return accentColor }
        return PlaybackSpeed.isEqual(playbackSpeed, 1) ? .primary : accentColor
    }

    private var resolvedIndex: Int {
        if isRandomPlaybackSpeed { return 0 }
        if let match = Self.sliderRates.firstIndex(where: { PlaybackSpeed.isEqual($0, playbackSpeed) }) {
            return match + 1
        }
        // Nearest stop when the rate came from the overflow menu (e.g. 0.5×).
        var best = 0
        var bestDelta = Float.greatestFiniteMagnitude
        for (i, rate) in Self.sliderRates.enumerated() {
            let delta = abs(rate - playbackSpeed)
            if delta < bestDelta {
                bestDelta = delta
                best = i
            }
        }
        return best + 1
    }

    var body: some View {
        Button {
            selectedIndex = resolvedIndex
            showMenu = true
        } label: {
            // `timer` renders taller than neighbors at `.title3`.
            Image(systemName: "timer")
                .font(.system(size: 17))
                .foregroundStyle(iconColor)
        }
        .disabled(!isEnabled)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                discreteSliderTrack

                HStack(spacing: 0) {
                    ForEach(0..<stepCount, id: \.self) { index in
                        let selected = selectedIndex == index
                        Button {
                            moveSelection(to: index)
                        } label: {
                            Text(Self.tickLabel(at: index))
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? accentColor : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(width: 360)
            .presentationCompactAdaptation(.popover)
            .onAppear { selectedIndex = resolvedIndex }
        }
    }

    private var discreteSliderTrack: some View {
        GeometryReader { geo in
            let count = CGFloat(stepCount)
            let cellWidth = geo.size.width / count
            let thumbSize = isDragging ? Self.draggingThumbSize : Self.restingThumbSize
            let thumbX = cellWidth * (CGFloat(selectedIndex) + 0.5)
            let midY = geo.size.height / 2

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: Self.trackHeight)

                // Quiet ticks at each stop center so the jump targets are visible.
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3, height: 3)
                        .position(x: cellWidth * (CGFloat(index) + 0.5), y: midY)
                }

                Circle()
                    .fill(accentColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: accentColor.opacity(isDragging ? 0.35 : 0), radius: isDragging ? 4 : 0)
                    .position(x: thumbX, y: midY)
                    .animation(.spring(response: 0.22, dampingFraction: 0.78), value: selectedIndex)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        let raw = Int(value.location.x / cellWidth)
                        let index = min(max(raw, 0), stepCount - 1)
                        if index != selectedIndex {
                            moveSelection(to: index)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 28)
    }

    private func moveSelection(to index: Int) {
        guard index != selectedIndex else {
            // Re-apply when tapping the already-selected label (no-op for rate).
            applySliderIndex(index)
            return
        }
        selectedIndex = index
        UISelectionFeedbackGenerator().selectionChanged()
        applySliderIndex(index)
    }

    private func applySliderIndex(_ index: Int) {
        if index <= 0 {
            guard !isRandomPlaybackSpeed else { return }
            onSelectRandom()
            return
        }
        let rateIndex = min(max(index - 1, 0), Self.sliderRates.count - 1)
        let rate = Self.sliderRates[rateIndex]
        if !isRandomPlaybackSpeed, PlaybackSpeed.isEqual(rate, playbackSpeed) { return }
        onSelect(rate)
    }

    /// Random, then labeled majors with dots for the implied in-between stops.
    private static func tickLabel(at index: Int) -> String {
        if index == 0 { return PlaybackSpeed.randomMenuLabel }
        switch index - 1 {
        case 0: return "0.8x"
        case 1: return "·"
        case 2: return "1x"
        case 3: return "·"
        case 4: return "1.5x"
        case 5: return "·"
        case 6: return "2x"
        default: return "·"
        }
    }
}

/// Hours + minutes pickers for the sleep timer. Used from the overflow submenu
/// and from the bottom-bar countdown chip popover.
private struct SleepTimerPanel: View {
    var deadline: Date?
    var onStart: (Int, Int) -> Void
    var onCancel: () -> Void
    /// When non-nil, shows a back chevron that returns to the overflow menu.
    var onBack: (() -> Void)? = nil

    @State private var hours: Double = 0
    @State private var minutes: Double = 15

    private var isActive: Bool { deadline != nil }
    private var canStart: Bool { hours > 0 || minutes > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 20, alignment: .center)
                        Text("Sleep Timer")
                            .font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.vertical, 4)
            } else {
                Text("Sleep Timer")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            Text(SleepTimer.label(hours: Int(hours), minutes: Int(minutes)))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hours")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(hours))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $hours, in: 0...Double(SleepTimer.maxHours), step: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minutes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(minutes))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $minutes, in: 0...59, step: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Button {
                onStart(Int(hours), Int(minutes))
            } label: {
                Text(isActive ? "Update" : "Start")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .padding(.horizontal, 14)

            if isActive {
                Button(role: .destructive, action: onCancel) {
                    Text("Turn Off")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
        .frame(width: 280)
        .onAppear { seedFromDeadline() }
    }

    private func seedFromDeadline() {
        guard let deadline else { return }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let totalMinutes = Int((remaining / 60).rounded(.up))
        hours = Double(min(totalMinutes / 60, SleepTimer.maxHours))
        minutes = Double(totalMinutes % 60)
    }
}

/// Live countdown chip shown left of Share while a sleep timer is active.
/// Owns its own `Text(timerInterval:)` so only this view ticks each second.
private struct SleepTimerChip: View {
    let deadline: Date
    var accentColor: Color
    var onStart: (Int, Int) -> Void
    var onCancel: () -> Void

    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(
                    timerInterval: Date()...deadline,
                    pauseTime: nil,
                    countsDown: true,
                    showsHours: true
                )
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            }
            .foregroundStyle(accentColor)
            .accessibilityLabel("Sleep timer")
        }
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            SleepTimerPanel(
                deadline: deadline,
                onStart: { hours, minutes in
                    showPanel = false
                    onStart(hours, minutes)
                },
                onCancel: {
                    showPanel = false
                    onCancel()
                }
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
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
