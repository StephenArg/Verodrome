import SwiftUI
import SwiftData
import VerodromeKit

struct AlbumsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedId: String?
    @State private var model = LibraryListModel<LibraryRowSnapshot>(cacheKey: "albums") { request in
        await AlbumsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.albums }

    /// Cheap fingerprint so album download badges refresh without refetching the library.
    private var downloadRevision: Int {
        downloadCenter.workingIds.count
            &+ downloadCenter.completedIds.count
            &+ downloadCenter.failedIds.count
    }

    var body: some View {
        Group {
            switch settings.libraryDisplayType {
            case .grid:
                AlbumsGridView(albums: gridAlbums)
            case .list, .table:
                IndexedEntityTableView(
                    sections: model.sections,
                    playingId: nowPlaying.currentItem?.playableId,
                    isPartial: model.isPartial,
                    isSectioned: model.isSectioned,
                    downloadRevision: downloadRevision,
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
                LibrarySortMenu(
                    selection: $settings.librarySort.albums,
                    options: LibrarySortOption.albumOptions
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Display", selection: $settings.libraryDisplayType) {
                    ForEach(LibraryDisplayType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .onChange(of: settings.libraryDisplayType) { _, _ in
            settings.save()
        }
        .perfAppear("Albums", details: "rows=\(model.rowCount) display=\(settings.libraryDisplayType.rawValue)")
        .task(id: LibraryReloadKey(search: debouncedSearch, sort: sort, isSyncing: librarySync.isSyncing)) {
            await model.load(search: debouncedSearch, sort: sort)
        }
        .refreshable {
            await model.load(search: debouncedSearch, sort: sort)
        }
    }

    private var gridAlbums: [AlbumGridSnapshot] {
        model.sections.flatMap(\.items).map(AlbumGridSnapshot.init)
    }

    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibraryRowSnapshot> {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let albums = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.limit,
                    matching: predicate(for: request)
                )
                let snapshots = albums.map { album -> LibraryRowSnapshot in
                    let songs = album.songs
                    let songIds = songs.map(\.remoteId)
                    let downloadedIds = Set(songs.compactMap { song -> String? in
                        song.relFilePath != nil ? song.remoteId : nil
                    })
                    return LibraryRowSnapshot(
                        id: album.compoundRemoteId,
                        sectionKey: (album.sortTitle.isEmpty ? album.title : album.sortTitle).sectionInitial,
                        title: album.title,
                        // Deliberately not `displayArtist`: its `artist?.name` fallback
                        // faults the relationship once per album. `LibraryRepository`
                        // keeps the denormalized column filled.
                        subtitle: album.artistName ?? "Unknown Artist",
                        artworkToken: album.artworkToken,
                        // Ordering by rating sorts on a value the row otherwise never
                        // shows, which reads as arbitrary without the key on screen.
                        trailingRating: request.sort == .ratingHighest ? album.rating : nil,
                        songRemoteIds: songIds,
                        downloadedSongIds: downloadedIds,
                        trackTotal: max(album.trackCount, songs.count)
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

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Album>] {
        switch sort {
        case .ratingHighest:
            [SortDescriptor(\Album.rating, order: .reverse), SortDescriptor(\Album.sortTitle)]
        default:
            [SortDescriptor(\Album.sortTitle, order: sort.sortsTitleDescending ? .reverse : .forward)]
        }
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty.
    ///
    /// The letter range is bounded to ASCII because `sortTitle` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Album>? {
        if request.isHeadPass {
            guard request.sort.isAlphabetical else { return nil }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Album> { $0.sortTitle < "a" }
            }
            return #Predicate<Album> { $0.sortTitle >= "a" && $0.sortTitle < "{" }
        }
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Album> { album in
            album.title.localizedStandardContains(search)
                || album.artistName?.localizedStandardContains(search) == true
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
