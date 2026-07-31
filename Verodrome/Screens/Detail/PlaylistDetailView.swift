import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistDetailView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @EnvironmentObject private var player: PlayerViewModel

    init(playlistID: String) {
        self.playlistID = playlistID
        _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
    }

    var body: some View {
        List {
            if let playlist = playlists.first {
                Section {
                    DetailHeader(
                        title: playlist.name,
                        subtitle: "\(playlist.songCount) songs",
                        artworkURL: playlist.displayArtworkToken,
                        symbol: "music.note.house.fill",
                        onPlay: { play(shuffle: false) },
                        onShuffle: { play(shuffle: true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Songs") {
                    let songs = displaySongs(for: playlist)
                    if songs.isEmpty {
                        Text("Loading songs…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(songs, id: \.compoundRemoteId) { song in
                            Button { playSong(song, playlist: playlist) } label: {
                                EntityRow(
                                    title: song.title,
                                    subtitle: song.displayArtist,
                                    artworkURL: song.artworkToken ?? song.album?.artworkToken,
                                    isPlaying: player.currentItem?.playableId == song.remoteId
                                )
                            }
                            .buttonStyle(.plain)
                            .songActions(song)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistAddSongsView(playlistID: playlistID) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: playlists.first?.remoteId) {
            guard let remoteId = playlists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(playlistId: remoteId)
        }
    }

    private func displaySongs(for playlist: Playlist) -> [Song] {
        playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
    }

    private func play(shuffle: Bool) {
        guard let playlist = playlists.first else { return }
        PlayTrace.begin(
            shuffle ? "PlaylistDetail Shuffle" : "PlaylistDetail Play",
            details: "playlist=\(playlist.name)"
        )
        PlayTrace.mark("resolving playlist songs…")
        var items = displaySongs(for: playlist).map(QueueItem.from)
        PlayTrace.mark("QueueItems ready", details: "count=\(items.count)")
        if shuffle {
            items.shuffle()
            PlayTrace.mark("items.shuffle() done")
        }
        PlayTrace.mark("calling player.play")
        player.play(items: items)
    }

    private func playSong(_ song: Song, playlist: Playlist) {
        PlayTrace.begin("PlaylistDetail track tap", details: "song=\(song.title)")
        let songs = displaySongs(for: playlist)
        let items = songs.map(QueueItem.from)
        let index = songs.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "count=\(items.count) startAt=\(index)")
        player.play(items: items, startAt: index)
    }
}
