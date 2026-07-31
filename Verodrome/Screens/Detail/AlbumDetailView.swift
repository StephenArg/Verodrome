import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumDetailView: View {
    let albumID: String
    @Query private var albums: [Album]
    @EnvironmentObject private var player: PlayerViewModel

    init(albumID: String) {
        self.albumID = albumID
        _albums = Query(filter: #Predicate<Album> { $0.compoundRemoteId == albumID })
    }

    var body: some View {
        List {
            if let album = albums.first {
                let tracks = tracks(for: album)
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
                                isPlaying: player.currentItem?.playableId == song.remoteId,
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
            guard let remoteId = albums.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: remoteId)
        }
    }

    /// Album relationship only — never scan the full song library.
    private func tracks(for album: Album) -> [Song] {
        album.songs.sorted {
            ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func play(shuffle: Bool) {
        guard let album = albums.first else { return }
        PlayTrace.begin(
            shuffle ? "AlbumDetail Shuffle" : "AlbumDetail Play",
            details: "album=\(album.title) remoteId=\(album.remoteId)"
        )
        PlayTrace.mark("reading album.songs…")
        var items = tracks(for: album).map(QueueItem.from)
        PlayTrace.mark("mapped QueueItems", details: "count=\(items.count)")

        if items.isEmpty {
            // Only hop async when we must wait on network sync.
            Task {
                PlayTrace.mark("empty tracks — syncing album…")
                try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: album.remoteId)
                items = tracks(for: album).map(QueueItem.from)
                PlayTrace.mark("remapped QueueItems", details: "count=\(items.count)")
                guard !items.isEmpty else {
                    PlayTrace.error("no tracks after sync")
                    return
                }
                if shuffle {
                    items.shuffle()
                    PlayTrace.mark("items.shuffle() done")
                }
                PlayTrace.mark("calling player.play")
                player.play(items: items)
            }
            return
        }

        if shuffle {
            items.shuffle()
            PlayTrace.mark("items.shuffle() done")
        }
        PlayTrace.mark("calling player.play")
        player.play(items: items)
    }

    private func playSong(_ song: Song, tracks: [Song]) {
        PlayTrace.begin("AlbumDetail track tap", details: "song=\(song.title)")
        PlayTrace.mark("mapping QueueItems", details: "count=\(tracks.count)")
        let items = tracks.map(QueueItem.from)
        let index = tracks.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        PlayTrace.mark("calling player.play", details: "startAt=\(index)")
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
