import Foundation
import SwiftData
import SwiftUI
import VerodromeKit

/// One pass of a library list fetch.
struct LibraryListPage<Item: LibraryRow>: Sendable {
    let sections: [LibraryRowSection<Item>]
    let count: Int

    static var empty: LibraryListPage { LibraryListPage(sections: [], count: 0) }
}

/// Single reload identity for a library screen. Separate `.task` modifiers each
/// fire once on appear, so a screen with appear/search/sync triggers ran its whole
/// fetch three times before it could draw a row.
struct LibraryReloadKey: Equatable {
    let search: String
    let sort: LibrarySortOption
    let isSyncing: Bool
    /// Bumped by screens that pull from the server before their rows are final.
    var version: Int = 0
}

/// One fetch pass for a library list.
struct LibraryFetchRequest: Sendable {
    let search: String
    let sort: LibrarySortOption
    /// Set only for the head pass that draws the top of the list before the rest.
    let headLimit: Int?

    var limit: Int? { headLimit }

    /// Head passes must restrict themselves to the section group that renders first,
    /// or the rows they return won't be the rows the user sees at the top.
    /// `LibraryListModel` only issues one while the search is empty, so the bucket
    /// predicate never has to compose with a search predicate.
    var isHeadPass: Bool { headLimit != nil }
}

extension AlphabetSectioning {
    /// Group rows into ready-to-render sections in the order `sort` displays them.
    ///
    /// Non-alphabetical sorts render as one unnamed section: the fetch order is already
    /// the display order, and letter headers would say nothing about a list ordered by
    /// duration or play count.
    static func sections<Item: LibraryRow>(
        _ items: [Item],
        sort: LibrarySortOption
    ) -> [LibraryRowSection<Item>] {
        guard sort.isAlphabetical else {
            return items.isEmpty ? [] : [LibraryRowSection(letter: "", items: items)]
        }
        return group(items, order: sectionOrder(for: sort)) { $0.sectionKey }
            .map { LibraryRowSection(letter: $0.letter, items: $0.items) }
    }
}

/// Last rendered rows per library screen, so pushing back into a list paints
/// immediately instead of waiting on a fetch.
@MainActor
final class LibrarySectionCache {
    static let shared = LibrarySectionCache()

    private var pages: [String: Any] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .accountChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LibrarySectionCache.shared.pages.removeAll() }
        }
    }

    func page<Item: LibraryRow>(for key: String) -> LibraryListPage<Item>? {
        pages[key] as? LibraryListPage<Item>
    }

    func store<Item: LibraryRow>(_ page: LibraryListPage<Item>, for key: String) {
        pages[key] = page
    }
}

/// Drives a library list: restores the previous rows, draws the top of the list
/// before the whole table has been read, and drops superseded results.
@MainActor
@Observable
final class LibraryListModel<Item: LibraryRow> {
    /// Rows loaded for the first paint. More than fills an iPad at 60pt rows, and
    /// stays under the count at which the table turns on its A–Z scrubber.
    private static var headLimit: Int { 150 }

    private(set) var sections: [LibraryRowSection<Item>] = []
    private(set) var rowCount = 0
    /// True while only the head page is on screen.
    private(set) var isPartial = false
    /// The ordering the rows on screen were fetched with, which lags the user's
    /// selection until the new rows land. Section headers key off this so they don't
    /// disappear from rows that are still grouped by letter.
    private(set) var appliedSort: LibrarySortOption = .titleAZ

    var isSectioned: Bool { appliedSort.isAlphabetical }

    private let baseCacheKey: String
    private let supportsHeadPage: Bool
    private let fetch: @Sendable (LibraryFetchRequest) async -> LibraryListPage<Item>
    private var generation = 0

    /// - Parameter supportsHeadPage: Pass false when the screen's sort column can't be
    ///   split into leading and trailing section groups by a fetch predicate, which
    ///   makes a limited fetch an unreliable prefix of the displayed order.
    init(
        cacheKey: String,
        supportsHeadPage: Bool = true,
        fetch: @escaping @Sendable (LibraryFetchRequest) async -> LibraryListPage<Item>
    ) {
        self.baseCacheKey = cacheKey
        self.supportsHeadPage = supportsHeadPage
        self.fetch = fetch
    }

    func load(search: String, sort: LibrarySortOption) async {
        generation += 1
        let generation = self.generation

        if !hasRows(for: sort), let cached: LibraryListPage<Item> = LibrarySectionCache.shared.page(for: cacheKey(for: sort)) {
            sections = cached.sections
            rowCount = cached.count
            appliedSort = sort
            isPartial = false
        }

        // Draw the top of the list before reading the whole table. Restricted to an
        // empty search so the head fetch only needs its section-bucket predicate; a
        // filtered list is small enough that the full pass is already quick.
        if !hasRows(for: sort), supportsHeadPage, search.isEmpty {
            let request = LibraryFetchRequest(search: search, sort: sort, headLimit: Self.headLimit)
            let head = await PerfTrace.measureAsync("LibraryList.head", details: baseCacheKey) {
                await fetch(request)
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            if !head.sections.isEmpty {
                sections = head.sections
                rowCount = head.count
                appliedSort = sort
                isPartial = true
            }
        }

        let request = LibraryFetchRequest(search: search, sort: sort, headLimit: nil)
        let full = await PerfTrace.measureAsync("LibraryList.full", details: baseCacheKey) {
            await fetch(request)
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        sections = full.sections
        rowCount = full.count
        appliedSort = sort
        isPartial = false
        LibrarySectionCache.shared.store(full, for: cacheKey(for: sort))
    }

    private func hasRows(for sort: LibrarySortOption) -> Bool {
        !sections.isEmpty && appliedSort == sort
    }

    /// Cached per ordering, so switching sorts never paints rows in the previous order.
    private func cacheKey(for sort: LibrarySortOption) -> String {
        "\(baseCacheKey).\(sort.rawValue)"
    }
}

/// Fetches list rows with the search filter pushed into the store instead of
/// materializing the whole table and filtering it in Swift.
///
/// Only predicate shapes proven to translate to SQL may be passed in. An
/// unsupported one raises an Objective-C exception from CoreData that `try`
/// cannot catch, so there is no runtime fallback to lean on — notably
/// `(optional ?? "").localizedStandardContains(_:)` fails this way, while
/// `optional?.localizedStandardContains(_:) == true` is fine.
/// `LibraryListFetchTests` covers every shape these screens use.
enum LibraryFetch {
    static func rows<Model: PersistentModel>(
        _ context: ModelContext,
        sortBy: [SortDescriptor<Model>],
        limit: Int?,
        matching predicate: Predicate<Model>? = nil
    ) throws -> [Model] {
        var descriptor = FetchDescriptor<Model>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }
}

/// Backfills artist and genre counts for stores written before the ingester learned
/// to do it. Runs once, after the first rows are on screen — the album scan it needs
/// is far too slow to sit in front of them.
enum LibraryCountRepair {
    /// Returns true when rows changed and the list should reload.
    static func repairArtistCounts() async -> Bool {
        await run("library.artistCountRepairDone") { context in
            let artists = try context.fetch(FetchDescriptor<Artist>())
            guard !artists.isEmpty else { return nil }
            guard artists.contains(where: { $0.albumCount == 0 || $0.songCount == 0 }) else { return false }

            let totals = albumTotals(in: context) { $0.artist?.compoundRemoteId }
            var changed = false
            for artist in artists {
                let key = artist.compoundRemoteId
                if artist.albumCount == 0, let albums = totals.albums[key], albums > 0 {
                    artist.albumCount = albums
                    changed = true
                }
                if artist.songCount == 0, let songs = totals.songs[key], songs > 0 {
                    artist.songCount = songs
                    changed = true
                }
            }
            return changed
        }
    }

    static func repairGenreCounts() async -> Bool {
        await run("library.genreCountRepairDone") { context in
            let genres = try context.fetch(FetchDescriptor<Genre>())
            guard !genres.isEmpty else { return nil }
            guard genres.contains(where: { $0.albumCount == 0 || $0.songCount == 0 }) else { return false }

            let totals = albumTotals(in: context) { album in
                let name = album.genreName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (name?.isEmpty == false) ? name : nil
            }
            var changed = false
            for genre in genres {
                if genre.albumCount == 0, let albums = totals.albums[genre.name], albums > 0 {
                    genre.albumCount = albums
                    changed = true
                }
                if genre.songCount == 0, let songs = totals.songs[genre.name], songs > 0 {
                    genre.songCount = songs
                    changed = true
                }
            }
            return changed
        }
    }

    /// `work` returns nil when there was nothing to inspect yet, which leaves the
    /// repair pending for a later launch instead of burning the one-shot flag.
    private static func run(
        _ defaultsKey: String,
        _ work: @escaping @Sendable (ModelContext) throws -> Bool?
    ) async -> Bool {
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return false }
        let token = PerfTrace.begin("Library.countRepair", details: defaultsKey)
        let outcome = try? await PersistentStorage.shared.backgroundActor.perform(work)
        guard let changed = outcome.flatMap({ $0 }) else {
            PerfTrace.end(token, details: "deferred")
            return false
        }
        UserDefaults.standard.set(true, forKey: defaultsKey)
        PerfTrace.end(token, details: "changed=\(changed)")
        return changed
    }

    private static func albumTotals(
        in context: ModelContext,
        key: (Album) -> String?
    ) -> (albums: [String: Int], songs: [String: Int]) {
        var albumCounts: [String: Int] = [:]
        var songCounts: [String: Int] = [:]
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] {
            guard let key = key(album) else { continue }
            albumCounts[key, default: 0] += 1
            songCounts[key, default: 0] += album.trackCount > 0 ? album.trackCount : album.songs.count
        }
        return (albumCounts, songCounts)
    }
}
