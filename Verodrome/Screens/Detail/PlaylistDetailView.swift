import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistDetailView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var songs: [Song] = []
    @State private var showPlaylistSelector = false
    @State private var artworkTint: ArtworkTint?

    init(playlistID: String) {
        self.playlistID = playlistID
        _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
    }

    /// Same fill as the Play button — colors the back chevron the way the album screen does.
    private var navigationTint: Color {
        (artworkTint ?? ArtworkTint(hue: 0, saturation: 0)).primaryButtonFill(for: colorScheme)
    }

    var body: some View {
        List {
            if let playlist = playlists.first {
                Section {
                    DetailHeader(
                        title: playlist.name,
                        subtitle: "\(playlist.songCount) songs",
                        artworkURL: playlist.artworkToken,
                        tintToken: backgroundArtworkToken,
                        symbol: "music.note.house.fill",
                        onPlay: { play(shuffle: false) },
                        onShuffle: { play(shuffle: true) },
                        accessory: { playlistStatusBar }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Songs") {
                    if songs.isEmpty {
                        Text("Loading songs…")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(songs, id: \.compoundRemoteId) { song in
                            Button { playSong(song) } label: {
                                EntityRow(
                                    title: song.title,
                                    subtitle: song.displayArtist,
                                    artworkURL: song.artworkToken,
                                    isPlaying: nowPlaying.currentItem?.playableId == song.remoteId,
                                    downloadStatus: downloadCenter.status(
                                        for: song.remoteId,
                                        isDownloaded: song.isDownloadedLocally
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .songActions(song)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .artworkTintedBackground(token: backgroundArtworkToken)
        .navigationBarTitleDisplayMode(.inline)
        .tint(navigationTint)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist = playlists.first {
                    playlistOptionsMenu(for: playlist)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistAddSongsView(playlistID: playlistID) } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Add Songs")
            }
        }
        .sheet(isPresented: $showPlaylistSelector) {
            PlaylistSelectorView { destination in
                let tracks = songs
                Task {
                    try? await LibraryActions.shared.addSongs(tracks, to: destination)
                    ActionToast.addedToPlaylist(destination.name)
                }
            }
        }
        .task(id: backgroundArtworkToken) {
            artworkTint = await ArtworkTintResolver.shared.tint(for: backgroundArtworkToken)
        }
        .task(id: playlists.first?.remoteId) {
            guard let playlist = playlists.first else { return }
            loadSongs(for: playlist)
            guard let remoteId = playlists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(playlistId: remoteId)
            if let playlist = playlists.first {
                loadSongs(for: playlist)
            }
        }
    }

    // MARK: - Status bar

    private var downloadSummary: SongsDownloadSummary {
        SongsDownloadSummary(songs: songs, center: downloadCenter)
    }

    /// Playlists have no favorite/rating in the library model yet, so this bar is the
    /// download control alone — same slot as the album's right-hand cluster.
    private var playlistStatusBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Button {
                togglePlaylistDownload()
            } label: {
                DownloadStatusIcon(status: downloadSummary.status, size: 22, showsIdleAffordance: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(songs.isEmpty)
            .accessibilityLabel(downloadActionTitle)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Options menu

    private func playlistOptionsMenu(for playlist: Playlist) -> some View {
        Menu {
            Button {
                togglePlaylistDownload()
            } label: {
                Label(downloadActionTitle, systemImage: downloadActionSymbol)
            }
            .disabled(songs.isEmpty)

            if downloadSummary.isPartiallyDownloaded && !downloadSummary.isWorking {
                Button(role: .destructive) {
                    let tracks = songs
                    Task { await LibraryActions.shared.removeDownloads(songs: tracks) }
                } label: {
                    Label("Remove Downloads", systemImage: "trash")
                }
            }

            Divider()

            Button {
                player.addToQueueTemporarily(songs.map(QueueItem.from))
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            .disabled(songs.isEmpty)

            Button {
                showPlaylistSelector = true
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(songs.isEmpty)

            ShareLink(item: playlist.name) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            // Match the album options control: centered ellipsis that inherits the
            // artwork navigation tint with the back chevron.
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
    }

    private var downloadActionTitle: String {
        let summary = downloadSummary
        if summary.isWorking { return "Cancel Downloads" }
        if summary.isFullyDownloaded { return "Remove Downloads" }
        if summary.isPartiallyDownloaded { return "Download Remaining (\(summary.remaining))" }
        return "Download All"
    }

    private var downloadActionSymbol: String {
        let summary = downloadSummary
        if summary.isWorking { return "stop.circle" }
        if summary.isFullyDownloaded { return "trash" }
        return "arrow.down.circle"
    }

    private func togglePlaylistDownload() {
        let tracks = songs
        let summary = downloadSummary
        Task {
            if summary.isWorking {
                await LibraryActions.shared.cancelDownloads(songs: tracks)
            } else if summary.isFullyDownloaded {
                await LibraryActions.shared.removeDownloads(songs: tracks)
            } else {
                await LibraryActions.shared.downloadRemaining(songs: tracks)
            }
        }
    }

    // MARK: - Playback

    /// Prefer the playlist's own cover; fall back to the first song so the
    /// screen still gets an artwork-derived tint when the playlist has no art.
    private var backgroundArtworkToken: String? {
        if let token = playlists.first?.artworkToken, !token.isEmpty { return token }
        return songs.first?.artworkToken
    }

    private func loadSongs(for playlist: Playlist) {
        songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
    }

    private func play(shuffle: Bool) {
        player.play(items: songs.map(QueueItem.from), shuffle: shuffle)
    }

    private func playSong(_ song: Song) {
        let items = songs.map(QueueItem.from)
        let index = songs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        player.play(items: items, startAt: index)
    }
}
