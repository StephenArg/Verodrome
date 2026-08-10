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
}
