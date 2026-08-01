import SwiftUI
import SwiftData
import VerodromeKit

struct PlaylistsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedId: String?
    @State private var catalogVersion = 0
    @State private var model = LibraryListModel<LibraryRowSnapshot>(cacheKey: "playlists") { request in
        await PlaylistsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.playlists }

    var body: some View {
        IndexedEntityTableView(
            sections: model.sections,
            playingId: nowPlaying.currentItem?.playableId,
            isPartial: model.isPartial,
            isSectioned: model.isSectioned,
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
                LibrarySortMenu(
                    selection: $settings.librarySort.playlists,
                    options: LibrarySortOption.titleOptions
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PlaylistEditView(playlistID: nil) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .perfAppear("Playlists", details: "count=\(model.rowCount)")
        .task(
            id: LibraryReloadKey(
                search: debouncedSearch,
                sort: sort,
                isSyncing: librarySync.isSyncing,
                version: catalogVersion
            )
        ) {
            await model.load(search: debouncedSearch, sort: sort)
        }
        // Runs alongside the load rather than in front of it: the locally stored
        // playlists are worth showing before the server round trip returns.
        .task {
            await syncCatalog()
        }
        .refreshable {
            await syncCatalog()
            await model.load(search: debouncedSearch, sort: sort)
        }
    }

    private func syncCatalog() async {
        do {
            guard let syncer = try await VerodromeKit.shared.ensureActiveLibrarySyncer(),
                  let account = try VerodromeKit.shared.activeAccount(),
                  let storage = VerodromeKit.shared.storage else {
                catalogVersion += 1
                return
            }
            let remoteIds = try await syncer.syncPlaylistCatalog()
            _ = try LibraryPruner.prunePlaylists(
                account: account,
                keepingRemoteIds: Set(remoteIds),
                context: storage.mainContext
            )
        } catch {
            // Keep showing the local catalog when the round trip fails.
        }
        catalogVersion += 1
    }

    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibraryRowSnapshot> {
        let accountKey = await MainActor.run {
            AccountStore.shared.activeAccountKey()?.storageKey
        }
        guard let accountKey else { return .empty }
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                // Account scoping is applied in memory — SwiftData list predicates are
                // restricted to proven SQL shapes, and playlist counts stay small.
                let playlists = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.limit,
                    matching: predicate(for: request)
                ).filter { $0.account?.compoundKey == accountKey }
                let snapshots = playlists.map { playlist in
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
                return LibraryListPage(
                    sections: AlphabetSectioning.sections(snapshots, sort: request.sort),
                    count: snapshots.count
                )
            }
        } catch {
            return .empty
        }
    }

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Playlist>] {
        [SortDescriptor(\Playlist.sortName, order: sort.sortsTitleDescending ? .reverse : .forward)]
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty.
    ///
    /// The letter range is bounded to ASCII because `sortName` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Playlist>? {
        if request.isHeadPass {
            guard request.sort.isAlphabetical else { return nil }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Playlist> { $0.sortName < "a" }
            }
            return #Predicate<Playlist> { $0.sortName >= "a" && $0.sortName < "{" }
        }
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Playlist> { $0.name.localizedStandardContains(search) }
    }
}
