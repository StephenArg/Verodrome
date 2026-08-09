import XCTest
@testable import VerodromeKit

final class AudioTranscodeResolverTests: XCTestCase {
    func testIsLosslessRecognizesCommonSuffixesAndMimeTypes() {
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "flac"))
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "WAV"))
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "audio/flac"))
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "audio/x-wav"))
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "aiff"))
        XCTAssertTrue(AudioTranscodeResolver.isLossless(contentType: "alac"))
        XCTAssertFalse(AudioTranscodeResolver.isLossless(contentType: "mp3"))
        XCTAssertFalse(AudioTranscodeResolver.isLossless(contentType: "audio/mpeg"))
        XCTAssertFalse(AudioTranscodeResolver.isLossless(contentType: "opus"))
        XCTAssertFalse(AudioTranscodeResolver.isLossless(contentType: nil))
        XCTAssertFalse(AudioTranscodeResolver.isLossless(contentType: ""))
    }

    func testResolveSkipsTranscodeForOriginalOrLossy() {
        let original = AudioTranscodeResolver.resolve(quality: .original, contentType: "flac")
        XCTAssertNil(original.maxBitRate)
        XCTAssertNil(original.format)

        let lossy = AudioTranscodeResolver.resolve(quality: .mp3_320, contentType: "mp3")
        XCTAssertNil(lossy.maxBitRate)
        XCTAssertNil(lossy.format)

        let unknown = AudioTranscodeResolver.resolve(quality: .mp3_256, contentType: nil)
        XCTAssertNil(unknown.maxBitRate)
        XCTAssertNil(unknown.format)
    }

    func testResolveRequestsMp3ForLossless() {
        let resolved = AudioTranscodeResolver.resolve(quality: .mp3_192, contentType: "flac")
        XCTAssertEqual(resolved.maxBitRate, 192)
        XCTAssertEqual(resolved.format, .mp3)

        let high = AudioTranscodeResolver.resolve(quality: .mp3_320, contentType: "audio/wav")
        XCTAssertEqual(high.maxBitRate, 320)
        XCTAssertEqual(high.format, .mp3)
    }

    func testLegacyStreamFormatPreferenceMigration() {
        XCTAssertEqual(StreamFormatPreference.mp3.asTranscodeQuality, .mp3_320)
        XCTAssertEqual(StreamFormatPreference.original.asTranscodeQuality, .original)
        XCTAssertEqual(StreamFormatPreference.flac.asTranscodeQuality, .original)
    }

    func testUserSettingsMigratesLegacyCacheTranscodingFormat() throws {
        let legacyJSON = """
        {"cacheTranscodingFormat":"mp3","streamingBitrateWifi":320,"streamingBitrateCellular":192}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(UserSettings.self, from: legacyJSON)
        XCTAssertEqual(settings.streamingQualityWifi, .mp3_320)
        XCTAssertEqual(settings.streamingQualityCellular, .mp3_320)
        XCTAssertEqual(settings.downloadTranscodeQuality, .original)
    }
}
