import Foundation

public struct PlayableRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artistName: String?
    public var albumName: String?
    public var albumId: String?
    public var artistId: String?
    public var duration: TimeInterval
    public var track: Int
    public var year: Int
    public var coverArtId: String?
    public var bitRate: Int?
    public var contentType: String?
    public var size: Int64?
    public var kind: Kind

    public enum Kind: String, Sendable, Codable {
        case song
        case podcastEpisode
        case radio
    }

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        albumId: String? = nil,
        artistId: String? = nil,
        duration: TimeInterval = 0,
        track: Int = 0,
        year: Int = 0,
        coverArtId: String? = nil,
        bitRate: Int? = nil,
        contentType: String? = nil,
        size: Int64? = nil,
        kind: Kind = .song
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.artistId = artistId
        self.duration = duration
        self.track = track
        self.year = year
        self.coverArtId = coverArtId
        self.bitRate = bitRate
        self.contentType = contentType
        self.size = size
        self.kind = kind
    }
}

public struct ArtistRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var albumCount: Int
    public var coverArtId: String?
    public init(id: String, name: String, albumCount: Int = 0, coverArtId: String? = nil) {
        self.id = id; self.name = name; self.albumCount = albumCount; self.coverArtId = coverArtId
    }
}

public struct AlbumRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var artistId: String?
    public var artistName: String?
    public var year: Int
    public var songCount: Int
    public var coverArtId: String?
    public init(id: String, name: String, artistId: String? = nil, artistName: String? = nil, year: Int = 0, songCount: Int = 0, coverArtId: String? = nil) {
        self.id = id; self.name = name; self.artistId = artistId; self.artistName = artistName
        self.year = year; self.songCount = songCount; self.coverArtId = coverArtId
    }
}

public struct GenreRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var songCount: Int
    public init(id: String, name: String, songCount: Int = 0) {
        self.id = id; self.name = name; self.songCount = songCount
    }
}

public struct PlaylistRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var songCount: Int
    public var owner: String?
    public var isPublic: Bool
    public init(id: String, name: String, songCount: Int = 0, owner: String? = nil, isPublic: Bool = false) {
        self.id = id; self.name = name; self.songCount = songCount; self.owner = owner; self.isPublic = isPublic
    }
}

public struct PodcastRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var coverArtId: String?
    public var episodeCount: Int
    public init(id: String, title: String, description: String? = nil, coverArtId: String? = nil, episodeCount: Int = 0) {
        self.id = id; self.title = title; self.description = description
        self.coverArtId = coverArtId; self.episodeCount = episodeCount
    }
}

public struct RadioRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var streamURL: URL?
    public var homePageURL: URL?
    public init(id: String, name: String, streamURL: URL? = nil, homePageURL: URL? = nil) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.homePageURL = homePageURL
    }
}

public struct DirectoryRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var parentId: String?
    public init(id: String, name: String, parentId: String? = nil) {
        self.id = id; self.name = name; self.parentId = parentId
    }
}

public struct MusicFolderRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SearchResults: Sendable {
    public var artists: [ArtistRef]
    public var albums: [AlbumRef]
    public var songs: [PlayableRef]
    public var playlists: [PlaylistRef]
    public init(artists: [ArtistRef] = [], albums: [AlbumRef] = [], songs: [PlayableRef] = [], playlists: [PlaylistRef] = []) {
        self.artists = artists; self.albums = albums; self.songs = songs; self.playlists = playlists
    }
}

public struct ServerCapabilities: Sendable {
    public var apiType: ApiType
    public var serverVersion: String?
    public var supportsPodcasts: Bool
    public var supportsRadios: Bool
    public init(apiType: ApiType, serverVersion: String? = nil, supportsPodcasts: Bool = true, supportsRadios: Bool = true) {
        self.apiType = apiType; self.serverVersion = serverVersion
        self.supportsPodcasts = supportsPodcasts; self.supportsRadios = supportsRadios
    }
}

public enum BackendError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case server(message: String, code: Int?)
    case parsing(String)
    case network(String)
    case notAuthenticated
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL"
        case .unauthorized: "Authentication failed"
        case .server(let message, let code): code.map { "[\($0)] \(message)" } ?? message
        case .parsing(let m): "Parse error: \(m)"
        case .network(let m): m
        case .notAuthenticated: "Not authenticated"
        case .unsupported: "Unsupported operation"
        }
    }
}

// MARK: - API transport models (used by BackendApi / syncers)

public struct ArtworkRef: Hashable, Sendable, Codable {
    public let id: String
    public let kind: ArtworkKind

    public init(id: String, kind: ArtworkKind) {
        self.id = id
        self.kind = kind
    }
}

public enum ArtworkKind: String, Sendable, Codable {
    case album
    case artist
    case song
    case podcast
    case playlist
}

public enum StreamFormat: String, Sendable, Codable {
    case original
    case mp3
    case ogg
    case raw
}

public struct ServerInfo: Sendable, Equatable {
    public let name: String
    public let version: String
    public let apiVersion: String?
    public let isSupported: Bool

    public init(name: String, version: String, apiVersion: String? = nil, isSupported: Bool = true) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.isSupported = isSupported
    }
}

public struct SearchArtist: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SearchAlbum: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let artistName: String?

    public init(id: String, name: String, artistName: String? = nil) {
        self.id = id
        self.name = name
        self.artistName = artistName
    }
}

public struct SearchSong: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let artistName: String?
    public let albumName: String?

    public init(id: String, title: String, artistName: String? = nil, albumName: String? = nil) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
    }
}

public struct RemoteMusicFolder: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum DirectoryEntryKind: String, Sendable {
    case artist
    case album
    case song
    case folder
}

public struct DirectoryEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let kind: DirectoryEntryKind
    public let coverArtId: String?
    public let artistName: String?
    public let albumName: String?
    public let duration: TimeInterval?

    public init(
        id: String,
        name: String,
        kind: DirectoryEntryKind,
        coverArtId: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.coverArtId = coverArtId
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
    }

    public func asQueueItem() -> QueueItem? {
        guard kind == .song else { return nil }
        return QueueItem(
            playableId: id,
            kind: .song,
            title: name,
            artistName: artistName,
            albumName: albumName,
            duration: duration ?? 0,
            artworkId: coverArtId
        )
    }
}

extension StreamFormatPreference {
    public var streamFormat: StreamFormat? {
        switch self {
        case .original: nil
        case .mp3: .mp3
        case .aac, .opus, .flac: .raw
        }
    }
}
