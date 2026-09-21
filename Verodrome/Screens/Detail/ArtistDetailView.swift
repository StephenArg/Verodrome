import SwiftUI
import SwiftData
import VerodromeKit

struct ArtistDetailView: View {
    let artistID: String
    @Query private var artists: [Artist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @State private var artistAlbums: [Album] = []
    @State private var artistSongs: [Song] = []
    @State private var topSongs: [IngestSong] = []
    @State private var showAllPopular = false
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

                if !topSongs.isEmpty {
                    Section(ArtistTopSongs.sectionTitle) {
                        ForEach(Array(displayedPopularSongs.enumerated()), id: \.element.id) { index, ingest in
                            topSongRow(ingest, rank: index + 1)
                        }
                        if ArtistTopSongs.showsMoreControl(keptCount: topSongs.count) {
                            HStack {
                                Spacer(minLength: 0)
                                popularExpansionCapsule(showAllPopular ? "Show less" : "Show more") {
                                    withAnimation(.snappy) { showAllPopular.toggle() }
                                }
                                Spacer(minLength: 0)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
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

                if !displayedArtistSongs.isEmpty {
                    Section("Songs") {
                        ForEach(displayedArtistSongs, id: \.compoundRemoteId) { song in
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
                                    ),
                                    isExplicit: song.isLyricsExplicit
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
        .onAppear {
            hydratePopularFromMemory()
        }
        .task(id: artists.first?.compoundRemoteId) {
            showAllPopular = false
            reloadArtistContent()
            await hydratePopularFromCache()
            guard let remoteId = artists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(artistId: remoteId)
            reloadArtistContent()
            startTrackFillIfNeeded()
            await loadTopSongsIfNeeded()
        }
        .onChange(of: settings.hideExplicitSongs) { _, _ in
            reloadArtistContent()
        }
        .onChange(of: settings.showArtistTopSongs) { _, enabled in
            if enabled, isPopularAvailable {
                hydratePopularFromMemory()
                Task { await loadTopSongsIfNeeded() }
            } else {
                topSongs = []
                showAllPopular = false
            }
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
        let songs = totalSongCount(for: artist)
        return "\(albums) albums · \(songs) songs"
    }

    private func totalSongCount(for artist: Artist) -> Int {
        let fromAlbumTracks = artistAlbums.reduce(0) { partial, album in
            // Prefer denormalized `trackCount` — never walk `album.songs` here.
            partial + max(album.trackCount, 0)
        }
        return max(artist.songCount, artistSongs.count, fromAlbumTracks)
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

    private var displayedArtistSongs: [Song] {
        settings.hideExplicitSongs ? artistSongs.filter { !$0.isLyricsExplicit } : artistSongs
    }

    private var displayedPopularSongs: [IngestSong] {
        let songs = ArtistTopSongs.displayedSongs(from: topSongs, expanded: showAllPopular)
        guard settings.hideExplicitSongs else { return songs }
        return songs.filter { ingest in
            localSong(for: ingest)?.isLyricsExplicit != true
        }
    }

    @ViewBuilder
    private func topSongRow(_ ingest: IngestSong, rank: Int) -> some View {
        let local = localSong(for: ingest)
        Button { playTopSong(at: rank - 1) } label: {
            EntityRow(
                title: local?.title ?? ingest.title,
                subtitle: local?.displayAlbum ?? ingest.albumName ?? "",
                artworkURL: local?.displayArtworkToken ?? ingest.artId,
                isPlaying: nowPlaying.currentItem?.playableId == ingest.id,
                trailing: formatDuration(local?.displayDuration ?? ingest.duration ?? 0),
                trackNumber: rank,
                showsArtworkBesideNumber: true,
                downloadStatus: local.map {
                    downloadCenter.status(for: $0.remoteId, isDownloaded: $0.isDownloadedLocally)
                },
                isExplicit: local?.isLyricsExplicit ?? false
            )
        }
        .buttonStyle(.plain)
        .songActions(compoundRemoteId: compoundSongId(ingest.id))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func popularExpansionCapsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.38), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func localSong(for ingest: IngestSong) -> Song? {
        artistSongs.first { $0.remoteId == ingest.id }
    }

    private func compoundSongId(_ remoteId: String) -> String {
        Song.makeCompoundRemoteId(account: artists.first?.account, remoteId: remoteId)
    }

    private var isPopularAvailable: Bool {
        guard settings.showArtistTopSongs else { return false }
        let apiType = artists.first?.account?.apiType
            ?? (try? VerodromeKit.shared.activeAccount()?.apiType)
        return ArtistTopSongs.isSupported(on: apiType)
    }

    private func hydratePopularFromMemory() {
        guard isPopularAvailable else { return }
        if let cached = ArtistPopularSongsCache.shared.cached(forArtistCompoundId: artistID) {
            topSongs = cached
        }
    }

    private func hydratePopularFromCache() async {
        guard isPopularAvailable else {
            topSongs = []
            showAllPopular = false
            return
        }
        if let cached = await ArtistPopularSongsCache.shared.load(forArtistCompoundId: artistID) {
            topSongs = cached
        }
    }

    private func loadTopSongsIfNeeded() async {
        guard isPopularAvailable, let artist = artists.first else {
            topSongs = []
            showAllPopular = false
            return
        }
        let songCount = totalSongCount(for: artist)
        // A cached list can paint before album counts land. Don't hide it just because
        // the header still says 0 songs; only skip the fetch for a known-small catalog.
        guard ArtistTopSongs.shouldFetch(artistSongCount: songCount) else {
            if songCount > 0 { topSongs = [] }
            return
        }
        guard let provider = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() as? any TopSongProviding else {
            return
        }
        let visible: [IngestSong]
        do {
            visible = try await ArtistTopSongs.fetchVisible(
                artistId: artist.remoteId,
                artistName: artist.name,
                songCount: songCount,
                provider: provider
            )
        } catch {
            // Keep whatever the cache already showed.
            return
        }
        guard !Task.isCancelled else { return }
        await ArtistPopularSongsCache.shared.store(visible, forArtistCompoundId: artistID)
        guard !ArtistTopSongs.listsMatch(visible, topSongs) else { return }
        topSongs = visible
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
            var songs = displayedArtistSongs
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
                songs = displayedArtistSongs
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
        let items = displayedArtistSongs.map(QueueItem.from)
        let index = displayedArtistSongs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
        let origin = artists.first.map { QueueOrigin.artist($0.name) }
            ?? song.artistName.map { QueueOrigin.artist($0) }
        player.play(items: items, startAt: index, origin: origin)
    }

    private func playTopSong(at index: Int) {
        PlayTrace.begin("ArtistDetail top song tap", details: "index=\(index)")
        let items = displayedPopularSongs.map { ingest in
            if let local = localSong(for: ingest) {
                return QueueItem.from(local)
            }
            return QueueItem.from(ingest)
        }
        guard !items.isEmpty else { return }
        let origin = artists.first.map { QueueOrigin.artist($0.name) }
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
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
