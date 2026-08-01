import SwiftUI
import SwiftData
import VerodromeKit

struct DownloadsView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var downloadedRows: [DownloadedSongRow] = []
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if downloadedRows.isEmpty && activeEntries.isEmpty && downloadCenter.failedIds.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Songs you download for offline listening appear here.")
                )
            } else {
                List {
                    if !activeEntries.isEmpty {
                        Section("In Progress") {
                            ForEach(activeEntries, id: \.row.id) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    EntityRow(
                                        title: entry.row.title,
                                        subtitle: entry.row.subtitle,
                                        artworkURL: entry.row.artworkToken,
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
                                let title = downloadedRows.first(where: { $0.remoteId == id })?.title ?? id
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

                    if !downloadedRows.isEmpty {
                        Section("Downloaded") {
                            ForEach(downloadedRows) { row in
                                Button {
                                    play(row)
                                } label: {
                                    EntityRow(
                                        title: row.title,
                                        subtitle: row.subtitle,
                                        artworkURL: row.artworkToken,
                                        isPlaying: nowPlaying.currentItem?.playableId == row.remoteId,
                                        trailing: row.durationText
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        // One trigger, not two: a plain `.task` alongside `.task(id:)` runs the
        // whole fetch twice on appear.
        .task(id: downloadCenter.completedIds.count) {
            await reload()
        }
    }

    /// Active download entries joined with song titles from the loaded rows.
    private var activeEntries: [(row: DownloadedSongRow, progress: Double)] {
        downloadCenter.activeDownloads.compactMap { id, progress in
            guard let row = downloadedRows.first(where: { $0.remoteId == id }) else { return nil }
            return (row, progress)
        }
        .sorted { $0.row.title < $1.row.title }
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let rows = await Self.fetchDownloaded()
        guard generation == loadGeneration else { return }
        downloadedRows = rows
    }

    private static func fetchDownloaded() async -> [DownloadedSongRow] {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let songs = try context.fetch(
                    FetchDescriptor<Song>(
                        predicate: #Predicate<Song> { $0.isDownloadedLocally == true },
                        sortBy: [SortDescriptor(\Song.title)]
                    )
                )
                return songs.map(DownloadedSongRow.init)
            }
        } catch {
            return []
        }
    }

    private func play(_ row: DownloadedSongRow) {
        let items = downloadedRows.map(\.queueItem)
        let index = downloadedRows.firstIndex(where: { $0.id == row.id }) ?? 0
        player.play(items: items, startAt: index)
    }
}

struct DownloadedSongRow: Identifiable, Hashable, Sendable {
    let id: String
    let remoteId: String
    let title: String
    let subtitle: String
    let artworkToken: String?
    let duration: TimeInterval
    let durationText: String

    init(song: Song) {
        id = song.compoundRemoteId
        remoteId = song.remoteId
        title = song.title
        subtitle = song.displayArtist
        artworkToken = song.artworkToken
        duration = song.playDuration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        durationText = String(format: "%d:%02d", minutes, seconds)
    }

    var queueItem: QueueItem {
        QueueItem(
            playableId: remoteId,
            kind: .song,
            title: title,
            artistName: subtitle,
            albumName: nil,
            duration: duration,
            artworkId: artworkToken
        )
    }
}
