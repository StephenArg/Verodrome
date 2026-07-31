import XCTest
@testable import VerodromeKit

@MainActor
final class PlayQueueHandlerTests: XCTestCase {
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
}
