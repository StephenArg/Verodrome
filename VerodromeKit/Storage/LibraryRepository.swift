import Foundation
import SwiftData

public enum LibraryRepositoryError: Error, Sendable {
    case accountNotFound
    case entityNotFound
}

/// Deliberately not `@MainActor`: the repository is bound to whatever `ModelContext` it
/// was given, and must run wherever that context lives — the main actor for UI callers,
/// the ingest actor for sync. Instances must not cross isolation domains.
public final class LibraryRepository {
    public let context: ModelContext

    /// Opt-in batch mode: preloads compound-id -> model dictionaries so `getOrCreate*`
    /// calls become O(1) lookups instead of per-item fetches, and `save()` is deferred
    /// until `endBatch()`. Nested `beginBatch`/`endBatch` calls are supported; the
    /// dictionaries are only torn down by the outermost `endBatch`.
    struct Batch {
        var artists: [String: Artist] = [:]
        var albums: [String: Album] = [:]
        var songs: [String: Song] = [:]
        var genres: [String: Genre] = [:]
        var playlists: [String: Playlist] = [:]
        var podcasts: [String: Podcast] = [:]
        var episodes: [String: PodcastEpisode] = [:]
        var radios: [String: Radio] = [:]
    }

    var batch: Batch?
    var batchDepth = 0

    public init(context: ModelContext) {
        self.context = context
    }

    @MainActor
    public convenience init(storage: PersistentStorage = .shared) {
        self.init(context: storage.mainContext)
    }

    // MARK: - Batch

    /// Begin a batch. Preloads one fetch per entity type into in-memory dictionaries.
    /// Nested calls reuse the already-loaded dictionaries without re-fetching.
    public func beginBatch() throws {
        if batchDepth == 0 {
            batch = try loadBatch()
        }
        batchDepth += 1
    }

    /// End a batch. Saves pending changes and clears the dictionaries on the
    /// outermost exit. Safe to call without a matching `beginBatch` (no-op).
    public func endBatch() throws {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0 {
            try save()
            batch = nil
        }
    }

    func loadBatch() throws -> Batch {
        var batch = Batch()
        for artist in try context.fetch(FetchDescriptor<Artist>()) {
            batch.artists[artist.compoundRemoteId] = artist
        }
        for album in try context.fetch(FetchDescriptor<Album>()) {
            // One-shot backfill: albums synced before `artistName` was denormalized.
            if album.artistName == nil, let artist = album.artist {
                album.artistName = artist.name
            }
            batch.albums[album.compoundRemoteId] = album
        }
        for song in try context.fetch(FetchDescriptor<Song>()) {
            batch.songs[song.compoundRemoteId] = song
        }
        for genre in try context.fetch(FetchDescriptor<Genre>()) {
            batch.genres[genre.compoundRemoteId] = genre
        }
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) {
            batch.playlists[playlist.compoundRemoteId] = playlist
        }
        for podcast in try context.fetch(FetchDescriptor<Podcast>()) {
            batch.podcasts[podcast.compoundRemoteId] = podcast
        }
        for episode in try context.fetch(FetchDescriptor<PodcastEpisode>()) {
            batch.episodes[episode.compoundRemoteId] = episode
        }
        for radio in try context.fetch(FetchDescriptor<Radio>()) {
            batch.radios[radio.compoundRemoteId] = radio
        }
        return batch
    }

    /// Saves only when no batch is active. Inside a batch, the caller is responsible
    /// for saving at the end (via `endBatch` or explicitly).
    @inline(__always)
    func saveIfNotBatching() throws {
        guard batchDepth == 0 else { return }
        try save()
    }

    // MARK: - Account

    @discardableResult
    public func getOrCreateAccount(info: AccountInfo, apiType: ApiType = .notDetected) throws -> Account {
        if let existing = try fetchAccount(key: info.key) {
            existing.serverUrl = info.serverURL
            existing.userName = info.username
            existing.apiType = apiType
            existing.updatedAt = .now
            try save()
            return existing
        }

        let account = Account(
            serverUrl: info.serverURL,
            serverHash: info.key.serverHash,
            userHash: info.key.userHash,
            userName: info.username,
            apiType: apiType
        )
        context.insert(account)
        try save()
        return account
    }

    public func fetchAccount(key: AccountInfo.Key) throws -> Account? {
        let compoundKey = key.storageKey
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.compoundKey == compoundKey }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Artists

    public func fetchArtists(account: Account, favoritesOnly: Bool = false) throws -> [Artist] {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<Artist>(sortBy: [SortDescriptor(\Artist.sortName)]))
        return all.filter { artist in
            guard artist.account?.persistentModelID == accountID else { return false }
            return favoritesOnly ? artist.isFavorite : true
        }
    }

    @discardableResult
    public func getOrCreateArtist(remoteId: String, name: String, account: Account) throws -> Artist {
        let compoundRemoteId = Artist.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.artists[compoundRemoteId] ?? fetchArtist(compoundRemoteId: compoundRemoteId) {
            existing.name = name
            existing.sortName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            existing.updatedAt = .now
            batch?.artists[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let artist = Artist(remoteId: remoteId, name: name, account: account)
        context.insert(artist)
        batch?.artists[compoundRemoteId] = artist
        try saveIfNotBatching()
        return artist
    }

    public func fetchArtist(compoundRemoteId: String) throws -> Artist? {
        var descriptor = FetchDescriptor<Artist>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Albums

    public func fetchAlbums(account: Account, artist: Artist? = nil, favoritesOnly: Bool = false) throws -> [Album] {
        let accountID = account.persistentModelID
        let all = try context.fetch(
            FetchDescriptor<Album>(
                sortBy: [
                    SortDescriptor(\Album.sortTitle),
                    SortDescriptor(\Album.year, order: .reverse)
                ]
            )
        )
        return all.filter { album in
            guard album.account?.persistentModelID == accountID else { return false }
            if favoritesOnly && !album.isFavorite { return false }
            if let artist, album.artist?.persistentModelID != artist.persistentModelID { return false }
            return true
        }
    }

    /// Albums currently marked favorite (any account). Used for differential home updates.
    public func fetchAlbums(favoritesOnly: Bool) throws -> [Album] {
        guard favoritesOnly else {
            return try context.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\Album.sortTitle)]))
        }
        return try context.fetch(
            FetchDescriptor<Album>(
                predicate: #Predicate { $0.isFavorite == true },
                sortBy: [SortDescriptor(\Album.sortTitle)]
            )
        )
    }

    public func fetchAlbums(newestIndexPositive: Bool) throws -> [Album] {
        guard newestIndexPositive else { return [] }
        return try context.fetch(
            FetchDescriptor<Album>(
                predicate: #Predicate { $0.newestIndex > 0 },
                sortBy: [SortDescriptor(\Album.newestIndex)]
            )
        )
    }

    public func fetchAlbums(recentIndexPositive: Bool) throws -> [Album] {
        guard recentIndexPositive else { return [] }
        return try context.fetch(
            FetchDescriptor<Album>(
                predicate: #Predicate { $0.recentIndex > 0 },
                sortBy: [SortDescriptor(\Album.recentIndex)]
            )
        )
    }

    @discardableResult
    public func getOrCreateAlbum(
        remoteId: String,
        title: String,
        account: Account,
        artist: Artist? = nil,
        year: Int? = nil
    ) throws -> Album {
        let compoundRemoteId = Album.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.albums[compoundRemoteId] ?? fetchAlbum(compoundRemoteId: compoundRemoteId) {
            existing.title = title
            existing.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            existing.artist = artist ?? existing.artist
            if let artist { existing.artistName = artist.name }
            existing.year = year ?? existing.year
            existing.updatedAt = .now
            batch?.albums[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let album = Album(remoteId: remoteId, title: title, account: account, artist: artist)
        album.year = year
        if let artist { album.artistName = artist.name }
        context.insert(album)
        batch?.albums[compoundRemoteId] = album
        try saveIfNotBatching()
        return album
    }

    public func fetchAlbum(compoundRemoteId: String) throws -> Album? {
        var descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func resolveAlbum(remoteId: String, account: Account) throws -> Album? {
        try fetchAlbum(compoundRemoteId: Album.makeCompoundRemoteId(account: account, remoteId: remoteId))
    }

    // MARK: - Songs

    public func fetchSongs(
        account: Account,
        album: Album? = nil,
        cachedOnly: Bool = false,
        favoritesOnly: Bool = false
    ) throws -> [Song] {
        let accountID = account.persistentModelID
        let all = try context.fetch(
            FetchDescriptor<Song>(
                sortBy: [
                    SortDescriptor(\Song.disc),
                    SortDescriptor(\Song.track),
                    SortDescriptor(\Song.sortTitle)
                ]
            )
        )
        return all.filter { song in
            guard song.account?.persistentModelID == accountID else { return false }
            if let album, song.album?.persistentModelID != album.persistentModelID { return false }
            if cachedOnly && song.relFilePath == nil { return false }
            if favoritesOnly && !song.isFavorite { return false }
            return true
        }
    }

    @discardableResult
    public func getOrCreateSong(
        remoteId: String,
        title: String,
        account: Account,
        album: Album? = nil,
        artist: Artist? = nil,
        track: Int? = nil
    ) throws -> Song {
        let compoundRemoteId = Song.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.songs[compoundRemoteId] ?? fetchSong(compoundRemoteId: compoundRemoteId) {
            existing.title = title
            existing.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            existing.album = album ?? existing.album
            existing.artist = artist ?? existing.artist
            existing.track = track ?? existing.track
            existing.updatedAt = .now
            batch?.songs[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let song = Song(remoteId: remoteId, title: title, account: account)
        song.album = album
        song.artist = artist
        song.track = track
        context.insert(song)
        batch?.songs[compoundRemoteId] = song
        try saveIfNotBatching()
        return song
    }

    public func fetchSong(compoundRemoteId: String) throws -> Song? {
        var descriptor = FetchDescriptor<Song>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func resolveSong(remoteId: String, account: Account) throws -> Song? {
        let compoundRemoteId = Song.makeCompoundRemoteId(account: account, remoteId: remoteId)
        return try fetchSong(compoundRemoteId: compoundRemoteId)
    }

    // MARK: - Playlists

    public func fetchPlaylists(account: Account) throws -> [Playlist] {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\Playlist.sortName)]))
        return all.filter { $0.account?.persistentModelID == accountID }
    }

    @discardableResult
    public func getOrCreatePlaylist(remoteId: String, name: String, account: Account) throws -> Playlist {
        let compoundRemoteId = Playlist.makeCompoundRemoteId(account: account, remoteId: remoteId)
        if let existing = try batch?.playlists[compoundRemoteId] ?? fetchPlaylist(compoundRemoteId: compoundRemoteId) {
            existing.name = name
            existing.sortName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            existing.updatedAt = .now
            batch?.playlists[compoundRemoteId] = existing
            try saveIfNotBatching()
            return existing
        }
        let playlist = Playlist(remoteId: remoteId, name: name, account: account)
        context.insert(playlist)
        batch?.playlists[compoundRemoteId] = playlist
        try saveIfNotBatching()
        return playlist
    }

    public func fetchPlaylist(compoundRemoteId: String) throws -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.compoundRemoteId == compoundRemoteId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func replacePlaylistItems(_ playlist: Playlist, with songs: [Song]) throws {
        for item in playlist.items {
            context.delete(item)
        }
        playlist.items.removeAll()
        for (index, song) in songs.enumerated() {
            let item = PlaylistItem(order: index, playlist: playlist, song: song)
            context.insert(item)
            playlist.items.append(item)
        }
        playlist.songCount = songs.count
        playlist.duration = songs.reduce(0) { $0 + $1.playDuration }
        playlist.updatedAt = .now
        try save()
    }

    // MARK: - Podcasts & Radios

    public func fetchPodcasts(account: Account) throws -> [Podcast] {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\Podcast.sortTitle)]))
        return all.filter { $0.account?.persistentModelID == accountID }
    }

    public func fetchPodcastEpisodes(account: Account, podcast: Podcast? = nil) throws -> [PodcastEpisode] {
        let accountID = account.persistentModelID
        let all = try context.fetch(
            FetchDescriptor<PodcastEpisode>(sortBy: [SortDescriptor(\PodcastEpisode.sortTitle)])
        )
        return all.filter { episode in
            guard episode.account?.persistentModelID == accountID else { return false }
            if let podcast, episode.podcast?.persistentModelID != podcast.persistentModelID { return false }
            return true
        }
    }

    public func fetchRadios(account: Account, favoritesOnly: Bool = false) throws -> [Radio] {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<Radio>(sortBy: [SortDescriptor(\Radio.sortTitle)]))
        return all.filter { radio in
            guard radio.account?.persistentModelID == accountID else { return false }
            return favoritesOnly ? radio.isFavorite : true
        }
    }

    // MARK: - Genres & Downloads

    public func fetchGenres(account: Account) throws -> [Genre] {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<Genre>(sortBy: [SortDescriptor(\Genre.name)]))
        return all.filter { $0.account?.persistentModelID == accountID }
    }

    public func fetchDownloads(account: Account, activeOnly: Bool = false) throws -> [DownloadRecord] {
        let accountID = account.persistentModelID
        let all = try context.fetch(
            FetchDescriptor<DownloadRecord>(sortBy: [SortDescriptor(\DownloadRecord.startedAt, order: .reverse)])
        )
        return all.filter { record in
            guard record.account?.persistentModelID == accountID else { return false }
            return activeOnly ? record.isActive : true
        }
    }

    // MARK: - Search

    public func searchArtists(account: Account, query: String) throws -> [Artist] {
        let base = try fetchArtists(account: account)
        return FuzzySearcher.ranked(query: query, items: base, keyPath: \.name).map(\.item)
    }

    public func searchAlbums(account: Account, query: String) throws -> [Album] {
        let base = try fetchAlbums(account: account)
        return FuzzySearcher.ranked(query: query, items: base, keyPath: \.title).map(\.item)
    }

    public func searchSongs(account: Account, query: String) throws -> [Song] {
        let base = try fetchSongs(account: account)
        return FuzzySearcher.ranked(query: query, items: base, keyPath: \.title).map(\.item)
    }

    public func searchAll(account: Account, query: String) throws -> (artists: [Artist], albums: [Album], songs: [Song]) {
        (
            artists: try searchArtists(account: account, query: query),
            albums: try searchAlbums(account: account, query: query),
            songs: try searchSongs(account: account, query: query)
        )
    }

    @discardableResult
    public func recordSearchHistory(account: Account, query: String, resultCount: Int) throws -> SearchHistoryItem {
        let item = SearchHistoryItem(query: query, account: account, resultCount: resultCount)
        context.insert(item)
        try save()
        return item
    }

    // MARK: - Player Data

    public func getOrCreatePlayerData(account: Account) throws -> PlayerData {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<PlayerData>())
        if let existing = all.first(where: { $0.account?.persistentModelID == accountID }) {
            return existing
        }
        let playerData = PlayerData(account: account)
        context.insert(playerData)
        try save()
        return playerData
    }

    public func updatePlayerQueue(
        account: Account,
        songs: [Song],
        index: Int,
        shuffle: ShuffleMode,
        repeatMode: RepeatMode,
        sourcePlaylist: Playlist? = nil
    ) throws -> PlayerData {
        let playerData = try getOrCreatePlayerData(account: account)
        playerData.musicQueue = songs
        playerData.musicIndex = min(max(0, index), max(0, songs.count - 1))
        playerData.shuffle = shuffle
        playerData.repeatMode = repeatMode
        playerData.sourcePlaylist = sourcePlaylist
        playerData.queueGeneration += 1
        playerData.updatedAt = .now
        try save()
        NotificationCenter.default.post(name: .queueChanged, object: nil)
        return playerData
    }

    // MARK: - Cache Helpers

    public func markCacheTouched(song: Song, reason: CacheReason) throws {
        song.cacheTouchedDate = .now
        song.cacheReason = reason
        if let record = song.cacheRecord {
            record.touchedAt = .now
            record.cacheReason = reason
        }
        try save()
    }

    public func markCacheTouched(episode: PodcastEpisode, reason: CacheReason) throws {
        episode.cacheTouchedDate = .now
        episode.cacheReason = reason
        if let record = episode.cacheRecord {
            record.touchedAt = .now
            record.cacheReason = reason
        }
        try save()
    }

    @discardableResult
    public func upsertCacheRecord(
        for song: Song,
        relFilePath: String,
        byteSize: Int64,
        reason: CacheReason
    ) throws -> PlayableCacheRecord {
        if let record = song.cacheRecord {
            record.relFilePath = relFilePath
            record.byteSize = byteSize
            record.cacheReason = reason
            record.touchedAt = .now
            song.relFilePath = relFilePath
            song.cacheReason = reason
            song.cacheTouchedDate = .now
            try save()
            return record
        }
        let record = PlayableCacheRecord(
            relFilePath: relFilePath,
            byteSize: byteSize,
            account: song.account,
            cacheReason: reason
        )
        record.song = song
        song.cacheRecord = record
        song.relFilePath = relFilePath
        song.cacheReason = reason
        song.cacheTouchedDate = .now
        context.insert(record)
        try save()
        return record
    }

    // MARK: - Statistics & Logging

    public func getOrCreateStatistics(account: Account) throws -> UserStatistics {
        let accountID = account.persistentModelID
        let all = try context.fetch(FetchDescriptor<UserStatistics>())
        if let existing = all.first(where: { $0.account?.persistentModelID == accountID }) {
            return existing
        }
        let stats = UserStatistics(account: account)
        context.insert(stats)
        try save()
        return stats
    }

    @discardableResult
    public func appendLog(
        account: Account?,
        level: LogLevelRaw,
        category: String,
        message: String
    ) throws -> LogEntry {
        let entry = LogEntry(level: level, category: category, message: message, account: account)
        context.insert(entry)
        try save()
        return entry
    }

    // MARK: - Save

    public func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }
}
