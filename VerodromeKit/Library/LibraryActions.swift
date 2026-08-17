import Foundation
import SwiftData

/// High-level library mutations for UI (favorite, rating, download, playlists).
@MainActor
public final class LibraryActions {
    public static let shared = LibraryActions()

    private var kit: VerodromeKit { .shared }
    private var syncer: (any LibrarySyncer)? { kit.activeLibrarySyncer }
    private var repository: LibraryRepository? { kit.repository() }
    private var downloader: DownloadManager? { kit.downloadManager }
    private var mutationOutbox: LibraryMutationOutbox? { kit.libraryMutationOutbox }

    private init() {}

    // MARK: - Favorite / Rating

    public func setFavorite(song: Song, isFavorite: Bool) async throws {
        song.isFavorite = isFavorite
        song.updatedAt = .now
        try repository?.save()
        try await syncOrEnqueue(
            .setFavorite(entityId: song.remoteId, type: .song, isFavorite: isFavorite)
        ) {
            try await syncer?.setFavorite(playableId: song.remoteId, isFavorite: isFavorite)
        }
    }

    public func toggleFavorite(song: Song) async throws {
        try await setFavorite(song: song, isFavorite: !song.isFavorite)
    }

    public func setRating(song: Song, rating: Int) async throws {
        let clamped = max(0, min(5, rating))
        song.rating = clamped
        song.updatedAt = .now
        try repository?.save()
        try await syncOrEnqueue(
            .setRating(entityId: song.remoteId, type: .song, rating: clamped)
        ) {
            try await syncer?.setRating(playableId: song.remoteId, rating: clamped)
        }
    }

    public func setFavorite(album: Album, isFavorite: Bool) async throws {
        album.isFavorite = isFavorite
        album.updatedAt = .now
        try repository?.save()
        try await syncOrEnqueue(
            .setFavorite(entityId: album.remoteId, type: .album, isFavorite: isFavorite)
        ) {
            try await syncer?.setFavorite(entityId: album.remoteId, type: .album, isFavorite: isFavorite)
        }
    }

    public func toggleFavorite(album: Album) async throws {
        try await setFavorite(album: album, isFavorite: !album.isFavorite)
    }

    public func setRating(album: Album, rating: Int) async throws {
        let clamped = max(0, min(5, rating))
        album.rating = clamped
        album.updatedAt = .now
        try repository?.save()
        try await syncOrEnqueue(
            .setRating(entityId: album.remoteId, type: .album, rating: clamped)
        ) {
            try await syncer?.setRating(entityId: album.remoteId, type: .album, rating: clamped)
        }
    }

    /// Counts a play locally as soon as it scrobbles.
    ///
    /// Servers report `playCount` back on the next library sync, which can be hours
    /// away, and some backends never report it at all — so without this the Plays
    /// ordering sorts a column that stays at zero.
    public func recordPlay(playableId: String) {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account)
        else { return }
        song.playCount += 1
        song.lastPlayedDate = .now
        song.updatedAt = .now
        try? repository.save()
    }

    // MARK: - Download

    /// Marks the song as wanted offline and queues the transfer. `relFilePath` — and
    /// therefore `isDownloadedLocally` — is only written once the bytes land.
    ///
    /// When downloads are Wi-Fi only, the transfer waits until an unmetered connection
    /// unless `force` is true ("Download Now" on a waiting track).
    public func download(song: Song, force: Bool = false) async {
        song.cacheReason = .userDownload
        song.isUserPinned = true
        song.cacheTouchedDate = .now
        try? repository?.save()
        await downloader?.enqueue(
            playableId: song.remoteId,
            kind: .song,
            reason: .userDownload,
            force: force
        )
    }

    public func cancelDownload(song: Song) async {
        await downloader?.cancel(playableId: song.remoteId)
        song.cacheReason = .none
        song.isUserPinned = false
        try? repository?.save()
    }

    /// Cancels any transfer, deletes the cached file, and clears the library's record.
    public func removeDownload(song: Song) async {
        await downloader?.cancel(playableId: song.remoteId)
        try? kit.playableCache?.deletePlayable(id: song.remoteId, kind: .song)
        // `cancel` clears the in-flight state but not a finished one; without this the
        // row keeps the downloaded glyph from `completedIds` for the rest of the session.
        DownloadCenter.shared.clearActive(playableId: song.remoteId)
        song.cacheReason = .none
        song.isUserPinned = false
        song.relFilePath = nil
        song.cacheTouchedDate = nil
        try? repository?.save()
    }

    /// Toggle used by row menus and swipe actions: cancel while working, retry after a
    /// failure, remove once downloaded, otherwise start.
    public func downloadOrCancel(song: Song) async {
        if DownloadCenter.shared.isWorking(on: song.remoteId) {
            await cancelDownload(song: song)
        } else if DownloadCenter.shared.deferredIds.contains(song.remoteId) {
            // Waiting on Wi-Fi. Asking again means "now", not "never".
            await download(song: song, force: true)
        } else if DownloadCenter.shared.failedIds.contains(song.remoteId) {
            await download(song: song)
        } else if song.isDownloadedLocally || song.isDownloadRequested {
            await removeDownload(song: song)
        } else {
            await download(song: song)
        }
    }

    // MARK: - Bulk download

    /// Downloads every song that isn't already on disk. Songs already downloaded are
    /// re-pinned rather than re-fetched, so a partial album finishes cleanly.
    public func downloadRemaining(songs: [Song]) async {
        for song in songs where !song.isDownloadedLocally {
            await download(song: song)
        }
    }

    public func removeDownloads(songs: [Song]) async {
        for song in songs where song.isDownloadedLocally || song.isDownloadRequested {
            await removeDownload(song: song)
        }
    }

    public func cancelDownloads(songs: [Song]) async {
        let center = DownloadCenter.shared
        for song in songs
        where center.isWorking(on: song.remoteId) || center.deferredIds.contains(song.remoteId) {
            await cancelDownload(song: song)
        }
    }

    /// Removes every offline / pinned download on this device and cancels in-flight
    /// transfers. Temporary queue-prefetch files are left alone (Storage owns those).
    ///
    /// Playlist `keepDownloaded` pins are cleared first so reconciliation cannot
    /// immediately re-queue the same tracks.
    public func clearAllDownloads() async {
        await downloader?.cancelAll()

        guard let repository,
              let account = try? kit.activeAccount()
        else { return }

        if let playlists = try? repository.fetchPlaylists(account: account) {
            var clearedPin = false
            for playlist in playlists where playlist.keepDownloaded {
                playlist.keepDownloaded = false
                playlist.updatedAt = .now
                clearedPin = true
            }
            if clearedPin {
                try? repository.save()
            }
        }

        let songs = ((try? repository.fetchSongs(account: account)) ?? [])
            .filter { $0.cacheReason.isUserPinnedReason || $0.isUserPinned }
        for song in songs {
            await removeDownload(song: song)
        }
    }

    // MARK: - Playlist downloads

    /// Marks a playlist to be kept on disk, tracks and all, including any added later.
    ///
    /// Turning it off deletes the files this playlist was the reason for. Songs held for
    /// another reason — downloaded by hand, or in a second playlist that is still kept —
    /// are left alone, so untoggling one playlist can't take a download the user asked for
    /// somewhere else with it.
    public func setKeepDownloaded(_ keep: Bool, for playlist: Playlist) async {
        playlist.keepDownloaded = keep
        playlist.updatedAt = .now
        try? repository?.save()

        if keep {
            await kit.playlistDownloads?.reconcile()
            return
        }

        let songs = playlist.items.compactMap(\.song)
        await cancelDownloads(songs: songs)
        let stillWanted = songIdsKeptByDownloadedPlaylists(excluding: playlist)
        for song in songs
        where song.cacheReason == .playlistCache && !stillWanted.contains(song.remoteId) {
            await removeDownload(song: song)
        }
    }

    /// Remote ids covered by the other playlists still marked `keepDownloaded`.
    private func songIdsKeptByDownloadedPlaylists(excluding playlist: Playlist) -> Set<String> {
        guard let repository,
              let account = try? kit.activeAccount(),
              let playlists = try? repository.fetchPlaylists(account: account)
        else { return [] }
        var ids: Set<String> = []
        for other in playlists
        where other.keepDownloaded && other.compoundRemoteId != playlist.compoundRemoteId {
            for song in other.items.compactMap(\.song) {
                ids.insert(song.remoteId)
            }
        }
        return ids
    }

    /// The reason the library has on record for a song it believes is on disk, if any.
    /// Lets the orphan sweep tell a lost cache-metadata entry from a file nothing wants.
    public func recordedCacheReason(playableId: String) -> CacheReason? {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account),
              song.relFilePath != nil
        else { return nil }
        return song.cacheReason
    }

    /// Clears the library's record of a local file after the cache dropped it, so
    /// `isDownloadedLocally` can never outlive the bytes it describes.
    public func forgetLocalFile(playableId: String) {
        guard let repository,
              let account = try? kit.activeAccount(),
              let song = try? repository.resolveSong(remoteId: playableId, account: account),
              song.relFilePath != nil
        else { return }
        song.relFilePath = nil
        song.cacheTouchedDate = nil
        if !song.isUserPinned { song.cacheReason = .none }
        try? repository.save()
    }

    // MARK: - Queue helpers

    /// Queues for a single listen: the row leaves the queue once playback moves past it.
    public func addToQueue(song: Song) {
        kit.player?.enqueueEphemeral([QueueItem.from(song)])
    }

    public func addToQueue(episode: PodcastEpisode) {
        kit.player?.enqueueEphemeral([QueueItem.from(episode)])
    }

    /// Fetches similar songs and builds a radio queue. Does not start playback — the
    /// UI should hand the items to `PlayerViewModel.play` so the on-screen queue updates.
    public func prepareRadioQueue(song: Song) async -> PrepareRadioOutcome {
        await prepareRadioQueue(seed: QueueItem.from(song))
    }

    /// Fetches similar songs and builds a radio queue. Does not start playback — the
    /// UI should hand the items to `PlayerViewModel.play` so the on-screen queue updates.
    ///
    /// - Parameters:
    ///   - count: How many similar songs to request (default matches Instant Mix scale).
    ///   - includeSeed: When true (Start Radio), the seed is first in the queue.
    public func prepareRadioQueue(
        seed: QueueItem,
        count: Int = SongRadioQueue.defaultSimilarCount,
        includeSeed: Bool = true
    ) async -> PrepareRadioOutcome {
        guard seed.kind == .song else {
            await EventLogger.shared.info(
                "radio",
                "Start radio skipped — seed kind=\(seed.kind.rawValue) id=\(seed.playableId)"
            )
            return .unavailable
        }
        guard let provider = syncer as? (any SimilarSongProviding) else {
            await EventLogger.shared.info(
                "radio",
                "Start radio unavailable — no SimilarSongProviding syncer seed=\(seed.playableId)"
            )
            return .unavailable
        }

        do {
            let similar = try await provider.similarSongs(
                toSongId: seed.playableId,
                count: count
            )
            let items: [QueueItem]
            if includeSeed {
                items = SongRadioQueue.makeItems(seed: seed, similar: similar)
            } else {
                items = SongRadioQueue.makeContinuationItems(similar: similar)
            }
            await EventLogger.shared.info(
                "radio",
                "Start radio seed=\(seed.playableId) title=\(seed.title) similar=\(similar.count) queue=\(items.count)"
            )

            // Need at least one similar beyond the seed when starting radio; for
            // continuation, any non-empty result is usable.
            if includeSeed {
                guard items.count > 1 else { return .noSimilarSongs }
            } else {
                guard !items.isEmpty else { return .noSimilarSongs }
            }

            if let ingestor = kit.activeLibraryIngester {
                let songs = similar
                Task.detached(priority: .utility) {
                    try? await ingestor.ingest(songs: songs)
                }
            }

            return .ready(items)
        } catch {
            await EventLogger.shared.warning(
                "radio",
                "Start radio failed seed=\(seed.playableId): \(error.localizedDescription)"
            )
            return .failed
        }
    }

    /// Builds a radio-continuation batch from server similar-songs, preferring
    /// related artists. For artist queues, drops same-artist tracks and pads with
    /// other artists in the same genre when similar results are thin.
    public func prepareRadioContinuation(
        seeds: [QueueItem],
        excluding alreadyQueued: Set<String>,
        origin: QueueOrigin? = nil
    ) async -> PrepareRadioOutcome {
        let songSeeds = seeds.filter { $0.kind == .song && !$0.playableId.isEmpty }
        guard !songSeeds.isEmpty else { return .unavailable }

        var combined: [QueueItem] = []
        var exclude = alreadyQueued
        let originArtistName: String? = {
            if case .artist(let name) = origin {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }()
        let wantsLargeDraw = originArtistName != nil || {
            if case .genre = origin { return true }
            return false
        }()

        // Song seeds only — artist/album ID anchors often return the same discography.
        if let similarItems = await similarContinuationItems(
            seeds: songSeeds,
            excluding: exclude,
            largeDraw: wantsLargeDraw
        ) {
            let filtered = originArtistName.map {
                SongRadioQueue.excludingArtist(similarItems, named: $0)
            } ?? similarItems
            if !filtered.isEmpty {
                combined.append(contentsOf: filtered)
                exclude.formUnion(filtered.map(\.playableId))
            }
        }

        if combined.count < SongRadioQueue.minContinuationBatch {
            let genreLimit = wantsLargeDraw ? SongRadioQueue.artistGenreSimilarCount : nil
            if let genreItems = genreContinuationItems(
                seeds: songSeeds,
                excluding: exclude,
                perGenreLimit: genreLimit,
                excludingArtistName: originArtistName
            ), !genreItems.isEmpty {
                combined.append(contentsOf: genreItems)
                await EventLogger.shared.info(
                    "radio",
                    "Radio continuation genre pad +\(genreItems.count) total=\(combined.count)"
                )
            }
        }

        guard !combined.isEmpty else { return .noSimilarSongs }
        return .ready(combined)
    }

    /// Similar-song path. Nil when the API is unavailable or every request fails;
    /// empty array when requests succeed but nothing survives dedupe.
    private func similarContinuationItems(
        seeds: [QueueItem],
        excluding alreadyQueued: Set<String>,
        largeDraw: Bool
    ) async -> [QueueItem]? {
        guard let provider = syncer as? (any SimilarSongProviding) else {
            return nil
        }

        let count: Int
        if largeDraw {
            count = seeds.count <= 1
                ? SongRadioQueue.artistGenreSimilarCount
                : 50
        } else if seeds.count == 1 {
            count = SongRadioQueue.defaultSimilarCount
        } else {
            count = SongRadioQueue.continuationSimilarCount
        }

        var seedResults: [(seed: QueueItem, similar: [IngestSong])] = []
        seedResults.reserveCapacity(seeds.count)

        await withTaskGroup(of: (Int, QueueItem, [IngestSong]?).self) { group in
            for (offset, seed) in seeds.enumerated() {
                group.addTask { @MainActor in
                    do {
                        let similar = try await provider.similarSongs(
                            toSongId: seed.playableId,
                            count: count
                        )
                        return (offset, seed, similar)
                    } catch {
                        return (offset, seed, nil)
                    }
                }
            }
            var collected: [(Int, QueueItem, [IngestSong])] = []
            for await (offset, seed, similar) in group {
                if let similar {
                    collected.append((offset, seed, similar))
                }
            }
            collected.sort { $0.0 < $1.0 }
            seedResults = collected.map { ($0.1, $0.2) }
        }

        guard !seedResults.isEmpty else { return nil }

        let items = SongRadioQueue.buildContinuation(
            seedResults: seedResults,
            excluding: alreadyQueued
        )
        await EventLogger.shared.info(
            "radio",
            "Radio continuation similar seeds=\(seeds.count) count=\(count) queue=\(items.count)"
        )

        if !items.isEmpty, let ingestor = kit.activeLibraryIngester {
            let songs = seedResults.flatMap(\.similar)
            Task.detached(priority: .utility) {
                try? await ingestor.ingest(songs: songs)
            }
        }

        return items
    }

    /// Local genre backup: unique genres from the seed tracks, one shuffled song list
    /// each, zipper-merged. Uses the same local genreName matching as GenreDetailView.
    /// When `excludingArtistName` is set (artist-queue radio), drops that artist's
    /// own tracks so the pad is related artists in the same genre.
    private func genreContinuationItems(
        seeds: [QueueItem],
        excluding alreadyQueued: Set<String>,
        perGenreLimit: Int? = nil,
        excludingArtistName: String? = nil
    ) -> [QueueItem]? {
        guard let repository, let account = try? kit.activeAccount() else { return nil }

        var genreNames: [String] = []
        var seenGenres = Set<String>()
        for seed in seeds {
            guard let song = try? repository.resolveSong(remoteId: seed.playableId, account: account)
            else { continue }
            let raw = song.genreName?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? song.album?.genreName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = raw, !name.isEmpty, seenGenres.insert(name).inserted else { continue }
            genreNames.append(name)
        }
        guard !genreNames.isEmpty else { return nil }

        // When dropping an origin artist, filter first so the pad is other artists.
        let baseLimit = perGenreLimit ?? (
            genreNames.count == 1
                ? SongRadioQueue.defaultSimilarCount
                : SongRadioQueue.continuationSimilarCount
        )
        let blockedArtist = excludingArtistName.map(SongRadioQueue.normalizedArtistKey)

        let lists: [[QueueItem]] = genreNames.compactMap { name in
            var songs = songsInGenre(name, repository: repository)
            if let blockedArtist, !blockedArtist.isEmpty {
                songs = songs.filter {
                    SongRadioQueue.normalizedArtistKey($0.artistName ?? $0.artist?.name)
                        != blockedArtist
                }
            }
            guard !songs.isEmpty else { return nil }
            return Array(songs.shuffled().prefix(baseLimit)).map(QueueItem.from)
        }
        guard !lists.isEmpty else { return nil }

        let items = SongRadioQueue.buildGenreContinuation(
            genreLists: lists,
            excluding: alreadyQueued
        )
        return items.isEmpty ? nil : items
    }

    /// Songs tagged with `genreName`, plus tracks on albums stamped with that genre.
    private func songsInGenre(_ name: String, repository: LibraryRepository) -> [Song] {
        let songDescriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { song in song.genreName == name }
        )
        let albumDescriptor = FetchDescriptor<Album>(
            predicate: #Predicate<Album> { album in album.genreName == name }
        )
        var byId: [String: Song] = [:]
        for song in (try? repository.context.fetch(songDescriptor)) ?? [] {
            byId[song.compoundRemoteId] = song
        }
        for album in (try? repository.context.fetch(albumDescriptor)) ?? [] {
            for song in album.songs {
                byId[song.compoundRemoteId] = song
            }
        }
        return Array(byId.values)
    }

    // MARK: - Playlists

    @discardableResult
    public func createPlaylist(name: String) async throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryRepositoryError.entityNotFound }
        guard let repository, let account = try kit.activeAccount() else {
            throw LibraryRepositoryError.accountNotFound
        }

        if shouldDeferRemoteMutation {
            let localId = UUID().uuidString
            await mutationOutbox?.enqueue(.createPlaylist(localId: localId, name: trimmed))
            return try repository.getOrCreatePlaylist(remoteId: localId, name: trimmed, account: account)
        }

        var remoteId = UUID().uuidString
        if let syncer {
            do {
                remoteId = try await syncer.createPlaylist(name: trimmed)
            } catch {
                if LibraryMutationSyncer.isRetriableNetworkError(error) {
                    let localId = UUID().uuidString
                    await mutationOutbox?.enqueue(.createPlaylist(localId: localId, name: trimmed))
                    return try repository.getOrCreatePlaylist(remoteId: localId, name: trimmed, account: account)
                }
                throw error
            }
        }
        return try repository.getOrCreatePlaylist(remoteId: remoteId, name: trimmed, account: account)
    }

    public func renamePlaylist(_ playlist: Playlist, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
        playlist.sortName = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        playlist.updatedAt = .now
        try repository?.save()
        try await syncOrEnqueue(
            .renamePlaylist(playlistId: playlist.remoteId, name: trimmed)
        ) {
            try await syncer?.renamePlaylist(id: playlist.remoteId, name: trimmed)
        }
    }

    public func addSongs(_ songs: [Song], to playlist: Playlist) async throws {
        guard !songs.isEmpty else { return }
        let songIds = songs.map(\.remoteId)

        if shouldDeferRemoteMutation {
            var existing = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
            let existingIds = Set(existing.map(\.compoundRemoteId))
            for song in songs where !existingIds.contains(song.compoundRemoteId) {
                existing.append(song)
            }
            try repository?.replacePlaylistItems(playlist, with: existing)
            await mutationOutbox?.enqueue(
                .addToPlaylist(playlistId: playlist.remoteId, songIds: songIds)
            )
            return
        }

        if let syncer {
            do {
                try await syncer.addToPlaylist(playlistId: playlist.remoteId, songIds: songIds)
            } catch {
                if LibraryMutationSyncer.isRetriableNetworkError(error) {
                    var existing = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
                    let existingIds = Set(existing.map(\.compoundRemoteId))
                    for song in songs where !existingIds.contains(song.compoundRemoteId) {
                        existing.append(song)
                    }
                    try repository?.replacePlaylistItems(playlist, with: existing)
                    await mutationOutbox?.enqueue(
                        .addToPlaylist(playlistId: playlist.remoteId, songIds: songIds)
                    )
                    return
                }
                throw error
            }
        }
        var existing = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let existingIds = Set(existing.map(\.compoundRemoteId))
        for song in songs where !existingIds.contains(song.compoundRemoteId) {
            existing.append(song)
        }
        try repository?.replacePlaylistItems(playlist, with: existing)
        if let syncer {
            // Reconcile with the server. updatePlaylist used to return ok while ignoring
            // our song ids (wrong query encoding); without this pull the local rewrite
            // was the only "proof" the add worked.
            try await syncer.syncPlaylistDown(id: playlist.remoteId)
            kit.storage?.mainContext.processPendingChanges()
        }
    }

    /// Playlists the server refused to change during this run.
    ///
    /// Deliberately not persisted. It is an inference drawn from one failure, and a wrong
    /// one written to the store would keep hiding a perfectly editable playlist long after
    /// the cause was gone. Losing it at launch costs at most one repeated error message.
    public private(set) var playlistsRejectedByServer: Set<String> = []

    /// Records that the server refused to edit this playlist.
    ///
    /// An older Navidrome reports nothing that identifies a smart playlist, so a rejection
    /// is the only signal there is. Someone else's playlist is refused the same way and the
    /// two are indistinguishable from here, which is why this claims nothing beyond "this
    /// server would not accept the change".
    ///
    /// Returns true when `error` came from the server rather than the network, since a
    /// dropped connection says nothing about whether the playlist can be edited.
    @discardableResult
    public func notePlaylistEditRejected(_ playlist: Playlist, error: any Error) -> Bool {
        guard let parseError = error as? XmlParseError, case .serverError = parseError else { return false }
        playlistsRejectedByServer.insert(playlist.remoteId)
        // The membership index only counts playlists that can be edited, so this changes
        // the answer it should be giving.
        NotificationCenter.default.post(name: .playlistItemsChanged, object: nil)
        return true
    }

    /// Removes every entry for `song` from `playlist`.
    ///
    /// The server addresses entries by position, so the local order is refreshed first —
    /// acting on a stale copy would delete whatever track happens to sit at that index now.
    public func removeSong(_ song: Song, from playlist: Playlist) async throws {
        if !shouldDeferRemoteMutation, let syncer {
            try? await syncer.syncPlaylistDown(id: playlist.remoteId)
        }
        let ordered = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let indices = ordered.indices.filter { ordered[$0].remoteId == song.remoteId }
        guard !indices.isEmpty else { return }
        try await removeSongs(at: indices, from: playlist)
    }

    public func removeSongs(at entryIndices: [Int], from playlist: Playlist) async throws {
        var songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let removedIds = entryIndices
            .filter { songs.indices.contains($0) }
            .map { songs[$0].remoteId }
        guard !removedIds.isEmpty else { return }

        if shouldDeferRemoteMutation {
            for index in entryIndices.sorted(by: >) where songs.indices.contains(index) {
                songs.remove(at: index)
            }
            try repository?.replacePlaylistItems(playlist, with: songs)
            await mutationOutbox?.enqueue(
                .removeFromPlaylist(playlistId: playlist.remoteId, songIds: removedIds)
            )
            return
        }

        if let syncer {
            do {
                try await syncer.removeFromPlaylist(
                    playlistId: playlist.remoteId,
                    entryIndices: entryIndices
                )
            } catch {
                if LibraryMutationSyncer.isRetriableNetworkError(error) {
                    for index in entryIndices.sorted(by: >) where songs.indices.contains(index) {
                        songs.remove(at: index)
                    }
                    try repository?.replacePlaylistItems(playlist, with: songs)
                    await mutationOutbox?.enqueue(
                        .removeFromPlaylist(playlistId: playlist.remoteId, songIds: removedIds)
                    )
                    return
                }
                throw error
            }
        }
        for index in entryIndices.sorted(by: >) where songs.indices.contains(index) {
            songs.remove(at: index)
        }
        try repository?.replacePlaylistItems(playlist, with: songs)
    }

    /// Replaces the playlist's song order on the server, then mirrors it locally.
    public func reorderPlaylist(_ playlist: Playlist, songs: [Song]) async throws {
        let songIds = songs.map(\.remoteId)

        if shouldDeferRemoteMutation {
            try repository?.replacePlaylistItems(playlist, with: songs)
            await mutationOutbox?.enqueue(
                .reorderPlaylist(playlistId: playlist.remoteId, songIds: songIds)
            )
            return
        }

        if let syncer {
            do {
                try await syncer.reorderPlaylist(playlistId: playlist.remoteId, songIds: songIds)
            } catch {
                if LibraryMutationSyncer.isRetriableNetworkError(error) {
                    try repository?.replacePlaylistItems(playlist, with: songs)
                    await mutationOutbox?.enqueue(
                        .reorderPlaylist(playlistId: playlist.remoteId, songIds: songIds)
                    )
                    return
                }
                throw error
            }
        }
        try repository?.replacePlaylistItems(playlist, with: songs)
        if let syncer {
            // Reorder is clear-then-readd on both backends; pull once so we match the
            // server if it dropped a duplicate or rewrote ids.
            try? await syncer.syncPlaylistDown(id: playlist.remoteId)
            kit.storage?.mainContext.processPendingChanges()
        }
    }

    // MARK: - Offline mutation queue

    /// Offline mode, no path, or no syncer yet — local write + outbox, flush later.
    private var shouldDeferRemoteMutation: Bool {
        guard kit.accountStore.activeAccountKey() != nil else { return false }
        return kit.settings.offlineModeEnabled
            || !NetworkMonitor.shared.isConnected
            || syncer == nil
    }

    /// Runs `remote` when reachable; on offline / transient failure, queues `mutation`.
    ///
    /// Callers that already applied the local change use this for favorites/ratings.
    /// Playlist methods that must stay server-first online use `shouldDeferRemoteMutation`
    /// and handle the network-error enqueue path themselves.
    private func syncOrEnqueue(
        _ mutation: PendingLibraryMutation,
        remote: () async throws -> Void
    ) async throws {
        guard kit.accountStore.activeAccountKey() != nil else { return }

        if shouldDeferRemoteMutation {
            await mutationOutbox?.enqueue(mutation)
            return
        }
        do {
            try await remote()
        } catch {
            if LibraryMutationSyncer.isRetriableNetworkError(error) {
                await mutationOutbox?.enqueue(mutation)
                return
            }
            throw error
        }
    }
}

// Local helpers for Song download state when used from Kit.
extension Song {
    /// The file is on disk. Written by `DownloadManager` only after the transfer
    /// completes, so this never reports a download that hasn't happened yet.
    public var isDownloadedLocally: Bool { relFilePath != nil }

    /// The user (or an auto-cache rule) asked for this song offline. True from the
    /// moment the download is queued, which is what a cancel/remove action keys off.
    public var isDownloadRequested: Bool { cacheReasonRaw != CacheReason.none.rawValue }

    /// Cover for UI rows and playback. Prefer the denormalized token; fall back to the
    /// album when song ingest ran before the album had art (or the song row never got
    /// the later album cover written onto it).
    public var displayArtworkToken: String? {
        if let artworkToken, !artworkToken.isEmpty { return artworkToken }
        if let albumToken = album?.artworkToken, !albumToken.isEmpty { return albumToken }
        return nil
    }
}

extension QueueItem {
    public static func from(_ song: Song) -> QueueItem {
        // Prefer denormalized fields — never fault `album`/`artist` on the play hot path.
        QueueItem(
            playableId: song.remoteId,
            kind: .song,
            title: song.title,
            artistName: song.artistName,
            albumName: song.albumTitle,
            duration: song.playDuration,
            artworkId: song.displayArtworkToken
        )
    }

    /// Album play/shuffle: stamp the album cover on every track.
    ///
    /// Servers such as Navidrome often give each song its own `coverArt` id that still
    /// serves the album image. Sharing one token keeps the player from reloading the
    /// same art on every skip.
    public static func from(_ song: Song, albumArtworkId: String?) -> QueueItem {
        var item = from(song)
        if let albumArtworkId, !albumArtworkId.isEmpty {
            item.artworkId = albumArtworkId
        }
        return item
    }

    public static func from(_ episode: PodcastEpisode) -> QueueItem {
        QueueItem(
            playableId: episode.remoteId,
            kind: .podcastEpisode,
            title: episode.title,
            artistName: episode.podcast?.title,
            albumName: episode.podcast?.title,
            duration: episode.playDuration,
            artworkId: episode.podcast?.artworkToken
        )
    }
}
