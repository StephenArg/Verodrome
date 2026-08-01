import SwiftUI
import SwiftData
import VerodromeKit

struct GenresView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedId: String?
    // No head page: `Genre.name` is the sort column and isn't case-folded, so a
    // limited fetch isn't a reliable prefix of the displayed order. Genre lists are
    // short enough that a single pass is fast anyway.
    @State private var model = LibraryListModel<LibraryRowSnapshot>(
        cacheKey: "genres",
        supportsHeadPage: false
    ) { request in
        await GenresView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.genres }

    var body: some View {
        IndexedEntityTableView(
            sections: model.sections,
            playingId: nowPlaying.currentItem?.playableId,
            isPartial: model.isPartial,
            isSectioned: model.isSectioned,
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    selection: $settings.librarySort.genres,
                    options: LibrarySortOption.titleOptions
                )
            }
        }
        .perfAppear("Genres", details: "count=\(model.rowCount)")
        .task(id: LibraryReloadKey(search: debouncedSearch, sort: sort, isSyncing: librarySync.isSyncing)) {
            await model.load(search: debouncedSearch, sort: sort)
            if await LibraryCountRepair.repairGenreCounts() {
                await model.load(search: debouncedSearch, sort: sort)
            }
        }
        .refreshable {
            await model.load(search: debouncedSearch, sort: sort)
        }
    }

    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibraryRowSnapshot> {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let genres = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.limit,
                    matching: predicate(for: request)
                )
                let snapshots = genres.map { genre in
                    LibraryRowSnapshot(
                        id: genre.compoundRemoteId,
                        sectionKey: genre.name.sectionInitial,
                        title: genre.name,
                        subtitle: "\(genre.albumCount) albums · \(genre.songCount) songs",
                        artworkToken: genre.artworkToken,
                        symbol: "guitars.fill"
                    )
                }
                return LibraryListPage(
                    sections: AlphabetSectioning.sections(snapshots, sort: request.sort),
                    count: snapshots.count
                )
            }
        } catch {
            return .empty
        }
    }

    /// No head-pass branch: this screen opts out of the head page, so every pass is a
    /// full one.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Genre>? {
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Genre> { $0.name.localizedStandardContains(search) }
    }

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Genre>] {
        [SortDescriptor(\Genre.name, order: sort.sortsTitleDescending ? .reverse : .forward)]
    }
}
