import SwiftUI
import SwiftData
import VerodromeKit

struct GenreDetailView: View {
    let genreID: String
    @Query private var genres: [Genre]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @State private var genreAlbums: [Album] = []
    @State private var genreSongs: [Song] = []

    init(genreID: String) {
        self.genreID = genreID
        _genres = Query(filter: #Predicate<Genre> { $0.compoundRemoteId == genreID })
    }

    var body: some View {
        List {
            if let genre = genres.first {
                Section {
                    DetailHeader(
                        title: genre.name,
                        subtitle: headerSubtitle(for: genre),
                        artworkURL: genre.artworkToken ?? genreAlbums.first?.artworkToken,
                        symbol: "guitars.fill",
                        onPlay: { play(shuffle: false, genre: genre) },
                        onShuffle: { play(shuffle: true, genre: genre) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !genreAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(genreAlbums, id: \.compoundRemoteId) { album in
                            NavigationLink {
                                AlbumDetailView(albumID: album.compoundRemoteId)
                            } label: {
                                EntityRow(
                                    title: album.title,
                                    subtitle: album.displayArtist,
                                    artworkURL: album.artworkToken,
                                    downloadStatus: SongsDownloadSummary(album: album, center: downloadCenter).status
                                )
                            }
                        }
                    }
                }

                if !genreSongs.isEmpty {
                    Section("Songs") {
                        ForEach(genreSongs, id: \.compoundRemoteId) { song in
                            Button { playSong(song) } label: {
                                EntityRow(
                                    title: song.title,
                                    subtitle: song.displayArtist,
                                    artworkURL: song.displayArtworkToken,
                                    isPlaying: nowPlaying.currentItem?.playableId == song.remoteId,
                                    trailing: formatDuration(song.displayDuration)
                                )
                            }
                            .buttonStyle(.plain)
                            .songActions(song)
                        }
                    }
                }
            }
        }
        .detailCollapsingNavTitle(genres.first?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: genres.first?.name) {
            reloadGenreContent()
        }
    }

    /// Prefer stored counts (from sync/backfill) when loaded content is incomplete —
    /// songs often lack `genreName`, so the song query alone under-counts.
    private func headerSubtitle(for genre: Genre) -> String {
        let albums = max(genre.albumCount, genreAlbums.count)
        let fromAlbumTracks = genreAlbums.reduce(0) { partial, album in
            partial + (album.trackCount > 0 ? album.trackCount : album.songs.count)
        }
        let songs = max(genre.songCount, genreSongs.count, fromAlbumTracks)
        return "\(albums) albums · \(songs) songs"
    }

    private func reloadGenreContent() {
        guard let genre = genres.first else {
            genreAlbums = []
            genreSongs = []
            return
        }
        let name = genre.name
        // Predicate on denormalized genreName — avoids loading the entire library into @Query.
        let songDescriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { song in
                song.genreName == name
            },
            sortBy: [SortDescriptor(\Song.sortTitle)]
        )
        let albumDescriptor = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { album in
                album.genreName == name
            },
            sortBy: [SortDescriptor(\Album.sortTitle)]
        )
        genreAlbums = (try? modelContext.fetch(albumDescriptor)) ?? []

        // Merge songs tagged with this genre and tracks on genre albums (many
        // libraries only stamp genre on the album).
        var byId: [String: Song] = [:]
        for song in (try? modelContext.fetch(songDescriptor)) ?? [] {
            byId[song.compoundRemoteId] = song
        }
        for album in genreAlbums {
            for song in album.songs {
                byId[song.compoundRemoteId] = song
            }
        }
        genreSongs = byId.values.sorted {
            ($0.albumTitle ?? "", $0.disc ?? 0, $0.track ?? 0)
                < ($1.albumTitle ?? "", $1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func play(shuffle: Bool, genre: Genre) {
        PlayTrace.begin(
            shuffle ? "GenreDetail Shuffle" : "GenreDetail Play",
            details: "genre=\(genre.name)"
        )
        PlayTrace.mark("mapping QueueItems", details: "count=\(genreSongs.count)")
        var items = genreSongs.map(QueueItem.from)
        if items.isEmpty {
            PlayTrace.mark("fallback via album.songs…")
            items = genreAlbums.flatMap { album in
                album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }.map {
                    QueueItem.from($0, albumArtworkId: album.artworkToken)
                }
            }
        }
        PlayTrace.mark("QueueItems ready", details: "count=\(items.count)")
        guard !items.isEmpty else { return }
        PlayTrace.mark("calling player.play")
        player.play(items: items, shuffle: shuffle)
        router.openPlayer()
    }

    private func playSong(_ song: Song) {
        PlayTrace.begin("GenreDetail track tap", details: "song=\(song.title)")
        let items = genreSongs.map(QueueItem.from)
        let index = genreSongs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
