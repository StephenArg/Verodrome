import XCTest
@testable import VerodromeKit

final class ScrobbleTimingTests: XCTestCase {
    private let threeMinutes: TimeInterval = 180
    private let twentyMinutes: TimeInterval = 20 * 60

    func testNeverHasNoThreshold() {
        XCTAssertNil(ScrobbleTiming.never.threshold(forDuration: threeMinutes))
    }

    func testOnStartQualifiesImmediately() {
        XCTAssertEqual(ScrobbleTiming.onStart.threshold(forDuration: threeMinutes), 0)
    }

    func testPercentageThresholdsScaleWithDuration() {
        XCTAssertEqual(ScrobbleTiming.quarter.threshold(forDuration: threeMinutes), 45)
        XCTAssertEqual(ScrobbleTiming.threeQuarters.threshold(forDuration: threeMinutes), 135)
    }

    /// The Last.fm rule: half the track, unless four minutes comes first.
    func testStandardUsesHalfOfAShortTrack() {
        XCTAssertEqual(ScrobbleTiming.standard.threshold(forDuration: threeMinutes), 90)
    }

    func testStandardCapsLongTracksAtFourMinutes() {
        XCTAssertEqual(ScrobbleTiming.standard.threshold(forDuration: twentyMinutes), 240)
    }

    /// Playback moves on before the clock reaches the full duration, so the end has to
    /// land slightly early to be reachable at all.
    func testOnFinishLandsJustBeforeTheEnd() {
        XCTAssertEqual(ScrobbleTiming.onFinish.threshold(forDuration: threeMinutes), 179)
    }

    func testOnFinishNeverGoesNegativeForVeryShortTracks() {
        XCTAssertEqual(ScrobbleTiming.onFinish.threshold(forDuration: 0.5), 0)
    }

    func testDecodingFallsBackToStandardWhenAbsent() throws {
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.scrobbleTiming, .standard)
    }

    func testTimingSurvivesARoundTrip() throws {
        var settings = UserSettings()
        settings.scrobbleTiming = .onFinish
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertEqual(decoded.scrobbleTiming, .onFinish)
    }
}
