import SwiftUI
import SwiftData
import VerodromeKit

struct DownloadsView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var shuffle: ShuffleAllCoordinator
    @EnvironmentObject private var router: AppRouter

    @State private var albumRows: [DownloadedAlbumRow] = []
    @State private var downloadedRows: [DownloadedSongRow] = []
    /// Titles for songs that are downloading but not on disk yet, so the in-progress
    /// section can name a track the downloaded list has never seen.
    @State private var inFlightRows: [String: DownloadedSongRow] = [:]
    /// remoteId → row for O(1) in-progress / waiting / failed lookups.
    @State private var songRowByRemoteId: [String: DownloadedSongRow] = [:]
    /// album compound id → song row ids (select cascade).
    @State private var songsByAlbumId: [String: Set<String>] = [:]
    /// song row id → album compound id (select cascade).
    @State private var albumIdBySongId: [String: String] = [:]

    /// Membership snapshots — updated on `activityEpoch`, not progress ticks.
    @State private var workingIds: Set<String> = []
    @State private var deferredIds: Set<String> = []
    @State private var failedIds: Set<String> = []
    @State private var completedCount = 0

    @State private var selectedAlbumId: String?
    @State private var loadGeneration = 0
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    /// False until the first library fetch finishes.
    @State private var hasLoadedOnce = false
    @State private var showRemoveConfirm = false

    private var hasLibraryContent: Bool {
        !albumRows.isEmpty || !downloadedRows.isEmpty
    }

    private var isSelecting: Bool {
        editMode.isEditing && hasLibraryContent
    }

    private var isEmpty: Bool {
        !hasLibraryContent
            && workingIds.isEmpty
            && deferredIds.isEmpty
            && failedIds.isEmpty
    }

    private var allSelectableIds: Set<String> {
        Set(albumRows.map(\.id)).union(downloadedRows.map(\.id))
    }

    private var isAllSelected: Bool {
        !allSelectableIds.isEmpty && allSelectableIds.isSubset(of: selection)
    }

    private var selectedSongRows: [DownloadedSongRow] {
        downloadedRows.filter { selection.contains($0.id) }
    }

    private var removeConfirmTitle: String {
        let count = selectedSongRows.count
        return count == 1 ? "Remove Download?" : "Remove \(count) Downloads?"
    }

    private var removeConfirmMessage: String {
        let count = selectedSongRows.count
        if count == 1, let title = selectedSongRows.first?.title {
            return "“\(title)” will be deleted from this device. You can download it again later."
        }
        return "\(count) songs will be deleted from this device. You can download them again later."
    }

    var body: some View {
        Group {
            if !hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Songs you download for offline listening appear here.")
                )
            } else {
                List {
                    if hasLibraryContent {
                        Section {
                            LibraryShuffleCountBar(
                                count: albumRows.count,
                                noun: "album",
                                secondaryCount: downloadedRows.count,
                                secondaryNoun: "song",
                                isShuffleBusy: shuffle.isStarting,
                                isShuffleDisabled: downloadedRows.isEmpty || isSelecting,
                                onShuffle: shuffleDownloaded
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }

                    // Observes `activeDownloads` in isolation so progress ticks don't
                    // rebuild the album / song sections.
                    DownloadsInProgressSection(
                        workingIds: workingIds,
                        rowsByRemoteId: songRowByRemoteId
                    )

                    if !waitingRows.isEmpty {
                        Section {
                            ForEach(waitingRows, id: \.id) { row in
                                EntityRow(
                                    title: row.title,
                                    subtitle: row.subtitle,
                                    artworkURL: row.artworkToken,
                                    downloadStatus: .waiting
                                )
                            }
                        } header: {
                            Text("Waiting for Wi-Fi")
                        } footer: {
                            Text("These start once you're on Wi-Fi. Change this under Settings › Library › Downloads.")
                        }
                    }

                    if !failedIds.isEmpty {
                        Section("Failed") {
                            ForEach(Array(failedIds).sorted(), id: \.self) { id in
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

                    if !albumRows.isEmpty {
                        Section("Albums") {
                            ForEach(albumRows) { row in
                                albumRow(row)
                            }
                        }
                    }

                    if !downloadedRows.isEmpty {
                        Section("Songs") {
                            ForEach(downloadedRows) { row in
                                songRow(row)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Downloads")
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .toolbar { toolbarContent }
        .alert(
            removeConfirmTitle,
            isPresented: $showRemoveConfirm
        ) {
            Button("Remove", role: .destructive) {
                removeSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
        .onChange(of: hasLibraryContent) { _, hasContent in
            if !hasContent {
                finishSelecting()
            }
        }
        .onReceive(DownloadCenter.shared.$activityEpoch) { _ in
            syncDownloadMembership()
        }
        .onAppear {
            syncDownloadMembership()
        }
        // One trigger, not two: a plain `.task` alongside `.task(id:)` runs the
        // whole fetch twice on appear.
        .task(id: reloadKey) {
            await reload()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func albumRow(_ row: DownloadedAlbumRow) -> some View {
        let content = EntityRow(
            title: row.title,
            subtitle: row.subtitle,
            artworkURL: row.artworkToken,
            symbol: "square.stack.fill",
            downloadStatus: albumDownloadStatus(for: row)
        )
        if isSelecting {
            Button {
                toggleAlbum(row)
            } label: {
                selectableRow(isSelected: selection.contains(row.id)) {
                    content
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                selectedAlbumId = row.id
            } label: {
                content
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func songRow(_ row: DownloadedSongRow) -> some View {
        let content = EntityRow(
            title: row.title,
            subtitle: row.subtitle,
            artworkURL: row.artworkToken,
            isPlaying: nowPlaying.currentItem?.playableId == row.remoteId,
            trailing: row.durationText
        )
        if isSelecting {
            Button {
                toggleSong(row)
            } label: {
                selectableRow(isSelected: selection.contains(row.id)) {
                    content
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                play(row)
            } label: {
                content
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

    private func selectableRow<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            content()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button(isAllSelected ? "Deselect All" : "Select All") {
                    if isAllSelected {
                        selection.removeAll()
                    } else {
                        selection = allSelectableIds
                    }
                }
                if !selection.isEmpty {
                    Button("Remove", role: .destructive) {
                        showRemoveConfirm = true
                    }
                }
                Button("Done") {
                    finishSelecting()
                }
            } else {
                // Always present so the trailing slot doesn't pop in after the first fetch.
                Button("Select") {
                    withAnimation { editMode = .active }
                }
                .disabled(!hasLibraryContent)
            }
        }
    }

    /// Changes whenever a download starts, finishes, or fails — each of those moves a
    /// song between the sections below. Progress ticks do not change this key.
    private var reloadKey: String {
        "\(completedCount)-\(workingIds.count)-\(failedIds.count)-\(deferredIds.count)"
    }

    /// Downloads parked until Wi-Fi. They have no file yet, so the metadata comes from
    /// the same in-flight lookup the In Progress section uses.
    private var waitingRows: [DownloadedSongRow] {
        deferredIds
            .compactMap { songRowByRemoteId[$0] }
            .sorted { $0.title < $1.title }
    }

    private func title(forRemoteId id: String) -> String {
        songRowByRemoteId[id]?.title ?? id
    }

    /// Membership-only album glyph — no live progress rings (those stay in In Progress).
    private func albumDownloadStatus(for row: DownloadedAlbumRow) -> DownloadStatus {
        // In-flight / deferred / failed remotes aren't always in `songRemoteIds` (that
        // list is only what's already on disk). Map through the remoteId index instead;
        // those sets stay small so scanning them per album is cheap.
        if workingIds.contains(where: { songRowByRemoteId[$0]?.albumId == row.id }) {
            return .pending
        }
        if deferredIds.contains(where: { songRowByRemoteId[$0]?.albumId == row.id }) {
            return .waiting
        }
        let downloaded = row.downloadedSongIds.count
        if downloaded > 0, downloaded >= row.trackTotal {
            return .downloaded
        }
        if downloaded > 0, downloaded < row.trackTotal {
            return .partial
        }
        if failedIds.contains(where: { songRowByRemoteId[$0]?.albumId == row.id }) {
            return .failed
        }
        return downloaded > 0 ? .downloaded : .none
    }

    private func syncDownloadMembership() {
        let center = DownloadCenter.shared
        workingIds = center.workingIds
        deferredIds = center.deferredIds
        failedIds = center.failedIds
        completedCount = center.completedIds.count
    }

    private func shuffleDownloaded() {
        Task {
            if await shuffle.shuffleDownloaded() {
                router.openPlayer()
            }
        }
    }

    private func finishSelecting() {
        withAnimation {
            editMode = .inactive
            selection.removeAll()
        }
    }

    // MARK: - Selection cascade

    private func toggleAlbum(_ album: DownloadedAlbumRow) {
        var next = selection
        let songIds = songsByAlbumId[album.id] ?? []
        if next.contains(album.id) {
            next.remove(album.id)
            next.subtract(songIds)
        } else {
            next.insert(album.id)
            next.formUnion(songIds)
        }
        selection = next
    }

    private func toggleSong(_ song: DownloadedSongRow) {
        var next = selection
        if next.contains(song.id) {
            next.remove(song.id)
            // Unchecking any song clears its album checkmark; siblings stay selected.
            if let albumId = albumIdBySongId[song.id] {
                next.remove(albumId)
            }
        } else {
            next.insert(song.id)
        }
        selection = next
    }

    private func rebuildSelectionMaps() {
        var byAlbum: [String: Set<String>] = [:]
        var albumBySong: [String: String] = [:]
        byAlbum.reserveCapacity(albumRows.count)
        albumBySong.reserveCapacity(downloadedRows.count)
        for song in downloadedRows {
            guard let albumId = song.albumId else { continue }
            byAlbum[albumId, default: []].insert(song.id)
            albumBySong[song.id] = albumId
        }
        songsByAlbumId = byAlbum
        albumIdBySongId = albumBySong
    }

    private func rebuildRemoteIdIndex() {
        var index: [String: DownloadedSongRow] = [:]
        index.reserveCapacity(downloadedRows.count + inFlightRows.count)
        for row in downloadedRows {
            index[row.remoteId] = row
        }
        for (remoteId, row) in inFlightRows {
            index[remoteId] = row
        }
        songRowByRemoteId = index
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let fetched = await Self.fetchDownloadedLibrary()
        let center = DownloadCenter.shared
        let pendingIds = center.workingIds
            .union(center.failedIds)
            .union(center.deferredIds)
            .subtracting(fetched.songs.map(\.remoteId))
        let pending = pendingIds.isEmpty ? [:] : await Self.fetchRows(remoteIds: pendingIds)
        guard generation == loadGeneration else { return }
        albumRows = fetched.albums
        downloadedRows = fetched.songs
        inFlightRows = pending
        rebuildSelectionMaps()
        rebuildRemoteIdIndex()
        hasLoadedOnce = true
        // Drop selection IDs that no longer exist after a background reload.
        let valid = allSelectableIds
        selection = selection.intersection(valid)
    }

    private static func fetchDownloadedLibrary() async -> (
        albums: [DownloadedAlbumRow],
        songs: [DownloadedSongRow]
    ) {
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

                // Group downloaded songs by album without faulting `album.songs`.
                var albumMeta: [String: Album] = [:]
                var downloadedRemoteIdsByAlbum: [String: Set<String>] = [:]
                var songRows: [DownloadedSongRow] = []
                songRows.reserveCapacity(songs.count)

                for song in songs {
                    let album = song.album
                    let albumId = album?.compoundRemoteId
                    songRows.append(DownloadedSongRow(song: song, albumId: albumId))
                    guard let album, let albumId else { continue }
                    albumMeta[albumId] = album
                    downloadedRemoteIdsByAlbum[albumId, default: []].insert(song.remoteId)
                }

                let albumRows = albumMeta.map { albumId, album -> DownloadedAlbumRow in
                    let downloadedIds = downloadedRemoteIdsByAlbum[albumId] ?? []
                    let downloadedList = Array(downloadedIds)
                    return DownloadedAlbumRow(
                        id: albumId,
                        title: album.title,
                        // Prefer the denormalized column so a missing artist
                        // relationship doesn't fault every album during the map.
                        subtitle: album.artistName ?? "Unknown Artist",
                        artworkToken: album.artworkToken,
                        // Only the downloaded tracks we already loaded — not the full
                        // album relationship, which can be much larger on partial albums.
                        songRemoteIds: downloadedList,
                        downloadedSongIds: downloadedIds,
                        trackTotal: max(album.trackCount, downloadedIds.count)
                    )
                }
                .sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }

                return (albumRows, songRows)
            }
        } catch {
            return ([], [])
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
        player.play(items: items, startAt: index, origin: .song(row.title))
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
            albumRows = albumRows.compactMap { album in
                var next = album
                next.downloadedSongIds.remove(row.remoteId)
                next.songRemoteIds.removeAll { $0 == row.remoteId }
                return next.downloadedSongIds.isEmpty ? nil : next
            }
            rebuildSelectionMaps()
            rebuildRemoteIdIndex()
        }
    }

    private func removeSelected() {
        let selectedSongs = selectedSongRows
        guard !selectedSongs.isEmpty else { return }
        let remoteIds = Set(selectedSongs.map(\.remoteId))
        let compoundIds = Set(selectedSongs.map(\.id))

        Task {
            guard let repository = VerodromeKit.shared.repository(),
                  let account = try? VerodromeKit.shared.activeAccount()
            else { return }
            let songs = selectedSongs.compactMap { row in
                try? repository.resolveSong(remoteId: row.remoteId, account: account)
            }
            await LibraryActions.shared.removeDownloads(songs: songs)

            downloadedRows.removeAll { compoundIds.contains($0.id) }
            albumRows = albumRows.compactMap { album in
                var next = album
                next.downloadedSongIds.subtract(remoteIds)
                next.songRemoteIds.removeAll { remoteIds.contains($0) }
                return next.downloadedSongIds.isEmpty ? nil : next
            }
            rebuildSelectionMaps()
            rebuildRemoteIdIndex()
            selection.removeAll()
            if albumRows.isEmpty && downloadedRows.isEmpty {
                editMode = .inactive
            }
        }
    }
}

/// Live progress for active transfers only — observing `DownloadCenter` here keeps
/// progress ticks from invalidating the rest of `DownloadsView`.
private struct DownloadsInProgressSection: View {
    let workingIds: Set<String>
    let rowsByRemoteId: [String: DownloadedSongRow]

    @ObservedObject private var downloadCenter = DownloadCenter.shared

    private var entries: [(row: DownloadedSongRow, progress: Double?)] {
        workingIds.compactMap { id in
            guard let row = rowsByRemoteId[id] else { return nil }
            return (row, downloadCenter.activeDownloads[id])
        }
        .sorted { $0.row.title < $1.row.title }
    }

    var body: some View {
        if !entries.isEmpty {
            Section("In Progress") {
                ForEach(entries, id: \.row.id) { entry in
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
    }
}

struct DownloadedAlbumRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkToken: String?
    var songRemoteIds: [String]
    var downloadedSongIds: Set<String>
    let trackTotal: Int
}

struct DownloadedSongRow: Identifiable, Hashable, Sendable {
    let id: String
    let remoteId: String
    /// Album compound id when the song belongs to an album; drives select cascade.
    let albumId: String?
    let title: String
    let subtitle: String
    let artworkToken: String?
    let duration: TimeInterval
    let durationText: String

    init(song: Song, albumId: String? = nil) {
        id = song.compoundRemoteId
        remoteId = song.remoteId
        self.albumId = albumId ?? song.album?.compoundRemoteId
        title = song.title
        subtitle = song.displayArtist
        artworkToken = song.displayArtworkToken
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
