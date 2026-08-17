import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

struct ArtistsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedId: String?
    @State private var model = LibraryListModel<LibraryRowSnapshot>(cacheKey: "artists") { request in
        await ArtistsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.artists }

    var body: some View {
        IndexedEntityTableView(
            sections: model.sections,
            playingId: nowPlaying.currentItem?.playableId,
            isPartial: model.isPartial,
            isSectioned: model.isSectioned,
            onSelect: { item, _ in selectedId = item.id },
            makeContextMenu: artistContextMenu(for:)
        )
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Filter artists")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .navigationDestination(item: $selectedId) { id in
            ArtistDetailView(artistID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    selection: $settings.librarySort.artists,
                    options: LibrarySortOption.titleOptions
                )
            }
        }
        .perfAppear("Artists", details: "rows=\(model.rowCount) search=\(searchText.isEmpty ? "off" : "on")")
        .task(id: LibraryReloadKey(search: debouncedSearch, sort: sort, isSyncing: librarySync.isSyncing)) {
            await model.load(search: debouncedSearch, sort: sort)
            if await LibraryCountRepair.repairArtistCounts() {
                await model.load(search: debouncedSearch, sort: sort)
            }
        }
        .refreshable {
            await model.load(search: debouncedSearch, sort: sort)
        }
    }

    // MARK: - Context menu

    private func artistContextMenu(for item: LibraryRowSnapshot) -> UIMenu? {
        let artist = resolveArtist(compoundRemoteId: item.id)

        var actions: [UIMenuElement] = [
            UIAction(
                title: "Play",
                image: UIImage(systemName: "play.fill"),
                attributes: artist == nil ? .disabled : []
            ) { _ in
                playArtist(compoundRemoteId: item.id, shuffle: false)
            },
            UIAction(
                title: "Shuffle",
                image: UIImage(systemName: "shuffle"),
                attributes: artist == nil ? .disabled : []
            ) { _ in
                playArtist(compoundRemoteId: item.id, shuffle: true)
            },
        ]

        if let artist {
            let subtitle = item.subtitle.isEmpty
                ? "\(max(artist.albumCount, artist.albums.count)) albums · \(max(artist.songCount, artist.songs.count)) songs"
                : item.subtitle
            let artwork = artist.artworkToken ?? artist.albums.first?.artworkToken
            actions.append(UIAction(
                title: "Share",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                ShareComposer.present(
                    ShareSubject(
                        resourceType: .artist,
                        resourceIds: [artist.remoteId],
                        title: artist.name,
                        subtitle: subtitle,
                        artwork: artwork.map { ArtworkRef(id: $0, kind: .artist) }
                    )
                )
            })
        }

        return UIMenu(children: actions)
    }

    private func resolveArtist(compoundRemoteId: String) -> Artist? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Artist>(
            predicate: #Predicate<Artist> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func playArtist(compoundRemoteId: String, shuffle: Bool) {
        guard let artist = resolveArtist(compoundRemoteId: compoundRemoteId) else { return }
        Task {
            var songs = sortedArtistSongs(artist)
            if songs.isEmpty {
                if let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() {
                    try? await syncer.sync(artistId: artist.remoteId)
                    let albums = resolveArtist(compoundRemoteId: compoundRemoteId)?.albums ?? artist.albums
                    for album in albums {
                        guard !Task.isCancelled else { return }
                        try? await syncer.sync(albumId: album.remoteId)
                    }
                }
                songs = resolveArtist(compoundRemoteId: compoundRemoteId).map(sortedArtistSongs) ?? []
            }
            let items = songs.map(QueueItem.from)
            guard !items.isEmpty else { return }
            player.play(items: items, shuffle: shuffle, origin: .artist(artist.name))
            router.openPlayer()
        }
    }

    private func sortedArtistSongs(_ artist: Artist) -> [Song] {
        artist.songs.sorted {
            ($0.albumTitle ?? "", $0.disc ?? 0, $0.track ?? 0)
                < ($1.albumTitle ?? "", $1.disc ?? 0, $1.track ?? 0)
        }
    }

    /// Fetch + map + section off the main actor so opening Artists stays responsive.
    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibraryRowSnapshot> {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let artists = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.limit,
                    matching: predicate(for: request)
                )
                let snapshots = artists.map { artist in
                    LibraryRowSnapshot(
                        id: artist.compoundRemoteId,
                        sectionKey: (artist.sortName.isEmpty ? artist.name : artist.sortName).sectionInitial,
                        title: artist.name,
                        subtitle: "\(artist.albumCount) albums · \(artist.songCount) songs",
                        artworkToken: artist.artworkToken,
                        symbol: "person.fill"
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

    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Artist>] {
        [SortDescriptor(\Artist.sortName, order: sort.sortsTitleDescending ? .reverse : .forward)]
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty.
    ///
    /// The letter range is bounded to ASCII because `sortName` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Artist>? {
        if request.isHeadPass {
            guard request.sort.isAlphabetical else { return nil }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Artist> { $0.sortName < "a" }
            }
            return #Predicate<Artist> { $0.sortName >= "a" && $0.sortName < "{" }
        }
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Artist> { $0.name.localizedStandardContains(search) }
    }
}
