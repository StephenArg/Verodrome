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

struct HomeView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @Environment(\.modelContext) private var modelContext

    @Query private var recentAlbums: [Album]
    @Query private var newestAlbums: [Album]
    @Query private var favoriteAlbums: [Album]
    @Query private var playlists: [Playlist]
    @Query private var podcasts: [Podcast]
    @Query private var radios: [Radio]
    @Query private var genres: [Genre]

    @State private var showEditor = false
    @State private var randomSeed = Int.random(in: Int.min...Int.max)
    @State private var randomTiles: [HomeTileItem] = []
    @State private var sectionTiles: [HomeSection: [HomeTileItem]] = [:]

    init() {
        var recent = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { $0.recentIndex > 0 },
            sortBy: [SortDescriptor(\Album.recentIndex)]
        )
        recent.fetchLimit = 20
        _recentAlbums = Query(recent)

        var newest = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { $0.newestIndex > 0 },
            sortBy: [SortDescriptor(\Album.newestIndex)]
        )
        newest.fetchLimit = 20
        _newestAlbums = Query(newest)

        var favorites = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { $0.isFavorite == true },
            sortBy: [SortDescriptor(\Album.sortTitle)]
        )
        favorites.fetchLimit = 20
        _favoriteAlbums = Query(favorites)

        var playlistDesc = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\Playlist.name)])
        playlistDesc.fetchLimit = 20
        _playlists = Query(playlistDesc)

        var podcastDesc = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\Podcast.title)])
        podcastDesc.fetchLimit = 20
        _podcasts = Query(podcastDesc)

        var radioDesc = FetchDescriptor<Radio>(sortBy: [SortDescriptor(\Radio.title)])
        radioDesc.fetchLimit = 20
        _radios = Query(radioDesc)

        var genreDesc = FetchDescriptor<Genre>(sortBy: [SortDescriptor(\Genre.name)])
        genreDesc.fetchLimit = 20
        _genres = Query(genreDesc)
    }

    var body: some View {
        ScrollView {
            // Eager VStack: Home only has ~8 sections. LazyVStack was destroying and
            // rebuilding entire carousels on every scroll pass (see Home.section.appear/
            // disappear spam), which hitch the main thread even when art is cached.
            VStack(alignment: .leading, spacing: 28) {
                ForEach(settings.enabledHomeSections) { section in
                    HomeSectionView(
                        section: section,
                        tiles: sectionTiles[section] ?? [],
                        onAlbumPlay: playAlbum
                    )
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .toolbar {
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
        .refreshable {
            randomSeed = Int.random(in: Int.min...Int.max)
            await refreshHomeLists()
            reloadRandomAlbums()
            rebuildSectionTiles()
        }
        .task(id: randomSeed) {
            reloadRandomAlbums()
            rebuildSectionTiles()
        }
        .task {
            guard !librarySync.isSyncing else {
                PerfTrace.event("Home.skipRefresh", details: "backgroundSync=true")
                return
            }
            if newestAlbums.isEmpty || recentAlbums.isEmpty {
                await refreshHomeLists()
            }
        }
        .task(id: homeDataFingerprint) {
            rebuildSectionTiles()
        }
        .perfAppear("Home", details: homeSnapshotDetails())
    }

    private var homeDataFingerprint: String {
        "\(recentAlbums.count)|\(newestAlbums.count)|\(favoriteAlbums.count)|\(playlists.count)|\(podcasts.count)|\(radios.count)|\(genres.count)|\(randomTiles.count)|\(settings.enabledHomeSections.count)"
    }

    private func homeSnapshotDetails() -> String {
        "sections=\(settings.enabledHomeSections.count) recent=\(recentAlbums.count) newest=\(newestAlbums.count) fav=\(favoriteAlbums.count) playlists=\(playlists.count) podcasts=\(podcasts.count) radios=\(radios.count) genres=\(genres.count) random=\(randomTiles.count)"
    }

    private func rebuildSectionTiles() {
        PerfTrace.measure("Home.rebuildTiles", details: homeSnapshotDetails()) {
            var next: [HomeSection: [HomeTileItem]] = [:]
            for section in settings.enabledHomeSections {
                switch section {
                case .recentlyPlayed:
                    next[section] = recentAlbums.map(Self.albumTile)
                case .recentlyAdded:
                    next[section] = newestAlbums.map(Self.albumTile)
                case .favorites:
                    next[section] = favoriteAlbums.map(Self.albumTile)
                case .randomAlbums:
                    next[section] = randomTiles
                case .playlists:
                    next[section] = playlists.map {
                        HomeTileItem(
                            id: $0.compoundRemoteId,
                            title: $0.name,
                            subtitle: "\($0.songCount) songs",
                            artworkToken: $0.artworkToken,
                            symbol: "music.note.house.fill"
                        )
                    }
                case .podcasts:
                    next[section] = podcasts.map {
                        HomeTileItem(
                            id: $0.compoundRemoteId,
                            title: $0.title,
                            subtitle: "\($0.episodeCount) episodes",
                            artworkToken: $0.artworkToken,
                            symbol: "mic.fill"
                        )
                    }
                case .radios:
                    next[section] = radios.map {
                        HomeTileItem(
                            id: $0.compoundRemoteId,
                            title: $0.title,
                            subtitle: "Radio",
                            artworkToken: $0.artworkToken,
                            symbol: "dot.radiowaves.left.and.right"
                        )
                    }
                case .genres:
                    next[section] = genres.map {
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
            let changed = next != sectionTiles
            sectionTiles = next
            if changed {
                PerfTrace.event(
                    "Home.tilesChanged",
                    details: "sections=\(next.count) totalTiles=\(next.values.reduce(0) { $0 + $1.count })"
                )
            }
        }
    }

    private static func albumTile(_ album: Album) -> HomeTileItem {
        HomeTileItem(
            id: album.compoundRemoteId,
            title: album.title,
            subtitle: album.displayArtist,
            artworkToken: album.artworkToken,
            albumCompoundId: album.compoundRemoteId,
            albumRemoteId: album.remoteId
        )
    }

    private func reloadRandomAlbums() {
        guard settings.enabledHomeSections.contains(.randomAlbums) else {
            randomTiles = []
            return
        }
        PerfTrace.measure("Home.reloadRandomAlbums") {
            var descriptor = FetchDescriptor<Album>(sortBy: [SortDescriptor(\Album.sortTitle)])
            descriptor.fetchLimit = 40
            let sample = (try? modelContext.fetch(descriptor)) ?? []
            randomTiles = Array(
                sample.sorted {
                    stableHash($0.remoteId) < stableHash($1.remoteId)
                }
                .prefix(20)
                .map(Self.albumTile)
            )
        }
        PerfTrace.event("Home.randomReady", details: "count=\(randomTiles.count)")
    }

    private func stableHash(_ value: String) -> Int {
        var hasher = Hasher()
        hasher.combine(randomSeed)
        hasher.combine(value)
        return hasher.finalize()
    }

    private func refreshHomeLists() async {
        let token = PerfTrace.begin("Home.refreshLists")
        defer { PerfTrace.end(token, details: homeSnapshotDetails()) }

        guard let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() else {
            PerfTrace.event("Home.refreshLists.noSyncer")
            return
        }
        _ = await PerfTrace.measureAsync("Home.syncNewest") {
            try? await syncer.syncNewestAlbums(limit: 40)
        }
        _ = await PerfTrace.measureAsync("Home.syncRecent") {
            try? await syncer.syncRecentAlbums(limit: 40)
        }
        await PerfTrace.measureAsync("Home.syncFavorites") {
            try? await syncer.syncFavoriteAlbums()
        }
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
            PlayTrace.mark("reading album.songs…")
            var songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
            PlayTrace.mark("songs loaded", details: "count=\(songs.count)")
            if songs.isEmpty {
                PlayTrace.mark("empty — syncing album…")
                try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: remoteId)
                songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
                PlayTrace.mark("after sync", details: "count=\(songs.count)")
            }
            guard !songs.isEmpty else {
                PlayTrace.error("no songs to play")
                return
            }
            let items = songs.map(QueueItem.from)
            PlayTrace.mark("calling kit.player.play", details: "count=\(items.count)")
            // Avoid @EnvironmentObject player so Home does not redraw on every track change.
            await VerodromeKit.shared.player?.play(items: items, startAt: 0)
        }
    }
}
