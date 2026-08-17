import SwiftUI
import SwiftData
import VerodromeKit

struct ArtistDetailView: View {
    let artistID: String
    @Query private var artists: [Artist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @State private var artistAlbums: [Album] = []
    @State private var artistSongs: [Song] = []
    @State private var selectedAlbum: AlbumNavigationID?
    /// Soft track fill for the Songs section / Play — cancelled when opening an album
    /// so SwiftData merges don't fight the navigation transition.
    @State private var trackFillTask: Task<Void, Never>?

    init(artistID: String) {
        self.artistID = artistID
        let id = artistID
        _artists = Query(filter: #Predicate<Artist> { $0.compoundRemoteId == id })
    }

    var body: some View {
        List {
            if let artist = artists.first {
                Section {
                    DetailHeader(
                        title: artist.name,
                        subtitle: headerSubtitle(for: artist),
                        artworkURL: artist.artworkToken,
                        tintToken: backgroundArtworkToken,
                        tintKey: tintKey,
                        symbol: "person.fill",
                        onPlay: { play(shuffle: false, artist: artist) },
                        onShuffle: { play(shuffle: true, artist: artist) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Albums") {
                    ForEach(artistAlbums, id: \.compoundRemoteId) { album in
                        Button {
                            openAlbum(album)
                        } label: {
                            EntityRow(
                                title: album.title,
                                subtitle: album.year.map(String.init) ?? "",
                                artworkURL: album.artworkToken,
                                // Avoid `SongsDownloadSummary(album:)` — it faults every
                                // track relationship on each body pass while sync merges.
                                downloadStatus: downloadStatus(for: album)
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                if !artistSongs.isEmpty {
                    Section("Songs") {
                        ForEach(artistSongs, id: \.compoundRemoteId) { song in
                            Button { playSong(song) } label: {
                                EntityRow(
                                    title: song.title,
                                    subtitle: song.displayAlbum,
                                    artworkURL: song.displayArtworkToken,
                                    isPlaying: nowPlaying.currentItem?.playableId == song.remoteId,
                                    trailing: formatDuration(song.displayDuration),
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
        .artworkTintedBackground(key: tintKey, token: backgroundArtworkToken)
        .detailCollapsingNavTitle(artists.first?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(albumID: album.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                artistOptionsMenu
            }
        }
        .task(id: artists.first?.compoundRemoteId) {
            reloadArtistContent()
            guard let remoteId = artists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(artistId: remoteId)
            reloadArtistContent()
            startTrackFillIfNeeded()
        }
        .onChange(of: selectedAlbum) { _, album in
            if album == nil {
                startTrackFillIfNeeded()
            } else {
                trackFillTask?.cancel()
                trackFillTask = nil
            }
        }
        .onDisappear {
            trackFillTask?.cancel()
            trackFillTask = nil
        }
    }

    /// Servers frequently ship no artist image, so fall back to the newest album's
    /// cover rather than leaving the screen on a flat untinted background.
    private var backgroundArtworkToken: String? {
        if let token = artists.first?.artworkToken, !token.isEmpty { return token }
        return artistAlbums.first?.artworkToken
    }

    /// Keyed by the artist, not the cover, so the fallback album's art can change
    /// without the screen picking up a different color.
    private var tintKey: ArtworkTintKey { .artist(artistID) }

    private var artistOptionsMenu: some View {
        Menu {
            if let artist = artists.first {
                ShareMenuButton(
                    subject: ShareSubject(
                        resourceType: .artist,
                        resourceIds: [artist.remoteId],
                        title: artist.name,
                        subtitle: headerSubtitle(for: artist),
                        artwork: backgroundArtworkToken.map { ArtworkRef(id: $0, kind: .artist) }
                    )
                )
                Divider()
            }

            Button {
                let token = backgroundArtworkToken
                Task { await ArtworkTintResolver.shared.refresh(key: tintKey, token: token) }
            } label: {
                Label("Refresh Background Color", systemImage: "eyedropper")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
    }

    /// Prefer stored counts when album tracks haven't been backfilled yet.
    private func headerSubtitle(for artist: Artist) -> String {
        let albums = max(artist.albumCount, artistAlbums.count)
        let fromAlbumTracks = artistAlbums.reduce(0) { partial, album in
            // Prefer denormalized `trackCount` — never walk `album.songs` here.
            partial + max(album.trackCount, 0)
        }
        let songs = max(artist.songCount, artistSongs.count, fromAlbumTracks)
        return "\(albums) albums · \(songs) songs"
    }

    private func reloadArtistContent() {
        guard let artist = artists.first else {
            artistAlbums = []
            artistSongs = []
            return
        }

        artistAlbums = artist.albums.sorted {
            ($0.year ?? 0, $0.sortTitle) > ($1.year ?? 0, $1.sortTitle)
        }

        // Only the artist relationship — merging every album's songs faults the whole
        // discography on each reload while a background fill is running.
        artistSongs = artist.songs.sorted {
            ($0.albumTitle ?? "", $0.disc ?? 0, $0.track ?? 0)
                < ($1.albumTitle ?? "", $1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func openAlbum(_ album: Album) {
        trackFillTask?.cancel()
        trackFillTask = nil
        if router.showFullPlayer {
            router.pushPlayer(.album(album.compoundRemoteId))
            return
        }
        selectedAlbum = AlbumNavigationID(id: album.compoundRemoteId)
    }

    /// Fills tracks one album at a time so Play / Songs can populate without blocking
    /// the first paint. Cancelled as soon as the user opens an album.
    private func startTrackFillIfNeeded() {
        trackFillTask?.cancel()
        let albumIds = artistAlbums.map(\.remoteId)
        guard !albumIds.isEmpty else { return }
        trackFillTask = Task {
            guard let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() else { return }
            for albumId in albumIds {
                guard !Task.isCancelled else { return }
                try? await syncer.sync(albumId: albumId)
                await Task.yield()
                guard !Task.isCancelled else { return }
                reloadArtistContent()
            }
        }
    }

    /// Download glyph from songs already loaded onto the artist — never from `album.songs`.
    private func downloadStatus(for album: Album) -> DownloadStatus? {
        let title = album.title
        let songs = artistSongs.filter { $0.albumTitle == title }
        guard !songs.isEmpty else { return nil }
        return SongsDownloadSummary(
            songRemoteIds: songs.map(\.remoteId),
            downloadedIds: Set(songs.filter(\.isDownloadedLocally).map(\.remoteId)),
            trackTotal: max(album.trackCount, songs.count),
            center: downloadCenter
        ).status
    }

    private func play(shuffle: Bool, artist: Artist) {
        PlayTrace.begin(
            shuffle ? "ArtistDetail Shuffle" : "ArtistDetail Play",
            details: "artist=\(artist.name)"
        )
        Task {
            var songs = artistSongs
            if songs.isEmpty {
                // Play was tapped before the soft fill finished — load tracks now.
                trackFillTask?.cancel()
                if let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() {
                    for album in artistAlbums {
                        guard !Task.isCancelled else { return }
                        try? await syncer.sync(albumId: album.remoteId)
                    }
                }
                reloadArtistContent()
                songs = artistSongs
            }
            PlayTrace.mark("mapping QueueItems", details: "count=\(songs.count)")
            let items = songs.map(QueueItem.from)
            guard !items.isEmpty else { return }
            PlayTrace.mark("QueueItems ready", details: "count=\(items.count)")
            PlayTrace.mark("calling player.play")
            player.play(items: items, shuffle: shuffle, origin: .artist(artist.name))
            router.openPlayer()
        }
    }

    private func playSong(_ song: Song) {
        PlayTrace.begin("ArtistDetail track tap", details: "song=\(song.title)")
        let items = artistSongs.map(QueueItem.from)
        let index = artistSongs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
        let origin = artists.first.map { QueueOrigin.artist($0.name) }
            ?? song.artistName.map { QueueOrigin.artist($0) }
        player.play(items: items, startAt: index, origin: origin)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct AlbumNavigationID: Identifiable, Hashable {
    let id: String
}
