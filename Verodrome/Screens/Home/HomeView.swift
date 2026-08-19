import SwiftUI
import SwiftData
import VerodromeKit

/// Lightweight home carousel tile — no SwiftData relationships retained in the view graph.
struct HomeTileItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artworkToken: String?
    var symbol: String = "music.note"
    /// When set, context-menu Play uses this album remote/compound id.
    var albumCompoundId: String? = nil
    var albumRemoteId: String? = nil
}

/// Everything that should cause a tile reload, collapsed into one `.task(id:)` key so
/// opening Home runs a single background load instead of one per trigger.
///
/// Deliberately excludes `isSyncing`: including it fired a full reload when a sync started
/// *and* again when it ended, and the mid-sync one contends with the ingest writes. Sync
/// completion is handled by a one-shot `onChange` instead.
private struct HomeLoadTrigger: Equatable {
    let sections: [HomeSection]
    let seed: Int
}

/// Populates `Album.artistName` for albums synced before it was denormalized.
///
/// Without this the tile mapper's fallback to `artist?.name` faults the relationship once
/// per album. Runs at most once per launch, and the predicate means it costs a single empty
/// fetch once every album has a value.
@MainActor
private enum HomeArtistNameBackfill {
    /// Persisted, not just per-launch: albums with no artist relationship at all can never
    /// get a name, so an in-memory flag would refetch and refault them on every launch.
    private static let defaultsKey = "home.artistNameBackfillDone"

    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        let token = PerfTrace.begin("Home.artistNameBackfill")
        let filled = (try? await PersistentStorage.shared.backgroundActor.perform { context in
            var desc = FetchDescriptor<Album>(predicate: #Predicate<Album> { $0.artistName == nil })
            desc.fetchLimit = 2000
            let albums = try context.fetch(desc)
            var filled = 0
            for album in albums {
                guard let name = album.artist?.name else { continue }
                album.artistName = name
                filled += 1
            }
            return filled
        }) ?? 0

        UserDefaults.standard.set(true, forKey: defaultsKey)
        PerfTrace.end(token, details: "filled=\(filled)")
    }
}

private struct HomeLibraryTotals: Equatable {
    var albums = 0
    var songs = 0
}

struct HomeView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @EnvironmentObject private var shuffle: ShuffleAllCoordinator
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext

    @State private var showEditor = false
    @State private var randomSeed = Int.random(in: Int.min...Int.max)
    @State private var sectionTiles: [HomeSection: [HomeTileItem]] = [:]
    @State private var libraryTotals = HomeLibraryTotals()
    /// False until the first store count lands — zeros before that aren't a real empty library.
    @State private var hasLoadedLibraryTotals = false
    /// True only while a post-sync recount is in flight — keeps the previous tally soft
    /// until the new one lands, without tying blur to the whole background sync.
    @State private var isRefreshingLibraryTotals = false
    @State private var didRequestInitialRefresh = false
    @State private var selectedAlbumId: String?
    @State private var selectedPlaylistId: String?
    @State private var selectedPodcastId: String?
    @State private var selectedGenreId: String?
    @State private var selectedSectionList: HomeSection?

    private var loadTrigger: HomeLoadTrigger {
        HomeLoadTrigger(
            sections: settings.enabledHomeSections,
            seed: randomSeed
        )
    }

    var body: some View {
        HomeCollectionView(
            sections: settings.enabledHomeSections,
            tiles: sectionTiles,
            stats: HomeStatsBarState(
                albumCount: libraryTotals.albums,
                songCount: libraryTotals.songs,
                // Don't key off `librarySync.isSyncing`: Navidrome's background job holds
                // that flag through the full track backfill, which would keep Home blurred
                // for minutes. Show the last settled tally; soften only before the first
                // count and during the brief post-sync recount.
                isCountProvisional: !hasLoadedLibraryTotals || isRefreshingLibraryTotals,
                isShuffleBusy: shuffle.isStarting,
                isShuffleDisabled: libraryTotals.songs == 0
            ),
            onSelectTile: select,
            onPlayAlbum: playAlbum,
            onSeeAll: { section in
                // Land on Albums already sorted the same way as this Home carousel.
                switch section {
                case .recentlyAdded:
                    settings.librarySort.albums = .recentlyAdded
                case .randomAlbums:
                    settings.librarySort.albums = .random
                default:
                    break
                }
                selectedSectionList = section
            },
            onShuffle: shuffleAllSongs,
            onRefresh: {
                await refreshHomeLists()
                randomSeed = Int.random(in: Int.min...Int.max)
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(account.homeTitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HomeAccountButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsHostView() } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            HomeEditorView()
        }
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .navigationDestination(item: $selectedPlaylistId) { PlaylistDetailView(playlistID: $0) }
        .navigationDestination(item: $selectedPodcastId) { PodcastDetailView(podcastID: $0) }
        .navigationDestination(item: $selectedGenreId) { GenreDetailView(genreID: $0) }
        .navigationDestination(item: $selectedSectionList) { sectionList(for: $0) }
        .task(id: loadTrigger) {
            await HomeArtistNameBackfill.runIfNeeded()
            await loadTiles()
            await loadLibraryTotals()
            // Server top-up runs once per view lifetime, after local tiles are on screen.
            guard !didRequestInitialRefresh, !librarySync.isSyncing else { return }
            didRequestInitialRefresh = true
            // Let the visible carousels finish decoding their artwork first. The ingest
            // writes this kicks off contend with artwork reads for the same disk, and
            // launch-time tiles are already on screen from the local store by now.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refreshHomeLists()
            await loadTiles()
            await loadLibraryTotals()
        }
        .onChange(of: librarySync.isSyncing) { wasSyncing, isSyncing in
            // Only once the writes have stopped — reloading mid-sync competes with ingest
            // for the store and produced the slowest loads by far.
            guard wasSyncing, !isSyncing else { return }
            isRefreshingLibraryTotals = true
            Task {
                await loadTiles()
                await loadLibraryTotals()
            }
        }
    }

    private func shuffleAllSongs() {
        Task {
            if await shuffle.shuffleAll() {
                router.openPlayer()
            }
        }
    }

    private func select(section: HomeSection, tile: HomeTileItem) {
        switch section {
        case .recentlyPlayed, .recentlyAdded, .favorites, .randomAlbums:
            selectedAlbumId = tile.id
        case .playlists:
            selectedPlaylistId = tile.id
        case .podcasts:
            selectedPodcastId = tile.id
        case .genres:
            selectedGenreId = tile.id
        case .radios:
            break
        }
    }

    @ViewBuilder
    private func sectionList(for section: HomeSection) -> some View {
        switch section {
        case .favorites: FavoritesView()
        case .playlists: PlaylistsView()
        case .podcasts: PodcastsView()
        case .radios: RadiosView()
        case .genres: GenresView()
        case .recentlyPlayed, .recentlyAdded, .randomAlbums:
            AlbumsView()
        }
    }

    private func loadLibraryTotals() async {
        let totals = await Self.fetchLibraryTotals()
        guard !Task.isCancelled else { return }
        if totals != libraryTotals {
            libraryTotals = totals
        }
        hasLoadedLibraryTotals = true
        isRefreshingLibraryTotals = false
    }

    private static func fetchLibraryTotals() async -> HomeLibraryTotals {
        (try? await PersistentStorage.shared.backgroundActor.perform { context in
            HomeLibraryTotals(
                albums: (try? context.fetchCount(FetchDescriptor<Album>())) ?? 0,
                songs: (try? context.fetchCount(FetchDescriptor<Song>())) ?? 0
            )
        }) ?? HomeLibraryTotals()
    }

    /// Fetches every section in one hop onto the storage actor, then publishes once.
    ///
    /// Publishing per-section was tried and was dramatically worse (33.6s versus 1.9s for
    /// the same work): each mutation drives a synchronous diffable apply, and with eight
    /// orthogonally-scrolling sections that reruns the compositional layout every time.
    /// One publish means one layout pass.
    private func loadTiles() async {
        let token = PerfTrace.begin("Home.loadTiles")
        let result = await Self.fetchTiles(
            sections: settings.enabledHomeSections,
            randomSeed: randomSeed
        )
        // `.task(id:)` already cancels the superseded load; bailing here also avoids
        // publishing tiles for a trigger the user has already scrolled past.
        guard !Task.isCancelled else {
            PerfTrace.end(token, details: "cancelled")
            return
        }
        guard result.tiles != sectionTiles else {
            PerfTrace.end(token, details: "unchanged, no re-render | \(result.breakdown)")
            return
        }
        sectionTiles = result.tiles
        PerfTrace.end(
            token,
            details: "sections=\(result.tiles.count) "
                + "tiles=\(result.tiles.values.reduce(0) { $0 + $1.count }) | \(result.breakdown)"
        )
    }

    /// Fetch + map all home sections in one background pass.
    ///
    /// `breakdown` reports how long each section's fetch-and-map took, plus how much of
    /// that was spent waiting to get onto the storage actor, so a slow load can be
    /// attributed to a specific section rather than guessed at.
    private static func fetchTiles(
        sections: [HomeSection],
        randomSeed: Int
    ) async -> (tiles: [HomeSection: [HomeTileItem]], breakdown: String) {
        let tQueued = CFAbsoluteTimeGetCurrent()
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let waitMs = Int(((CFAbsoluteTimeGetCurrent() - tQueued) * 1000).rounded())
                var result: [HomeSection: [HomeTileItem]] = [:]
                var timings: [String] = ["actorWait=\(waitMs)ms"]

                for section in sections {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let tiles = try Self.fetchSection(section, randomSeed: randomSeed, context: context)
                    let ms = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())
                    result[section] = tiles
                    timings.append("\(section.title)=\(ms)ms/\(tiles.count)")
                }

                return (result, timings.joined(separator: " "))
            }
        } catch {
            return ([:], "failed")
        }
    }

    /// Runs inside `backgroundActor.perform`, so it must not be main-actor isolated.
    private nonisolated static func fetchSection(
        _ section: HomeSection,
        randomSeed: Int,
        context: ModelContext
    ) throws -> [HomeTileItem] {
        switch section {
        case .recentlyPlayed:
            var desc = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { $0.recentIndex > 0 },
                sortBy: [SortDescriptor(\Album.recentIndex)]
            )
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map(Self.albumTile)

        case .recentlyAdded:
            var desc = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { $0.newestIndex > 0 },
                sortBy: [SortDescriptor(\Album.newestIndex)]
            )
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map(Self.albumTile)

        case .favorites:
            var desc = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { $0.isFavorite == true },
                sortBy: [SortDescriptor(\Album.sortTitle)]
            )
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map(Self.albumTile)

        case .randomAlbums:
            var desc = FetchDescriptor<Album>(sortBy: [SortDescriptor(\Album.sortTitle)])
            desc.fetchLimit = 40
            let sample = try context.fetch(desc)
            return Array(
                sample
                    .sorted {
                        stableHash($0.remoteId, seed: randomSeed)
                            < stableHash($1.remoteId, seed: randomSeed)
                    }
                    .prefix(20)
                    .map(Self.albumTile)
            )

        case .playlists:
            var desc = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\Playlist.name)])
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map {
                HomeTileItem(
                    id: $0.compoundRemoteId,
                    title: $0.name,
                    subtitle: "\($0.songCount) songs",
                    artworkToken: $0.artworkToken,
                    symbol: "music.note.house.fill"
                )
            }

        case .podcasts:
            var desc = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\Podcast.title)])
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map {
                HomeTileItem(
                    id: $0.compoundRemoteId,
                    title: $0.title,
                    subtitle: "\($0.episodeCount) episodes",
                    artworkToken: $0.artworkToken,
                    symbol: "mic.fill"
                )
            }

        case .radios:
            var desc = FetchDescriptor<Radio>(sortBy: [SortDescriptor(\Radio.title)])
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map {
                HomeTileItem(
                    id: $0.compoundRemoteId,
                    title: $0.title,
                    subtitle: "Radio",
                    artworkToken: $0.artworkToken,
                    symbol: "dot.radiowaves.left.and.right"
                )
            }

        case .genres:
            var desc = FetchDescriptor<Genre>(sortBy: [SortDescriptor(\Genre.name)])
            desc.fetchLimit = 20
            return (try context.fetch(desc)).map {
                HomeTileItem(
                    id: $0.compoundRemoteId,
                    title: $0.name,
                    subtitle: "\($0.albumCount) albums",
                    artworkToken: $0.artworkToken,
                    symbol: "guitars.fill"
                )
            }
        }
    }

    /// Runs inside `backgroundActor.perform`, so it must not be main-actor isolated.
    ///
    /// Reads `artistName` directly rather than `displayArtist`: the latter falls back to
    /// `artist?.name`, which faults the relationship once per album and turns a single
    /// fetch into dozens of round trips. `HomeArtistNameBackfill` keeps the denormalized
    /// column populated so the fallback isn't needed.
    private nonisolated static func albumTile(_ album: Album) -> HomeTileItem {
        HomeTileItem(
            id: album.compoundRemoteId,
            title: album.title,
            subtitle: album.artistName ?? "Unknown Artist",
            artworkToken: album.artworkToken,
            albumCompoundId: album.compoundRemoteId,
            albumRemoteId: album.remoteId
        )
    }

    private nonisolated static func stableHash(_ value: String, seed: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(value)
        return hasher.finalize()
    }

    private func refreshHomeLists() async {
        guard let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() else { return }
        _ = try? await syncer.syncNewestAlbums(limit: 40)
        _ = try? await syncer.syncRecentAlbums(limit: 40)
        try? await syncer.syncFavoriteAlbums()
    }

    private func playAlbum(compoundId: String, remoteId: String) {
        PlayTrace.begin("Home playAlbum", details: "album=\(compoundId)")
        Task {
            let id = compoundId
            var descriptor = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { $0.compoundRemoteId == id }
            )
            descriptor.fetchLimit = 1
            guard let album = try? modelContext.fetch(descriptor).first else {
                PlayTrace.error("album not found")
                return
            }
            var songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
            if songs.isEmpty {
                try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: remoteId)
                songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
            }
            guard !songs.isEmpty else {
                PlayTrace.error("no songs to play")
                return
            }
            let items = songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) }
            RecentQueueStore.shared.record(album: album)
            await VerodromeKit.shared.player?.play(
                items: items,
                startAt: 0,
                shuffle: nil,
                origin: .album(album.title)
            )
        }
    }
}
