import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistDetailView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Stable row ids so a playlist can hold the same song twice without ForEach collisions.
    @State private var entries: [PlaylistRowItem] = []
    @State private var showPlaylistSelector = false
    @State private var showRename = false
    @State private var artworkTint: ArtworkTint?
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<PlaylistRowItem.ID> = []
    @State private var reorderTask: Task<Void, Never>?
    @State private var isMutating = false

    init(playlistID: String) {
        self.playlistID = playlistID
        _playlists = Query(filter: #Predicate<Playlist> { $0.compoundRemoteId == playlistID })
    }

    /// Same fill as the Play button — colors the back chevron the way the album screen does.
    private var navigationTint: Color {
        (artworkTint ?? ArtworkTint(hue: 0, saturation: 0)).primaryButtonFill(for: colorScheme)
    }

    private var songs: [Song] { entries.map(\.song) }

    private var canEditPlaylist: Bool {
        guard let playlist = playlists.first else { return false }
        return playlist.isEditable
            && !playlist.isSmart
            && !LibraryActions.shared.playlistsRejectedByServer.contains(playlist.remoteId)
    }

    private var isEditing: Bool { editMode.isEditing && canEditPlaylist }

    var body: some View {
        List(selection: isEditing ? $selection : nil) {
            if let playlist = playlists.first {
                Section {
                    DetailHeader(
                        title: playlist.name,
                        subtitle: "\(playlist.songCount) songs",
                        artworkURL: playlist.displayArtworkToken,
                        tintToken: backgroundArtworkToken,
                        symbol: "music.note.house.fill",
                        onPlay: { play(shuffle: false) },
                        onShuffle: { play(shuffle: true) },
                        accessory: { playlistStatusBar }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .allowsHitTesting(!isEditing)

                Section("Songs") {
                    if entries.isEmpty {
                        Text(isMutating ? "Updating…" : "Loading songs…")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(entries) { entry in
                            songRow(entry)
                                // Opaque while editing so a lifted drag cell doesn't flash black
                                // over the artwork-tinted list background.
                                .listRowBackground(songRowBackground)
                                .listRowSeparator(.hidden)
                        }
                        .onMove(perform: isEditing ? moveEntries : nil)
                        .onDelete(perform: isEditing ? deleteEntries : nil)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .artworkTintedBackground(token: backgroundArtworkToken)
        .navigationBarTitleDisplayMode(.inline)
        .tint(navigationTint)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showPlaylistSelector) {
            PlaylistSelectorView { destination in
                let tracks = songs
                Task {
                    try? await LibraryActions.shared.addSongs(tracks, to: destination)
                    ActionToast.addedToPlaylist(destination.name)
                }
            }
        }
        .sheet(isPresented: $showRename) {
            NavigationStack {
                PlaylistEditView(playlistID: playlistID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showRename = false }
                        }
                    }
            }
        }
        .task(id: backgroundArtworkToken) {
            artworkTint = await ArtworkTintResolver.shared.tint(for: backgroundArtworkToken)
        }
        .task(id: playlists.first?.remoteId) {
            guard let playlist = playlists.first else { return }
            loadSongs(for: playlist)
            guard let remoteId = playlists.first?.remoteId else { return }
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(playlistId: remoteId)
            // Don't clobber an in-progress edit with the server pull.
            guard !isEditing, let playlist = playlists.first else { return }
            loadSongs(for: playlist)
        }
        .onChange(of: canEditPlaylist) { _, canEdit in
            if !canEdit {
                editMode = .inactive
                selection.removeAll()
            }
        }
        .onDisappear {
            flushReorderIfNeeded()
        }
    }

    @ViewBuilder
    private var songRowBackground: some View {
        if isEditing {
            Rectangle().fill(.background)
        } else {
            Color.clear
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func songRow(_ entry: PlaylistRowItem) -> some View {
        let song = entry.song
        Group {
            if isEditing {
                EntityRow(
                    title: song.title,
                    subtitle: song.displayArtist,
                    artworkURL: song.artworkToken,
                    isPlaying: nowPlaying.currentItem?.playableId == song.remoteId,
                    trailing: formatDuration(song.displayDuration),
                    downloadStatus: downloadCenter.status(
                        for: song.remoteId,
                        isDownloaded: song.isDownloadedLocally
                    )
                )
            } else {
                Button { playSong(song, entryId: entry.id) } label: {
                    EntityRow(
                        title: song.title,
                        subtitle: song.displayArtist,
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
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canEditPlaylist {
                if isEditing {
                    if !selection.isEmpty {
                        Button("Remove", role: .destructive) {
                            removeSelected()
                        }
                        .disabled(isMutating)
                    }
                    Button("Done") {
                        finishEditing()
                    }
                } else {
                    Button("Edit") {
                        withAnimation { editMode = .active }
                    }
                }
            }

            if let playlist = playlists.first, !isEditing {
                playlistOptionsMenu(for: playlist)
            }

            if canEditPlaylist, !isEditing {
                NavigationLink { PlaylistAddSongsView(playlistID: playlistID) } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Add Songs")
            }
        }
    }

    // MARK: - Status bar

    private var downloadSummary: SongsDownloadSummary {
        SongsDownloadSummary(songs: songs, center: downloadCenter)
    }

    private var isKeptDownloaded: Bool { playlists.first?.keepDownloaded ?? false }

    /// A playlist marked for download but with nothing transferring yet is waiting on the
    /// network, not idle — the summary alone can't tell those apart before the first
    /// enqueue lands, so the flag decides.
    private var downloadStatus: DownloadStatus {
        let summary = downloadSummary
        if isKeptDownloaded, summary.status == .none { return .waiting }
        return summary.status
    }

    /// Playlists have no favorite/rating in the library model yet, so this bar is the
    /// download control alone — same slot as the album's right-hand cluster.
    private var playlistStatusBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Button {
                togglePlaylistDownload()
            } label: {
                DownloadStatusIcon(status: downloadStatus, size: 22, showsIdleAffordance: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(songs.isEmpty && !isKeptDownloaded)
            .accessibilityLabel(downloadActionTitle)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Options menu

    private func playlistOptionsMenu(for playlist: Playlist) -> some View {
        Menu {
            if canEditPlaylist {
                Button {
                    showRename = true
                } label: {
                    Label("Edit Name", systemImage: "pencil")
                }
                Divider()
            }

            Button {
                togglePlaylistDownload()
            } label: {
                Label(downloadActionTitle, systemImage: downloadActionSymbol)
            }
            .disabled(songs.isEmpty && !isKeptDownloaded)

            if isKeptDownloaded {
                Text(downloadStateDescription)
            }

            Divider()

            Button {
                player.addToQueueTemporarily(songs.map(QueueItem.from))
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            .disabled(songs.isEmpty)

            Button {
                showPlaylistSelector = true
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(songs.isEmpty)

            ShareLink(item: playlist.name) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            // Match the album options control: centered ellipsis that inherits the
            // artwork navigation tint with the back chevron.
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
    }

    /// The control is a switch now, so it names the action either way rather than
    /// reporting how far a one-off batch has got. Progress goes in the line below it.
    private var downloadActionTitle: String {
        isKeptDownloaded ? "Remove Downloads" : "Download Playlist"
    }

    private var downloadStateDescription: String {
        let summary = downloadSummary
        if summary.isWaiting { return "Waiting for Wi-Fi — \(summary.waiting) songs" }
        if summary.isWorking { return "Downloading — \(summary.remaining) left" }
        return "Songs added to this playlist download automatically."
    }

    private var downloadActionSymbol: String {
        isKeptDownloaded ? "trash" : "arrow.down.circle"
    }

    private func togglePlaylistDownload() {
        guard let playlist = playlists.first else { return }
        let keep = !playlist.keepDownloaded
        Task { await LibraryActions.shared.setKeepDownloaded(keep, for: playlist) }
    }

    // MARK: - Edit mutations

    private func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        scheduleReorderCommit()
    }

    private func deleteEntries(at offsets: IndexSet) {
        remove(at: offsets)
    }

    private func removeSelected() {
        let offsets = IndexSet(entries.indices.filter { selection.contains(entries[$0].id) })
        remove(at: offsets)
    }

    private func remove(at offsets: IndexSet) {
        guard let playlist = playlists.first, !offsets.isEmpty else { return }
        let indices = Array(offsets)
        entries.remove(atOffsets: offsets)
        selection.removeAll()
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await LibraryActions.shared.removeSongs(at: indices, from: playlist)
                if let playlist = playlists.first {
                    loadSongs(for: playlist)
                }
            } catch {
                if let playlist = playlists.first {
                    loadSongs(for: playlist)
                }
                if LibraryActions.shared.notePlaylistEditRejected(playlist, error: error) {
                    ActionToast.show("\(playlist.name) can't be edited")
                    editMode = .inactive
                } else {
                    ActionToast.show("Couldn't remove from \(playlist.name)")
                }
            }
        }
    }

    private func finishEditing() {
        withAnimation {
            editMode = .inactive
            selection.removeAll()
        }
        flushReorderIfNeeded()
    }

    private func scheduleReorderCommit() {
        guard playlists.first != nil else { return }
        let ordered = entries.map(\.song)
        reorderTask?.cancel()
        reorderTask = Task {
            // Coalesce rapid drag adjustments — both backends clear then re-add.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await commitReorder(songs: ordered)
        }
    }

    /// Sends any outstanding local order to the server. Used after the debounce window
    /// and when leaving edit mode so a final drag isn't abandoned.
    private func flushReorderIfNeeded() {
        reorderTask?.cancel()
        guard let playlist = playlists.first else { return }
        let ordered = entries.map(\.song)
        let currentIds = playlist.items
            .sorted { $0.order < $1.order }
            .compactMap { $0.song?.remoteId }
        guard currentIds != ordered.map(\.remoteId) else { return }
        Task { await commitReorder(songs: ordered) }
    }

    private func commitReorder(songs ordered: [Song]) async {
        guard let playlist = playlists.first else { return }
        do {
            try await LibraryActions.shared.reorderPlaylist(playlist, songs: ordered)
            guard !isEditing, let playlist = playlists.first else { return }
            loadSongs(for: playlist)
        } catch {
            if let playlist = playlists.first {
                loadSongs(for: playlist)
            }
            if LibraryActions.shared.notePlaylistEditRejected(playlist, error: error) {
                ActionToast.show("\(playlist.name) can't be edited")
                editMode = .inactive
            } else {
                ActionToast.show("Couldn't reorder \(playlist.name)")
            }
        }
    }

    // MARK: - Playback

    /// Prefer the playlist's own cover; fall back to the first song so the
    /// screen still gets an artwork-derived tint when the playlist has no art.
    private var backgroundArtworkToken: String? {
        if let token = playlists.first?.artworkToken, !token.isEmpty { return token }
        return songs.first?.artworkToken
    }

    private func loadSongs(for playlist: Playlist) {
        let ordered = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        entries = ordered.map { PlaylistRowItem(song: $0) }
    }

    private func play(shuffle: Bool) {
        player.play(items: songs.map(QueueItem.from), shuffle: shuffle)
    }

    private func playSong(_ song: Song, entryId: PlaylistRowItem.ID) {
        let items = songs.map(QueueItem.from)
        let index = entries.firstIndex(where: { $0.id == entryId }) ?? 0
        player.play(items: items, startAt: index)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// One playlist entry in the detail list. UUID identity keeps duplicate tracks distinct.
private struct PlaylistRowItem: Identifiable, Hashable {
    let id: UUID
    let song: Song

    init(id: UUID = UUID(), song: Song) {
        self.id = id
        self.song = song
    }

    static func == (lhs: PlaylistRowItem, rhs: PlaylistRowItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
