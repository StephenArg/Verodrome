import Foundation

public final class AmpacheLibrarySyncer: LibrarySyncer, @unchecked Sendable {
    private let server: AmpacheServerApi
    private let ingestor: LibraryIngesting
    private var isConnected: () -> Bool

    public init(
        server: AmpacheServerApi,
        ingestor: LibraryIngesting,
        isConnected: @escaping @Sendable () -> Bool = { true }
    ) {
        self.server = server
        self.ingestor = ingestor
        self.isConnected = isConnected
    }

    public func syncInitial(progress: @escaping @Sendable (String) -> Void) async throws {
        try await syncCatalog(progress: progress)
        try await syncAllSongs(progress: progress)
        CommonLibrarySyncer.report(progress, "Library sync complete.")
    }

    public func syncCatalog(progress: @escaping @Sendable (String) -> Void) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        try await ingestor.beginSync()

        CommonLibrarySyncer.report(progress, "Fetching genres…")
        let genres = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getGenres(limit: limit, offset: offset)
            return try AmpacheParsers.parseGenres(data: data)
        }
        try await ingestor.ingest(genres: genres)

        CommonLibrarySyncer.report(progress, "Fetching artists…")
        let artists = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getArtists(limit: limit, offset: offset)
            return try AmpacheParsers.parseArtists(data: data)
        }
        try await ingestor.ingest(artists: artists)

        CommonLibrarySyncer.report(progress, "Fetching albums…")
        let albums = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getAlbums(limit: limit, offset: offset)
            return try AmpacheParsers.parseAlbums(data: data)
        }
        try await ingestor.ingest(albums: albums)

        CommonLibrarySyncer.report(progress, "Fetching playlists…")
        let playlists = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getPlaylists(limit: limit, offset: offset)
            return try AmpacheParsers.parsePlaylists(data: data)
        }
        try await ingestor.ingest(playlists: playlists)

        CommonLibrarySyncer.report(progress, "Fetching podcasts…")
        do {
            let podcasts = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
                let data = try await self.server.getPodcasts(limit: limit, offset: offset)
                return try AmpacheParsers.parsePodcasts(data: data)
            }
            try await ingestor.ingest(podcasts: podcasts)
        } catch {
            CommonLibrarySyncer.report(progress, "Podcasts not supported by server (skipped).")
        }

        CommonLibrarySyncer.report(progress, "Fetching radios…")
        do {
            let radios = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
                let data = try await self.server.getRadios(limit: limit, offset: offset)
                return try AmpacheParsers.parseRadios(data: data)
            }
            try await ingestor.ingest(radios: radios)
        } catch {
            CommonLibrarySyncer.report(progress, "Radios not supported by server (skipped).")
        }

        try await ingestor.finishSync()
        CommonLibrarySyncer.report(progress, "Catalog sync complete.")
    }

    public func syncAllSongs(progress: @escaping @Sendable (String) -> Void) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())

        CommonLibrarySyncer.report(progress, "Backfilling songs…")
        let songs = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getSongs(limit: limit, offset: offset)
            return try AmpacheParsers.parseSongs(data: data)
        }
        try await ingestor.ingest(songs: songs)
        CommonLibrarySyncer.report(progress, "Track backfill complete.")
    }

    public func sync(albumId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getAlbum(id: albumId)
        let albums = try AmpacheParsers.parseAlbums(data: data)
        let songs = try AmpacheParsers.parseSongs(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.ingest(songs: songs)
    }

    public func sync(artistId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let albumsData = try await server.getAlbums(artistId: artistId)
        let albums = try AmpacheParsers.parseAlbums(data: albumsData)
        try await ingestor.ingest(albums: albums)

        for album in albums {
            let songsData = try await server.getSongs(albumId: album.id)
            let songs = try AmpacheParsers.parseSongs(data: songsData)
            try await ingestor.ingest(songs: songs)
        }
    }

    public func sync(playlistId: String) async throws {
        try await syncPlaylistDown(id: playlistId)
    }

    public func sync(podcastId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        do {
            let data = try await server.getPodcast(id: podcastId)
            let podcasts = try AmpacheParsers.parsePodcasts(data: data)
            let episodes = try AmpacheParsers.parsePodcastEpisodes(data: data, podcastId: podcastId)
            try await ingestor.ingest(podcasts: podcasts)
            try await ingestor.ingest(episodes: episodes)
        } catch {
            // Server may not implement podcast APIs.
        }
    }

    @discardableResult
    public func syncNewestAlbums(limit: Int) async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getNewestAlbums(limit: max(1, limit), offset: 0)
        let albums = try AmpacheParsers.parseAlbums(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyNewestAlbumRanks(albums.map(\.id))

        var songIds: [String] = []
        for album in albums.prefix(limit) {
            let songsData = try await server.getSongs(albumId: album.id)
            let songs = try AmpacheParsers.parseSongs(data: songsData)
            try await ingestor.ingest(songs: songs)
            songIds.append(contentsOf: songs.map(\.id))
        }
        return songIds
    }

    @discardableResult
    public func syncRecentAlbums(limit: Int) async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getRecentAlbums(limit: max(1, limit), offset: 0)
        let albums = try AmpacheParsers.parseAlbums(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyRecentAlbumRanks(albums.map(\.id))
        return albums.map(\.id)
    }

    public func syncFavoriteAlbums() async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getFlaggedAlbums(limit: 200, offset: 0)
        let albums = try AmpacheParsers.parseAlbums(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyFavoriteAlbums(albums.map(\.id))
    }

    public func searchArtists(query: String) async throws -> [SearchArtist] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.advancedSearch(query: query, objectType: "artist")
        return try AmpacheParsers.parseSearchArtists(data: data)
    }

    public func searchAlbums(query: String) async throws -> [SearchAlbum] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.advancedSearch(query: query, objectType: "album")
        return try AmpacheParsers.parseSearchAlbums(data: data)
    }

    public func searchSongs(query: String) async throws -> [SearchSong] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.advancedSearch(query: query, objectType: "song")
        return try AmpacheParsers.parseSearchSongs(data: data)
    }

    public func setFavorite(playableId: String, isFavorite: Bool) async throws {
        try await server.setFlag(objectId: playableId, objectType: "song", flagged: isFavorite)
    }

    public func setRating(playableId: String, rating: Int) async throws {
        try await server.setRating(objectId: playableId, rating: rating)
    }

    public func scrobble(playableId: String, timestamp: Date, duration: TimeInterval?) async throws {
        try await server.scrobble(songId: playableId, timestamp: timestamp, duration: duration)
    }

    public func reportNowPlaying(playableId: String, position: TimeInterval) async throws {
        // Ampache has no dedicated now-playing endpoint; scrobble-on-play is handled separately.
        _ = (playableId, position)
    }

    public func createPlaylist(name: String) async throws -> String {
        let data = try await server.createPlaylist(name: name)
        return try AmpacheParsers.parseCreatedPlaylistId(data: data)
    }

    public func renamePlaylist(id: String, name: String) async throws {
        try await server.renamePlaylist(id: id, name: name)
    }

    public func addToPlaylist(playlistId: String, songIds: [String]) async throws {
        for songId in songIds {
            try await server.playlistAdd(playlistId: playlistId, songId: songId)
        }
    }

    public func removeFromPlaylist(playlistId: String, entryIndices: [Int]) async throws {
        let data = try await server.getPlaylist(id: playlistId)
        let playlists = try AmpacheParsers.parsePlaylists(data: data)
        guard let playlist = playlists.first else { return }

        for index in entryIndices.sorted(by: >) {
            guard playlist.songIds.indices.contains(index) else { continue }
            let songId = playlist.songIds[index]
            try await server.playlistRemove(playlistId: playlistId, songId: songId)
        }
    }

    public func reorderPlaylist(playlistId: String, songIds: [String]) async throws {
        let data = try await server.getPlaylist(id: playlistId)
        let playlists = try AmpacheParsers.parsePlaylists(data: data)
        guard let playlist = playlists.first else { return }

        for songId in playlist.songIds {
            try await server.playlistRemove(playlistId: playlistId, songId: songId)
        }
        try await addToPlaylist(playlistId: playlistId, songIds: songIds)
    }

    public func syncPlaylistDown(id: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getPlaylist(id: id)
        let songs = try AmpacheParsers.parsePlaylistSongs(data: data)
        if !songs.isEmpty {
            try await ingestor.ingest(songs: songs)
        }
        let playlists = try AmpacheParsers.parsePlaylists(data: data)
        try await ingestor.ingest(playlists: playlists)
    }

    public func syncPodcasts() async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        do {
            let podcasts = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
                let data = try await self.server.getPodcasts(limit: limit, offset: offset)
                return try AmpacheParsers.parsePodcasts(data: data)
            }
            try await ingestor.ingest(podcasts: podcasts)

            for podcast in podcasts {
                let data = try await server.getPodcast(id: podcast.id)
                let episodes = try AmpacheParsers.parsePodcastEpisodes(data: data, podcastId: podcast.id)
                try await ingestor.ingest(episodes: episodes)
            }
        } catch {
            // Server may not implement podcast APIs.
        }
    }

    @discardableResult
    public func syncPlaylistCatalog() async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let playlists = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getPlaylists(limit: limit, offset: offset)
            return try AmpacheParsers.parsePlaylists(data: data)
        }
        try await ingestor.ingest(playlists: playlists)
        return playlists.map(\.id)
    }

    public func listMusicFolders() async throws -> [RemoteMusicFolder] {
        throw BackendApiError.unsupportedOperation("Ampache does not expose music folders")
    }

    public func listMusicDirectory(folderId: String?) async throws -> [DirectoryEntry] {
        throw BackendApiError.unsupportedOperation("Ampache does not expose music directories")
    }
}

extension AmpacheLibrarySyncer: LyricsProviding {
    public func fetchLyrics(playableId: String) async throws -> String? {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getSong(id: playableId)
        return try AmpacheParsers.parseSongLyrics(data: data)
    }
}
