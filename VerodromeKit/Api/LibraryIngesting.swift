import Foundation

// MARK: - Ingest DTOs

public struct IngestGenre: Sendable, Hashable {
    public let id: String
    public let name: String
    public let albumCount: Int?
    public let songCount: Int?

    public init(id: String, name: String, albumCount: Int? = nil, songCount: Int? = nil) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
    }
}

public struct IngestArtist: Sendable, Hashable {
    public let id: String
    public let name: String
    public let albumCount: Int?
    public let songCount: Int?
    public let artId: String?

    public init(
        id: String,
        name: String,
        albumCount: Int? = nil,
        songCount: Int? = nil,
        artId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
        self.artId = artId
    }
}

public struct IngestAlbum: Sendable, Hashable {
    public let id: String
    public let name: String
    public let artistId: String?
    public let artistName: String?
    public let year: Int?
    public let songCount: Int?
    public let artId: String?
    public let genreIds: [String]
    /// Subsonic-style genre name when no genre id is provided.
    public let genreName: String?

    public init(
        id: String,
        name: String,
        artistId: String? = nil,
        artistName: String? = nil,
        year: Int? = nil,
        songCount: Int? = nil,
        artId: String? = nil,
        genreIds: [String] = [],
        genreName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artistId = artistId
        self.artistName = artistName
        self.year = year
        self.songCount = songCount
        self.artId = artId
        self.genreIds = genreIds
        self.genreName = genreName
    }
}

public struct IngestSong: Sendable, Hashable {
    public let id: String
    public let title: String
    public let albumId: String?
    public let albumName: String?
    public let artistId: String?
    public let artistName: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let duration: TimeInterval?
    public let artId: String?
    public let bitrate: Int?
    public let format: String?

    public init(
        id: String,
        title: String,
        albumId: String? = nil,
        albumName: String? = nil,
        artistId: String? = nil,
        artistName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artId: String? = nil,
        bitrate: Int? = nil,
        format: String? = nil
    ) {
        self.id = id
        self.title = title
        self.albumId = albumId
        self.albumName = albumName
        self.artistId = artistId
        self.artistName = artistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artId = artId
        self.bitrate = bitrate
        self.format = format
    }
}

public struct IngestPlaylist: Sendable, Hashable {
    public let id: String
    public let name: String
    public let songCount: Int?
    public let owner: String?
    public let isPublic: Bool
    public let songIds: [String]
    /// Subsonic `coverArt` id or Ampache `art` URL/token.
    public let artId: String?

    public init(
        id: String,
        name: String,
        songCount: Int? = nil,
        owner: String? = nil,
        isPublic: Bool = false,
        songIds: [String] = [],
        artId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.owner = owner
        self.isPublic = isPublic
        self.songIds = songIds
        self.artId = artId
    }
}

public struct IngestPodcast: Sendable, Hashable {
    public let id: String
    public let title: String
    public let description: String?
    public let artId: String?

    public init(id: String, title: String, description: String? = nil, artId: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.artId = artId
    }
}

public struct IngestPodcastEpisode: Sendable, Hashable {
    public let id: String
    public let podcastId: String
    public let title: String
    public let publishDate: Date?
    public let duration: TimeInterval?
    public let artId: String?

    public init(
        id: String,
        podcastId: String,
        title: String,
        publishDate: Date? = nil,
        duration: TimeInterval? = nil,
        artId: String? = nil
    ) {
        self.id = id
        self.podcastId = podcastId
        self.title = title
        self.publishDate = publishDate
        self.duration = duration
        self.artId = artId
    }
}

public struct IngestRadio: Sendable, Hashable {
    public let id: String
    public let name: String
    public let streamURL: String?
    public let homepageURL: String?
    public let artId: String?

    public init(
        id: String,
        name: String,
        streamURL: String? = nil,
        homepageURL: String? = nil,
        artId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homepageURL = homepageURL
        self.artId = artId
    }
}

// MARK: - Ingestor protocol

/// Decouples library sync from persistence (SwiftData, Core Data, etc.).
public protocol LibraryIngesting: AnyObject, Sendable {
    func beginSync() async throws
    func finishSync() async throws

    func ingest(genres: [IngestGenre]) async throws
    func ingest(artists: [IngestArtist]) async throws
    func ingest(albums: [IngestAlbum]) async throws
    func ingest(songs: [IngestSong]) async throws
    func ingest(playlists: [IngestPlaylist]) async throws
    func ingest(podcasts: [IngestPodcast]) async throws
    func ingest(episodes: [IngestPodcastEpisode]) async throws
    func ingest(radios: [IngestRadio]) async throws

    /// Clears previous newest ranks, then assigns 1-based ranks from ordered remote album ids.
    func applyNewestAlbumRanks(_ orderedRemoteIds: [String]) async throws
    /// Clears previous recent ranks, then assigns 1-based ranks from ordered remote album ids.
    func applyRecentAlbumRanks(_ orderedRemoteIds: [String]) async throws
    /// Marks albums (and optionally songs) as favorites; clears favorite flag on albums not listed.
    func applyFavoriteAlbums(_ remoteIds: [String]) async throws
}
