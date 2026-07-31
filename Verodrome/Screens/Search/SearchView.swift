import SwiftUI
import SwiftData
import VerodromeKit

struct SearchView: View {
    @StateObject private var history = SearchHistoryStore()
    @Query(sort: \Artist.name) private var artists: [Artist]
    @Query(sort: \Album.title) private var albums: [Album]
    @Query(sort: \Song.title) private var songs: [Song]
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var searchText = ""
    @State private var remoteTask: Task<Void, Never>?
    @State private var isRemoteSearching = false

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
                if !filteredArtists.isEmpty {
                    Section("Artists") {
                        ForEach(filteredArtists, id: \.compoundRemoteId) { artist in
                            NavigationLink {
                                ArtistDetailView(artistID: artist.compoundRemoteId)
                            } label: {
                                EntityRow(title: artist.name, subtitle: "Artist", artworkURL: artist.artworkToken, symbol: "person.fill")
                            }
                        }
                    }
                }
                if !filteredAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(filteredAlbums, id: \.compoundRemoteId) { album in
                            NavigationLink {
                                AlbumDetailView(albumID: album.compoundRemoteId)
                            } label: {
                                EntityRow(title: album.title, subtitle: album.displayArtist, artworkURL: album.artworkToken)
                            }
                        }
                    }
                }
                if !filteredSongs.isEmpty {
                    Section("Songs") {
                        ForEach(filteredSongs, id: \.compoundRemoteId) { song in
                            EntityRow(title: song.title, subtitle: song.displayArtist, artworkURL: song.album?.artworkToken)
                                .songActions(song)
                        }
                    }
                }
                if !filteredPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(filteredPlaylists, id: \.compoundRemoteId) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlistID: playlist.compoundRemoteId)
                            } label: {
                                EntityRow(
                                    title: playlist.name,
                                    subtitle: "Playlist",
                                    artworkURL: playlist.displayArtworkToken,
                                    symbol: "music.note.house.fill"
                                )
                            }
                        }
                    }
                }
                if !isRemoteSearching,
                   filteredArtists.isEmpty && filteredAlbums.isEmpty && filteredSongs.isEmpty && filteredPlaylists.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Artists, albums, songs…")
        .onSubmit(of: .search) {
            history.add(searchText)
            Task { await runRemoteSearch(for: searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            remoteTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                isRemoteSearching = false
                return
            }
            remoteTask = Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                await runRemoteSearch(for: trimmed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verodromePerformSearch)) { note in
            if let query = note.userInfo?["query"] as? String {
                searchText = query
                history.add(query)
                Task { await runRemoteSearch(for: query) }
            }
        }
    }

    private var filteredArtists: [Artist] {
        artists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredAlbums: [Album] {
        albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredSongs: [Song] {
        songs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredPlaylists: [Playlist] {
        playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
    }
}
