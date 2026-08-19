import XCTest
@testable import VerodromeKit

final class HomeGridAssemblerTests: XCTestCase {
    func testSixRecentsAreUnchanged() {
        let tiles = HomeGridAssembler.assemble(
            recents: ["a", "b", "c", "d", "e", "f"],
            fillers: ["g"],
            id: { $0 }
        )
        XCTAssertEqual(tiles, ["a", "b", "c", "d", "e", "f"])
    }

    func testFillersCompleteAShortRecentsList() {
        let tiles = HomeGridAssembler.assemble(
            recents: ["a", "b"],
            fillers: ["c", "d", "e", "f", "g"],
            id: { $0 }
        )
        XCTAssertEqual(tiles, ["a", "b", "c", "d", "e", "f"])
    }

    func testDuplicateFillersAreSkipped() {
        let tiles = HomeGridAssembler.assemble(
            recents: ["a", "b"],
            fillers: ["a", "c", "b", "d"],
            id: { $0 }
        )
        XCTAssertEqual(tiles, ["a", "b", "c", "d"])
    }

    func testOddCountWithoutFillersSnapsDown() {
        XCTAssertEqual(
            HomeGridAssembler.assemble(recents: ["a", "b", "c", "d", "e"], fillers: [], id: { $0 }),
            ["a", "b", "c", "d"]
        )
        XCTAssertEqual(
            HomeGridAssembler.assemble(recents: ["a"], fillers: [], id: { $0 }),
            []
        )
        XCTAssertEqual(
            HomeGridAssembler.assemble(recents: ["a", "b", "c"], fillers: [], id: { $0 }),
            ["a", "b"]
        )
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(HomeGridAssembler.assemble(recents: [String](), fillers: [], id: { $0 }).isEmpty)
    }
}
