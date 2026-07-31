import XCTest
@testable import VerodromeKit

@MainActor
final class PlayQueueHandlerTests: XCTestCase {
    private static func songs(_ count: Int) -> [QueueItem] {
        (0..<count).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
    }

    func testReplaceAndAdvance() {
        let handler = PlayQueueHandler()
        let items = (0..<5).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "1")
        XCTAssertEqual(handler.queueGeneration, 1)
    }

    func testWindowItems() {
        let handler = PlayQueueHandler()
        let items = (0..<10).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 4)
        let window = handler.windowItems(previous: 2, next: 5)
        XCTAssertEqual(window.map(\.playableId), ["2", "3", "4", "5", "6", "7", "8", "9"])
    }

    func testRetreatWrapsWhenRepeatAll() {
        let handler = PlayQueueHandler()
        let items = (0..<3).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        handler.setRepeat(.all)

        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "2")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "1")
    }

    func testRetreatDoesNotWrapWhenRepeatOff() {
        let handler = PlayQueueHandler()
        let items = (0..<3).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 0)
        handler.setRepeat(.off)

        XCTAssertEqual(handler.currentItem?.playableId, "0")
        _ = handler.retreat()
        XCTAssertEqual(handler.currentItem?.playableId, "0")
    }

    func testToggleShuffleLeadsWithPlayingTrackAndKeepsWholeContext() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 30)

        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .on)
        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "30")
        XCTAssertEqual(Set(handler.activeQueue.map(\.playableId)), Set(items.map(\.playableId)))
        XCTAssertNotEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
    }

    /// Play Next can insert a second copy of a song already in the context. Shuffle must
    /// keep the *playing* row, not the first id match.
    func testToggleShufflePrefersPlayingRowWhenIdsDuplicate() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 2) // playing "2"
        handler.enqueueNext([QueueItem(playableId: "2", title: "Song 2 queued")])
        // Queue is [0, 1, 2, 2(user)]; still playing the context copy at index 2.
        XCTAssertEqual(handler.currentIndex, 2)
        XCTAssertFalse(handler.activeQueue[2].isUserQueued)

        handler.toggleShuffle()

        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "2")
        XCTAssertFalse(handler.currentItem?.isUserQueued == true)
        XCTAssertEqual(handler.activeQueue.filter { $0.playableId == "2" }.count, 2)
    }

    func testTogglingShuffleOffRestoresOriginalOrderAndIndex() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.replaceContext(with: items, startAt: 12)

        handler.toggleShuffle()
        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .off)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
        XCTAssertEqual(handler.currentItem?.playableId, "12")
    }

    /// A context started in shuffle mode must remember the order it arrived in, so the
    /// button can un-shuffle back to it.
    func testShuffledContextUnshufflesToIncomingOrder() {
        let handler = PlayQueueHandler()
        let items = (0..<40).map { QueueItem(playableId: "\($0)", title: "Song \($0)") }
        handler.setShuffle(.on, reorder: false)
        handler.replaceContext(with: items, startAt: 7)

        XCTAssertNotEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))

        handler.toggleShuffle()

        XCTAssertEqual(handler.shuffleMode, .off)
        XCTAssertEqual(handler.activeQueue.map(\.playableId), items.map(\.playableId))
        XCTAssertEqual(handler.currentItem?.playableId, "7")
    }

    func testMoveFromAbovePlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 1), to: 9)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "2", "3", "4", "5", "6", "7", "8", "1", "9"])
        XCTAssertEqual(handler.currentIndex, 4)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMoveFromBelowPlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 8), to: 0)

        XCTAssertEqual(handler.currentIndex, 6)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMovingThePlayingTrackFollowsIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet(integer: 5), to: 0)

        XCTAssertEqual(handler.currentIndex, 0)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testMultiRowMoveLandsContiguously() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 5)

        handler.move(from: IndexSet([0, 1]), to: 10)

        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["2", "3", "4", "5", "6", "7", "8", "9", "0", "1"])
        XCTAssertEqual(handler.currentIndex, 3)
        XCTAssertEqual(handler.currentItem?.playableId, "5")
    }

    func testEnqueueMarksItemsAsUserQueued() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(3), startAt: 0)

        handler.enqueueNext([QueueItem(playableId: "next", title: "Next")])
        handler.enqueueLast([QueueItem(playableId: "last", title: "Last")])

        XCTAssertEqual(handler.activeQueue.filter(\.isUserQueued).map(\.playableId), ["next", "last"])
        XCTAssertFalse(handler.activeQueue[0].isUserQueued)
    }

    func testRemoveOnlyTakesUserQueuedRows() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 0)
        handler.enqueueNext([QueueItem(playableId: "queued", title: "Queued")])

        handler.remove(at: IndexSet(integer: 2))
        XCTAssertEqual(handler.activeQueue.count, 6, "context rows must not be removable")

        handler.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(handler.activeQueue.map(\.playableId), ["0", "1", "2", "3", "4"])
    }

    func testRemovingRowAbovePlayingTrackKeepsPointerOnIt() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(5), startAt: 0)
        handler.enqueueNext([QueueItem(playableId: "queued", title: "Queued")])
        _ = handler.advance()
        _ = handler.advance()
        XCTAssertEqual(handler.currentItem?.playableId, "1")

        handler.remove(at: IndexSet(integer: 1))

        XCTAssertEqual(handler.currentIndex, 1)
        XCTAssertEqual(handler.currentItem?.playableId, "1")
    }

    func testUnshufflingKeepsQueueEditsMadeWhileShuffled() {
        let handler = PlayQueueHandler()
        handler.replaceContext(with: Self.songs(10), startAt: 0)
        handler.toggleShuffle()

        handler.enqueueLast([
            QueueItem(playableId: "kept", title: "Kept"),
            QueueItem(playableId: "dropped", title: "Dropped")
        ])
        let removeAt = handler.activeQueue.firstIndex { $0.playableId == "dropped" }!
        handler.remove(at: IndexSet(integer: removeAt))

        handler.toggleShuffle()

        let ids = handler.activeQueue.map(\.playableId)
        XCTAssertEqual(ids, ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "kept"])
    }
}
