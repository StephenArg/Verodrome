import SwiftUI
import SwiftData
import VerodromeKit

struct ArtistsView: View {
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
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Filter artists")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedId) { id in
            ArtistDetailView(artistID: id)
        }
        .perfAppear("Artists", details: "rows=\(rowCount) search=\(searchText.isEmpty ? "off" : "on")")
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

    /// Fetch + map + section off the main actor so opening Artists stays responsive.
    private static func fetchSections(searchText: String) async -> (sections: [LibraryRowSection<LibraryRowSnapshot>], count: Int) {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let artists = try context.fetch(
                    FetchDescriptor<Artist>(sortBy: [SortDescriptor(\Artist.sortName)])
                )
                // Subsonic never ships artist songCount; repair zeros from album track totals.
                let localCounts = Self.localArtistCounts(in: context)
                var didRepair = false
                for artist in artists {
                    let key = artist.compoundRemoteId
                    if artist.songCount == 0, let songs = localCounts.songs[key], songs > 0 {
                        artist.songCount = songs
                        didRepair = true
                    }
                    if artist.albumCount == 0, let albums = localCounts.albums[key], albums > 0 {
                        artist.albumCount = albums
                        didRepair = true
                    }
                }
                if didRepair { try? context.save() }

                let filtered: [Artist]
                if searchText.isEmpty {
                    filtered = artists
                } else {
                    filtered = artists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                }
                let snapshots = filtered.map { artist in
                    LibraryRowSnapshot(
                        id: artist.compoundRemoteId,
                        sectionKey: (artist.sortName.isEmpty ? artist.name : artist.sortName).sectionInitial,
                        title: artist.name,
                        subtitle: "\(artist.albumCount) albums · \(artist.songCount) songs",
                        artworkToken: artist.artworkToken,
                        symbol: "person.fill"
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

    private static func localArtistCounts(in context: ModelContext) -> (albums: [String: Int], songs: [String: Int]) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        var albumCounts: [String: Int] = [:]
        var songCounts: [String: Int] = [:]
        for album in albums {
            guard let key = album.artist?.compoundRemoteId else { continue }
            albumCounts[key, default: 0] += 1
            let tracks = album.trackCount > 0 ? album.trackCount : album.songs.count
            songCounts[key, default: 0] += tracks
        }
        return (albumCounts, songCounts)
    }
}
