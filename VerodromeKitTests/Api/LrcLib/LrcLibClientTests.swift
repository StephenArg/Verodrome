import XCTest
@testable import VerodromeKit

final class LrcLibClientTests: XCTestCase {
    private func makeClient() -> LrcLibClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return LrcLibClient(session: session, baseURL: URL(string: "https://lrclib.test")!, userAgent: "Test/1.0")
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testPrefersSyncedOverPlain() async {
        StubURLProtocol.handler = { _ in
            let body = """
            {"syncedLyrics": "[00:01.00]Synced", "plainLyrics": "Plain", "instrumental": false}
            """
            return (Self.ok, Data(body.utf8))
        }
        let text = await makeClient().fetchLyrics(
            query: .init(trackName: "Song", artistName: "Artist")
        )
        XCTAssertEqual(text, "[00:01.00]Synced")
    }

    func testFallsBackToPlainWhenSyncedEmpty() async {
        StubURLProtocol.handler = { _ in
            let body = """
            {"syncedLyrics": "  ", "plainLyrics": "Plain lyrics", "instrumental": false}
            """
            return (Self.ok, Data(body.utf8))
        }
        let text = await makeClient().fetchLyrics(
            query: .init(trackName: "Song", artistName: "Artist")
        )
        XCTAssertEqual(text, "Plain lyrics")
    }

    func testInstrumentalReturnsNil() async {
        StubURLProtocol.handler = { _ in
            let body = """
            {"syncedLyrics": null, "plainLyrics": null, "instrumental": true}
            """
            return (Self.ok, Data(body.utf8))
        }
        let text = await makeClient().fetchLyrics(
            query: .init(trackName: "Song", artistName: "Artist")
        )
        XCTAssertNil(text)
    }

    func testNotFoundReturnsNil() async {
        StubURLProtocol.handler = { request in
            (Self.status(404, url: request.url!), Data("{\"code\":404}".utf8))
        }
        let text = await makeClient().fetchLyrics(
            query: .init(trackName: "Song", artistName: "Artist")
        )
        XCTAssertNil(text)
    }

    func testMissingTitleOrArtistSkipsRequest() async {
        var called = false
        StubURLProtocol.handler = { request in
            called = true
            return (Self.ok, Data("{}".utf8))
        }
        let text = await makeClient().fetchLyrics(
            query: .init(trackName: "  ", artistName: "Artist")
        )
        XCTAssertNil(text)
        XCTAssertFalse(called)
    }

    func testBuildsQueryWithAlbumAndDuration() async {
        var captured: URLComponents?
        StubURLProtocol.handler = { request in
            captured = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            return (Self.ok, Data("{\"plainLyrics\": \"x\"}".utf8))
        }
        _ = await makeClient().fetchLyrics(
            query: .init(trackName: "I Want to Live", artistName: "Borislav Slavov", albumName: "BG3", duration: 233.4)
        )
        let items = captured?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "track_name" }?.value, "I Want to Live")
        XCTAssertEqual(items.first { $0.name == "artist_name" }?.value, "Borislav Slavov")
        XCTAssertEqual(items.first { $0.name == "album_name" }?.value, "BG3")
        XCTAssertEqual(items.first { $0.name == "duration" }?.value, "233")
        XCTAssertEqual(captured?.path, "/api/get")
    }

    func testOutOfRangeDurationOmitted() async {
        var captured: URLComponents?
        StubURLProtocol.handler = { request in
            captured = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            return (Self.ok, Data("{\"plainLyrics\": \"x\"}".utf8))
        }
        _ = await makeClient().fetchLyrics(
            query: .init(trackName: "Song", artistName: "Artist", duration: 5000)
        )
        XCTAssertNil((captured?.queryItems ?? []).first { $0.name == "duration" })
    }

    // MARK: - Helpers

    private static let ok = HTTPURLResponse(
        url: URL(string: "https://lrclib.test/api/get")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!

    private static func status(_ code: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
}

/// Minimal URLProtocol stub so the client can be tested without network access.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
