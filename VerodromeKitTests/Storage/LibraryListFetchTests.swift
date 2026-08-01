import XCTest
import SwiftData
@testable import VerodromeKit

/// The library lists push their search filter into the store and draw a limited
/// head page before the full list. Both depend on SwiftData translating these
/// predicate shapes and on `fetchLimit` respecting the sort, so pin that down.
///
/// An untranslatable predicate raises an Objective-C exception from CoreData that
/// `try` cannot catch, so these are the only shapes the screens are allowed to use.
@MainActor
final class LibraryListFetchTests: XCTestCase {
    /// Held for the lifetime of the test: it owns the `ModelContainer` backing the
    /// context, and letting it go releases the store out from under the fetches.
    private var storage: PersistentStorage!

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    private func makeContext() throws -> (ModelContext, Account) {
        storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        return (repo.context, account)
    }

    func testSearchPredicateFiltersInTheStore() throws {
        let (context, account) = try makeContext()
        for title in ["Blue Train", "Kind of Blue", "Giant Steps"] {
            context.insert(Song(remoteId: title, title: title, account: account))
        }
        try context.save()

        let search = "blue"
        let descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.title.localizedStandardContains(search) },
            sortBy: [SortDescriptor(\Song.sortTitle)]
        )
        XCTAssertEqual(try context.fetch(descriptor).map(\.title), ["Blue Train", "Kind of Blue"])
    }

    func testSearchPredicateCoversOptionalDenormalizedColumns() throws {
        let (context, account) = try makeContext()
        let coltrane = Song(remoteId: "1", title: "Untitled One", account: account)
        coltrane.artistName = "John Coltrane"
        let davis = Song(remoteId: "2", title: "Untitled Two", account: account)
        davis.artistName = "Miles Davis"
        // No artist or album at all: a nil column must not sink the whole predicate.
        let anonymous = Song(remoteId: "3", title: "Untitled Three", account: account)
        for song in [coltrane, davis, anonymous] { context.insert(song) }
        try context.save()

        // `== true` on the optional Bool, not `(column ?? "").contains` — coalescing
        // the string itself is what CoreData can't generate SQL for.
        let search = "coltrane"
        let descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { song in
                song.title.localizedStandardContains(search)
                    || song.artistName?.localizedStandardContains(search) == true
                    || song.albumTitle?.localizedStandardContains(search) == true
            }
        )
        XCTAssertEqual(try context.fetch(descriptor).map(\.remoteId), ["1"])
    }

    func testHeadPageIsAPrefixOfTheFullList() throws {
        let (context, account) = try makeContext()
        for index in 0..<20 {
            let title = String(format: "Track %02d", index)
            context.insert(Song(remoteId: "\(index)", title: title, account: account))
        }
        try context.save()

        let sortBy = [SortDescriptor(\Song.sortTitle)]
        var head = FetchDescriptor<Song>(sortBy: sortBy)
        head.fetchLimit = 5
        let full = try context.fetch(FetchDescriptor<Song>(sortBy: sortBy))

        XCTAssertEqual(try context.fetch(head).map(\.title), Array(full.map(\.title).prefix(5)))
    }

    func testDescendingHeadPageIsAPrefixOfTheFullList() throws {
        let (context, account) = try makeContext()
        for index in 0..<20 {
            let title = String(format: "Track %02d", index)
            context.insert(Song(remoteId: "\(index)", title: title, account: account))
        }
        try context.save()

        let sortBy = [SortDescriptor(\Song.sortTitle, order: .reverse)]
        var head = FetchDescriptor<Song>(sortBy: sortBy)
        head.fetchLimit = 5
        let full = try context.fetch(FetchDescriptor<Song>(sortBy: sortBy))

        XCTAssertEqual(try context.fetch(head).map(\.title), Array(full.map(\.title).prefix(5)))
    }

    /// The head page has to hold the rows that render first, and the alphabetical
    /// orderings put letters and symbols in different places. That bucketing is a
    /// string range over the folded `sortTitle`.
    func testLetterRangePredicateSeparatesLettersFromSymbols() throws {
        let (context, account) = try makeContext()
        for title in ["Alpha", "zulu", "1999", "...Baby", "€uro"] {
            context.insert(Song(remoteId: title, title: title, account: account))
        }
        try context.save()

        let letters = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.sortTitle >= "a" && $0.sortTitle < "{" },
            sortBy: [SortDescriptor(\Song.sortTitle)]
        )
        XCTAssertEqual(try context.fetch(letters).map(\.title), ["Alpha", "zulu"])

        let symbols = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.sortTitle < "a" },
            sortBy: [SortDescriptor(\Song.sortTitle)]
        )
        XCTAssertEqual(try context.fetch(symbols).map(\.title), ["...Baby", "1999"])
    }

    func testLetterRangeCombinesWithSearchPredicate() throws {
        let (context, account) = try makeContext()
        let hit = Song(remoteId: "1", title: "Alpha Waves", account: account)
        hit.artistName = "Coltrane"
        let wrongBucket = Song(remoteId: "2", title: "1999 Waves", account: account)
        wrongBucket.artistName = "Coltrane"
        let wrongSearch = Song(remoteId: "3", title: "Beta Waves", account: account)
        wrongSearch.artistName = "Davis"
        for song in [hit, wrongBucket, wrongSearch] { context.insert(song) }
        try context.save()

        let search = "coltrane"
        let descriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { song in
                (song.sortTitle >= "a" && song.sortTitle < "{")
                    && (song.title.localizedStandardContains(search)
                        || song.artistName?.localizedStandardContains(search) == true)
            },
            sortBy: [SortDescriptor(\Song.sortTitle)]
        )
        XCTAssertEqual(try context.fetch(descriptor).map(\.remoteId), ["1"])
    }
}
