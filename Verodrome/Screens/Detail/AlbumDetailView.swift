import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumDetailView: View {
    let albumID: String
    @Query private var albums: [Album]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var tracks: [Song] = []
    @State private var showPlaylistSelector = false
    @State private var artworkTint: ArtworkTint?

    init(albumID: String) {
        self.albumID = albumID
        _albums = Query(filter: #Predicate<Album> { $0.compoundRemoteId == albumID })
    }

    /// Same fill as the Play button — used for the back chevron and options glyph so
    /// the top bar belongs to the artwork the way the action buttons do.
    private var navigationTint: Color {
        (artworkTint ?? ArtworkTint(hue: 0, saturation: 0)).primaryButtonFill(for: colorScheme)
    }

    var body: some View {
        List {
            if let album = albums.first {
                Section {
                    DetailHeader(
                        title: album.title,
                        subtitle: "\(album.displayArtist) · \(album.year ?? 0)",
                        artworkURL: album.artworkToken,
                        onPlay: { play(shuffle: false) },
                        onShuffle: { play(shuffle: true) },
                        accessory: { albumStatusBar(for: album) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Tracks") {
                    ForEach(Array(tracks.enumerated()), id: \.element.compoundRemoteId) { index, song in
                        Button { playSong(song, tracks: tracks) } label: {
                            EntityRow(
                                title: song.title,
                                subtitle: song.displayArtist,
                                isPlaying: nowPlaying.currentItem?.playableId == song.remoteId,
                                trailing: formatDuration(song.displayDuration),
                                trackNumber: song.track ?? (index + 1),
                                // Live from DownloadCenter — pending/active tracks spin,
                                // then flip to the downloaded glyph as each file lands.
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
        .artworkTintedBackground(token: albums.first?.artworkToken)
        .navigationBarTitleDisplayMode(.inline)
        .tint(navigationTint)
        .toolbar {
            if let album = albums.first {
                ToolbarItem(placement: .topBarTrailing) {
                    albumOptionsMenu(for: album)
                }
            }
        }
        .sheet(isPresented: $showPlaylistSelector) {
            PlaylistSelectorView { playlist in
                let songs = tracks
                Task { try? await LibraryActions.shared.addSongs(songs, to: playlist) }
            }
        }
        .task(id: albums.first?.artworkToken) {
            artworkTint = await ArtworkTintResolver.shared.tint(for: albums.first?.artworkToken)
        }
        .task(id: albums.first?.remoteId) {
            guard let album = albums.first else { return }
            loadTracks(for: album)
            guard let remoteId = albums.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: remoteId)
            if let album = albums.first {
                loadTracks(for: album)
            }
        }
    }

    // MARK: - Status bar

    private var downloadSummary: SongsDownloadSummary {
        SongsDownloadSummary(songs: tracks, center: downloadCenter)
    }

    /// Rating on the left, download state and favorite on the right — album-level
    /// counterparts of the controls the player shows for a single track.
    private func albumStatusBar(for album: Album) -> some View {
        HStack(spacing: 12) {
            RatingStarsView(rating: album.rating, starSize: 17, spacing: 6) { newRating in
                Task { try? await LibraryActions.shared.setRating(album: album, rating: newRating) }
            }

            Spacer(minLength: 0)

            Button {
                toggleAlbumDownload()
            } label: {
                DownloadStatusIcon(status: downloadSummary.status, size: 22, showsIdleAffordance: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel(downloadActionTitle)

            Button {
                Task { try? await LibraryActions.shared.toggleFavorite(album: album) }
            } label: {
                Image(systemName: album.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(album.isFavorite ? themeManager.accentColor : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(album.isFavorite ? "Remove Album from Favorites" : "Add Album to Favorites")
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Options menu

    private func albumOptionsMenu(for album: Album) -> some View {
        Menu {
            Button {
                toggleAlbumDownload()
            } label: {
                Label(downloadActionTitle, systemImage: downloadActionSymbol)
            }
            .disabled(tracks.isEmpty)

            // Offered alongside "Download Remaining" so a half-downloaded album can be
            // cleared without first finishing it.
            if downloadSummary.isPartiallyDownloaded && !downloadSummary.isWorking {
                Button(role: .destructive) {
                    let songs = tracks
                    Task { await LibraryActions.shared.removeDownloads(songs: songs) }
                } label: {
                    Label("Remove Downloads", systemImage: "trash")
                }
            }

            Divider()

            Button {
                player.addToQueueTemporarily(tracks.map(QueueItem.from))
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            .disabled(tracks.isEmpty)

            Button {
                showPlaylistSelector = true
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(tracks.isEmpty)

            // Text for now — swap the item for a share URL once albums have one.
            ShareLink(item: "\(album.title) — \(album.displayArtist)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            // Plain ellipsis (same glyph as the player). Centered in the toolbar hit
            // target so it doesn't sit off to one side of the circular chrome, and
            // left untinted here so it inherits `navigationTint` with the back chevron.
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

    private func toggleAlbumDownload() {
        let songs = tracks
        let summary = downloadSummary
        Task {
            if summary.isWorking {
                await LibraryActions.shared.cancelDownloads(songs: songs)
            } else if summary.isFullyDownloaded {
                await LibraryActions.shared.removeDownloads(songs: songs)
            } else {
                await LibraryActions.shared.downloadRemaining(songs: songs)
            }
        }
    }

    // MARK: - Playback

    private func loadTracks(for album: Album) {
        tracks = album.songs.sorted {
            ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func play(shuffle: Bool) {
        guard let album = albums.first else { return }
        var items = tracks.map(QueueItem.from)

        if items.isEmpty {
            Task {
                try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: album.remoteId)
                if let album = albums.first {
                    loadTracks(for: album)
                }
                items = tracks.map(QueueItem.from)
                guard !items.isEmpty else {
                    PlayTrace.error("no tracks after sync")
                    return
                }
                player.play(items: items, shuffle: shuffle)
            }
            return
        }

        player.play(items: items, shuffle: shuffle)
    }

    private func playSong(_ song: Song, tracks: [Song]) {
        let items = tracks.map(QueueItem.from)
        let index = tracks.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}