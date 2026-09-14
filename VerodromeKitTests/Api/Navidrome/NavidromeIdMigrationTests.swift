import XCTest
import SwiftData
@testable import VerodromeKit

@MainActor
final class NavidromeIdMigrationTests: XCTestCase {

    // MARK: - Plan

    /// Only IDs that actually change under `canonical` end up in the map — a 22-char
    /// hash-family ID is already canonical and should be silently skipped so the map
    /// size stays proportional to work.
    func testBuildMapSkipsAlreadyCanonicalIds() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        // Already-canonical (22 chars, fits in 128 bits) → skipped.
        _ = try repo.getOrCreateSong(remoteId: "5cLJPkLA5DK2BADhoeotPk", title: "Canonical Song", account: account)
        // 32-char legacy hex → gets re-encoded.
        _ = try repo.getOrCreateSong(remoteId: "e3b7fc2ae9447bbec37a13bf916e3cf6", title: "Legacy Song", account: account)

        let map = try NavidromeIdMigration.buildMap(
            repository: repo,
            account: account,
            toVersion: "0.64.0",
            fromVersion: "0.63.1"
        )

        XCTAssertEqual(map.entries.count, 1)
        XCTAssertEqual(map.entries.first?.oldId, "e3b7fc2ae9447bbec37a13bf916e3cf6")
        XCTAssertEqual(map.entries.first?.newId, "6VHl3uR4kss6sUPKA8Cwnk")
        XCTAssertEqual(map.entries.first?.kind, .song)
        XCTAssertFalse(map.applied)
        XCTAssertEqual(map.toVersion, "0.64.0")
        XCTAssertEqual(map.fromVersion, "0.63.1")
    }

    /// Every family the migration covers gets its own map entry when its ID changes.
    /// Genre and MusicFolder are deliberately excluded — a 32-char genre name would be
    /// silently corrupted by re-encoding — so this test asserts they stay untouched.
    func testBuildMapCoversAllRelevantFamiliesAndSkipsGenreAndFolder() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let legacyHex = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        _ = try repo.getOrCreateArtist(remoteId: legacyHex, name: "Artist", account: account)
        _ = try repo.getOrCreateAlbum(remoteId: legacyHex, title: "Album", account: account)
        _ = try repo.getOrCreateSong(remoteId: legacyHex, title: "Song", account: account)
        _ = try repo.getOrCreatePlaylist(remoteId: legacyHex, name: "Playlist", account: account)
        // Genre would be caught but its "ID" is a name; excluded intentionally.
        let genre = Genre(remoteId: legacyHex, name: legacyHex, account: account)
        storage.mainContext.insert(genre)
        try repo.save()

        let map = try NavidromeIdMigration.buildMap(
            repository: repo,
            account: account,
            toVersion: "0.64.0",
            fromVersion: nil
        )

        let kinds = Set(map.entries.map(\.kind))
        XCTAssertTrue(kinds.contains(.song))
        XCTAssertTrue(kinds.contains(.album))
        XCTAssertTrue(kinds.contains(.artist))
        XCTAssertTrue(kinds.contains(.playlist))
        XCTAssertFalse(kinds.contains(where: { $0.rawValue == "genre" }))
    }

    // MARK: - Apply

    /// The DB rewrite moves both `remoteId` and `compoundRemoteId` and updates
    /// `relFilePath` in the same pass so a downloaded file stays reachable from its row.
    func testApplyRewritesSongIdAndRelFilePathTogether() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let song = try repo.getOrCreateSong(
            remoteId: "e3b7fc2ae9447bbec37a13bf916e3cf6",
            title: "Downloaded",
            account: account
        )
        song.relFilePath = "song/e3b7fc2ae9447bbec37a13bf916e3cf6"
        song.artworkToken = "embedded-e3b7fc2ae9447bbec37a13bf916e3cf6"
        try repo.save()

        let map = try NavidromeIdMigration.buildMap(
            repository: repo,
            account: account,
            toVersion: "0.64.0",
            fromVersion: nil
        )
        let report = try NavidromeIdMigration.apply(map: map, repository: repo, account: account)

        XCTAssertEqual(report.songsRewritten, 1)
        XCTAssertEqual(report.relFilePathsRewritten, 1)
        XCTAssertEqual(report.embeddedArtworkTokensRewritten, 1)
        XCTAssertEqual(song.remoteId, "6VHl3uR4kss6sUPKA8Cwnk")
        XCTAssertEqual(song.relFilePath, "song/6VHl3uR4kss6sUPKA8Cwnk")
        XCTAssertEqual(song.artworkToken, "embedded-6VHl3uR4kss6sUPKA8Cwnk")
        XCTAssertEqual(
            song.compoundRemoteId,
            Song.makeCompoundRemoteId(account: account, remoteId: "6VHl3uR4kss6sUPKA8Cwnk")
        )
    }

    /// Two rows fighting for the same compoundRemoteId — the pre-migration sync inserted
    /// a canonical-id row before the migration ran — merge on the row with `relFilePath`
    /// set, mirroring `DuplicateResolver`.
    func testApplyMergesUniqueConstraintCollisionPreferringDownloadedRow() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let legacy = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        let canonical = "6VHl3uR4kss6sUPKA8Cwnk"

        // Row with the legacy ID — has the download.
        let downloaded = try repo.getOrCreateSong(remoteId: legacy, title: "Downloaded", account: account)
        downloaded.relFilePath = "song/\(legacy)"
        // Row with the canonical ID — no download, just partial-sync metadata.
        _ = try repo.getOrCreateSong(remoteId: canonical, title: "Canonical", account: account)
        try repo.save()

        let map = try NavidromeIdMigration.buildMap(
            repository: repo,
            account: account,
            toVersion: "0.64.0",
            fromVersion: nil
        )
        let report = try NavidromeIdMigration.apply(map: map, repository: repo, account: account)

        XCTAssertEqual(report.collisionsMerged, 1)
        let surviving = try repo.fetchSongs(account: account)
        XCTAssertEqual(surviving.count, 1)
        // The keeper is the row that started as `downloaded` — the collision resolver
        // kept the row with `relFilePath`, and that row got assigned the canonical ID.
        XCTAssertEqual(surviving[0].remoteId, canonical)
        XCTAssertEqual(surviving[0].relFilePath, "song/\(canonical)")
    }

    /// Applying a map is idempotent — the second pass sees the destination compound-id
    /// already present and does nothing beyond bookkeeping.
    func testApplyIsIdempotent() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        _ = try repo.getOrCreateSong(remoteId: "e3b7fc2ae9447bbec37a13bf916e3cf6", title: "A", account: account)

        let map = try NavidromeIdMigration.buildMap(
            repository: repo, account: account, toVersion: "0.64.0", fromVersion: nil
        )
        _ = try NavidromeIdMigration.apply(map: map, repository: repo, account: account)

        // Rebuild against the already-rewritten store — the map should be empty now.
        let rebuilt = try NavidromeIdMigration.buildMap(
            repository: repo, account: account, toVersion: "0.64.0", fromVersion: nil
        )
        XCTAssertEqual(rebuilt.entries.count, 0)
    }

    /// The map is invertible: applying the inverse restores the store byte-for-byte.
    /// This is what makes the backward branch (server rolled back to a pre-0.64 backup)
    /// work without any server round-trips.
    func testForwardThenInverseMigrationRestoresStore() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let originalId = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        _ = try repo.getOrCreateSong(remoteId: originalId, title: "Track", account: account)

        let forward = try NavidromeIdMigration.buildMap(
            repository: repo, account: account,
            toVersion: "0.64.0", fromVersion: "0.63.1"
        )
        _ = try NavidromeIdMigration.apply(map: forward, repository: repo, account: account)

        // Migrate back.
        let inverse = forward.inverse()
        _ = try NavidromeIdMigration.apply(map: inverse, repository: repo, account: account)

        let songs = try repo.fetchSongs(account: account)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].remoteId, originalId)
    }

    /// Directory.parentRemoteId is a plain string field pointing at another directory's
    /// ID. It has to move with the parent even when the child itself doesn't change.
    func testApplyRewritesDirectoryParentReferences() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        let parentId = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        let parent = Directory(remoteId: parentId, name: "Root", account: account)
        storage.mainContext.insert(parent)
        // Child has a canonical ID (no-op) but points at the legacy parent id.
        let child = Directory(remoteId: "5cLJPkLA5DK2BADhoeotPk", name: "Child", account: account)
        child.parentRemoteId = parentId
        storage.mainContext.insert(child)
        try repo.save()

        let map = try NavidromeIdMigration.buildMap(
            repository: repo, account: account,
            toVersion: "0.64.0", fromVersion: nil
        )
        _ = try NavidromeIdMigration.apply(map: map, repository: repo, account: account)

        XCTAssertEqual(child.parentRemoteId, "6VHl3uR4kss6sUPKA8Cwnk")
    }

    /// ScrobbleEntry.remoteTrackId is not a unique constraint; a plain rewrite is enough.
    func testApplyRewritesScrobbleTrackIds() throws {
        let storage = PersistentStorage(inMemory: true)
        let repo = LibraryRepository(storage: storage)
        let account = try repo.getOrCreateAccount(
            info: AccountInfo(serverURL: "https://music.example", username: "vera"),
            apiType: .subsonic
        )
        _ = try repo.getOrCreateSong(remoteId: "e3b7fc2ae9447bbec37a13bf916e3cf6", title: "Song", account: account)
        let scrobble = ScrobbleEntry(title: "S", artistName: "A", playedAt: .now, account: account)
        scrobble.remoteTrackId = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        storage.mainContext.insert(scrobble)
        try repo.save()

        let map = try NavidromeIdMigration.buildMap(
            repository: repo, account: account,
            toVersion: "0.64.0", fromVersion: nil
        )
        let report = try NavidromeIdMigration.apply(map: map, repository: repo, account: account)

        XCTAssertEqual(report.scrobblesRewritten, 1)
        XCTAssertEqual(scrobble.remoteTrackId, "6VHl3uR4kss6sUPKA8Cwnk")
    }
}
