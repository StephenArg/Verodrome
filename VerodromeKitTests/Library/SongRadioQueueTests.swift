import XCTest
@testable import VerodromeKit

final class SongRadioQueueTests: XCTestCase {
    func testMakeItemsPutsSeedFirstAndDropsDuplicates() {
        let seed = QueueItem(playableId: "seed", title: "Seed")
        let similar = [
            IngestSong(id: "seed", title: "Seed Echo"),
            IngestSong(id: "a", title: "A"),
            IngestSong(id: "a", title: "A Dup"),
            IngestSong(id: "b", title: "B"),
            IngestSong(id: "", title: "Blank")
        ]

        let items = SongRadioQueue.makeItems(seed: seed, similar: similar)
        XCTAssertEqual(items.map(\.playableId), ["seed", "a", "b"])
        XCTAssertEqual(items.first?.title, "Seed")
        XCTAssertEqual(items[1].title, "A")
    }

    func testMakeItemsWithOnlySeedEchoesIsJustSeed() {
        let seed = QueueItem(playableId: "seed", title: "Seed")
        let items = SongRadioQueue.makeItems(
            seed: seed,
            similar: [IngestSong(id: "seed", title: "Echo")]
        )
        XCTAssertEqual(items.map(\.playableId), ["seed"])
    }

    func testMakeItemsEmptySimilarIsJustSeed() {
        let seed = QueueItem(playableId: "seed", title: "Seed")
        let items = SongRadioQueue.makeItems(seed: seed, similar: [])
        XCTAssertEqual(items.map(\.playableId), ["seed"])
    }

    func testMakeContinuationItemsMarksFlagAndExcludesQueued() {
        let similar = [
            IngestSong(id: "a", title: "A"),
            IngestSong(id: "b", title: "B"),
            IngestSong(id: "c", title: "C")
        ]
        let items = SongRadioQueue.makeContinuationItems(
            similar: similar,
            excluding: ["b"]
        )
        XCTAssertEqual(items.map(\.playableId), ["a", "c"])
        XCTAssertTrue(items.allSatisfy(\.isRadioContinuation))
        XCTAssertFalse(items.contains(where: \.isUserQueued))
    }

    func testZipperMergeInterleavesAndDropsCrossListDuplicates() {
        let a = [
            QueueItem(playableId: "a1", title: "A1", isRadioContinuation: true),
            QueueItem(playableId: "a2", title: "A2", isRadioContinuation: true),
            QueueItem(playableId: "dup", title: "Dup A", isRadioContinuation: true)
        ]
        let b = [
            QueueItem(playableId: "b1", title: "B1", isRadioContinuation: true),
            QueueItem(playableId: "dup", title: "Dup B", isRadioContinuation: true)
        ]
        let c = [
            QueueItem(playableId: "c1", title: "C1", isRadioContinuation: true)
        ]
        let merged = SongRadioQueue.zipperMerge([a, b, c])
        XCTAssertEqual(merged.map(\.playableId), ["a1", "b1", "c1", "a2", "dup"])
    }

    func testPickContinuationSeedsUsesAllWhenFew() {
        let queue = [
            QueueItem(playableId: "1", title: "One"),
            QueueItem(playableId: "2", title: "Two")
        ]
        let seeds = SongRadioQueue.pickContinuationSeeds(from: queue)
        XCTAssertEqual(Set(seeds.map(\.playableId)), Set(["1", "2"]))
    }

    func testPickContinuationSeedsCapsAtThreeDistinct() {
        let queue = (0..<10).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        let seeds = SongRadioQueue.pickContinuationSeeds(from: queue)
        XCTAssertEqual(seeds.count, 3)
        XCTAssertEqual(Set(seeds.map(\.playableId)).count, 3)
    }

    func testBuildContinuationSingleSeedIsFullList() {
        let seed = QueueItem(playableId: "seed", title: "Seed")
        let similar = (0..<5).map { IngestSong(id: "s\($0)", title: "S\($0)") }
        let items = SongRadioQueue.buildContinuation(
            seedResults: [(seed, similar)],
            excluding: ["seed"]
        )
        XCTAssertEqual(items.map(\.playableId), ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertTrue(items.allSatisfy(\.isRadioContinuation))
    }

    func testBuildContinuationZippersMultipleSeeds() {
        let seedA = QueueItem(playableId: "a", title: "A")
        let seedB = QueueItem(playableId: "b", title: "B")
        let items = SongRadioQueue.buildContinuation(
            seedResults: [
                (seedA, [IngestSong(id: "a1", title: "A1"), IngestSong(id: "a2", title: "A2")]),
                (seedB, [IngestSong(id: "b1", title: "B1"), IngestSong(id: "b2", title: "B2")])
            ],
            excluding: ["a", "b"]
        )
        XCTAssertEqual(items.map(\.playableId), ["a1", "b1", "a2", "b2"])
    }

    func testContinuationExclusionAllowsAlreadyPlayedForArtistAndGenreOnly() {
        var queue = (0..<5).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        queue.append(QueueItem(playableId: "r0", title: "Radio", isRadioContinuation: true))

        let artistExcluded = SongRadioQueue.continuationExclusionIDs(
            queue: queue,
            currentIndex: 3,
            origin: .artist("Radiohead")
        )
        XCTAssertEqual(artistExcluded, Set(["3", "4", "r0"]))

        let genreExcluded = SongRadioQueue.continuationExclusionIDs(
            queue: queue,
            currentIndex: 3,
            origin: .genre("Rock")
        )
        XCTAssertEqual(genreExcluded, Set(["3", "4", "r0"]))

        let albumExcluded = SongRadioQueue.continuationExclusionIDs(
            queue: queue,
            currentIndex: 3,
            origin: .album("OK Computer")
        )
        XCTAssertEqual(albumExcluded, Set(["0", "1", "2", "3", "4", "r0"]))

        let playlistExcluded = SongRadioQueue.continuationExclusionIDs(
            queue: queue,
            currentIndex: 3,
            origin: .playlist("Favorites")
        )
        XCTAssertEqual(playlistExcluded, Set(["0", "1", "2", "3", "4", "r0"]))
    }

    func testBuildGenreContinuationZippersAndDedupes() {
        let rock = [
            QueueItem(playableId: "r1", title: "Rock 1"),
            QueueItem(playableId: "shared", title: "Shared"),
            QueueItem(playableId: "r2", title: "Rock 2")
        ]
        let jazz = [
            QueueItem(playableId: "j1", title: "Jazz 1"),
            QueueItem(playableId: "shared", title: "Shared Again"),
            QueueItem(playableId: "j2", title: "Jazz 2")
        ]
        let items = SongRadioQueue.buildGenreContinuation(
            genreLists: [rock, jazz],
            excluding: ["r1"]
        )
        XCTAssertEqual(items.map(\.playableId), ["shared", "j1", "r2", "j2"])
        XCTAssertTrue(items.allSatisfy(\.isRadioContinuation))
    }

    func testQueueOriginRadioSectionTitle() {
        XCTAssertEqual(QueueOrigin.album("Abbey Road").radioSectionTitle, "Abbey Road radio")
        XCTAssertEqual(QueueOrigin.playlist("Favorites").radioSectionTitle, "Favorites radio")
        XCTAssertEqual(QueueOrigin.artist("Radiohead").radioSectionTitle, "Radiohead radio")
        XCTAssertEqual(QueueOrigin.song("").radioSectionTitle, "Radio")
    }
}
