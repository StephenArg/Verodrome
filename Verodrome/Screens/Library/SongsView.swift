import SwiftUI
import SwiftData
import VerodromeKit

struct SongsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @EnvironmentObject private var shuffle: ShuffleAllCoordinator
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var actionsSong: Song?
    @State private var showActions = false
    @State private var model = LibraryListModel<LibrarySongRowSnapshot>(cacheKey: "songs") { request in
        await SongsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.songs }

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(
                prompt: "Filter songs",
                text: $searchText,
                // The server picks the tracks, and no backend's random endpoint takes a
                // free-text filter — offering the button while one is typed would just
                // ignore it.
                onShuffle: searchText.isEmpty ? shuffleAll : nil,
                isShuffleBusy: shuffle.isStarting
            )
            IndexedEntityTableView(
                sections: model.sections,
                playingId: nowPlaying.currentItem?.playableId,
                isPartial: model.isPartial,
                isSectioned: model.isSectioned,
                onSelect: play,
                onPlayNext: { item in
                    player.playNext([item.queueItem])
                },
                onRequestActions: { compoundId in
                    actionsSong = resolveSong(compoundRemoteId: compoundId)
                    showActions = actionsSong != nil
                }
            )
        }
        .navigationTitle("Songs")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    selection: $settings.librarySort.songs,
                    options: LibrarySortOption.songOptions
                )
            }
        }
        .perfAppear("Songs", details: "rows=\(model.rowCount) search=\(searchText.isEmpty ? "off" : "on")")
        .task(id: LibraryReloadKey(search: debouncedSearch, sort: sort, isSyncing: librarySync.isSyncing)) {
            await model.load(search: debouncedSearch, sort: sort)
        }
        .refreshable {
            await model.load(search: debouncedSearch, sort: sort)
        }
        .sheet(isPresented: $showActions) {
            if let song = actionsSong {
                NavigationStack {
                    List {
                        EntityRow(
                            title: song.title,
                            subtitle: "\(song.displayArtist) · \(song.displayAlbum)",
                            artworkURL: song.artworkToken
                        )
                        .songActions(song)
                    }
                    .navigationTitle(song.title)
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func shuffleAll() {
        // Only on success — raising an empty player would be a worse answer than the
        // button simply not having worked.
        Task {
            if await shuffle.shuffleAll() { router.openPlayer() }
        }
    }

    private func play(item: LibrarySongRowSnapshot, allItems: [LibrarySongRowSnapshot]) {
        PlayTrace.begin("SongsView track tap", details: "song=\(item.title)")
        guard let start = allItems.firstIndex(where: { $0.id == item.id }) else {
            PlayTrace.error("song not found in rows")
            return
        }
        let end = min(start + 40, allItems.count)
        PlayTrace.mark("mapping window QueueItems", details: "start=\(start) end=\(end)")
        let items = allItems[start..<end].map(\.queueItem)
        PlayTrace.mark("calling player.play", details: "count=\(items.count)")
        // Explicitly unshuffled, so shuffle left on from an album or playlist doesn't
        // follow the user here and randomise the tracks queued behind the one they
        // tapped. Picking a song out of a list is a request for that song, then the ones
        // after it.
        player.play(items: items, startAt: 0, shuffle: false)

        // Only unfiltered, for the same reason the Shuffle All button hides while a
        // filter is typed: the rows on screen are then the user's own selection, and no
        // backend's random endpoint can reproduce it.
        if searchText.isEmpty, let first = items.first {
            shuffle.trackSongsLibrary(seededBy: first)
        }
    }

    private func resolveSong(compoundRemoteId: String) -> Song? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetch + map + section off the main actor so opening Songs stays responsive.
    private static func fetchPage(_ request: LibraryFetchRequest) async -> LibraryListPage<LibrarySongRowSnapshot> {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let t0 = CFAbsoluteTimeGetCurrent()
                let songs = try LibraryFetch.rows(
                    context,
                    sortBy: sortDescriptors(for: request.sort),
                    limit: request.limit,
                    matching: predicate(for: request)
                )
                let fetchMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())

                let t1 = CFAbsoluteTimeGetCurrent()
                let snapshots = songs.map { LibrarySongRowSnapshot(song: $0, sort: request.sort) }
                let mapMs = Int(((CFAbsoluteTimeGetCurrent() - t1) * 1000).rounded())

                let t2 = CFAbsoluteTimeGetCurrent()
                let sections = AlphabetSectioning.sections(snapshots, sort: request.sort)
                let sectionMs = Int(((CFAbsoluteTimeGetCurrent() - t2) * 1000).rounded())

                PerfTrace.event(
                    "Songs.backgroundBreakdown",
                    details: "fetch=\(fetchMs)ms map=\(mapMs)ms section=\(sectionMs)ms rows=\(snapshots.count) limit=\(request.limit.map(String.init) ?? "none")"
                )
                return LibraryListPage(sections: sections, count: snapshots.count)
            }
        } catch {
            PerfTrace.event("Songs.backgroundFetch.failed", details: error.localizedDescription)
            return .empty
        }
    }

    /// Secondary title sort so equal durations, ratings and play counts stay alphabetical
    /// instead of coming back in whatever order the store happens to produce.
    private static func sortDescriptors(for sort: LibrarySortOption) -> [SortDescriptor<Song>] {
        switch sort {
        case .titleAZ, .titleZA, .titleSymbolsFirst:
            [SortDescriptor(\Song.sortTitle, order: sort.sortsTitleDescending ? .reverse : .forward)]
        case .durationLongest:
            [SortDescriptor(\Song.playDuration, order: .reverse), SortDescriptor(\Song.sortTitle)]
        case .durationShortest:
            [SortDescriptor(\Song.playDuration), SortDescriptor(\Song.sortTitle)]
        case .ratingHighest:
            [SortDescriptor(\Song.rating, order: .reverse), SortDescriptor(\Song.sortTitle)]
        case .playsMost:
            [SortDescriptor(\Song.playCount, order: .reverse), SortDescriptor(\Song.sortTitle)]
        }
    }

    /// A head pass filters to the leading section group instead of the search text; the
    /// two never overlap because head passes only run while the search is empty.
    ///
    /// The letter range is bounded to ASCII because `sortTitle` is case-folded, and
    /// anything folding above "z" sections as "?" and renders with the symbols.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Song>? {
        if request.isHeadPass {
            guard request.sort.isAlphabetical else { return nil }
            if request.sort.showsSymbolsFirst {
                return #Predicate<Song> { $0.sortTitle < "a" }
            }
            return #Predicate<Song> { $0.sortTitle >= "a" && $0.sortTitle < "{" }
        }
        let search = request.search
        guard !search.isEmpty else { return nil }
        return #Predicate<Song> { song in
            song.title.localizedStandardContains(search)
                || song.artistName?.localizedStandardContains(search) == true
                || song.albumTitle?.localizedStandardContains(search) == true
        }
    }
}
