import Foundation
import SwiftData

// MARK: - Account

@Model
public final class Account {
    @Attribute(.unique) public var serverHash: String
    @Attribute(.unique) public var compoundKey: String
    public var serverUrl: String
    public var userHash: String
    public var userName: String
    public var apiTypeRaw: Int
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Artist.account)
    public var artists: [Artist]

    @Relationship(deleteRule: .cascade, inverse: \Album.account)
    public var albums: [Album]

    @Relationship(deleteRule: .cascade, inverse: \Genre.account)
    public var genres: [Genre]

    @Relationship(deleteRule: .cascade, inverse: \Directory.account)
    public var directories: [Directory]

    @Relationship(deleteRule: .cascade, inverse: \MusicFolder.account)
    public var musicFolders: [MusicFolder]

    @Relationship(deleteRule: .cascade, inverse: \Song.account)
    public var songs: [Song]

    @Relationship(deleteRule: .cascade, inverse: \PodcastEpisode.account)
    public var podcastEpisodes: [PodcastEpisode]

    @Relationship(deleteRule: .cascade, inverse: \Radio.account)
    public var radios: [Radio]

    @Relationship(deleteRule: .cascade, inverse: \Playlist.account)
    public var playlists: [Playlist]

    @Relationship(deleteRule: .cascade, inverse: \Podcast.account)
    public var podcasts: [Podcast]

    @Relationship(deleteRule: .cascade, inverse: \Artwork.account)
    public var artworks: [Artwork]

    @Relationship(deleteRule: .cascade, inverse: \DownloadRecord.account)
    public var downloads: [DownloadRecord]

    @Relationship(deleteRule: .cascade, inverse: \PlayerData.account)
    public var playerDataRecords: [PlayerData]

    @Relationship(deleteRule: .cascade, inverse: \ScrobbleEntry.account)
    public var scrobbles: [ScrobbleEntry]

    @Relationship(deleteRule: .cascade, inverse: \SearchHistoryItem.account)
    public var searchHistory: [SearchHistoryItem]

    @Relationship(deleteRule: .cascade, inverse: \LogEntry.account)
    public var logs: [LogEntry]

    @Relationship(deleteRule: .cascade, inverse: \UserStatistics.account)
    public var statistics: [UserStatistics]

    @Relationship(deleteRule: .cascade, inverse: \PlayableCacheRecord.account)
    public var cacheRecords: [PlayableCacheRecord]

    public var apiType: ApiType {
        get { ApiType(rawValue: apiTypeRaw) ?? .notDetected }
        set { apiTypeRaw = newValue.rawValue }
    }

    public init(
        serverUrl: String,
        serverHash: String,
        userHash: String,
        userName: String,
        apiType: ApiType = .notDetected
    ) {
        self.serverUrl = serverUrl
        self.serverHash = serverHash
        self.userHash = userHash
        self.compoundKey = "\(serverHash)_\(userHash)"
        self.userName = userName
        self.apiTypeRaw = apiType.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.artists = []
        self.albums = []
        self.genres = []
        self.directories = []
        self.musicFolders = []
        self.songs = []
        self.podcastEpisodes = []
        self.radios = []
        self.playlists = []
        self.podcasts = []
        self.artworks = []
        self.downloads = []
        self.playerDataRecords = []
        self.scrobbles = []
        self.searchHistory = []
        self.logs = []
        self.statistics = []
        self.cacheRecords = []
    }
}

// MARK: - Library Entities

@Model
public final class Artist {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var name: String
    public var sortName: String
    public var albumCount: Int
    public var songCount: Int
    public var playCount: Int
    public var isFavorite: Bool
    public var rating: Int
    public var artworkToken: String?
    public var updatedAt: Date

    public var account: Account?

    @Relationship(deleteRule: .nullify, inverse: \Album.artist)
    public var albums: [Album]

    @Relationship(deleteRule: .nullify, inverse: \Song.artist)
    public var songs: [Song]

    public init(remoteId: String, name: String, account: Account?) {
        self.remoteId = remoteId
        self.name = name
        self.sortName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.albumCount = 0
        self.songCount = 0
        self.playCount = 0
        self.isFavorite = false
        self.rating = 0
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Artist.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.albums = []
        self.songs = []
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::artist::\(remoteId)"
    }
}

@Model
public final class Album {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String
    public var year: Int?
    public var trackCount: Int
    public var duration: TimeInterval
    public var playCount: Int
    public var isFavorite: Bool
    public var rating: Int
    public var genreName: String?
    public var artworkToken: String?
    public var updatedAt: Date
    /// Rank from server `getAlbumList2 type=newest` (1-based). 0 = not in newest set.
    /// Default is required for lightweight migration of existing stores.
    public var newestIndex: Int = 0
    /// Rank from server `getAlbumList2 type=recent` (1-based). 0 = not in recent set.
    public var recentIndex: Int = 0

    public var account: Account?
    public var artist: Artist?

    @Relationship(deleteRule: .nullify, inverse: \Song.album)
    public var songs: [Song]

    public init(remoteId: String, title: String, account: Account?, artist: Artist? = nil) {
        self.remoteId = remoteId
        self.title = title
        self.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.trackCount = 0
        self.duration = 0
        self.playCount = 0
        self.isFavorite = false
        self.rating = 0
        self.updatedAt = .now
        self.newestIndex = 0
        self.recentIndex = 0
        self.account = account
        self.artist = artist
        self.compoundRemoteId = Album.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.songs = []
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::album::\(remoteId)"
    }
}

@Model
public final class Genre {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var name: String
    public var songCount: Int
    public var albumCount: Int
    /// Cover from a representative album (genres have no server artwork).
    public var artworkToken: String?

    public var account: Account?

    public init(remoteId: String, name: String, account: Account?) {
        self.remoteId = remoteId
        self.name = name
        self.songCount = 0
        self.albumCount = 0
        self.account = account
        self.compoundRemoteId = Genre.makeCompoundRemoteId(account: account, remoteId: remoteId)
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::genre::\(remoteId)"
    }
}

@Model
public final class Directory {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var name: String
    public var parentRemoteId: String?

    public var account: Account?
    public var parent: Directory?

    @Relationship(deleteRule: .nullify, inverse: \Directory.parent)
    public var children: [Directory]

    public init(remoteId: String, name: String, account: Account?, parent: Directory? = nil) {
        self.remoteId = remoteId
        self.name = name
        self.parentRemoteId = parent?.remoteId
        self.account = account
        self.parent = parent
        self.compoundRemoteId = Directory.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.children = []
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::directory::\(remoteId)"
    }
}

@Model
public final class MusicFolder {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var name: String

    public var account: Account?

    public init(remoteId: String, name: String, account: Account?) {
        self.remoteId = remoteId
        self.name = name
        self.account = account
        self.compoundRemoteId = MusicFolder.makeCompoundRemoteId(account: account, remoteId: remoteId)
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::musicFolder::\(remoteId)"
    }
}

// MARK: - Playables

@Model
public final class Song {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String
    public var track: Int?
    public var disc: Int?
    public var year: Int?
    public var bitrate: Int?
    public var size: Int64?
    public var contentType: String?
    public var relFilePath: String?
    public var playProgress: TimeInterval
    public var playDuration: TimeInterval
    public var playCount: Int
    public var lastPlayedDate: Date?
    public var rating: Int
    public var isFavorite: Bool
    public var cacheReasonRaw: Int
    public var isUserPinned: Bool
    public var cacheTouchedDate: Date?
    public var remoteStatusRaw: Int
    public var artistName: String?
    public var albumTitle: String?
    public var genreName: String?
    /// Denormalized cover art id so list rows avoid faulting `album`.
    public var artworkToken: String?
    public var updatedAt: Date

    public var account: Account?
    public var artist: Artist?
    public var album: Album?
    public var genre: Genre?

    @Relationship(deleteRule: .cascade, inverse: \EmbeddedArtwork.song)
    public var embeddedArtwork: EmbeddedArtwork?

    @Relationship(deleteRule: .nullify, inverse: \PlaylistItem.song)
    public var playlistItems: [PlaylistItem]

    @Relationship(deleteRule: .cascade, inverse: \PlayableCacheRecord.song)
    public var cacheRecord: PlayableCacheRecord?

    public var cacheReason: CacheReason {
        get { CacheReason(rawValue: cacheReasonRaw) ?? .none }
        set { cacheReasonRaw = newValue.rawValue }
    }

    public var remoteStatus: RemoteItemStatus {
        get { RemoteItemStatus(rawValue: remoteStatusRaw) ?? .available }
        set { remoteStatusRaw = newValue.rawValue }
    }

    public init(remoteId: String, title: String, account: Account?) {
        self.remoteId = remoteId
        self.title = title
        self.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.playProgress = 0
        self.playDuration = 0
        self.playCount = 0
        self.rating = 0
        self.isFavorite = false
        self.cacheReasonRaw = CacheReason.none.rawValue
        self.isUserPinned = false
        self.remoteStatusRaw = RemoteItemStatus.available.rawValue
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Song.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.playlistItems = []
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::song::\(remoteId)"
    }
}

@Model
public final class PodcastEpisode {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String
    public var track: Int?
    public var year: Int?
    public var bitrate: Int?
    public var size: Int64?
    public var contentType: String?
    public var relFilePath: String?
    public var playProgress: TimeInterval
    public var playDuration: TimeInterval
    public var playCount: Int
    public var lastPlayedDate: Date?
    public var rating: Int
    public var isFavorite: Bool
    public var cacheReasonRaw: Int
    public var isUserPinned: Bool
    public var cacheTouchedDate: Date?
    public var remoteStatusRaw: Int
    public var publishedAt: Date?
    public var descriptionText: String?
    public var updatedAt: Date

    public var account: Account?
    public var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \PlayableCacheRecord.podcastEpisode)
    public var cacheRecord: PlayableCacheRecord?

    public var cacheReason: CacheReason {
        get { CacheReason(rawValue: cacheReasonRaw) ?? .none }
        set { cacheReasonRaw = newValue.rawValue }
    }

    public var remoteStatus: RemoteItemStatus {
        get { RemoteItemStatus(rawValue: remoteStatusRaw) ?? .available }
        set { remoteStatusRaw = newValue.rawValue }
    }

    public init(remoteId: String, title: String, account: Account?, podcast: Podcast? = nil) {
        self.remoteId = remoteId
        self.title = title
        self.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.playProgress = 0
        self.playDuration = 0
        self.playCount = 0
        self.rating = 0
        self.isFavorite = false
        self.cacheReasonRaw = CacheReason.none.rawValue
        self.isUserPinned = false
        self.remoteStatusRaw = RemoteItemStatus.available.rawValue
        self.updatedAt = .now
        self.account = account
        self.podcast = podcast
        self.compoundRemoteId = PodcastEpisode.makeCompoundRemoteId(account: account, remoteId: remoteId)
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::episode::\(remoteId)"
    }
}

@Model
public final class Radio {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String
    public var track: Int?
    public var year: Int?
    public var bitrate: Int?
    public var size: Int64?
    public var contentType: String?
    public var relFilePath: String?
    public var playProgress: TimeInterval
    public var playDuration: TimeInterval
    public var playCount: Int
    public var lastPlayedDate: Date?
    public var rating: Int
    public var isFavorite: Bool
    public var cacheReasonRaw: Int
    public var isUserPinned: Bool
    public var cacheTouchedDate: Date?
    public var remoteStatusRaw: Int
    public var streamURL: String?
    public var homepageURL: String?
    /// OpenSubsonic `coverArt` / Ampache `art` when the server provides station artwork.
    public var artworkToken: String?
    public var updatedAt: Date

    public var account: Account?

    @Relationship(deleteRule: .cascade, inverse: \PlayableCacheRecord.radio)
    public var cacheRecord: PlayableCacheRecord?

    public var cacheReason: CacheReason {
        get { CacheReason(rawValue: cacheReasonRaw) ?? .none }
        set { cacheReasonRaw = newValue.rawValue }
    }

    public var remoteStatus: RemoteItemStatus {
        get { RemoteItemStatus(rawValue: remoteStatusRaw) ?? .available }
        set { remoteStatusRaw = newValue.rawValue }
    }

    public init(remoteId: String, title: String, account: Account?) {
        self.remoteId = remoteId
        self.title = title
        self.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.playProgress = 0
        self.playDuration = 0
        self.playCount = 0
        self.rating = 0
        self.isFavorite = false
        self.cacheReasonRaw = CacheReason.none.rawValue
        self.isUserPinned = false
        self.remoteStatusRaw = RemoteItemStatus.available.rawValue
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Radio.makeCompoundRemoteId(account: account, remoteId: remoteId)
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::radio::\(remoteId)"
    }
}

// MARK: - Playlists

@Model
public final class Playlist {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var name: String
    public var sortName: String
    public var isSmart: Bool
    public var isEditable: Bool
    public var songCount: Int
    public var duration: TimeInterval
    /// Subsonic `coverArt` / Ampache `art` token (or first-song fallback).
    public var artworkToken: String?
    public var updatedAt: Date

    public var account: Account?

    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    public var items: [PlaylistItem]

    public init(remoteId: String, name: String, account: Account?, isSmart: Bool = false, isEditable: Bool = true) {
        self.remoteId = remoteId
        self.name = name
        self.sortName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.isSmart = isSmart
        self.isEditable = isEditable
        self.songCount = 0
        self.duration = 0
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Playlist.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.items = []
    }

    /// Cover art for UI: server token, else first track with artwork.
    public var displayArtworkToken: String? {
        if let artworkToken, !artworkToken.isEmpty { return artworkToken }
        return items
            .sorted { $0.order < $1.order }
            .compactMap { $0.song?.artworkToken ?? $0.song?.album?.artworkToken }
            .first
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::playlist::\(remoteId)"
    }
}

@Model
public final class PlaylistItem {
    public var order: Int
    public var addedAt: Date

    public var playlist: Playlist?
    public var song: Song?

    public init(order: Int, playlist: Playlist?, song: Song?) {
        self.order = order
        self.addedAt = .now
        self.playlist = playlist
        self.song = song
    }
}

@Model
public final class Podcast {
    @Attribute(.unique) public var compoundRemoteId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String
    public var author: String?
    public var descriptionText: String?
    public var artworkToken: String?
    public var episodeCount: Int
    public var updatedAt: Date

    public var account: Account?

    @Relationship(deleteRule: .nullify, inverse: \PodcastEpisode.podcast)
    public var episodes: [PodcastEpisode]

    public init(remoteId: String, title: String, account: Account?) {
        self.remoteId = remoteId
        self.title = title
        self.sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.episodeCount = 0
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Podcast.makeCompoundRemoteId(account: account, remoteId: remoteId)
        self.episodes = []
    }

    public static func makeCompoundRemoteId(account: Account?, remoteId: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::podcast::\(remoteId)"
    }
}

// MARK: - Artwork

@Model
public final class Artwork {
    @Attribute(.unique) public var compoundRemoteId: String
    public var token: String
    public var relFilePath: String?
    public var width: Int?
    public var height: Int?
    public var byteSize: Int64?
    public var updatedAt: Date

    public var account: Account?

    public init(token: String, account: Account?) {
        self.token = token
        self.updatedAt = .now
        self.account = account
        self.compoundRemoteId = Artwork.makeCompoundRemoteId(account: account, token: token)
    }

    public static func makeCompoundRemoteId(account: Account?, token: String) -> String {
        let prefix = account?.compoundKey ?? "global"
        return "\(prefix)::artwork::\(token)"
    }
}

@Model
public final class EmbeddedArtwork {
    public var mimeType: String?
    public var byteSize: Int64?
    public var relFilePath: String?

    public var song: Song?

    public init(song: Song?) {
        self.song = song
    }
}

// MARK: - Downloads & Cache

@Model
public final class DownloadRecord {
    public var remoteId: String
    public var title: String
    public var progress: Double
    public var byteTotal: Int64
    public var byteReceived: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var lastError: String?
    public var isActive: Bool
    public var relFilePath: String?

    public var account: Account?
    public var song: Song?
    public var podcastEpisode: PodcastEpisode?

    public init(remoteId: String, title: String, account: Account?) {
        self.remoteId = remoteId
        self.title = title
        self.progress = 0
        self.byteTotal = 0
        self.byteReceived = 0
        self.startedAt = .now
        self.isActive = true
        self.account = account
    }
}

@Model
public final class PlayableCacheRecord {
    public var relFilePath: String
    public var byteSize: Int64
    public var cacheReasonRaw: Int
    public var isUserPinned: Bool
    public var touchedAt: Date
    public var checksum: String?

    public var account: Account?
    public var song: Song?
    public var podcastEpisode: PodcastEpisode?
    public var radio: Radio?

    public var cacheReason: CacheReason {
        get { CacheReason(rawValue: cacheReasonRaw) ?? .none }
        set { cacheReasonRaw = newValue.rawValue }
    }

    public init(relFilePath: String, byteSize: Int64, account: Account?, cacheReason: CacheReason = .none) {
        self.relFilePath = relFilePath
        self.byteSize = byteSize
        self.cacheReasonRaw = cacheReason.rawValue
        self.isUserPinned = false
        self.touchedAt = .now
        self.account = account
    }
}

// MARK: - Player

@Model
public final class PlayerData {
    public var musicIndex: Int
    public var podcastIndex: Int
    public var playerModeRaw: Int
    public var shuffleRaw: Int
    public var repeatRaw: Int
    public var queueGeneration: Int
    public var updatedAt: Date

    public var account: Account?

    @Relationship(deleteRule: .nullify)
    public var musicQueue: [Song]

    @Relationship(deleteRule: .nullify)
    public var podcastQueue: [PodcastEpisode]

    @Relationship(deleteRule: .nullify)
    public var radioQueue: [Radio]

    @Relationship(deleteRule: .nullify)
    public var sourcePlaylist: Playlist?

    public var playerMode: PlayerMode {
        get { PlayerMode(rawValue: playerModeRaw) ?? .music }
        set { playerModeRaw = newValue.rawValue }
    }

    public var shuffle: ShuffleMode {
        get { ShuffleMode(rawValue: shuffleRaw) ?? .off }
        set { shuffleRaw = newValue.rawValue }
    }

    public var repeatMode: RepeatMode {
        get { RepeatMode(rawValue: repeatRaw) ?? .off }
        set { repeatRaw = newValue.rawValue }
    }

    public init(account: Account?) {
        self.musicIndex = 0
        self.podcastIndex = 0
        self.playerModeRaw = PlayerMode.music.rawValue
        self.shuffleRaw = ShuffleMode.off.rawValue
        self.repeatRaw = RepeatMode.off.rawValue
        self.queueGeneration = 1
        self.updatedAt = .now
        self.account = account
        self.musicQueue = []
        self.podcastQueue = []
        self.radioQueue = []
    }
}

// MARK: - Auxiliary Records

@Model
public final class ScrobbleEntry {
    public var title: String
    public var artistName: String
    public var albumTitle: String?
    public var playedAt: Date
    public var duration: TimeInterval
    public var isSubmitted: Bool
    public var remoteTrackId: String?

    public var account: Account?

    public init(title: String, artistName: String, playedAt: Date, account: Account?) {
        self.title = title
        self.artistName = artistName
        self.playedAt = playedAt
        self.duration = 0
        self.isSubmitted = false
        self.account = account
    }
}

@Model
public final class SearchHistoryItem {
    public var query: String
    public var searchedAt: Date
    public var resultCount: Int

    public var account: Account?

    public init(query: String, account: Account?, resultCount: Int = 0) {
        self.query = query
        self.searchedAt = .now
        self.resultCount = resultCount
        self.account = account
    }
}

@Model
public final class LogEntry {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var levelRaw: String
    public var category: String
    public var message: String

    public var account: Account?

    public init(level: LogLevelRaw, category: String, message: String, account: Account? = nil) {
        self.id = UUID()
        self.timestamp = .now
        self.levelRaw = level.rawValue
        self.category = category
        self.message = message
        self.account = account
    }
}

@Model
public final class UserStatistics {
    public var totalPlayCount: Int
    public var totalPlayDuration: TimeInterval
    public var songsPlayed: Int
    public var albumsPlayed: Int
    public var artistsPlayed: Int
    public var lastUpdatedAt: Date

    public var account: Account?

    public init(account: Account?) {
        self.totalPlayCount = 0
        self.totalPlayDuration = 0
        self.songsPlayed = 0
        self.albumsPlayed = 0
        self.artistsPlayed = 0
        self.lastUpdatedAt = .now
        self.account = account
    }
}

public enum VerodromeSchema {
    public static let models: [any PersistentModel.Type] = [
        Account.self,
        Artist.self,
        Album.self,
        Genre.self,
        Directory.self,
        MusicFolder.self,
        Song.self,
        PodcastEpisode.self,
        Radio.self,
        Playlist.self,
        PlaylistItem.self,
        Podcast.self,
        Artwork.self,
        EmbeddedArtwork.self,
        DownloadRecord.self,
        PlayableCacheRecord.self,
        PlayerData.self,
        ScrobbleEntry.self,
        SearchHistoryItem.self,
        LogEntry.self,
        UserStatistics.self
    ]
}
