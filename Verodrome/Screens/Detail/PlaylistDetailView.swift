import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistDetailView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel

    @State private var songs: [Song] = []

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
                        artworkURL: playlist.artworkToken,
                        tintToken: backgroundArtworkToken,
                        symbol: "music.note.house.fill",
                        onPlay: { play(shuffle: false) },
                        onShuffle: { play(shuffle: true) }
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
                                    isPlaying: nowPlaying.currentItem?.playableId == song.remoteId
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistAddSongsView(playlistID: playlistID) } label: {
                    Image(systemName: "plus")
                }
            }
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
