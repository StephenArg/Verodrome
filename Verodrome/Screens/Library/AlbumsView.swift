import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

struct AlbumsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedId: String?
    @State private var playlistSongs: [Song] = []
    @State private var showPlaylistSelector = false
    /// Reshuffles when Random is chosen or the list is pull-to-refreshed.
    @State private var randomSeed = Int.random(in: Int.min...Int.max)
    @State private var model = LibraryListModel<LibraryRowSnapshot>(cacheKey: "albums") { request in
        await AlbumsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.albums }

    /// Cheap fingerprint so album download badges refresh without refetching the library.
    private var downloadRevision: Int {
        downloadCenter.workingIds.count
            &+ downloadCenter.completedIds.count
            &+ downloadCenter.failedIds.count
            &+ downloadCenter.deferredIds.count
    }

    private var reloadKey: LibraryReloadKey {
        LibraryReloadKey(
            search: debouncedSearch,
            sort: sort,
            isSyncing: librarySync.isSyncing,
            randomSeed: sort == .random ? randomSeed : 0
        )
    }

    var body: some View {
        Group {
            if let columns = settings.libraryDisplayType.gridColumnCount {
                AlbumsGridView(
                    albums: gridAlbums,
                    columnCount: columns,
                    showsText: settings.libraryDisplayType.showsGridText,
                    contextMenu: albumSwiftUIContextMenu(for:)
                )
            } else {
                IndexedEntityTableView(
                    sections: model.sections,
                    playingId: nowPlaying.currentItem?.playableId,
                    isPartial: model.isPartial,
                    isSectioned: model.isSectioned,
                    downloadRevision: downloadRevision,
                    onSelect: { item, _ in selectedId = item.id },
                    // Same choices as song rows, minus "Go to Album".
                    makeContextMenu: albumContextMenu(for:)
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
        .sheet(isPresented: $showPlaylistSelector) {
            PlaylistSelectorView { playlist in
                let songs = playlistSongs
                Task {
                    try? await LibraryActions.shared.addSongs(songs, to: playlist)
                    ActionToast.addedToPlaylist(playlist.name)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibrarySortMenu(
                    selection: $settings.librarySort.albums,
                    options: LibrarySortOption.albumOptions
                )
                LibraryLayoutMenu(selection: $settings.libraryDisplayType)
            }
        }
        .perfAppear("Albums", details: "rows=\(model.rowCount) display=\(settings.libraryDisplayType.rawValue)")
        .task(id: reloadKey) {
            await model.load(search: debouncedSearch, sort: sort, randomSeed: randomSeed)
        }
        .refreshable {
            if sort == .random {
                randomSeed = Int.random(in: Int.min...Int.max)
            }
            await model.load(search: debouncedSearch, sort: sort, randomSeed: randomSeed)
        }
    }

    private var gridAlbums: [AlbumGridSnapshot] {
        model.sections.flatMap(\.items).map(AlbumGridSnapshot.init)
    }

    // MARK: - Context menu

    private func albumContextMenu(for item: LibraryRowSnapshot) -> UIMenu? {
        let album = resolveAlbum(compoundRemoteId: item.id)
        let summary = SongsDownloadSummary(
            songRemoteIds: item.songRemoteIds,
            downloadedIds: item.downloadedSongIds,
            trackTotal: item.trackTotal,
            center: downloadCenter
        )

        var primary: [UIMenuElement] = []
        primary.append(UIAction(
            title: album?.isFavorite == true ? "Unlike" : "Like",
            image: UIImage(systemName: album?.isFavorite == true ? "heart.slash" : "heart"),
            attributes: album == nil ? .disabled : []
        ) { _ in
            guard let album else { return }
            Task {
                let liking = !album.isFavorite
                try? await LibraryActions.shared.toggleFavorite(album: album)
                ActionToast.songLiked(liking)
            }
        })
        primary.append(UIAction(
            title: "Add to Queue",
            image: UIImage(systemName: "text.append"),
            attributes: album == nil ? .disabled : []
        ) { _ in
            guard let album else { return }
            Task { await addAlbumToQueue(album) }
        })
        primary.append(UIAction(
            title: "Share",
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: album == nil ? .disabled : []
        ) { _ in
            guard let album else { return }
            shareAlbum(album)
        })

        var secondary: [UIMenuElement] = []
        secondary.append(UIAction(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            attributes: album == nil ? .disabled : []
        ) { _ in
            guard let album else { return }
            Task { await presentPlaylistSelector(for: album) }
        })
        secondary.append(UIAction(
            title: albumDownloadActionTitle(for: summary),
            image: UIImage(systemName: albumDownloadActionSymbol(for: summary)),
            attributes: album == nil ? .disabled : []
        ) { _ in
            guard let album else { return }
            Task { await toggleAlbumDownload(album, summary: summary) }
        })

        return UIMenu(children: [
            UIMenu(options: .displayInline, children: primary),
            UIMenu(options: .displayInline, children: secondary)
        ])
    }

    @ViewBuilder
    private func albumSwiftUIContextMenu(for snapshot: AlbumGridSnapshot) -> some View {
        let album = resolveAlbum(compoundRemoteId: snapshot.id)
        let summary = album.map { SongsDownloadSummary(album: $0, center: downloadCenter) }
            ?? SongsDownloadSummary(
                songRemoteIds: [],
                downloadedIds: [],
                trackTotal: 0,
                center: downloadCenter
            )

        Button {
            guard let album else { return }
            Task {
                let liking = !album.isFavorite
                try? await LibraryActions.shared.toggleFavorite(album: album)
                ActionToast.songLiked(liking)
            }
        } label: {
            Label(
                album?.isFavorite == true ? "Unlike" : "Like",
                systemImage: album?.isFavorite == true ? "heart.slash" : "heart"
            )
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            Task { await addAlbumToQueue(album) }
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            shareAlbum(album)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(album == nil)

        Divider()

        Button {
            guard let album else { return }
            Task { await presentPlaylistSelector(for: album) }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(album == nil)

        Button {
            guard let album else { return }
            Task { await toggleAlbumDownload(album, summary: summary) }
        } label: {
            Label(
                albumDownloadActionTitle(for: summary),
                systemImage: albumDownloadActionSymbol(for: summary)
            )
        }
        .disabled(album == nil)
    }

    private func albumDownloadActionTitle(for summary: SongsDownloadSummary) -> String {
        if summary.isWorking || summary.isWaiting { return "Cancel Downloads" }
        if summary.isFullyDownloaded { return "Remove Downloads" }
        if summary.isPartiallyDownloaded { return "Download Remaining" }
        return "Download"
    }

    private func albumDownloadActionSymbol(for summary: SongsDownloadSummary) -> String {
        if summary.isWorking || summary.isWaiting { return "stop.circle" }
        if summary.isFullyDownloaded { return "trash" }
        return "arrow.down.circle"
    }

    private func shareAlbum(_ album: Album) {
        ShareComposer.present(
            ShareSubject(
                resourceType: .album,
                resourceIds: [album.remoteId],
                title: album.title,
                subtitle: album.artistName ?? "Unknown Artist",
                artwork: album.artworkToken.map { ArtworkRef(id: $0, kind: .album) }
            )
        )
    }

    private func addAlbumToQueue(_ album: Album) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        player.addToQueueTemporarily(
            songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) }
        )
    }

    private func presentPlaylistSelector(for album: Album) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        playlistSongs = songs
        showPlaylistSelector = true
    }

    private func toggleAlbumDownload(_ album: Album, summary: SongsDownloadSummary) async {
        let songs = await ensureSongs(for: album)
        guard !songs.isEmpty else { return }
        if summary.isWorking || summary.isWaiting {
            await LibraryActions.shared.cancelDownloads(songs: songs)
        } else if summary.isFullyDownloaded {
            await LibraryActions.shared.removeDownloads(songs: songs)
        } else {
            await LibraryActions.shared.downloadRemaining(songs: songs)
        }
    }

    private func ensureSongs(for album: Album) async -> [Song] {
        var songs = sortedSongs(for: album)
        if songs.isEmpty {
            try? await VerodromeKit.shared.ensureActiveLibrarySyncer()?.sync(albumId: album.remoteId)
            songs = sortedSongs(for: album)
        }
        return songs
    }

    private func sortedSongs(for album: Album) -> [Song] {
        album.songs.sorted {
            ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0)
        }
    }

    private func resolveAlbum(compoundRemoteId: String) -> Album? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibraryRowSnapshot> {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let albums = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.sort == .random ? nil : request.limit,
                    matching: predicate(for: request)
                )
                var snapshots = albums.map { album -> LibraryRowSnapshot in
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
                if request.sort == .random {
                    let seed = request.randomSeed
                    snapshots.sort {
                        stableHash($0.id, seed: seed) < stableHash($1.id, seed: seed)
                    }
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

    /// Same seed+id hash Home uses for its Random Albums carousel.
    private static func stableHash(_ value: String, seed: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(value)
        return hasher.finalize()
    }

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Album>] {
        switch sort {
        case .ratingHighest:
            [SortDescriptor(\Album.rating, order: .reverse), SortDescriptor(\Album.sortTitle)]
        case .recentlyAdded:
            // 1-based server newest rank; lower index = newer. Secondary title for ties.
            [SortDescriptor(\Album.newestIndex), SortDescriptor(\Album.sortTitle)]
        case .random, .titleAZ, .titleZA, .titleSymbolsFirst, .durationLongest, .durationShortest,
             .playsMost, .smartPlaylistsFirst:
            // Random reorders in memory after the fetch; any stable store order is fine.
            [SortDescriptor(\Album.sortTitle, order: sort.sortsTitleDescending ? .reverse : .forward)]
        }
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty.
    ///
    /// The letter range is bounded to ASCII because `sortTitle` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    ///
    /// Recently Added only includes albums the server ranked into `newestIndex` (> 0).
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Album>? {
        let recentlyAddedOnly = request.sort == .recentlyAdded
        let search = request.search

        if request.isHeadPass {
            guard request.sort.isAlphabetical else {
                return recentlyAddedOnly ? #Predicate<Album> { $0.newestIndex > 0 } : nil
            }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Album> { $0.sortTitle < "a" }
            }
            return #Predicate<Album> { $0.sortTitle >= "a" && $0.sortTitle < "{" }
        }

        if search.isEmpty {
            return recentlyAddedOnly ? #Predicate<Album> { $0.newestIndex > 0 } : nil
        }
        if recentlyAddedOnly {
            return #Predicate<Album> { album in
                album.newestIndex > 0
                    && (album.title.localizedStandardContains(search)
                        || album.artistName?.localizedStandardContains(search) == true)
            }
        }
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
