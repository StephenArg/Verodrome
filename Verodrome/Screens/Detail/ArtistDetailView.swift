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
                        symbol: "person.fill",
                        onPlay: { play(shuffle: false, artist: artist) },
                        onShuffle: { play(shuffle: true, artist: artist) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Albums") {
                    ForEach(artistAlbums, id: \.compoundRemoteId) { album in
                        NavigationLink {
                            AlbumDetailView(albumID: album.compoundRemoteId)
                        } label: {
                            EntityRow(
                                title: album.title,
                                subtitle: "\(album.year ?? 0)",
                                artworkURL: album.artworkToken,
                                downloadStatus: SongsDownloadSummary(album: album, center: downloadCenter).status
                            )
                        }
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
                                    artworkURL: song.artworkToken,
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
        .artworkTintedBackground(token: backgroundArtworkToken)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artists.first?.compoundRemoteId) {
            reloadArtistContent()
            guard let remoteId = artists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(artistId: remoteId)
            reloadArtistContent()
        }
    }

    /// Servers frequently ship no artist image, so fall back to the newest album's
    /// cover rather than leaving the screen on a flat untinted background.
    private var backgroundArtworkToken: String? {
        if let token = artists.first?.artworkToken, !token.isEmpty { return token }
        return artistAlbums.first?.artworkToken
    }

    /// Prefer stored counts when album tracks haven't been backfilled yet.
    private func headerSubtitle(for artist: Artist) -> String {
        let albums = max(artist.albumCount, artistAlbums.count)
        let fromAlbumTracks = artistAlbums.reduce(0) { partial, album in
            partial + (album.trackCount > 0 ? album.trackCount : album.songs.count)
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

        // Songs often appear both on artist.songs and album.songs — merge without trapping.
        var byId: [String: Song] = [:]
        for song in artist.songs {
            byId[song.compoundRemoteId] = song
        }
        for album in artist.albums {
            for song in album.songs {
                byId[song.compoundRemoteId] = song
            }
        }
        artistSongs = byId.values.sorted {
            ($0.albumTitle ?? "", $0.disc ?? 0, $0.track ?? 0)
                < ($1.albumTitle ?? "", $1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func play(shuffle: Bool, artist: Artist) {
        PlayTrace.begin(
            shuffle ? "ArtistDetail Shuffle" : "ArtistDetail Play",
            details: "artist=\(artist.name)"
        )
        PlayTrace.mark("mapping QueueItems", details: "count=\(artistSongs.count)")
        let items = artistSongs.map(QueueItem.from)
        guard !items.isEmpty else { return }
        PlayTrace.mark("QueueItems ready", details: "count=\(items.count)")
        PlayTrace.mark("calling player.play")
        player.play(items: items, shuffle: shuffle)
        router.openPlayer()
    }

    private func playSong(_ song: Song) {
        PlayTrace.begin("ArtistDetail track tap", details: "song=\(song.title)")
        let items = artistSongs.map(QueueItem.from)
        let index = artistSongs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
