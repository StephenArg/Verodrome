import XCTest
@testable import VerodromeKit

final class DeepLinkRouterTests: XCTestCase {
    func testPlayQuery() {
        let url = URL(string: "verodrome://play?q=Hello%20World")!
        XCTAssertEqual(DeepLinkRouter.parse(url), .play(query: "Hello World"))
    }

    func testXCallbackSearch() {
        let url = URL(string: "verodrome://x-callback-url/search?query=jazz")!
        XCTAssertEqual(DeepLinkRouter.parse(url), .search(query: "jazz"))
    }

    func testNavigateLibrary() {
        let url = URL(string: "verodrome://library")!
        XCTAssertEqual(DeepLinkRouter.parse(url), .navigate(destination: "library"))
    }
}
