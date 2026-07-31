import SwiftUI
import SwiftData
import VerodromeKit

struct SongsView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingModel
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var sections: [LibraryRowSection<LibrarySongRowSnapshot>] = []
    @State private var rowCount = 0
    @State private var actionsSong: Song?
    @State private var showActions = false
    @State private var loadGeneration = 0

    var body: some View {
        IndexedEntityTableView(
            sections: sections,
            playingId: nowPlaying.currentItem?.playableId,
            onSelect: play,
            onPlayNext: { item in
                player.playNext([item.queueItem])
            },
            onRequestActions: { compoundId in
                actionsSong = resolveSong(compoundRemoteId: compoundId)
                showActions = actionsSong != nil
            }
        )
        .navigationTitle("Songs")
        .searchable(text: $searchText, prompt: "Filter songs")
        .debouncedSearch(text: $searchText) { newValue in
            debouncedSearch = newValue
        }
        .perfAppear("Songs", details: "rows=\(rowCount) search=\(searchText.isEmpty ? "off" : "on")")
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
        player.play(items: Array(items), startAt: 0)
    }

    private func resolveSong(compoundRemoteId: String) -> Song? {
        let id = compoundRemoteId
        var descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.compoundRemoteId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func reload(reason: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        let search = debouncedSearch
        let token = PerfTrace.begin("Songs.reload", details: reason)

        let built = await PerfTrace.measureAsync(
            "Songs.backgroundFetch",
            details: "search=\(search.isEmpty ? "off" : "on")"
        ) {
            await Self.fetchSections(searchText: search)
        }

        guard generation == loadGeneration else {
            PerfTrace.event("Songs.reload.cancelled", details: reason)
            return
        }

        sections = built.sections
        rowCount = built.count
        PerfTrace.end(token, details: "rows=\(built.count) sections=\(built.sections.count)")
    }

    /// Fetch + map + section off the main actor so opening Songs stays responsive.
    private static func fetchSections(searchText: String) async -> (sections: [LibraryRowSection<LibrarySongRowSnapshot>], count: Int) {
        do {
            return try await PersistentStorage.shared.backgroundActor.perform { context in
                let t0 = CFAbsoluteTimeGetCurrent()
                let descriptor = FetchDescriptor<Song>(
                    sortBy: [SortDescriptor(\Song.sortTitle)]
                )
                let songs = try context.fetch(descriptor)
                let fetchMs = Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded())

                let t1 = CFAbsoluteTimeGetCurrent()
                let filtered: [Song]
                if searchText.isEmpty {
                    filtered = songs
                } else {
                    filtered = songs.filter {
                        $0.title.localizedCaseInsensitiveContains(searchText)
                            || ($0.artistName?.localizedCaseInsensitiveContains(searchText) ?? false)
                            || ($0.albumTitle?.localizedCaseInsensitiveContains(searchText) ?? false)
                    }
                }
                let snapshots = filtered.map(LibrarySongRowSnapshot.init)
                let mapMs = Int(((CFAbsoluteTimeGetCurrent() - t1) * 1000).rounded())

                let t2 = CFAbsoluteTimeGetCurrent()
                let grouped = AlphabetSectioning.group(snapshots) { $0.sectionKey }
                let sections = grouped.map { LibraryRowSection(letter: $0.letter, items: $0.items) }
                let sectionMs = Int(((CFAbsoluteTimeGetCurrent() - t2) * 1000).rounded())

                PerfTrace.event(
                    "Songs.backgroundBreakdown",
                    details: "fetch=\(fetchMs)ms map=\(mapMs)ms section=\(sectionMs)ms rows=\(snapshots.count)"
                )
                return (sections, snapshots.count)
            }
        } catch {
            PerfTrace.event("Songs.backgroundFetch.failed", details: error.localizedDescription)
            return ([], 0)
        }
    }
}
