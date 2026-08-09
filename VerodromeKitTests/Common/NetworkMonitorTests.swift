import XCTest
@testable import VerodromeKit

final class NetworkMonitorTests: XCTestCase {
    /// Cellular often reports `isExpensive == false`. The download gate must not treat
    /// that as Wi‑Fi or album downloads keep burning mobile data.
    func testCellularIsNotUnmeteredEvenWhenNotExpensive() {
        XCTAssertFalse(
            NetworkMonitor.evaluateUnmeteredForDownloads(
                isConnected: true,
                isWiFi: false,
                isExpensive: false,
                isConstrained: false
            )
        )
    }

    func testWiFiIsUnmetered() {
        XCTAssertTrue(
            NetworkMonitor.evaluateUnmeteredForDownloads(
                isConnected: true,
                isWiFi: true,
                isExpensive: false,
                isConstrained: false
            )
        )
    }

    /// Personal hotspot looks like Wi‑Fi but is someone else's cellular.
    func testExpensiveWiFiIsMetered() {
        XCTAssertFalse(
            NetworkMonitor.evaluateUnmeteredForDownloads(
                isConnected: true,
                isWiFi: true,
                isExpensive: true,
                isConstrained: false
            )
        )
    }

    func testLowDataModeBlocksDownloads() {
        XCTAssertFalse(
            NetworkMonitor.evaluateUnmeteredForDownloads(
                isConnected: true,
                isWiFi: true,
                isExpensive: false,
                isConstrained: true
            )
        )
    }
}
