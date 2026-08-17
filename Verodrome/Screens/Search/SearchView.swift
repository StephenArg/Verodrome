import SwiftUI
import SwiftData
import VerodromeKit

struct SearchView: View {
    @StateObject private var history = SearchHistoryStore()
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var remoteTask: Task<Void, Never>?
    @State private var isRemoteSearching = false
    @State private var isLocalSearching = false

    @State private var artistRows: [LibraryRowSnapshot] = []
    @State private var albumRows: [LibraryRowSnapshot] = []
    @State private var songRows: [LibraryRowSnapshot] = []
    @State private var playlistRows: [LibraryRowSnapshot] = []
    @State private var loadGeneration = 0
    @State private var selectedArtistId: String?
    @State private var selectedAlbumId: String?
    @State private var selectedPlaylistId: String?
    @State private var showPlaylistSelector = false
    @State private var playlistSongs: [Song] = []

    private var hasResults: Bool {
        !artistRows.isEmpty || !albumRows.isEmpty || !songRows.isEmpty || !playlistRows.isEmpty
    }

    /// Debounce hasn't caught up yet, or the local fetch for the current query is in flight.
    private var isAwaitingLocalSearch: Bool {
        !searchText.isEmpty && (searchText != debouncedSearch || isLocalSearching)
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(
                prompt: "Artists, albums, songs…",
                text: $searchText,
                onSubmit: {
                    history.add(searchText)
                    Task { await runRemoteSearch(for: searchText) }
                }
            )
            List {
                if searchText.isEmpty {
                    if !history.terms.isEmpty {
                        Section {
                            ForEach(history.terms, id: \.self) { term in
                                RecentSearchRow(
                                    term: term,
                                    onSelect: { searchText = term },
                                    onDelete: { history.remove(term) }
                                )
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color(.systemBackground))
                            }
                        } header: {
                            HStack {
                                Text("Recent Searches")
                                Spacer()
                                Button("Clear") {
                                    history.clear()
                                }
                                .font(.subheadline)
                                .textCase(nil)
                            }
                        }
                    }
                } else {
                    if isRemoteSearching {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Searching server…").foregroundStyle(.secondary)
                            }
                            .listRowBackground(Color(.systemBackground))
                        }
                    } else if isAwaitingLocalSearch, !hasResults {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Searching…").foregroundStyle(.secondary)
                            }
                            .listRowBackground(Color(.systemBackground))
                        }
                    }
                    if !artistRows.isEmpty {
                        Section("Artists") {
                            ForEach(artistRows) { row in
                                Button { selectedArtistId = row.id } label: {
                                    EntityRow(title: row.title, subtitle: "Artist", artworkURL: row.artworkToken, symbol: "person.fill")
                                }
                                .buttonStyle(.plain)
                                .contextMenu { artistContextMenu(for: row) }
                                .listRowBackground(Color(.systemBackground))
                            }
                        }
                    }
                    if !albumRows.isEmpty {
                        Section("Albums") {
                            ForEach(albumRows) { row in
                                Button { selectedAlbumId = row.id } label: {
                                    EntityRow(
                                        title: row.title,
                                        subtitle: row.subtitle,
                                        artworkURL: row.artworkToken,
                                        downloadStatus: albumDownloadStatus(for: row)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { albumContextMenu(for: row) }
                                .listRowBackground(Color(.systemBackground))
                            }
                        }
                    }
                    if !songRows.isEmpty {
                        Section("Songs") {
                            ForEach(songRows) { row in
                                Button { play(row) } label: {
                                    EntityRow(
                                        title: row.title,
                                        subtitle: row.subtitle,
                                        artworkURL: row.artworkToken,
                                        isPlaying: nowPlaying.isCurrent(row.playableId)
                                    )
                                }
                                .buttonStyle(.plain)
                                .songActions(compoundRemoteId: row.id)
                                .listRowBackground(Color(.systemBackground))
                            }
                        }
                    }
                    if !playlistRows.isEmpty {
                        Section("Playlists") {
                            ForEach(playlistRows) { row in
                                Button { selectedPlaylistId = row.id } label: {
                                    EntityRow(
                                        title: row.title,
                                        subtitle: "Playlist",
                                        artworkURL: row.artworkToken,
                                        symbol: "music.note.house.fill"
                                    )
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color(.systemBackground))
                            }
                        }
                    }
                    if !isRemoteSearching,
                       !isAwaitingLocalSearch,
                       !hasResults {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color(.systemBackground))
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Search")
        .debouncedSearch(text: $searchText, delay: .milliseconds(300)) { newValue in
            debouncedSearch = newValue
            history.add(newValue)
        }
        .navigationDestination(item: $selectedArtistId) { ArtistDetailView(artistID: $0) }
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .navigationDestination(item: $selectedPlaylistId) { PlaylistDetailView(playlistID: $0) }
        .sheet(isPresented: $showPlaylistSelector) {
            PlaylistSelectorView { playlist in
                let songs = playlistSongs
                Task {
                    try? await LibraryActions.shared.addSongs(songs, to: playlist)
                    ActionToast.addedToPlaylist(playlist.name)
                }
            }
        }
        .task(id: debouncedSearch) {
            await reload()
        }
        .task(id: librarySync.isSyncing) {
            if !librarySync.isSyncing {
                await reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verodromePerformSearch)) { note in
            if let query = note.userInfo?["query"] as? String {
                searchText = query
                debouncedSearch = query
                history.add(query)
                Task { await runRemoteSearch(for: query) }
            }
        }
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let search = debouncedSearch
        guard !search.isEmpty else {
            isLocalSearching = false
            artistRows = []
            albumRows = []
            songRows = []
            playlistRows = []
            return
        }
        isLocalSearching = true
        defer {
            if generation == loadGeneration {
                isLocalSearching = false
            }
        }
        let built = await Self.fetch(searchText: search)
        guard generation == loadGeneration else { return }
        artistRows = built.artists
        albumRows = built.albums
        songRows = built.songs
        playlistRows = built.playlists
    }

    private static func fetch(searchText: String) async -> (artists: [LibraryRowSnapshot], albums: [LibraryRowSnapshot], songs: [LibraryRowSnapshot], playlists: [LibraryRowSnapshot]) {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let artists = try context.fetch(FetchDescriptor<Artist>(sortBy: [SortDescriptor(\Artist.name)]))
                    .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                    .map { LibraryRowSnapshot(id: $0.compoundRemoteId, sectionKey: $0.name.sectionInitial, title: $0.name, subtitle: "Artist", artworkToken: $0.artworkToken, symbol: "person.fill") }

                let albums = try context.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\Album.title)]))
                    .filter {
                        $0.title.localizedCaseInsensitiveContains(searchText)
                            || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
                    }
                    .map { album -> LibraryRowSnapshot in
                        let songs = album.songs
                        return LibraryRowSnapshot(
                            id: album.compoundRemoteId,
                            sectionKey: album.title.sectionInitial,
                            title: album.title,
                            subtitle: album.displayArtist,
                            artworkToken: album.artworkToken,
                            songRemoteIds: songs.map(\.remoteId),
                            downloadedSongIds: Set(songs.compactMap { $0.relFilePath != nil ? $0.remoteId : nil }),
                            trackTotal: max(album.trackCount, songs.count)
                        )
                    }

                let songs = try context.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\Song.title)]))
                    .filter {
                        $0.title.localizedCaseInsensitiveContains(searchText)
                            || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
                    }
                    .map {
                        LibraryRowSnapshot(
                            id: $0.compoundRemoteId,
                            sectionKey: $0.title.sectionInitial,
                            title: $0.title,
                            subtitle: $0.displayArtist,
                            artworkToken: $0.displayArtworkToken,
                            playableId: $0.remoteId
                        )
                    }

                let playlists = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\Playlist.name)]))
                    .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                    .map { LibraryRowSnapshot(id: $0.compoundRemoteId, sectionKey: $0.name.sectionInitial, title: $0.name, subtitle: "Playlist", artworkToken: $0.artworkToken, symbol: "music.note.house.fill") }

                return (artists, albums, songs, playlists)
            }
        } catch {
            return ([], [], [], [])
        }
    }

    private func albumDownloadStatus(for row: LibraryRowSnapshot) -> DownloadStatus {
        SongsDownloadSummary(
            songRemoteIds: row.songRemoteIds,
            downloadedIds: row.downloadedSongIds,
            trackTotal: row.trackTotal,
            center: downloadCenter
        ).status
    }

    // MARK: - Context menus

    @ViewBuilder
    private func artistContextMenu(for row: LibraryRowSnapshot) -> some View {
        let artist = resolveArtist(compoundRemoteId: row.id)

        Button {
            playArtist(compoundRemoteId: row.id, shuffle: false)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(artist == nil)

        Button {
            playArtist(compoundRemoteId: row.id, shuffle: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(artist == nil)

        if let artist {
            ShareMenuButton(
                subject: ShareSubject(
                    resourceType: .artist,
                    resourceIds: [artist.remoteId],
                    title: artist.name,
                    subtitle: "\(max(artist.albumCount, artist.albums.count)) albums · \(max(artist.songCount, artist.songs.count)) songs",
                    artwork: (artist.artworkToken ?? artist.albums.first?.artworkToken)
                        .map { ArtworkRef(id: $0, kind: .artist) }
                )
            )
        }
    }

    @ViewBuilder
    private func albumContextMenu(for row: LibraryRowSnapshot) -> some View {
        let album = resolveAlbum(compoundRemoteId: row.id)
        let summary = SongsDownloadSummary(
            songRemoteIds: row.songRemoteIds,
            downloadedIds: row.downloadedSongIds,
            trackTotal: row.trackTotal,
            center: downloadCenter
        )

        Button {
            guard let album else { return }
            Task {
                let liking = !album.isFavorite
                try? await LibraryActions.shared.toggleFavorite(album: album)
                ActionToast.songLiked(liking)
            }
        } label: {
            Label(
                album?.isFavorite == true ? "Unlike" : "Like",
                systemImage: album?.isFavorite == true ? "heart.slash" : "heart"
            )
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            Task { await addAlbumToQueue(album) }
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            shareAlbum(album)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(album == nil)

        Divider()

        Button {
            guard let album else { return }
            Task { await presentPlaylistSelector(for: album) }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            Task { await toggleAlbumDownload(album, summary: summary) }
        } label: {
            Label(
                albumDownloadActionTitle(for: summary),
                systemImage: albumDownloadActionSymbol(for: summary)
            )
        }
        .disabled(album == nil)
    }

    private func albumDownloadActionTitle(for summary: SongsDownloadSummary) -> String {
        if summary.isWorking || summary.isWaiting { return "Cancel Downloads" }
        if summary.isFullyDownloaded { return "Remove Downloads" }
        if summary.isPartiallyDownloaded { return "Download Remaining" }
        return "Download"
    }

    private func albumDownloadActionSymbol(for summary: SongsDownloadSummary) -> String {
        if summary.isWorking || summary.isWaiting { return "stop.circle" }
        if summary.isFullyDownloaded { return "trash" }
        return "arrow.down.circle"
    }

    private func shareAlbum(_ album: Album) {
        ShareComposer.present(
            ShareSubject(
                resourceType: .album,
                resourceIds: [album.remoteId],
                title: album.title,
                subtitle: album.artistName ?? "Unknown Artist",
                artwork: album.artworkToken.map { ArtworkRef(id: $0, kind: .album) }
            )
        )
    }

    private func addAlbumToQueue(_ album: Album) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        player.addToQueueTemporarily(
            songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) }
        )
    }

    private func presentPlaylistSelector(for album: Album) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        playlistSongs = songs
        showPlaylistSelector = true
    }

    private func toggleAlbumDownload(_ album: Album, summary: SongsDownloadSummary) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        if summary.isWorking || summary.isWaiting {
            await LibraryActions.shared.cancelDownloads(songs: songs)
        } else if summary.isFullyDownloaded {
            await LibraryActions.shared.removeDownloads(songs: songs)
        } else {
            await LibraryActions.shared.downloadRemaining(songs: songs)
        }
    }

    private func ensureSongs(for album: Album) async -> [Song] {
        var songs = sortedSongs(for: album)
        if songs.isEmpty {
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: album.remoteId)
            songs = sortedSongs(for: album)
        }
        return songs
    }

    private func sortedSongs(for album: Album) -> [Song] {
        album.songs.sorted {
            ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func resolveAlbum(compoundRemoteId: String) -> Album? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func resolveArtist(compoundRemoteId: String) -> Artist? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Artist>(
            predicate: #Predicate<Artist> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func playArtist(compoundRemoteId: String, shuffle: Bool) {
        guard let artist = resolveArtist(compoundRemoteId: compoundRemoteId) else { return }
        Task {
            var songs = sortedArtistSongs(artist)
            if songs.isEmpty {
                if let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() {
                    try? await syncer.sync(artistId: artist.remoteId)
                    let albums = resolveArtist(compoundRemoteId: compoundRemoteId)?.albums ?? artist.albums
                    for album in albums {
                        guard !Task.isCancelled else { return }
                        try? await syncer.sync(albumId: album.remoteId)
                    }
                }
                songs = resolveArtist(compoundRemoteId: compoundRemoteId).map(sortedArtistSongs) ?? []
            }
            let items = songs.map(QueueItem.from)
            guard !items.isEmpty else { return }
            player.play(items: items, shuffle: shuffle)
            router.openPlayer()
        }
    }

    private func sortedArtistSongs(_ artist: Artist) -> [Song] {
        artist.songs.sorted {
            ($0.albumTitle ?? "", $0.disc ?? 0, $0.track ?? 0)
                < ($1.albumTitle ?? "", $1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func play(_ row: LibraryRowSnapshot) {
        guard let start = songRows.firstIndex(where: { $0.id == row.id }) else { return }
        let end = min(start + 40, songRows.count)
        let windowIds = songRows[start..<end].map(\.id)
        let idSet = Set(windowIds)
        guard let songs = try? modelContext.fetch(
            FetchDescriptor<Song>(predicate: #Predicate<Song> { idSet.contains($0.compoundRemoteId) })
        ) else { return }
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.compoundRemoteId, $0) })
        let items = windowIds.compactMap { byId[$0].map(QueueItem.from) }
        guard !items.isEmpty else { return }
        // Explicitly unshuffled — same as Songs: a search hit is a request for that song,
        // then the ones after it in the result list.
        player.play(items: items, startAt: 0, shuffle: false)
        router.openPlayer()
    }

    @MainActor
    private func runRemoteSearch(for query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRemoteSearching = true
        defer { isRemoteSearching = false }

        guard let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer(),
              let repository = VerodromeKit.shared.repository(),
              let account = try? VerodromeKit.shared.activeAccount() else {
            return
        }

        async let remoteArtists = (try? await syncer.searchArtists(query: trimmed)) ?? []
        async let remoteAlbums = (try? await syncer.searchAlbums(query: trimmed)) ?? []
        async let remoteSongs = (try? await syncer.searchSongs(query: trimmed)) ?? []
        let (artistsResult, albumsResult, songsResult) = await (remoteArtists, remoteAlbums, remoteSongs)

        for item in artistsResult {
            _ = try? repository.getOrCreateArtist(remoteId: item.id, name: item.name, account: account)
        }
        for item in albumsResult {
            _ = try? repository.getOrCreateAlbum(
                remoteId: item.id,
                title: item.name,
                account: account
            )
        }
        for item in songsResult {
            let song = try? repository.getOrCreateSong(
                remoteId: item.id,
                title: item.title,
                account: account
            )
            song?.artistName = item.artistName
            song?.albumTitle = item.albumName
        }
        try? repository.save()
        let total = artistsResult.count + albumsResult.count + songsResult.count
        _ = try? repository.recordSearchHistory(account: account, query: trimmed, resultCount: total)
        history.add(trimmed)
        await reload()
    }
}

/// Keeps the search term on-screen: swipe left grows a red delete control from the trailing
/// edge instead of sliding the label off via `List` swipeActions.
private struct RecentSearchRow: View {
    let term: String
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var revealedWidth: CGFloat = 0

    private let deleteWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: 0) {
            Text(term)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    if revealedWidth > 0 {
                        withAnimation(.easeOut(duration: 0.2)) { revealedWidth = 0 }
                    } else {
                        onSelect()
                    }
                }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            .frame(width: revealedWidth, alignment: .trailing)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Ignore mostly-vertical drags so the List can still scroll.
                    guard abs(dx) > abs(dy) else { return }
                    revealedWidth = min(deleteWidth, max(0, -dx))
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) else {
                        withAnimation(.easeOut(duration: 0.2)) { revealedWidth = 0 }
                        return
                    }
                    let shouldOpen = -dx > deleteWidth * 0.45
                        || -value.predictedEndTranslation.width > deleteWidth
                    withAnimation(.easeOut(duration: 0.2)) {
                        revealedWidth = shouldOpen ? deleteWidth : 0
                    }
                    if -dx > deleteWidth * 1.35 {
                        onDelete()
                    }
                }
        )
    }
}
