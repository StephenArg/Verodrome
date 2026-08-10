import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistDetailView: View {
    let playlistID: String
    @Query private var playlists: [Playlist]
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var downloadCenter = DownloadCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Stable row ids so a playlist can hold the same song twice without ForEach collisions.
    @State private var entries: [PlaylistRowItem] = []
    @State private var searchText = ""
    /// True once the in-header filter row has scrolled under the nav.
    @State private var isFilterOffScreen = false
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

    /// Distinct albums among loaded tracks. Partial until `entries` is filled — playlist
    /// metadata only carries a song count, not an album total.
    private var loadedAlbumCount: Int {
        var seen = Set<String>()
        for song in songs {
            if let id = song.album?.compoundRemoteId, !id.isEmpty {
                seen.insert(id)
            } else if let title = song.albumTitle, !title.isEmpty {
                seen.insert(title)
            }
        }
        return seen.count
    }

    /// Songs first (the playlist's unit), then albums once tracks have loaded —
    /// same ` · ` pairing as artist / genre headers.
    private func headerSubtitle(for playlist: Playlist) -> String {
        let songCount = max(playlist.songCount, entries.count)
        let songLabel = songCount == 1 ? "1 song" : "\(songCount) songs"
        let albums = loadedAlbumCount
        guard albums > 0 else { return songLabel }
        let albumLabel = albums == 1 ? "1 album" : "\(albums) albums"
        return "\(songLabel) · \(albumLabel)"
    }

    /// Local filter over the loaded playlist — same title/artist match as Add Songs.
    private var filterQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [PlaylistRowItem] {
        let query = filterQuery
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.song.title.localizedCaseInsensitiveContains(query)
                || $0.song.displayArtist.localizedCaseInsensitiveContains(query)
        }
    }

    private var canEditPlaylist: Bool {
        guard let playlist = playlists.first else { return false }
        return playlist.isEditable
            && !playlist.isSmart
            && !LibraryActions.shared.playlistsRejectedByServer.contains(playlist.remoteId)
    }

    private var isEditing: Bool { editMode.isEditing && canEditPlaylist }

    /// Pin a copy under the nav only after the in-header bar has scrolled away — and
    /// only while it still holds a query, so filtered results stay explainable.
    private var showsStickyFilterBar: Bool { !searchText.isEmpty && isFilterOffScreen }

    var body: some View {
        List(selection: isEditing ? $selection : nil) {
            if let playlist = playlists.first {
                Section {
                    DetailHeader(
                        title: playlist.name,
                        subtitle: headerSubtitle(for: playlist),
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
                    } else if filteredEntries.isEmpty {
                        Text("No Matching Songs")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredEntries) { entry in
                            songRow(entry)
                                // Opaque while editing so a lifted drag cell doesn't flash black
                                // over the artwork-tinted list background.
                                .listRowBackground(songRowBackground)
                                .listRowSeparator(.hidden)
                        }
                        // Reorder/delete need the full playlist order; hide while filtered.
                        .onMove(perform: isEditing && filterQuery.isEmpty ? moveEntries : nil)
                        .onDelete(perform: isEditing && filterQuery.isEmpty ? deleteEntries : nil)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .artworkTintedBackground(token: backgroundArtworkToken)
        .detailCollapsingNavTitle(playlists.first?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .tint(navigationTint)
        .toolbar { toolbarContent }
        // Overlay (not safeAreaInset) so pinning doesn't shove list content and
        // feedback into the scroll offset the moment the bar appears.
        .overlay(alignment: .top) {
            if showsStickyFilterBar {
                playlistStatusBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsStickyFilterBar)
        .onDetailListScrollOffset(handleScroll)
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
            artworkTint = await ArtworkTintResolver.shared.tint(for: nil, token: backgroundArtworkToken)
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
                PlaylistOptionsMenuButton(
                    canEdit: canEditPlaylist,
                    isKeptDownloaded: playlist.keepDownloaded,
                    hasSongs: !entries.isEmpty,
                    shareSubject: ShareSubject(
                        resourceType: .playlist,
                        resourceIds: [playlist.remoteId],
                        title: playlist.name,
                        subtitle: entries.count == 1 ? "1 song" : "\(entries.count) songs",
                        artwork: playlist.artworkToken.map { ArtworkRef(id: $0, kind: .playlist) }
                    ),
                    onRename: { showRename = true },
                    onToggleDownload: togglePlaylistDownload,
                    onAddToQueue: {
                        player.addToQueueTemporarily(songs.map(QueueItem.from))
                    },
                    onAddToPlaylist: { showPlaylistSelector = true }
                )
                .equatable()
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

    /// Filter field plus download control — same accessory slot as the album's
    /// rating / download / favorite cluster. The field matches the Songs list.
    private var playlistStatusBar: some View {
        HStack(spacing: 12) {
            LibraryFilterBar(
                prompt: "Filter songs",
                text: $searchText,
                showsOuterPadding: false
            )

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

    /// Pin only once the in-header filter has cleared the top of the list. Keyboard
    /// focus can nudge offset by tens of points — thresholds sit past the accessory
    /// itself so typing never flips this.
    private func handleScroll(_ offset: CGFloat) {
        let pinAt = DetailHeaderMetrics.accessoryTopDistance + 24
        let unpinAt = DetailHeaderMetrics.accessoryTopDistance - 8
        let shouldPin = isFilterOffScreen ? offset > unpinAt : offset > pinAt
        guard shouldPin != isFilterOffScreen else { return }
        isFilterOffScreen = shouldPin
    }

    private var downloadActionTitle: String {
        isKeptDownloaded ? "Remove Downloads" : "Download Playlist"
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
        let items = songs.map(QueueItem.from)
        guard !items.isEmpty else { return }
        player.play(items: items, shuffle: shuffle)
        router.openPlayer()
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

/// Isolated from `DownloadCenter` updates: the playlist screen observes download
/// progress for row badges, and rebuilding this `Menu` on every tick made its labels
/// pulse. `.equatable()` skips those refreshes when the menu's inputs haven't changed.
private struct PlaylistOptionsMenuButton: View, Equatable {
    let canEdit: Bool
    let isKeptDownloaded: Bool
    let hasSongs: Bool
    let shareSubject: ShareSubject
    let onRename: () -> Void
    let onToggleDownload: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canEdit == rhs.canEdit
            && lhs.isKeptDownloaded == rhs.isKeptDownloaded
            && lhs.hasSongs == rhs.hasSongs
            && lhs.shareSubject == rhs.shareSubject
    }

    var body: some View {
        Menu {
            if canEdit {
                Button(action: onRename) {
                    Label("Edit Name", systemImage: "pencil")
                }
                Divider()
            }

            Button(action: onToggleDownload) {
                Label(
                    isKeptDownloaded ? "Remove Downloads" : "Download Playlist",
                    systemImage: isKeptDownloaded ? "trash" : "arrow.down.circle"
                )
            }
            .disabled(!hasSongs && !isKeptDownloaded)

            if isKeptDownloaded {
                Text("Songs added to this playlist download automatically.")
            }

            Divider()

            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "text.append")
            }
            .disabled(!hasSongs)

            Button(action: onAddToPlaylist) {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(!hasSongs)

            ShareMenuButton(subject: shareSubject)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
    }
}
