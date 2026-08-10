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

    func testResolveSkipsTranscodeForOriginalOrKnownLossy() {
        let original = AudioTranscodeResolver.resolve(quality: .original, contentType: "flac")
        XCTAssertNil(original.maxBitRate)
        XCTAssertNil(original.format)

        let lossy = AudioTranscodeResolver.resolve(quality: .mp3_320, contentType: "mp3")
        XCTAssertNil(lossy.maxBitRate)
        XCTAssertNil(lossy.format)

        let mpeg = AudioTranscodeResolver.resolve(quality: .mp3_192, contentType: "audio/mpeg")
        XCTAssertNil(mpeg.maxBitRate)
        XCTAssertNil(mpeg.format)
    }

    func testResolveRequestsMp3ForLosslessOrUnknown() {
        let flac = AudioTranscodeResolver.resolve(quality: .mp3_192, contentType: "flac")
        XCTAssertEqual(flac.maxBitRate, 192)
        XCTAssertEqual(flac.format, .mp3)

        let wav = AudioTranscodeResolver.resolve(quality: .mp3_320, contentType: "audio/wav")
        XCTAssertEqual(wav.maxBitRate, 320)
        XCTAssertEqual(wav.format, .mp3)

        let unknown = AudioTranscodeResolver.resolve(quality: .mp3_256, contentType: nil)
        XCTAssertEqual(unknown.maxBitRate, 256)
        XCTAssertEqual(unknown.format, .mp3)
    }

    func testStorageQualityMatchesWhatDownloadManagerWrites() {
        XCTAssertEqual(
            AudioTranscodeResolver.storageQuality(requested: .mp3_320, contentType: "mp3"),
            .original,
            "known lossy must not look for an .mp3.320 suffix that was never written"
        )
        XCTAssertEqual(
            AudioTranscodeResolver.storageQuality(requested: .mp3_320, contentType: "flac"),
            .mp3_320
        )
        XCTAssertEqual(
            AudioTranscodeResolver.storageQuality(requested: .original, contentType: "flac"),
            .original
        )
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
