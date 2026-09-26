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
                    options: LibrarySortOption.playlistOptions
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
        // addSongs / removeSong rewrite playlist items (and songCount) without a catalog
        // sync, so the cached rows would otherwise keep the old counts until the next
        // pull-to-refresh.
        .onReceive(NotificationCenter.default.publisher(for: .playlistItemsChanged)) { _ in
            catalogVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistFavoriteChanged)) { _ in
            catalogVersion += 1
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
                // Smart-first reorders after the fetch, so a limited head page of A–Z
                // names would drop later smart lists. Pull the whole catalog instead —
                // playlist counts stay modest.
                let limit = request.sort == .smartPlaylistsFirst ? nil : request.limit
                var playlists = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: limit,
                    matching: predicate(for: request)
                ).filter { $0.account?.compoundKey == accountKey }
                // A head pass leaves favorites out of its letter bucket (see `predicate`).
                // They lead every order, so read them whole and put them in front, which
                // keeps the head a true prefix of the full list.
                if request.isHeadPass, request.sort.isAlphabetical {
                    let favorites = try LibraryFetch.rows(
                        context,
                        sortBy: sortDescriptors(for: request.sort),
                        limit: nil,
                        matching: #Predicate<Playlist> { $0.isFavorite }
                    ).filter { $0.account?.compoundKey == accountKey }
                    playlists = favorites + playlists
                }
                // SwiftData's SortDescriptor can't order a Bool column, so smart-first
                // is applied here.
                if request.sort == .smartPlaylistsFirst {
                    playlists.sort { lhs, rhs in
                        if lhs.isSmart != rhs.isSmart { return lhs.isSmart && !rhs.isSmart }
                        return lhs.sortName.localizedStandardCompare(rhs.sortName) == .orderedAscending
                    }
                }
                let snapshot = { (playlist: Playlist) in
                    LibraryRowSnapshot(
                        id: playlist.compoundRemoteId,
                        sectionKey: (playlist.sortName.isEmpty ? playlist.name : playlist.sortName).sectionInitial,
                        title: playlist.name,
                        subtitle: "\(playlist.songCount) songs",
                        artworkToken: playlist.displayArtworkToken,
                        symbol: "music.note.house.fill",
                        // Icons rather than words, so what explains a row's place in
                        // the list doesn't crowd its song count.
                        isFavorite: playlist.isFavorite,
                        isSmartPlaylist: playlist.isSmart
                    )
                }
                // Favorites lead every order, each group keeping the chosen order within it.
                let favorites = playlists.filter(\.isFavorite)
                let others = playlists.filter { !$0.isFavorite }
                guard request.sort.isAlphabetical else {
                    let snapshots = (favorites + others).map(snapshot)
                    return LibraryListPage(
                        sections: AlphabetSectioning.sections(snapshots, sort: request.sort),
                        count: snapshots.count
                    )
                }
                var sections: [LibraryRowSection<LibraryRowSnapshot>] = []
                if !favorites.isEmpty {
                    let ordered = AlphabetSectioning.sections(favorites.map(snapshot), sort: request.sort).flatMap(\.items)
                    sections.append(LibraryRowSection(letter: "Favorites", items: ordered, showsInIndex: false))
                }
                // Title orders keep smart playlists out of the letters and after them:
                // they're rebuilt by the server from rules rather than added to by hand,
                // so they're the ones least often looked for.
                let regular = others.filter { !$0.isSmart }.map(snapshot)
                let smart = others.filter(\.isSmart).map(snapshot)
                sections += AlphabetSectioning.sections(regular, sort: request.sort)
                if !smart.isEmpty {
                    // Same title order as the letters above, laid end to end.
                    let ordered = AlphabetSectioning.sections(smart, sort: request.sort).flatMap(\.items)
                    sections.append(LibraryRowSection(letter: "Smart Playlists", items: ordered, showsInIndex: false))
                }
                return LibraryListPage(sections: sections, count: playlists.count)
            }
        } catch {
            return .empty
        }
    }

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Playlist>] {
        // Smart-first reorders in memory after the fetch; the store still returns A–Z#.
        [SortDescriptor(\Playlist.sortName, order: sort.sortsTitleDescending ? .reverse : .forward)]
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty. It
    /// leaves out favorites, which lead the list and are read separately, and smart
    /// playlists, which title orders move to the end of it.
    ///
    /// The letter range is bounded to ASCII because `sortName` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Playlist>? {
        if request.isHeadPass {
            guard request.sort.isAlphabetical else { return nil }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Playlist> { $0.sortName < "a" && !$0.isSmart && !$0.isFavorite }
            }
            return #Predicate<Playlist> {
                $0.sortName >= "a" && $0.sortName < "{" && !$0.isSmart && !$0.isFavorite
            }
        }
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Playlist> { $0.name.localizedStandardContains(search) }
    }
}

/// The Playlists list's order for a flat list of playlists, so the add-to-playlist sheets
/// read the same way as the list they're picked from. Favorites first, then the rest, each
/// in the list's chosen sort.
enum PlaylistListOrder {
    static func ordered(_ playlists: [Playlist], by sort: LibrarySortOption) -> [Playlist] {
        let sorted = titleOrdered(playlists, by: sort)
        return sorted.filter(\.isFavorite) + sorted.filter { !$0.isFavorite }
    }

    /// Same rules as `PlaylistsView.fetchPage`: title sorts go by `sortName` and then group
    /// by section the way the letter headers do; Smart Playlists puts smart ones first and
    /// the rest in natural name order.
    private static func titleOrdered(_ playlists: [Playlist], by sort: LibrarySortOption) -> [Playlist] {
        guard sort.isAlphabetical else {
            return playlists.sorted { lhs, rhs in
                if lhs.isSmart != rhs.isSmart { return lhs.isSmart && !rhs.isSmart }
                return lhs.sortName.localizedStandardCompare(rhs.sortName) == .orderedAscending
            }
        }
        let byName = playlists.sorted {
            sort.sortsTitleDescending ? $0.sortName > $1.sortName : $0.sortName < $1.sortName
        }
        return AlphabetSectioning.group(byName, order: AlphabetSectioning.sectionOrder(for: sort)) {
            ($0.sortName.isEmpty ? $0.name : $0.sortName).sectionInitial
        }
        .flatMap(\.items)
    }
}
