import XCTest
@testable import VerodromeKit

final class LyricsParserTests: XCTestCase {
    func testPlainLyricsHaveNoTimestamps() {
        let lines = LyricsParser.parse("Line one\nLine two\n\nLine three")
        XCTAssertEqual(lines.map(\.text), ["Line one", "Line two", "", "Line three"])
        XCTAssertTrue(lines.allSatisfy { $0.start == nil })
        XCTAssertFalse(LyricsParser.isSynced(lines))
    }

    func testHundredthsAndMillisecondFractions() {
        let lines = LyricsParser.parse("[00:12.34]Hundredths\n[00:13.456]Milliseconds\n[01:05]Whole seconds")
        XCTAssertTrue(LyricsParser.isSynced(lines))
        XCTAssertEqual(lines.map(\.text), ["Hundredths", "Milliseconds", "Whole seconds"])
        XCTAssertEqual(lines[0].start ?? 0, 12.34, accuracy: 0.001)
        XCTAssertEqual(lines[1].start ?? 0, 13.456, accuracy: 0.001)
        XCTAssertEqual(lines[2].start ?? 0, 65, accuracy: 0.001)
    }

    func testMetadataTagsAreSkipped() {
        let lines = LyricsParser.parse("[ar:Alpha]\n[ti:Song One]\n[00:01.00]Only lyric")
        XCTAssertEqual(lines.map(\.text), ["Only lyric"])
    }

    func testOffsetTagShiftsTimestamps() {
        // A positive LRC offset means the lyrics should appear earlier.
        let lines = LyricsParser.parse("[offset:500]\n[00:10.00]Shifted")
        XCTAssertEqual(lines[0].start ?? 0, 9.5, accuracy: 0.001)
    }

    func testMultipleTimestampsOnOneLineAreExpanded() {
        let lines = LyricsParser.parse("[00:05.00][01:05.00]Chorus\n[00:30.00]Verse")
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Verse", "Chorus"])
        XCTAssertEqual(lines.map { $0.start ?? 0 }, [5, 30, 65])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
    }

    func testEmptyTimedLinesAreDropped() {
        let lines = LyricsParser.parse("[00:00.00]\n[00:05.00]Only line")
        XCTAssertEqual(lines.map(\.text), ["Only line"])
    }

    func testActiveIndexBoundaries() {
        let lines = LyricsParser.parse("[00:05.00]One\n[00:10.00]Two\n[00:15.00]Three")
        XCTAssertNil(LyricsParser.activeIndex(in: lines, at: 0))
        XCTAssertNil(LyricsParser.activeIndex(in: lines, at: 4.99))
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 5), 0)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 9.9), 0)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 10), 1)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 999), 2)
    }

    func testActiveIndexIsNilForUnsyncedLyrics() {
        let lines = LyricsParser.parse("Line one\nLine two")
        XCTAssertNil(LyricsParser.activeIndex(in: lines, at: 42))
    }

    func testEmptyInputProducesNoLines() {
        XCTAssertTrue(LyricsParser.parse("").isEmpty)
        XCTAssertTrue(LyricsParser.parse("   \n  ").isEmpty)
    }

    func testTimestampRendering() {
        XCTAssertEqual(LyricsParser.timestamp(forMilliseconds: 0), "[00:00.00]")
        XCTAssertEqual(LyricsParser.timestamp(forMilliseconds: 12_340), "[00:12.34]")
        XCTAssertEqual(LyricsParser.timestamp(forMilliseconds: 65_500), "[01:05.50]")
        XCTAssertEqual(LyricsParser.timestamp(forMilliseconds: -100), "[00:00.00]")
    }
}
