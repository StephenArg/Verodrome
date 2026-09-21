import SwiftData
import XCTest
@testable import VerodromeKit

@MainActor
final class LyricsExplicitEvaluatorTests: XCTestCase {
    private var storage: PersistentStorage!
    private var repository: LibraryRepository!
    private var account: Account!

    override func setUpWithError() throws {
        storage = PersistentStorage(inMemory: true)
        repository = LibraryRepository(storage: storage)
        account = try repository.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
    }

    override func tearDown() {
        storage = nil
        repository = nil
        account = nil
        super.tearDown()
    }

    func testUnknownSongIsEvaluated() throws {
        let song = Song(remoteId: "1", title: "Track", account: account)
        repository.context.insert(song)
        var settings = UserSettings.default
        settings.explicitDetectionEnabled = true

        let result = LyricsExplicitEvaluator.applyIfNeeded(
            to: song,
            lyrics: "what the fuck",
            settings: settings,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(result.didEvaluate)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.status, .explicit)
        XCTAssertEqual(song.lyricsExplicitStatus, .explicit)
        XCTAssertEqual(song.lyricsExplicitCheckedAt, Date(timeIntervalSince1970: 100))
    }

    func testFreshRatingIsNotReevaluated() throws {
        let song = Song(remoteId: "1", title: "Track", account: account)
        song.lyricsExplicitStatus = .explicit
        song.lyricsExplicitCheckedAt = Date(timeIntervalSince1970: 200)
        repository.context.insert(song)
        var settings = UserSettings.default
        settings.explicitDetectionEnabled = true
        settings.explicitWordListChangedAt = Date(timeIntervalSince1970: 100)

        let result = LyricsExplicitEvaluator.applyIfNeeded(
            to: song,
            lyrics: "a wholesome chorus",
            settings: settings,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertFalse(result.didEvaluate)
        XCTAssertEqual(result.status, .explicit)
        XCTAssertEqual(song.lyricsExplicitCheckedAt, Date(timeIntervalSince1970: 200))
    }

    func testStaleRatingIsReevaluatedAfterWordListChange() throws {
        let song = Song(remoteId: "1", title: "Track", account: account)
        song.lyricsExplicitStatus = .explicit
        song.lyricsExplicitCheckedAt = Date(timeIntervalSince1970: 100)
        repository.context.insert(song)
        var settings = UserSettings.default
        settings.explicitDetectionEnabled = true
        settings.explicitSensitivity = .loose
        settings.explicitWhitelistWords = ["fuck"]
        settings.explicitWordListChangedAt = Date(timeIntervalSince1970: 200)

        let result = LyricsExplicitEvaluator.applyIfNeeded(
            to: song,
            lyrics: "what the fuck",
            settings: settings,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(result.didEvaluate)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.status, .clean)
        XCTAssertEqual(song.lyricsExplicitCheckedAt, Date(timeIntervalSince1970: 300))
    }

    func testDisabledDetectionDoesNotEvaluate() throws {
        let song = Song(remoteId: "1", title: "Track", account: account)
        repository.context.insert(song)
        var settings = UserSettings.default
        settings.explicitDetectionEnabled = false

        let result = LyricsExplicitEvaluator.applyIfNeeded(
            to: song,
            lyrics: "what the fuck",
            settings: settings
        )

        XCTAssertFalse(result.didEvaluate)
        XCTAssertEqual(song.lyricsExplicitStatus, .unknown)
    }

    func testCleanLyricsMarkClean() throws {
        let song = Song(remoteId: "1", title: "Track", account: account)
        repository.context.insert(song)

        let result = LyricsExplicitEvaluator.applyIfNeeded(
            to: song,
            lyrics: "hello world",
            settings: UserSettings.default
        )

        XCTAssertEqual(result.status, .clean)
        XCTAssertEqual(song.lyricsExplicitStatus, .clean)
    }

    func testHidePolicyDropsOnlyNewlyExplicitQueuedSongs() {
        XCTAssertTrue(
            LyricsExplicitEvaluator.shouldRemoveNonCurrentFromQueue(
                hideExplicit: true,
                didChange: true,
                status: .explicit
            )
        )
        XCTAssertFalse(
            LyricsExplicitEvaluator.shouldRemoveNonCurrentFromQueue(
                hideExplicit: false,
                didChange: true,
                status: .explicit
            )
        )
        XCTAssertFalse(
            LyricsExplicitEvaluator.shouldRemoveNonCurrentFromQueue(
                hideExplicit: true,
                didChange: false,
                status: .explicit
            )
        )
        XCTAssertFalse(
            LyricsExplicitEvaluator.shouldRemoveNonCurrentFromQueue(
                hideExplicit: true,
                didChange: true,
                status: .clean
            )
        )
        XCTAssertFalse(
            LyricsExplicitEvaluator.shouldRemoveNonCurrentFromQueue(
                hideExplicit: true,
                didChange: true,
                status: .unknown
            )
        )
    }
}
