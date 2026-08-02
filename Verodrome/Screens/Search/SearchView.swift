import SwiftUI
import SwiftData
import VerodromeKit

struct SearchView: View {
    @StateObject private var history = SearchHistoryStore()
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var remoteTask: Task<Void, Never>?
    @State private var isRemoteSearching = false

    @State private var artistRows: [LibraryRowSnapshot] = []
    @State private var albumRows: [LibraryRowSnapshot] = []
    @State private var songRows: [LibraryRowSnapshot] = []
    @State private var playlistRows: [LibraryRowSnapshot] = []
    @State private var loadGeneration = 0
    @State private var selectedArtistId: String?
    @State private var selectedAlbumId: String?
    @State private var selectedPlaylistId: String?

    var body: some View {
        List {
            if searchText.isEmpty {
                if !history.terms.isEmpty {
                    Section("Recent Searches") {
                        ForEach(history.terms, id: \.self) { term in
                            Button(term) { searchText = term }
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
                    }
                }
                if !artistRows.isEmpty {
                    Section("Artists") {
                        ForEach(artistRows) { row in
                            Button { selectedArtistId = row.id } label: {
                                EntityRow(title: row.title, subtitle: "Artist", artworkURL: row.artworkToken, symbol: "person.fill")
                            }
                            .buttonStyle(.plain)
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
                        }
                    }
                }
                if !songRows.isEmpty {
                    Section("Songs") {
                        ForEach(songRows) { row in
                            EntityRow(title: row.title, subtitle: row.subtitle, artworkURL: row.artworkToken)
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
                        }
                    }
                }
                if !isRemoteSearching,
                   artistRows.isEmpty && albumRows.isEmpty && songRows.isEmpty && playlistRows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Artists, albums, songs…")
        .debouncedSearch(text: $searchText, delay: .milliseconds(300)) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedArtistId) { ArtistDetailView(artistID: $0) }
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .navigationDestination(item: $selectedPlaylistId) { PlaylistDetailView(playlistID: $0) }
        .onSubmit(of: .search) {
            history.add(searchText)
            Task { await runRemoteSearch(for: searchText) }
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
            artistRows = []
            albumRows = []
            songRows = []
            playlistRows = []
            return
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
                    .map { LibraryRowSnapshot(id: $0.compoundRemoteId, sectionKey: $0.title.sectionInitial, title: $0.title, subtitle: $0.displayArtist, artworkToken: $0.artworkToken) }

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
