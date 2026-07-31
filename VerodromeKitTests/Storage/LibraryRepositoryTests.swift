import XCTest
import SwiftData
@testable import VerodromeKit

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    func testGetOrCreateArtist() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let info = AccountInfo(serverURL: "https://music.example", username: "vera")
        let account = try repo.getOrCreateAccount(info: info, apiType: .subsonic)
        let artist = try repo.getOrCreateArtist(remoteId: "1", name: "Test Artist", account: account)
        XCTAssertEqual(artist.name, "Test Artist")
        let again = try repo.getOrCreateArtist(remoteId: "1", name: "Renamed", account: account)
        XCTAssertEqual(again.persistentModelID, artist.persistentModelID)
        XCTAssertEqual(again.name, "Renamed")
    }
}
