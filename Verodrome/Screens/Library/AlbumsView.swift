import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var sections: [LibraryRowSection<LibraryRowSnapshot>] = []
    @State private var rowCount = 0
    @State private var loadGeneration = 0
    @State private var selectedId: String?

    var body: some View {
        Group {
            switch settings.libraryDisplayType {
            case .grid:
                AlbumsGridView(albums: filteredGridAlbums)
            case .list, .table:
                IndexedEntityTableView(
                    sections: sections,
                    playingId: nowPlaying.currentItem?.playableId,
                    onSelect: { item, _ in selectedId = item.id }
                )
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Filter albums")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedId) { id in
            AlbumDetailView(albumID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Display", selection: $settings.libraryDisplayType) {
                    ForEach(LibraryDisplayType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .perfAppear("Albums", details: "rows=\(rowCount) display=\(settings.libraryDisplayType.rawValue)")
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

    /// Grid mode filters the flat list of all loaded albums by the (debounced) search text.
    private var filteredGridAlbums: [AlbumGridSnapshot] {
        let all = sections.flatMap(\.items)
        let search = debouncedSearch
        guard !search.isEmpty else { return all.map(AlbumGridSnapshot.init) }
        return all
            .filter {
                $0.title.localizedCaseInsensitiveContains(search)
                    || $0.subtitle.localizedCaseInsensitiveContains(search)
            }
            .map(AlbumGridSnapshot.init)
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
                let albums = try context.fetch(
                    FetchDescriptor<Album>(sortBy: [SortDescriptor(\Album.sortTitle)])
                )
                let filtered: [Album]
                if searchText.isEmpty {
                    filtered = albums
                } else {
                    filtered = albums.filter {
                        $0.title.localizedCaseInsensitiveContains(searchText)
                            || $0.displayArtist.localizedCaseInsensitiveContains(searchText)
                    }
                }
                let snapshots = filtered.map { album in
                    LibraryRowSnapshot(
                        id: album.compoundRemoteId,
                        sectionKey: (album.sortTitle.isEmpty ? album.title : album.sortTitle).sectionInitial,
                        title: album.title,
                        subtitle: album.displayArtist,
                        artworkToken: album.artworkToken
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

/// Lightweight album snapshot for grid mode (avoids holding SwiftData models in the view graph).
struct AlbumGridSnapshot: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artworkToken: String?

    init(_ row: LibraryRowSnapshot) {
        id = row.id
        title = row.title
        subtitle = row.subtitle
        artworkToken = row.artworkToken
    }
}
