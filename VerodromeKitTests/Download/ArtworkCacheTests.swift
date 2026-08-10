import XCTest
import UIKit
@testable import VerodromeKit

final class ArtworkCacheTests: XCTestCase {
    final class MockURLProvider: ArtworkURLProviding, @unchecked Sendable {
        func artworkURL(forArtId artId: String, kind: ArtworkKind, size: Int?) async throws -> URL {
            URL(string: "https://example.com/art/\(artId)?size=\(size ?? 0)")!
        }
    }

    private var cacheDirectory: URL!

    override func setUpWithError() throws {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func makeManager() -> ArtworkDownloadManager {
        ArtworkDownloadManager(urlProvider: MockURLProvider(), cacheDirectory: cacheDirectory)
    }

    /// Writes a real PNG so decode paths have something to work with.
    @discardableResult
    private func writeRender(artId: String, size: Int, pixels: CGFloat = 64) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        let url = cacheDirectory.appendingPathComponent("\(artId)_s\(size)")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    /// Renders cached by a previous launch have to be found without re-downloading them:
    /// the manager builds its lookup table from the directory, not from its own writes.
    func testFindsRendersWrittenBeforeLaunch() async throws {
        let expected = try writeRender(artId: "album1", size: 120)
        let manager = makeManager()

        let found = await manager.localURL(for: "album1", size: 120)
        let hasRender = await manager.hasLocalRender(for: "album1", size: 120)
        XCTAssertEqual(found, expected)
        XCTAssertTrue(hasRender)
    }

    func testMissingTokenHasNoLocalRender() async throws {
        try writeRender(artId: "album1", size: 120)
        let manager = makeManager()

        let found = await manager.localURL(for: "album2", size: 120)
        let hasRender = await manager.hasLocalRender(for: "album2", size: 120)
        let hasRenderForNilToken = await manager.hasLocalRender(for: nil, size: 120)
        XCTAssertNil(found)
        XCTAssertFalse(hasRender)
        XCTAssertFalse(hasRenderForNilToken)
    }

    /// A larger render is a valid answer for a smaller request — the decode downsamples it.
    func testLargerRenderSatisfiesSmallerRequest() async throws {
        let expected = try writeRender(artId: "album1", size: 1200)
        let manager = makeManager()

        let found = await manager.localURL(for: "album1", size: 300)
        let hasRender = await manager.hasLocalRender(for: "album1", size: 300)
        XCTAssertEqual(found, expected)
        XCTAssertTrue(hasRender)
    }

    /// Covers cached at 1200px by an earlier version still answer today's requests, so
    /// lowering the largest requested size doesn't make everyone re-download their library.
    func testOversizedRenderFromEarlierVersionIsReused() async throws {
        let expected = try writeRender(artId: "album1", size: 1200)
        let manager = makeManager()

        let found = await manager.localURL(for: "album1", size: ArtworkDownloadManager.largestRequestedSize)
        XCTAssertEqual(found, expected)
        let standIn = await manager.downgradedCachedImage(
            for: "album1",
            size: ArtworkDownloadManager.largestRequestedSize
        )
        XCTAssertNil(standIn, "no stand-in needed when a usable render is already on disk")
    }

    /// The reverse doesn't hold: a 120px file can't stand in as the real 1200px render,
    /// otherwise a hero would keep a blurry image forever instead of fetching a sharp one.
    func testSmallerRenderDoesNotSatisfyLargerRequest() async throws {
        try writeRender(artId: "album1", size: 120)
        let manager = makeManager()

        let found = await manager.localURL(for: "album1", size: 1200)
        XCTAssertNil(found)
    }

    /// ...but it is good enough to show while the sharp one downloads.
    func testDowngradedImageUsesSmallerRender() async throws {
        try writeRender(artId: "album1", size: 120)
        let manager = makeManager()

        let standIn = await manager.downgradedCachedImage(for: "album1", size: 1200)
        XCTAssertNotNil(standIn)
    }

    /// When the request can already be served from disk, the stand-in would just decode the
    /// same file a second time, so there shouldn't be one.
    func testNoDowngradedImageWhenRequestedSizeIsCached() async throws {
        try writeRender(artId: "album1", size: 1200)
        let manager = makeManager()

        let standIn = await manager.downgradedCachedImage(for: "album1", size: 1200)
        XCTAssertNil(standIn)
    }

    func testNoDowngradedImageWhenNothingIsCached() async {
        let manager = makeManager()

        let standIn = await manager.downgradedCachedImage(for: "album1", size: 1200)
        XCTAssertNil(standIn)
        let empty = await manager.downgradedCachedImage(for: nil, size: 1200)
        XCTAssertNil(empty)
    }

    /// Embedded artwork is stored under size 0 and has to stay findable after the write.
    func testStoredArtworkIsFoundAfterWrite() async throws {
        let manager = makeManager()
        let data = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
                .image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
                .pngData()
        )

        await manager.storeEmbeddedArtwork(artId: "embedded-song1", data: data)

        let found = await manager.localURL(for: "embedded-song1", size: 0)
        XCTAssertNotNil(found)
    }

    /// UI always asks for a standard pixel size; size-0 embedded art still has to answer.
    func testEmbeddedSizeZeroSatisfiesStandardRequest() async throws {
        let manager = makeManager()
        let data = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
                .image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
                .pngData()
        )

        await manager.storeEmbeddedArtwork(artId: "embedded-song1", data: data)

        let found = await manager.localURL(for: "embedded-song1", size: 300)
        let image = await manager.loadImage(for: "embedded-song1", size: 300)
        XCTAssertNotNil(found)
        XCTAssertNotNil(image)
    }

    func testClearCacheDropsRenders() async throws {
        try writeRender(artId: "album1", size: 120)
        let manager = makeManager()
        let beforeClear = await manager.localURL(for: "album1", size: 120)
        XCTAssertNotNil(beforeClear)

        try await manager.clearCache()

        let afterClear = await manager.localURL(for: "album1", size: 120)
        let stats = await manager.cacheStats()
        XCTAssertNil(afterClear)
        XCTAssertEqual(stats.fileCount, 0)
    }
}
