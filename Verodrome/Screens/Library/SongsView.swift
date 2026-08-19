import SwiftUI
import SwiftData
import UIKit
import VerodromeKit

struct SongsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @EnvironmentObject private var shuffle: ShuffleAllCoordinator
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var downloadCenter = DownloadCenter.shared

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var selectedAlbumId: String?
    @State private var playlistTarget: Song?
    @State private var isScrolledDown = false
    @State private var model = LibraryListModel<LibrarySongRowSnapshot>(cacheKey: "songs") { request in
        await SongsView.fetchPage(request)
    }

    private var sort: LibrarySortOption { settings.librarySort.songs }
    private var downloadedOnly: Bool { settings.songsDownloadedOnly }

    /// The filter stays put while it's holding a query — hiding it would leave the
    /// missing rows unexplained — and otherwise leaves with the large title on scroll.
    private var showsFilterBar: Bool { !isScrolledDown || !searchText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if showsFilterBar {
                LibraryFilterBar(prompt: "Filter songs", text: $searchText)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            IndexedEntityTableView(
                sections: model.sections,
                playingId: nowPlaying.currentItem?.playableId,
                isPartial: model.isPartial,
                isSectioned: model.isSectioned,
                placeholderIndexTitles: sort.isAlphabetical
                    ? AlphabetSectioning.sectionOrder(for: sort)
                    : [],
                onSelect: play,
                // Same actions as the queue row ellipsis menu.
                makeContextMenu: songContextMenu(for:),
                header: AnyView(
                    LibraryShuffleCountBar(
                        count: model.rowCount,
                        noun: "song",
                        // Head page reports only its own row count until the full fetch lands.
                        isCountProvisional: model.isPartial,
                        isShuffleBusy: shuffle.isStarting,
                        // Downloaded-only has a local walk of its own; a typed filter is
                        // still a selection no random source can reproduce.
                        isShuffleDisabled: !searchText.isEmpty,
                        onShuffle: shuffleAll
                    )
                ),
                onScroll: handleScroll
            )
        }
        .animation(.easeOut(duration: 0.2), value: showsFilterBar)
        .navigationTitle("Songs")
        .navigationDestination(item: $selectedAlbumId) { AlbumDetailView(albumID: $0) }
        .sheet(item: $playlistTarget) { song in
            PlaylistSelectorView { playlist in
                Task {
                    try? await LibraryActions.shared.addSongs([song], to: playlist)
                    ActionToast.addedToPlaylist(playlist.name)
                }
            }
        }
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    selection: $settings.librarySort.songs,
                    options: LibrarySortOption.songOptions,
                    downloadedOnly: $settings.songsDownloadedOnly
                )
            }
        }
        .perfAppear(
            "Songs",
            details: "rows=\(model.rowCount) search=\(searchText.isEmpty ? "off" : "on") downloadedOnly=\(downloadedOnly)"
        )
        .task(id: LibraryReloadKey(
            search: debouncedSearch,
            sort: sort,
            isSyncing: librarySync.isSyncing,
            downloadedOnly: downloadedOnly
        )) {
            await model.load(search: debouncedSearch, sort: sort, downloadedOnly: downloadedOnly)
        }
        .refreshable {
            await model.load(search: debouncedSearch, sort: sort, downloadedOnly: downloadedOnly)
        }
    }

    /// Mirrors `QueueRowMenu` so a long-press here offers the same choices as the
    /// queue's trailing ellipsis.
    private func songContextMenu(for item: LibrarySongRowSnapshot) -> UIMenu? {
        let song = resolveSong(compoundRemoteId: item.id)
        let status = downloadCenter.status(
            for: item.remoteId,
            isDownloaded: song?.isDownloadedLocally ?? false
        )

        var primary: [UIMenuElement] = []
        primary.append(UIAction(
            title: song?.isFavorite == true ? "Unlike" : "Like",
            image: UIImage(systemName: song?.isFavorite == true ? "heart.slash" : "heart"),
            attributes: song == nil ? .disabled : []
        ) { _ in
            guard let song else { return }
            Task { await ActionToast.toggleFavorite(song: song) }
        })
        primary.append(UIAction(
            title: "Add to Queue",
            image: UIImage(systemName: "text.append")
        ) { [player] _ in
            player.addToQueueTemporarily([item.queueItem])
        })
        primary.append(UIAction(
            title: "Start Radio",
            image: UIImage(systemName: "dot.radiowaves.left.and.right"),
            attributes: player.isStartingRadio ? .disabled : []
        ) { [player, router] _ in
            Task { await ActionToast.startRadio(seed: item.queueItem, player: player, router: router) }
        })
        primary.append(UIAction(
            title: "Share",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { _ in
            presentNowPlayingShare(item: item.queueItem)
        })

        var secondary: [UIMenuElement] = []
        if let albumId = song?.album?.compoundRemoteId {
            secondary.append(UIAction(
                title: "Go to Album",
                image: UIImage(systemName: "square.stack")
            ) { _ in
                selectedAlbumId = albumId
            })
        }
        secondary.append(UIAction(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            attributes: song == nil ? .disabled : []
        ) { _ in
            playlistTarget = song
        })
        secondary.append(UIAction(
            title: downloadActionTitle(for: status),
            image: UIImage(systemName: downloadActionSymbol(for: status)),
            attributes: song == nil ? .disabled : []
        ) { _ in
            guard let song else { return }
            Task { await LibraryActions.shared.downloadOrCancel(song: song) }
        })

        return UIMenu(children: [
            UIMenu(options: .displayInline, children: primary),
            UIMenu(options: .displayInline, children: secondary)
        ])
    }

    private func downloadActionTitle(for status: DownloadStatus) -> String {
        switch status {
        case .pending, .downloading: return "Cancel Download"
        case .waiting: return "Download Now"
        case .downloaded: return "Remove Download"
        case .failed: return "Retry Download"
        case .none, .partial, .cached: return "Download"
        }
    }

    private func downloadActionSymbol(for status: DownloadStatus) -> String {
        switch status {
        case .pending, .downloading: return "stop.circle"
        case .downloaded: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .none, .waiting, .partial, .cached: return "arrow.down.circle"
        }
    }

    /// Hiding the filter grows the table and shifts its content, which reads back here as
    /// another scroll. Showing and hiding therefore use marks far enough apart that the
    /// shift can't immediately flip the state again.
    private func handleScroll(_ offset: CGFloat) {
        let shouldHide = isScrolledDown ? offset > 8 : offset > 40
        guard shouldHide != isScrolledDown else { return }
        isScrolledDown = shouldHide
    }

    private func shuffleAll() {
        // Only on success — raising an empty player would be a worse answer than the
        // button simply not having worked.
        Task {
            let started = downloadedOnly
                ? await shuffle.shuffleDownloaded()
                : await shuffle.shuffleAll()
            if started { router.openPlayer() }
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
        player.play(items: items, startAt: 0, shuffle: false, origin: .song(item.title))

        // Only unfiltered, for the same reason Shuffle All disables while a filter is
        // typed or downloaded-only is on: the rows on screen are then the user's own
        // selection, and no backend's random endpoint can reproduce it.
        if searchText.isEmpty, !downloadedOnly, let first = items.first {
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
        case .titleAZ, .titleZA, .titleSymbolsFirst, .smartPlaylistsFirst, .recentlyAdded, .random:
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
    ///
    /// Downloaded-only is `relFilePath != nil` — the same signal `isDownloadedLocally`
    /// uses — and is folded into every branch so CoreData still gets a single
    /// translatable predicate.
    private static func predicate(for request: LibraryFetchRequest) -> Predicate<Song>? {
        let downloadedOnly = request.downloadedOnly
        let search = request.search

        if request.isHeadPass {
            guard request.sort.isAlphabetical else {
                return downloadedOnly ? #Predicate<Song> { $0.relFilePath != nil } : nil
            }
            if request.sort.showsSymbolsFirst {
                return downloadedOnly
                    ? #Predicate<Song> { $0.sortTitle < "a" && $0.relFilePath != nil }
                    : #Predicate<Song> { $0.sortTitle < "a" }
            }
            return downloadedOnly
                ? #Predicate<Song> { $0.sortTitle >= "a" && $0.sortTitle < "{" && $0.relFilePath != nil }
                : #Predicate<Song> { $0.sortTitle >= "a" && $0.sortTitle < "{" }
        }

        if search.isEmpty {
            return downloadedOnly ? #Predicate<Song> { $0.relFilePath != nil } : nil
        }
        if downloadedOnly {
            return #Predicate<Song> { song in
                song.relFilePath != nil
                    && (song.title.localizedStandardContains(search)
                        || song.artistName?.localizedStandardContains(search) == true
                        || song.albumTitle?.localizedStandardContains(search) == true)
            }
        }
        return #Predicate<Song> { song in
            song.title.localizedStandardContains(search)
                || song.artistName?.localizedStandardContains(search) == true
                || song.albumTitle?.localizedStandardContains(search) == true
        }
    }
}
