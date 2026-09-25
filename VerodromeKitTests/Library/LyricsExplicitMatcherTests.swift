import XCTest
@testable import VerodromeKit

final class LyricsExplicitMatcherTests: XCTestCase {
    func testWholeWordMatchDoesNotHitEmbeddedSubstrings() {
        let words = LyricsExplicitWordLists.words(for: .conservative)
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("in a first-class cabin", words: words))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("the assassin waited", words: words))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("kiss my ass goodbye", words: words))
    }

    func testStripsLrcTimestampsBeforeMatching() {
        let words: Set<String> = ["fuck"]
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("[00:12.00]what the fuck\n[00:13.00]chorus", words: words))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("[ar:Artist]\n[ti:Song]\n[00:01.00]hello world", words: words))
    }

    func testEmptyLyricsAreNotExplicit() {
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("", words: ["fuck"]))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("   \n  ", words: ["fuck"]))
    }

    func testWhitelistRemovesPresetWords() {
        var settings = UserSettings.default
        settings.explicitSensitivity = .average
        settings.explicitWhitelistWords = ["fuck"]
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("what the fuck", settings: settings))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("this is pussy", settings: settings))
    }

    func testWhitelistOverridesTheSameBlacklistedWord() {
        var settings = UserSettings.default
        settings.explicitSensitivity = .loose
        settings.explicitBlacklistWords = ["banana"]
        settings.explicitWhitelistWords = ["banana"]
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("banana phone", settings: settings))
    }

    func testBlacklistAddsCustomWords() {
        var settings = UserSettings.default
        settings.explicitSensitivity = .loose
        settings.explicitBlacklistWords = ["banana"]
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("banana phone", settings: settings))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("this is shit", settings: settings))
    }

    func testPresetsNest() {
        XCTAssertTrue(LyricsExplicitWordLists.average.isSuperset(of: LyricsExplicitWordLists.loose))
        XCTAssertTrue(LyricsExplicitWordLists.conservative.isSuperset(of: LyricsExplicitWordLists.average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("oh hell no", words: LyricsExplicitWordLists.conservative))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("oh hell no", words: LyricsExplicitWordLists.average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("this is pussy", words: LyricsExplicitWordLists.average))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("this is pussy", words: LyricsExplicitWordLists.loose))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("what the fuck", words: LyricsExplicitWordLists.loose))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("this is shit", words: LyricsExplicitWordLists.conservative))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("this is shit", words: LyricsExplicitWordLists.average))
    }

    func testStarredSpellingMatchesAverageList() {
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("what the f*ck", words: LyricsExplicitWordLists.average))
    }

    func testCaseAndDiacriticsAreIgnored() {
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("WHAT THE FUCK", words: ["fuck"]))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("café fuck", words: ["fuck"]))
    }

    func testCommonForeignCursesNestBySensitivity() {
        let loose = LyricsExplicitWordLists.words(for: .loose)
        let average = LyricsExplicitWordLists.words(for: .average)
        let conservative = LyricsExplicitWordLists.words(for: .conservative)

        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("no me joder", words: loose))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("qué mierda", words: conservative))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("qué mierda", words: average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("putain de merde", words: conservative))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("putain de merde", words: average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("scheiße drauf", words: average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("che cazzo fai", words: average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("porcodio", words: loose))
        XCTAssertFalse(LyricsExplicitMatcher.isExplicit("pinche canción", words: average))
        XCTAssertTrue(LyricsExplicitMatcher.isExplicit("pinche canción", words: conservative))
    }

    func testMatchingRangesHighlightWholeTokensOnly() {
        let words = LyricsExplicitWordLists.words(for: .conservative)
        let text = "kiss my ass goodbye in a first-class cabin"
        let hits = LyricsExplicitMatcher.matchingRanges(in: text, words: words).map { String(text[$0]) }
        XCTAssertEqual(hits, ["ass"])
    }

    func testMatchingRangesKeepOriginalCasing() {
        let text = "what the FUCK"
        let ranges = LyricsExplicitMatcher.matchingRanges(in: text, words: ["fuck"])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["FUCK"])
    }

    func testMatchingRangesFollowWhitelistAndBlacklist() {
        var settings = UserSettings.default
        settings.explicitSensitivity = .average
        settings.explicitWhitelistWords = ["fuck"]
        settings.explicitBlacklistWords = ["banana"]
        let words = LyricsExplicitMatcher.activeWords(in: settings)
        XCTAssertTrue(LyricsExplicitMatcher.matchingRanges(in: "what the fuck", words: words).isEmpty)
        let banana = "banana phone"
        XCTAssertEqual(
            LyricsExplicitMatcher.matchingRanges(in: banana, words: words).map { String(banana[$0]) },
            ["banana"]
        )
    }
}
