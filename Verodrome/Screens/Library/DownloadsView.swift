import SwiftUI
import SwiftData
import VerodromeKit

struct DownloadsView: View {
    @Query(sort: \Song.title) private var allSongs: [Song]
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    private var downloads: [Song] {
        allSongs.filter(\.isDownloadedLocally)
    }

    private var activeSongs: [(song: Song, progress: Double)] {
        downloadCenter.activeDownloads.compactMap { id, progress in
            guard let song = allSongs.first(where: { $0.remoteId == id }) else { return nil }
            return (song, progress)
        }
        .sorted { $0.song.title < $1.song.title }
    }

    var body: some View {
        Group {
            if downloads.isEmpty && activeSongs.isEmpty && downloadCenter.failedIds.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Songs you download for offline listening appear here.")
                )
            } else {
                List {
                    if !activeSongs.isEmpty {
                        Section("In Progress") {
                            ForEach(activeSongs, id: \.song.compoundRemoteId) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    EntityRow(
                                        title: entry.song.title,
                                        subtitle: entry.song.displayArtist,
                                        artworkURL: entry.song.album?.artworkToken,
                                        trailing: "\(Int(entry.progress * 100))%"
                                    )
                                    ProgressView(value: entry.progress)
                                }
                            }
                        }
                    }

                    if !downloadCenter.failedIds.isEmpty {
                        Section("Failed") {
                            ForEach(Array(downloadCenter.failedIds).sorted(), id: \.self) { id in
                                let title = allSongs.first(where: { $0.remoteId == id })?.title ?? id
                                HStack {
                                    Text(title)
                                    Spacer()
                                    Button("Retry") {
                                        Task { await VerodromeKit.shared.downloadManager?.retryFailed() }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    if !downloads.isEmpty {
                        Section("Downloaded") {
                            ForEach(downloads, id: \.compoundRemoteId) { song in
                                Button {
                                    play(song)
                                } label: {
                                    EntityRow(
                                        title: song.title,
                                        subtitle: song.displayArtist,
                                        artworkURL: song.album?.artworkToken,
                                        isPlaying: player.currentItem?.playableId == song.remoteId,
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
        }
        .navigationTitle("Downloads")
    }

    private func play(_ song: Song) {
        let items = downloads.map(QueueItem.from)
        let index = downloads.firstIndex(where: { $0.compoundRemoteId == song.compoundRemoteId }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
