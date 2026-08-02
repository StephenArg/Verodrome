import SwiftUI
import SwiftData
import VerodromeKit

struct DownloadsView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var downloadedRows: [DownloadedSongRow] = []
    /// Titles for songs that are downloading but not on disk yet, so the in-progress
    /// section can name a track the downloaded list has never seen.
    @State private var inFlightRows: [String: DownloadedSongRow] = [:]
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
                                        trailing: entry.progress == nil
                                            ? "Waiting"
                                            : "\(Int((entry.progress ?? 0) * 100))%"
                                    )
                                    ProgressView(value: entry.progress ?? 0)
                                        .opacity(entry.progress == nil ? 0.4 : 1)
                                }
                            }
                        }
                    }

                    if !downloadCenter.failedIds.isEmpty {
                        Section("Failed") {
                            ForEach(Array(downloadCenter.failedIds).sorted(), id: \.self) { id in
                                let title = title(forRemoteId: id)
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
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        remove(row)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        // One trigger, not two: a plain `.task` alongside `.task(id:)` runs the
        // whole fetch twice on appear.
        .task(id: reloadKey) {
            await reload()
        }
    }

    /// Changes whenever a download starts, finishes, or fails — each of those moves a
    /// song between the sections below.
    private var reloadKey: String {
        "\(downloadCenter.completedIds.count)-\(downloadCenter.workingIds.count)-\(downloadCenter.failedIds.count)"
    }

    /// Active and queued downloads with whatever metadata we have for them. `progress`
    /// is nil while a download waits behind the concurrency limit.
    private var activeEntries: [(row: DownloadedSongRow, progress: Double?)] {
        downloadCenter.workingIds.compactMap { id in
            guard let row = row(forRemoteId: id) else { return nil }
            return (row, downloadCenter.activeDownloads[id])
        }
        .sorted { $0.row.title < $1.row.title }
    }

    private func row(forRemoteId id: String) -> DownloadedSongRow? {
        downloadedRows.first { $0.remoteId == id } ?? inFlightRows[id]
    }

    private func title(forRemoteId id: String) -> String {
        row(forRemoteId: id)?.title ?? id
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let rows = await Self.fetchDownloaded()
        let pendingIds = downloadCenter.workingIds.union(downloadCenter.failedIds)
            .subtracting(rows.map(\.remoteId))
        let pending = pendingIds.isEmpty ? [:] : await Self.fetchRows(remoteIds: pendingIds)
        guard generation == loadGeneration else { return }
        downloadedRows = rows
        inFlightRows = pending
    }

    private static func fetchDownloaded() async -> [DownloadedSongRow] {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                // `relFilePath` is the stored column behind `isDownloadedLocally`; a
                // predicate cannot key-path into the computed property.
                let songs = try context.fetch(
                    FetchDescriptor<Song>(
                        predicate: #Predicate<Song> { $0.relFilePath != nil },
                        sortBy: [SortDescriptor(\Song.title)]
                    )
                )
                return songs.map(DownloadedSongRow.init)
            }
        } catch {
            return []
        }
    }

    private static func fetchRows(remoteIds: Set<String>) async -> [String: DownloadedSongRow] {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let ids = remoteIds
                let songs = try context.fetch(
                    FetchDescriptor<Song>(predicate: #Predicate<Song> { ids.contains($0.remoteId) })
                )
                return Dictionary(
                    songs.map { ($0.remoteId, DownloadedSongRow(song: $0)) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        } catch {
            return [:]
        }
    }

    private func play(_ row: DownloadedSongRow) {
        let items = downloadedRows.map(\.queueItem)
        let index = downloadedRows.firstIndex(where: { $0.id == row.id }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func remove(_ row: DownloadedSongRow) {
        let compoundId = row.id
        Task {
            guard let repository = VerodromeKit.shared.repository(),
                  let account = try? VerodromeKit.shared.activeAccount(),
                  let song = try? repository.resolveSong(remoteId: row.remoteId, account: account)
            else { return }
            await LibraryActions.shared.removeDownload(song: song)
            downloadedRows.removeAll { $0.id == compoundId }
        }
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
