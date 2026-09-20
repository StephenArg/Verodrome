import XCTest
@testable import VerodromeKit

final class CredentialFailureTests: XCTestCase {
    /// Subsonic/Navidrome use `40` for a wrong password. That is the only Subsonic code
    /// that means the stored secret is dead — `41` is "try another auth scheme", `50` is
    /// "you can't do this operation".
    func testMatchesWrongPasswordAndHandshakeCodesOnly() {
        XCTAssertTrue(CredentialFailure.matches(XmlParseError.serverError(code: 40, message: "Wrong username or password")))
        XCTAssertTrue(CredentialFailure.matches(XmlParseError.serverError(code: 4703, message: "Invalid Handshake")))
        XCTAssertTrue(CredentialFailure.matches(BackendApiError.http(status: 401, message: "unauthorized")))

        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 41, message: "Token auth not supported")))
        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 42, message: "Auth mechanism not supported")))
        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 50, message: "Not authorized")))
        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 70, message: "Not found")))
        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 4701, message: "Session expired")))
        // Ampache XML 401 is ACCESS_DENIED (permissions), not HTTP 401.
        XCTAssertFalse(CredentialFailure.matches(XmlParseError.serverError(code: 401, message: "Access denied")))
        XCTAssertFalse(CredentialFailure.matches(BackendApiError.http(status: 403, message: "forbidden")))
        XCTAssertFalse(CredentialFailure.matches(BackendApiError.http(status: 501, message: "not implemented")))
        XCTAssertFalse(CredentialFailure.matches(BackendApiError.notAuthenticated))
        XCTAssertFalse(CredentialFailure.matches(URLError(.notConnectedToInternet)))
    }

    func testSubsonicErrorEnvelopeThrowsCode40() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <subsonic-response xmlns="http://subsonic.org/restapi" status="failed" version="1.16.1">
            <error code="40" message="Wrong username or password"/>
        </subsonic-response>
        """
        XCTAssertThrowsError(try SubsonicParsers.checkForError(data: Data(xml.utf8))) { error in
            guard case XmlParseError.serverError(let code, let message) = error else {
                return XCTFail("expected serverError, got \(error)")
            }
            XCTAssertEqual(code, 40)
            XCTAssertEqual(message, "Wrong username or password")
            XCTAssertTrue(CredentialFailure.matches(error))
        }
    }

    func testAmpacheInvalidHandshakeThrowsCode4703() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
            <error code="4703"><![CDATA[Invalid Handshake - ]]></error>
        </root>
        """
        XCTAssertThrowsError(try AmpacheParsers.checkForError(data: Data(xml.utf8))) { error in
            guard case XmlParseError.serverError(let code, _) = error else {
                return XCTFail("expected serverError, got \(error)")
            }
            XCTAssertEqual(code, 4703)
            XCTAssertTrue(CredentialFailure.matches(error))
        }
    }

    func testReportPostsWhenNotSuppressed() {
        let posted = expectation(description: "credentialsRejected")
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsRejected,
            object: nil,
            queue: nil
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        CredentialFailure.reportIfNeeded(
            XmlParseError.serverError(code: 40, message: "Wrong username or password")
        )
        wait(for: [posted], timeout: 1)
    }

    func testReportIsSilentInsideIgnoring() async {
        let posted = expectation(description: "should not post")
        posted.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsRejected,
            object: nil,
            queue: nil
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try? await CredentialFailure.ignoring {
            CredentialFailure.reportIfNeeded(
                XmlParseError.serverError(code: 40, message: "Wrong username or password")
            )
        }
        await fulfillment(of: [posted], timeout: 0.3)
    }
}
