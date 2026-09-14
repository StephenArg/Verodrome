import Foundation
import SwiftData

/// Rewrites every local reference to a Navidrome song / album / artist / playlist ID from
/// the pre-0.64.0 form to the canonical 22-char base62 form, so a Navidrome upgrade does
/// not orphan downloaded files or double-insert library rows on the next sync.
///
/// This file is the SwiftData half. The on-disk half (audio files, `cache-meta.json`,
/// lyrics, embedded artwork, play queue, mutation outbox) lives in
/// `NavidromeIdFileMigrator` / `NavidromeIdAuxMigrator` and consumes the same map. The
/// map is written to disk **before** anything is applied, and retained after a successful
/// apply so the backward branch (server rolled back to a pre-0.64 backup) can invert it
/// without any server round-trips.
public enum NavidromeIdMigration {

    /// The affected model families. Deliberately does **not** include Genre (Subsonic
    /// genre IDs are just names — a 22/32/36-char genre name would be silently corrupted)
    /// or MusicFolder (`library.id` is an integer, passthrough anyway).
    public static let coveredKinds: [NavidromeIdMap.Kind] = [
        .song, .album, .artist, .playlist,
        .directory, .podcast, .podcastEpisode, .radio,
    ]

    // MARK: - Planning

    /// Read the whole SwiftData store for this account, apply `NavidromeCanonicalID` to
    /// every `remoteId`, and return the map of entries that actually change. IDs whose
    /// transform is a no-op are omitted so the map size stays proportional to work.
    ///
    /// Runs on whichever thread owns the context; callers must hand in a `LibraryRepository`
    /// bound to the right actor. The read is fetch-only and does not mutate.
    public static func buildMap(
        repository: LibraryRepository,
        account: Account,
        toVersion: String,
        fromVersion: String?
    ) throws -> NavidromeIdMap {
        var entries: [NavidromeIdMap.Entry] = []
        entries.reserveCapacity(1024)

        let accountID = account.persistentModelID

        // One fetch per family; the compare is O(N) with tiny per-item constant. The
        // heavy lifting is the base62 math in `canonical`, which is pure and fast.
        for song in try repository.context.fetch(FetchDescriptor<Song>())
            where song.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .song, oldId: song.remoteId)
        }
        for album in try repository.context.fetch(FetchDescriptor<Album>())
            where album.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .album, oldId: album.remoteId)
        }
        for artist in try repository.context.fetch(FetchDescriptor<Artist>())
            where artist.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .artist, oldId: artist.remoteId)
        }
        for playlist in try repository.context.fetch(FetchDescriptor<Playlist>())
            where playlist.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .playlist, oldId: playlist.remoteId)
        }
        for directory in try repository.context.fetch(FetchDescriptor<Directory>())
            where directory.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .directory, oldId: directory.remoteId)
        }
        for podcast in try repository.context.fetch(FetchDescriptor<Podcast>())
            where podcast.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .podcast, oldId: podcast.remoteId)
        }
        for episode in try repository.context.fetch(FetchDescriptor<PodcastEpisode>())
            where episode.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .podcastEpisode, oldId: episode.remoteId)
        }
        for radio in try repository.context.fetch(FetchDescriptor<Radio>())
            where radio.account?.persistentModelID == accountID {
            appendIfChanged(&entries, kind: .radio, oldId: radio.remoteId)
        }

        return NavidromeIdMap(
            toVersion: toVersion,
            fromVersion: fromVersion,
            createdAt: .now,
            applied: false,
            entries: entries
        )
    }

    /// Append an entry iff the canonical transform actually changes the ID.
    private static func appendIfChanged(
        _ entries: inout [NavidromeIdMap.Entry],
        kind: NavidromeIdMap.Kind,
        oldId: String
    ) {
        let newId = NavidromeCanonicalID.canonical(oldId)
        guard newId != oldId else { return }
        entries.append(NavidromeIdMap.Entry(kind: kind, oldId: oldId, newId: newId))
    }

    // MARK: - Apply (SwiftData)

    /// Apply the map to the SwiftData store. Rewrites `remoteId` + `compoundRemoteId` for
    /// every covered kind, updates `Directory.parentRemoteId` where it points at a
    /// remapped parent, rewrites `Song.relFilePath` to reflect the new filename layout,
    /// and updates the small string denormalization `Song.artworkToken == "embedded-{oldId}"`.
    ///
    /// Collisions on the unique `compoundRemoteId` constraint — which happen when the
    /// syncer already inserted a canonical-ID row before the migration ran — are merged
    /// by keeping the row with `relFilePath` set so downloaded files survive.
    ///
    /// Idempotent by construction: rewriting an already-canonical ID is a no-op, so it is
    /// safe to re-run after a crash. The caller marks the map `applied = true` and
    /// persists it once this returns without throwing.
    @discardableResult
    public static func apply(
        map: NavidromeIdMap,
        repository: LibraryRepository,
        account: Account
    ) throws -> ApplyReport {
        var report = ApplyReport()
        guard !map.entries.isEmpty else { return report }

        // Precompute per-kind lookups once; the inner loops are dictionary reads only.
        let songMap = map.forwardLookup(kind: .song)
        let albumMap = map.forwardLookup(kind: .album)
        let artistMap = map.forwardLookup(kind: .artist)
        let playlistMap = map.forwardLookup(kind: .playlist)
        let directoryMap = map.forwardLookup(kind: .directory)
        let podcastMap = map.forwardLookup(kind: .podcast)
        let episodeMap = map.forwardLookup(kind: .podcastEpisode)
        let radioMap = map.forwardLookup(kind: .radio)

        try rewriteSongs(mapping: songMap, repository: repository, account: account, report: &report)
        try rewriteAlbums(mapping: albumMap, repository: repository, account: account, report: &report)
        try rewriteArtists(mapping: artistMap, repository: repository, account: account, report: &report)
        try rewritePlaylists(mapping: playlistMap, repository: repository, account: account, report: &report)
        try rewriteDirectories(mapping: directoryMap, repository: repository, account: account, report: &report)
        try rewritePodcasts(mapping: podcastMap, repository: repository, account: account, report: &report)
        try rewriteEpisodes(mapping: episodeMap, repository: repository, account: account, report: &report)
        try rewriteRadios(mapping: radioMap, repository: repository, account: account, report: &report)

        // ScrobbleEntry.remoteTrackId is a plain string, not a unique constraint, so a
        // straight rewrite is enough.
        let accountID = account.persistentModelID
        for scrobble in try repository.context.fetch(FetchDescriptor<ScrobbleEntry>())
            where scrobble.account?.persistentModelID == accountID {
            guard let old = scrobble.remoteTrackId, let new = songMap[old] else { continue }
            scrobble.remoteTrackId = new
            report.scrobblesRewritten += 1
        }

        try repository.save()
        return report
    }

    /// Aggregate counts for logging / test assertions. Not persisted.
    public struct ApplyReport: Equatable, Sendable {
        public var songsRewritten: Int = 0
        public var albumsRewritten: Int = 0
        public var artistsRewritten: Int = 0
        public var playlistsRewritten: Int = 0
        public var directoriesRewritten: Int = 0
        public var podcastsRewritten: Int = 0
        public var episodesRewritten: Int = 0
        public var radiosRewritten: Int = 0
        public var scrobblesRewritten: Int = 0
        public var collisionsMerged: Int = 0
        public var relFilePathsRewritten: Int = 0
        public var embeddedArtworkTokensRewritten: Int = 0

        public init() {}
    }

    // MARK: - Song rewriter (special-cased for relFilePath and artworkToken)

    /// Songs get their own rewriter because they also carry two derived strings that
    /// embed the ID: `relFilePath` ("song/{id}") and `artworkToken` ("embedded-{id}" for
    /// downloaded tracks whose art was extracted from the file rather than fetched
    /// server-side). Both must move with the ID or the local file lookup breaks.
    private static func rewriteSongs(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Song>())
            .filter { $0.account?.persistentModelID == accountID }

        // Detect collisions up-front: a target compoundRemoteId may already belong to
        // another row (partial sync landed first, DuplicateResolver hasn't fired yet).
        var byCompoundId: [String: Song] = [:]
        for song in all { byCompoundId[song.compoundRemoteId] = song }

        for song in all {
            guard let newId = mapping[song.remoteId] else { continue }
            let newCompoundId = Song.makeCompoundRemoteId(account: account, remoteId: newId)

            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != song.persistentModelID {
                // Two rows collapse to one after the rewrite. Prefer the row already
                // holding the local file so the download survives the merge; the other
                // is deleted and its useful metadata folded in first.
                if songRetentionScore(existing) >= songRetentionScore(song) {
                    mergeSong(into: existing, from: song)
                    repository.context.delete(song)
                    report.collisionsMerged += 1
                    // Existing already carries the target ID.
                } else {
                    mergeSong(into: song, from: existing)
                    repository.context.delete(existing)
                    report.collisionsMerged += 1
                    applySongIdChange(song, newId: newId, account: account, report: &report)
                    byCompoundId[newCompoundId] = song
                }
            } else {
                applySongIdChange(song, newId: newId, account: account, report: &report)
                byCompoundId[newCompoundId] = song
            }
        }
    }

    /// Mirrors DuplicateResolver.songRetentionScore for consistency with the existing
    /// merge behavior. Downloaded rows win.
    private static func songRetentionScore(_ song: Song) -> Int {
        var score = 0
        if song.relFilePath != nil { score += 4 }
        if song.cacheTouchedDate != nil { score += 2 }
        score += song.playCount
        if song.isUserPinned { score += 8 }
        return score
    }

    private static func mergeSong(into keeper: Song, from loser: Song) {
        keeper.playCount = max(keeper.playCount, loser.playCount)
        keeper.playProgress = max(keeper.playProgress, loser.playProgress)
        keeper.rating = max(keeper.rating, loser.rating)
        keeper.isFavorite = keeper.isFavorite || loser.isFavorite
        keeper.isUserPinned = keeper.isUserPinned || loser.isUserPinned
        if keeper.relFilePath == nil { keeper.relFilePath = loser.relFilePath }
        if keeper.cacheTouchedDate == nil { keeper.cacheTouchedDate = loser.cacheTouchedDate }
        if let loserLast = loser.lastPlayedDate {
            keeper.lastPlayedDate = max(keeper.lastPlayedDate ?? .distantPast, loserLast)
        }
    }

    private static func applySongIdChange(
        _ song: Song,
        newId: String,
        account: Account,
        report: inout ApplyReport
    ) {
        let oldId = song.remoteId
        song.remoteId = newId
        song.compoundRemoteId = Song.makeCompoundRemoteId(account: account, remoteId: newId)
        report.songsRewritten += 1

        // Only the ID portion of relFilePath moves; the "song/" prefix (or any future
        // kind subdirectory) is kept exactly. If somehow the stored path did not embed
        // the old ID as its last component, leave it alone rather than guessing — the
        // on-disk migrator will treat it as a broken entry.
        if let rel = song.relFilePath, rel.hasSuffix("/\(oldId)") {
            song.relFilePath = String(rel.dropLast(oldId.count)) + newId
            report.relFilePathsRewritten += 1
        }

        // Embedded artwork tokens are minted client-side as "embedded-{songId}" by
        // `DownloadManager`; the disk file gets renamed by the artwork migrator, and
        // this string has to stay pointing at it.
        if let token = song.artworkToken, token == "embedded-\(oldId)" {
            song.artworkToken = "embedded-\(newId)"
            report.embeddedArtworkTokensRewritten += 1
        }
    }

    // MARK: - Kind-specific rewriters

    private static func rewriteAlbums(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Album>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Album] = [:]
        for album in all { byCompoundId[album.compoundRemoteId] = album }

        for album in all {
            guard let newId = mapping[album.remoteId] else { continue }
            let newCompoundId = Album.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != album.persistentModelID {
                // Keep the newer row (the sync-inserted one) and drop the current.
                // Album rows carry no downloaded state of their own — songs do.
                repository.context.delete(album)
                report.collisionsMerged += 1
                continue
            }
            album.remoteId = newId
            album.compoundRemoteId = newCompoundId
            report.albumsRewritten += 1
            byCompoundId[newCompoundId] = album
        }
    }

    private static func rewriteArtists(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Artist>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Artist] = [:]
        for artist in all { byCompoundId[artist.compoundRemoteId] = artist }

        for artist in all {
            guard let newId = mapping[artist.remoteId] else { continue }
            let newCompoundId = Artist.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != artist.persistentModelID {
                repository.context.delete(artist)
                report.collisionsMerged += 1
                continue
            }
            artist.remoteId = newId
            artist.compoundRemoteId = newCompoundId
            report.artistsRewritten += 1
            byCompoundId[newCompoundId] = artist
        }
    }

    private static func rewritePlaylists(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Playlist>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Playlist] = [:]
        for playlist in all { byCompoundId[playlist.compoundRemoteId] = playlist }

        for playlist in all {
            guard let newId = mapping[playlist.remoteId] else { continue }
            let newCompoundId = Playlist.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != playlist.persistentModelID {
                // Playlist items live under whichever row the syncer's compound id
                // points at; the one that already matches wins.
                repository.context.delete(playlist)
                report.collisionsMerged += 1
                continue
            }
            playlist.remoteId = newId
            playlist.compoundRemoteId = newCompoundId
            report.playlistsRewritten += 1
            byCompoundId[newCompoundId] = playlist
        }
    }

    private static func rewriteDirectories(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Directory>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Directory] = [:]
        for dir in all { byCompoundId[dir.compoundRemoteId] = dir }

        for dir in all {
            // The parent id is a plain string field; remap it independently of the
            // directory's own id, because a directory may keep its own id while its
            // parent moves.
            if let parent = dir.parentRemoteId, let newParent = mapping[parent] {
                dir.parentRemoteId = newParent
            }
            guard let newId = mapping[dir.remoteId] else { continue }
            let newCompoundId = Directory.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != dir.persistentModelID {
                repository.context.delete(dir)
                report.collisionsMerged += 1
                continue
            }
            dir.remoteId = newId
            dir.compoundRemoteId = newCompoundId
            report.directoriesRewritten += 1
            byCompoundId[newCompoundId] = dir
        }
    }

    private static func rewritePodcasts(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Podcast>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Podcast] = [:]
        for podcast in all { byCompoundId[podcast.compoundRemoteId] = podcast }

        for podcast in all {
            guard let newId = mapping[podcast.remoteId] else { continue }
            let newCompoundId = Podcast.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != podcast.persistentModelID {
                repository.context.delete(podcast)
                report.collisionsMerged += 1
                continue
            }
            podcast.remoteId = newId
            podcast.compoundRemoteId = newCompoundId
            report.podcastsRewritten += 1
            byCompoundId[newCompoundId] = podcast
        }
    }

    private static func rewriteEpisodes(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<PodcastEpisode>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: PodcastEpisode] = [:]
        for episode in all { byCompoundId[episode.compoundRemoteId] = episode }

        for episode in all {
            guard let newId = mapping[episode.remoteId] else { continue }
            let newCompoundId = PodcastEpisode.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != episode.persistentModelID {
                // Episode rows can carry `relFilePath`. Prefer the row with a download.
                if episode.relFilePath != nil && existing.relFilePath == nil {
                    // Current row has the file; keep it, drop the collision, then rename.
                    repository.context.delete(existing)
                    report.collisionsMerged += 1
                    byCompoundId[episode.compoundRemoteId] = nil
                } else {
                    repository.context.delete(episode)
                    report.collisionsMerged += 1
                    continue
                }
            }
            episode.remoteId = newId
            episode.compoundRemoteId = newCompoundId
            report.episodesRewritten += 1
            byCompoundId[newCompoundId] = episode
        }
    }

    private static func rewriteRadios(
        mapping: [String: String],
        repository: LibraryRepository,
        account: Account,
        report: inout ApplyReport
    ) throws {
        guard !mapping.isEmpty else { return }
        let accountID = account.persistentModelID
        let all = try repository.context.fetch(FetchDescriptor<Radio>())
            .filter { $0.account?.persistentModelID == accountID }
        var byCompoundId: [String: Radio] = [:]
        for radio in all { byCompoundId[radio.compoundRemoteId] = radio }

        for radio in all {
            guard let newId = mapping[radio.remoteId] else { continue }
            let newCompoundId = Radio.makeCompoundRemoteId(account: account, remoteId: newId)
            if let existing = byCompoundId[newCompoundId], existing.persistentModelID != radio.persistentModelID {
                repository.context.delete(radio)
                report.collisionsMerged += 1
                continue
            }
            radio.remoteId = newId
            radio.compoundRemoteId = newCompoundId
            report.radiosRewritten += 1
            byCompoundId[newCompoundId] = radio
        }
    }
}
