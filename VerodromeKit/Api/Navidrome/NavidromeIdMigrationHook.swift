import Foundation
import SwiftData

/// Glue between `VerodromeKit`'s live services and the canonical-ID migration pieces.
/// The hook exposes a single `runIfNeeded` entry point that `ensureActiveLibrarySyncer`
/// awaits before handing out a syncer.
///
/// Splitting this out keeps `VerodromeKit.swift` free of migration-mechanics detail (and
/// keeps the migration testable without spinning up the whole app), while still binding
/// to the concrete singletons for services that are process-wide.
///
/// Concurrency: everything the hook exposes is main-actor bound, because the entities it
/// coordinates (`ObservableSettings`, `LibraryRepository` on the main context, the two
/// actor-backed stores) all live on or funnel through the main actor already.
@MainActor
public enum NavidromeIdMigrationHook {

    /// Drop the last-checked version and the retained id-epoch map so the next
    /// `runIfNeeded` re-probes. Does **not** clear `serverTypeName` or `serverVersion`.
    public static func clearVerificationMarker(kit: VerodromeKit) {
        guard let accountKey = kit.accountStore.activeAccountKey() else { return }
        var copy = kit.settings.loadAccountSettings(for: accountKey)
        copy.canonicalIdsVerifiedAtVersion = nil
        kit.settings.saveAccountSettings(copy, for: accountKey)
        kit.observableSettings.reload(accountKey: accountKey)
        NavidromeIdMapStore(accountKey: accountKey.storageKey).remove()
    }

    /// Run one migration attempt for the currently-active account. Safe to call on
    /// every `ensureActiveLibrarySyncer` invocation — the same-epoch fast path is one
    /// settings read. Returns `true` if a mutating outcome occurred; the caller can
    /// use this to decide whether to force a duplicate resolution pass.
    ///
    /// - Parameters:
    ///   - kit: The shared `VerodromeKit` instance. Provides access to storage, the
    ///     mutation outbox, the queue store, and settings.
    ///   - syncer: The freshly-created library syncer that will handle probe calls.
    ///     Passed in rather than looked up because at the call site the syncer has
    ///     just been minted and is not yet assigned to `activeLibrarySyncer`.
    /// - Returns: The `Outcome` from the coordinator, for the caller to log.
    @discardableResult
    public static func runIfNeeded(
        kit: VerodromeKit,
        syncer: any LibrarySyncer
    ) async -> NavidromeIdMigrationCoordinator.Outcome {
        guard let storage = kit.storage,
              let accountKey = kit.accountStore.activeAccountKey(),
              let account = try? LibraryRepository(storage: storage).fetchAccount(key: accountKey) else {
            return .noop
        }

        let repository = LibraryRepository(storage: storage)
        let settingsStore = kit.settings
        let mapStore = NavidromeIdMapStore(accountKey: accountKey.storageKey)
        let outbox = kit.libraryMutationOutbox
        let queueStore = kit.queueStore
        let playablesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromePlayables", isDirectory: true)
        let lyricsRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeLyrics", isDirectory: true)
        let artworkRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeArtwork", isDirectory: true)
        let queueDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeQueue", isDirectory: true)

        // Read live from the persisted account row. The in-memory `observableSettings`
        // copy is `.default` on cold launch until something binds it, which used to
        // make this gate skip forever (nil server type → no probe → old IDs on a
        // 0.64 server → every stream 404s and the player skips).
        let accountSettings = { settingsStore.loadAccountSettings(for: accountKey) }

        let deps = NavidromeIdMigrationCoordinator.Dependencies(
            reportedVersion: { accountSettings().serverVersion },
            markerVersion: { accountSettings().canonicalIdsVerifiedAtVersion },
            serverTypeName: { accountSettings().serverTypeName },
            writeMarker: { version in
                var copy = settingsStore.loadAccountSettings(for: accountKey)
                copy.canonicalIdsVerifiedAtVersion = version
                settingsStore.saveAccountSettings(copy, for: accountKey)
                kit.observableSettings.reload(accountKey: accountKey)
            },
            forceFullResync: {
                await forceFullResync(kit: kit, accountKey: accountKey)
            },
            sampleCandidateSongIds: { limit in
                sampleSongIds(repository: repository, account: account, limit: limit)
            },
            songResolves: { id in
                try await songResolves(id: id, syncer: syncer)
            },
            mapStore: mapStore,
            planAndApplyForward: { toVersion, fromVersion in
                try await planAndApplyForward(
                    toVersion: toVersion,
                    fromVersion: fromVersion,
                    repository: repository,
                    account: account,
                    mapStore: mapStore,
                    outbox: outbox,
                    queueStore: queueStore,
                    accountKey: accountKey.storageKey,
                    playablesRoot: playablesRoot,
                    lyricsRoot: lyricsRoot,
                    artworkRoot: artworkRoot,
                    queueDirectory: queueDir
                )
            },
            applyMap: { map in
                try await applyMap(
                    map,
                    repository: repository,
                    account: account,
                    outbox: outbox,
                    queueStore: queueStore,
                    accountKey: accountKey.storageKey,
                    playablesRoot: playablesRoot,
                    lyricsRoot: lyricsRoot,
                    artworkRoot: artworkRoot,
                    queueDirectory: queueDir
                )
            },
            log: { message in
                Task { await EventLogger.shared.info("migration", message) }
            },
            presentBusyOverlay: { message in
                await kit.presentCanonicalIdMigrationOverlay(message)
            },
            dismissBusyOverlay: {
                kit.dismissCanonicalIdMigrationOverlay()
            }
        )

        let coordinator = NavidromeIdMigrationCoordinator(dependencies: deps)
        return await coordinator.run()
    }

    // MARK: - Helpers

    /// Sample IDs the probe can throw at the server. Preference order: downloaded songs
    /// (their files are what the migration exists to save), then songs the user has
    /// interacted with, then any song. Deduplicated and capped at `limit`.
    private static func sampleSongIds(
        repository: LibraryRepository,
        account: Account,
        limit: Int
    ) -> [String] {
        do {
            let downloaded = try repository.fetchSongs(account: account, cachedOnly: true)
            let others = try repository.fetchSongs(account: account)
            var seen = Set<String>()
            var out: [String] = []
            for song in downloaded {
                if seen.insert(song.remoteId).inserted { out.append(song.remoteId) }
                if out.count >= limit { return out }
            }
            for song in others {
                if seen.insert(song.remoteId).inserted { out.append(song.remoteId) }
                if out.count >= limit { return out }
            }
            return out
        } catch {
            return []
        }
    }

    /// Resolve one song via the syncer. Missing songs (Subsonic error 70 / not-found)
    /// return `false`; transport errors propagate so the probe can distinguish "server
    /// said no" from "we could not ask". `fetchSongUserState` is a `getSong` under the
    /// hood — the answer only cares that the row exists.
    private static func songResolves(id: String, syncer: any LibrarySyncer) async throws -> Bool {
        do {
            _ = try await syncer.fetchSongUserState(playableId: id)
            return true
        } catch let error as XmlParseError {
            if case .serverError(let code, _) = error, code == 70 { return false }
            throw error
        } catch let error as BackendApiError {
            if case .http(let status, _) = error, status == 404 { return false }
            throw error
        }
    }

    /// Plan + apply the forward migration. Order: build map → persist unapplied →
    /// rewrite files → rewrite DB → rewrite aux stores → save map with `applied = true`.
    /// Files first so a crash between phases leaves files still matchable to DB rows.
    private static func planAndApplyForward(
        toVersion: String,
        fromVersion: String?,
        repository: LibraryRepository,
        account: Account,
        mapStore: NavidromeIdMapStore,
        outbox: LibraryMutationOutbox?,
        queueStore: FilePlayerQueueStore?,
        accountKey: String,
        playablesRoot: URL,
        lyricsRoot: URL,
        artworkRoot: URL,
        queueDirectory: URL
    ) async throws -> Int {
        let map = try NavidromeIdMigration.buildMap(
            repository: repository,
            account: account,
            toVersion: toVersion,
            fromVersion: fromVersion
        )
        if map.entries.isEmpty {
            // Marker seed only — nothing to remap.
            return 0
        }
        try mapStore.save(map)
        let entries = try await applyMap(
            map,
            repository: repository,
            account: account,
            outbox: outbox,
            queueStore: queueStore,
            accountKey: accountKey,
            playablesRoot: playablesRoot,
            lyricsRoot: lyricsRoot,
            artworkRoot: artworkRoot,
            queueDirectory: queueDirectory
        )
        return entries
    }

    /// Apply an already-built map (forward, inverse, or resumed). Idempotent — a second
    /// pass sees the destination already-canonical and skips. Marks the map applied on
    /// success so `run` treats it as retained (rather than resumable) on next launch.
    private static func applyMap(
        _ map: NavidromeIdMap,
        repository: LibraryRepository,
        account: Account,
        outbox: LibraryMutationOutbox?,
        queueStore: FilePlayerQueueStore?,
        accountKey: String,
        playablesRoot: URL,
        lyricsRoot: URL,
        artworkRoot: URL,
        queueDirectory: URL
    ) async throws -> Int {
        // 1. Filesystem first — see the file header for why.
        _ = try NavidromeIdFileMigrator.apply(
            map: map,
            playablesRoot: playablesRoot,
            lyricsRoot: lyricsRoot,
            artworkRoot: artworkRoot
        )

        // 2. SwiftData. Runs on the main actor because the repository is bound to the
        //    main context — this hook itself is `@MainActor`, so we are already there.
        let dbReport = try NavidromeIdMigration.apply(
            map: map,
            repository: repository,
            account: account
        )

        // 3. Aux state — play queue JSON files.
        _ = try? NavidromeIdAuxMigrator.apply(
            map: map,
            queueDirectory: queueDirectory,
            accountKey: accountKey
        )

        // 4. Outbox — actor-based, so the remap happens in-process via its public API.
        if let outbox {
            let songs = map.forwardLookup(kind: .song)
            let albums = map.forwardLookup(kind: .album)
            let artists = map.forwardLookup(kind: .artist)
            let playlists = map.forwardLookup(kind: .playlist)
            let entities: [LibraryEntityType: [String: String]] = [
                .song: songs,
                .album: albums,
                .artist: artists,
            ]
            await outbox.remapIds(playlists: playlists, songs: songs, entities: entities)
        }

        // 5. If the queue store is live and pointed at this account, force it to reload
        //    from the newly-rewritten file so the in-memory queue does not still hold
        //    stale IDs.
        if let queueStore {
            _ = await queueStore.loadQueue()
        }

        // 6. Save the map with `applied = true` so the coordinator will not treat it as
        //    resumable on the next launch. Retained (not deleted) so it doubles as the
        //    inverse map.
        var completed = map
        completed.applied = true
        try? NavidromeIdMapStore(accountKey: accountKey).save(completed)

        return dbReport.songsRewritten
            + dbReport.albumsRewritten
            + dbReport.artistsRewritten
            + dbReport.playlistsRewritten
            + dbReport.directoriesRewritten
            + dbReport.podcastsRewritten
            + dbReport.episodesRewritten
            + dbReport.radiosRewritten
    }

    /// Wipes per-account library state so the next `ensureActiveLibrarySyncer` re-syncs
    /// from scratch. Only invoked in the backward-regression / no-retained-map corner —
    /// the alternative is silently corrupted IDs, so a full re-sync is the safer path.
    /// Downloads that no longer match any DB row will be pruned by the existing
    /// cache-management passes.
    private static func forceFullResync(kit: VerodromeKit, accountKey: AccountInfo.Key) async {
        kit.settings.isLibrarySynced = false
        kit.settings.save()
        kit.observableSettings.updateApp {
            $0.isLibrarySynced = false
            $0.tracksBackfillVersion = 0
        }
        // Do not delete downloads or the SwiftData store — the next sync will replace
        // the rows with correctly-IDed ones, and orphaned files fall out through the
        // usual prune loop.
    }
}
