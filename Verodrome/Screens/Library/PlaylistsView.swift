import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistsView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var sections: [LibraryRowSection<LibraryRowSnapshot>] = []
    @State private var rowCount = 0
    @State private var loadGeneration = 0
    @State private var selectedId: String?

    var body: some View {
        IndexedEntityTableView(
            sections: sections,
            playingId: nowPlaying.currentItem?.playableId,
            onSelect: { item, _ in selectedId = item.id }
        )
        .navigationTitle("Playlists")
        .searchable(text: $searchText, prompt: "Filter playlists")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedId) { id in
            PlaylistDetailView(playlistID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistEditView(playlistID: nil) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .perfAppear("Playlists", details: "count=\(rowCount)")
        .task {
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.syncPlaylistCatalog()
            await reload(reason: "appear")
        }
        .task(id: debouncedSearch) {
            await reload(reason: "search")
        }
        .task(id: librarySync.isSyncing) {
            if !librarySync.isSyncing {
                await reload(reason: "syncFinished")
            }
        }
        .refreshable {
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.syncPlaylistCatalog()
            await reload(reason: "pullToRefresh")
        }
    }

    private func reload(reason: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        let search = debouncedSearch
        let built = await Self.fetchSections(searchText: search)
        guard generation == loadGeneration else { return }
        sections = built.sections
        rowCount = built.count
    }

    private static func fetchSections(searchText: String) async -> (sections: [LibraryRowSection<LibraryRowSnapshot>], count: Int) {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let playlists = try context.fetch(
                    FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\Playlist.sortName)])
                )
                let filtered: [Playlist]
                if searchText.isEmpty {
                    filtered = playlists
                } else {
                    filtered = playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                }
                let snapshots = filtered.map { playlist in
                    LibraryRowSnapshot(
                        id: playlist.compoundRemoteId,
                        sectionKey: (playlist.sortName.isEmpty ? playlist.name : playlist.sortName).sectionInitial,
                        title: playlist.name,
                        subtitle: playlist.isSmart
                            ? "Smart · \(playlist.songCount) songs"
                            : "\(playlist.songCount) songs",
                        artworkToken: playlist.artworkToken,
                        symbol: "music.note.house.fill"
                    )
                }
                let grouped = AlphabetSectioning.group(snapshots) { $0.sectionKey }
                let sections = grouped.map { LibraryRowSection(letter: $0.letter, items: $0.items) }
                return (sections, snapshots.count)
            }
        } catch {
            return ([], 0)
        }
    }
}
