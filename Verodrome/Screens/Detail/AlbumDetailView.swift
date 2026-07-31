import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumDetailView: View {
    let albumID: String
    @Query private var albums: [Album]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel

    @State private var tracks: [Song] = []

    init(albumID: String) {
        self.albumID = albumID
        _albums = Query(filter: #Predicate<Album> { $0.compoundRemoteId == albumID })
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
                        onShuffle: { play(shuffle: true) }
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
                                trackNumber: song.track ?? (index + 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .songActions(song)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
                if shuffle { items.shuffle() }
                player.play(items: items)
            }
            return
        }

        if shuffle { items.shuffle() }
        player.play(items: items)
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
