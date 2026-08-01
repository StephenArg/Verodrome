import SwiftUI
import SwiftData
import VerodromeKit

struct GenresView: View {
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
        .navigationTitle("Genres")
        .searchable(text: $searchText, prompt: "Filter genres")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedId) { id in
            GenreDetailView(genreID: id)
        }
        .perfAppear("Genres", details: "count=\(rowCount)")
        .task {
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
                let genres = try context.fetch(
                    FetchDescriptor<Genre>(sortBy: [SortDescriptor(\Genre.name)])
                )
                // Repair zeroed counts from album tags (older syncs wiped these).
                // Leave non-zero server-provided counts alone.
                let localCounts = Self.localGenreCounts(in: context)
                var didRepair = false
                for genre in genres {
                    if genre.albumCount == 0, let albums = localCounts.albums[genre.name], albums > 0 {
                        genre.albumCount = albums
                        didRepair = true
                    }
                    if genre.songCount == 0, let songs = localCounts.songs[genre.name], songs > 0 {
                        genre.songCount = songs
                        didRepair = true
                    }
                }
                if didRepair { try? context.save() }

                let filtered: [Genre]
                if searchText.isEmpty {
                    filtered = genres
                } else {
                    filtered = genres.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                }
                let snapshots = filtered.map { genre in
                    LibraryRowSnapshot(
                        id: genre.compoundRemoteId,
                        sectionKey: genre.name.sectionInitial,
                        title: genre.name,
                        subtitle: "\(genre.albumCount) albums · \(genre.songCount) songs",
                        artworkToken: genre.artworkToken,
                        symbol: "guitars.fill"
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

    private static func localGenreCounts(in context: ModelContext) -> (albums: [String: Int], songs: [String: Int]) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        var albumCounts: [String: Int] = [:]
        var songCounts: [String: Int] = [:]
        for album in albums {
            guard let name = album.genreName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            albumCounts[name, default: 0] += 1
            let tracks = album.trackCount > 0 ? album.trackCount : album.songs.count
            songCounts[name, default: 0] += tracks
        }
        return (albumCounts, songCounts)
    }
}
