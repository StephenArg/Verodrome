import Foundation

public final class SubsonicLibrarySyncer: LibrarySyncer, @unchecked Sendable {
    private let server: SubsonicServerApi
    private let ingestor: LibraryIngesting
    private let native: NavidromeNativeApi?
    private var isConnected: () -> Bool

    public init(
        server: SubsonicServerApi,
        ingestor: LibraryIngesting,
        native: NavidromeNativeApi? = nil,
        isConnected: @escaping @Sendable () -> Bool = { true }
    ) {
        self.server = server
        self.ingestor = ingestor
        self.native = native
        self.isConnected = isConnected
    }

    public func syncInitial(progress: @escaping LibrarySyncProgressHandler) async throws {
        try await syncCatalog(progress: progress)
        try await syncAllSongs(progress: progress)
        CommonLibrarySyncer.report(progress, "Library sync complete.", fraction: 1)
    }

    public func syncCatalog(progress: @escaping LibrarySyncProgressHandler) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        try await ingestor.beginSync()

        CommonLibrarySyncer.report(progress, "Fetching genres…", stage: .genres)
        do {
            let genresData = try await server.getGenres()
            let genres = try SubsonicParsers.parseGenres(data: genresData)
            try await ingestor.ingest(genres: genres)
        } catch {
            CommonLibrarySyncer.report(progress, "Genres not supported by server (skipped).")
        }

        CommonLibrarySyncer.report(progress, "Fetching artists…", stage: .artists)
        let artistsData = try await server.getArtists()
        let artists = try SubsonicParsers.parseArtists(data: artistsData)
        try await ingestor.ingest(artists: artists)

        CommonLibrarySyncer.report(progress, "Fetching albums…", stage: .albums)
        let albums = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getAlbumList(size: limit, offset: offset)
            return try SubsonicParsers.parseAlbumList(data: data)
        }
        try await ingestor.ingest(albums: albums)

        CommonLibrarySyncer.report(progress, "Fetching playlists…", stage: .playlists)
        let playlistsData = try await server.getPlaylists()
        let playlists = try SubsonicParsers.parsePlaylists(data: playlistsData)
        try await ingestor.ingest(playlists: playlists)

        // Navidrome (and some other servers) return HTTP 501 for podcast endpoints.
        CommonLibrarySyncer.report(progress, "Fetching podcasts…", stage: .podcasts)
        do {
            let podcastsData = try await server.getPodcasts()
            let podcasts = try SubsonicParsers.parsePodcasts(data: podcastsData)
            try await ingestor.ingest(podcasts: podcasts)
        } catch {
            CommonLibrarySyncer.report(progress, "Podcasts not supported by server (skipped).")
        }

        CommonLibrarySyncer.report(progress, "Fetching radios…", stage: .radios)
        do {
            let radiosData = try await server.getInternetRadioStations()
            let radios = try SubsonicParsers.parseRadios(data: radiosData)
            try await ingestor.ingest(radios: radios)
        } catch {
            CommonLibrarySyncer.report(progress, "Radios not supported by server (skipped).")
        }

        try await ingestor.finishSync()
        CommonLibrarySyncer.report(progress, "Catalog sync complete.", fraction: LibrarySyncPhase.catalog.overall(1))
    }

    public func syncAllSongs(progress: @escaping LibrarySyncProgressHandler) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())

        if let native {
            do {
                try await syncAllSongsInBulk(native, progress: progress)
                return
            } catch {
                // The native API is undocumented and can change under us, so anything
                // unexpected drops to the album crawl rather than failing the sync.
                await EventLogger.shared.warning(
                    "sync",
                    "Navidrome bulk song sync failed, falling back to album crawl: \(error.localizedDescription)"
                )
            }
        }

        try await syncAllSongsByAlbum(progress: progress)
    }

    /// Pages Navidrome's native `/api/song`, which returns whole song rows in bulk.
    private func syncAllSongsInBulk(
        _ native: NavidromeNativeApi,
        progress: @escaping LibrarySyncProgressHandler
    ) async throws {
        CommonLibrarySyncer.report(progress, "Fetching tracks…", tracksCompleted: 0, of: nil)
        try await native.authenticate()

        let pageSize = CommonLibrarySyncer.defaultPageSize
        var ingested = 0
        var total: Int?

        while true {
            let page = try await native.songs(offset: ingested, limit: pageSize)
            if page.songs.isEmpty { break }

            try await ingestor.ingest(songs: page.songs)
            ingested += page.songs.count
            total = page.total ?? total

            let counted = total.map { "\(ingested) of \($0) songs" } ?? "\(ingested) songs"
            CommonLibrarySyncer.report(
                progress,
                "Fetching tracks… \(counted)",
                tracksCompleted: ingested,
                of: total
            )

            if let total, ingested >= total { break }
            if page.songs.count < pageSize { break }
        }

        CommonLibrarySyncer.report(progress, "Track sync complete.", fraction: 1)
    }

    private func syncAllSongsByAlbum(progress: @escaping LibrarySyncProgressHandler) async throws {
        CommonLibrarySyncer.report(progress, "Backfilling album tracks…", tracksCompleted: 0, of: nil)
        let albums = try await CommonLibrarySyncer.fetchAllPages { offset, limit in
            let data = try await self.server.getAlbumList(size: limit, offset: offset)
            return try SubsonicParsers.parseAlbumList(data: data)
        }

        var completed = 0
        for album in albums {
            let detail = try await server.getAlbum(id: album.id)
            let parsed = try SubsonicParsers.parseAlbumDetail(data: detail)
            try await ingestor.ingest(songs: parsed.songs)
            completed += 1
            // One report per album would republish faster than the UI can use; every
            // fifth still moves the number often enough to read as progress.
            if completed == 1 || completed % 5 == 0 || completed == albums.count {
                CommonLibrarySyncer.report(
                    progress,
                    "Backfilling tracks… \(completed) of \(albums.count) albums",
                    tracksCompleted: completed,
                    of: albums.count
                )
            }
        }

        CommonLibrarySyncer.report(progress, "Track backfill complete.", fraction: 1)
    }

    public func sync(albumId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getAlbum(id: albumId)
        let parsed = try SubsonicParsers.parseAlbumDetail(data: data)
        try await ingestor.ingest(albums: parsed.albums)
        try await ingestor.ingest(songs: parsed.songs)
    }

    public func sync(artistId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getArtist(id: artistId)
        let artists = try SubsonicParsers.parseArtists(data: data)
        try await ingestor.ingest(artists: artists)

        let albums = try SubsonicParsers.parseAlbumList(data: data)
        try await ingestor.ingest(albums: albums)

        for album in albums {
            try await sync(albumId: album.id)
        }
    }

    public func sync(playlistId: String) async throws {
        try await syncPlaylistDown(id: playlistId)
    }

    public func sync(podcastId: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        do {
            let data = try await server.getPodcastEpisodes(id: podcastId)
            let episodes = try SubsonicParsers.parsePodcastEpisodes(data: data, podcastId: podcastId)
            try await ingestor.ingest(episodes: episodes)
        } catch {
            // Server may not implement podcast episode APIs (e.g. Navidrome → HTTP 501).
        }
    }

    @discardableResult
    public func syncNewestAlbums(limit: Int) async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getAlbumList(type: "newest", size: max(1, limit), offset: 0)
        let albums = try SubsonicParsers.parseAlbumList(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyNewestAlbumRanks(albums.map(\.id))

        var songIds: [String] = []
        for album in albums.prefix(limit) {
            let detail = try await server.getAlbum(id: album.id)
            let parsed = try SubsonicParsers.parseAlbumDetail(data: detail)
            try await ingestor.ingest(songs: parsed.songs)
            songIds.append(contentsOf: parsed.songs.map(\.id))
        }
        return songIds
    }

    @discardableResult
    public func syncRecentAlbums(limit: Int) async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getAlbumList(type: "recent", size: max(1, limit), offset: 0)
        let albums = try SubsonicParsers.parseAlbumList(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyRecentAlbumRanks(albums.map(\.id))
        return albums.map(\.id)
    }

    public func syncFavoriteAlbums() async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getStarred2()
        let albums = try SubsonicParsers.parseStarredAlbums(data: data)
        try await ingestor.ingest(albums: albums)
        try await ingestor.applyFavoriteAlbums(albums.map(\.id))
    }

    public func searchArtists(query: String) async throws -> [SearchArtist] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.search3(query: query)
        return try SubsonicParsers.parseSearch(data: data).artists
    }

    public func searchAlbums(query: String) async throws -> [SearchAlbum] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.search3(query: query)
        return try SubsonicParsers.parseSearch(data: data).albums
    }

    public func searchSongs(query: String) async throws -> [SearchSong] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.search3(query: query)
        return try SubsonicParsers.parseSearch(data: data).songs
    }

    public func setFavorite(playableId: String, isFavorite: Bool) async throws {
        try await server.star(id: playableId, unstar: !isFavorite)
    }

    public func setRating(playableId: String, rating: Int) async throws {
        try await server.setRating(id: playableId, rating: rating)
    }

    public func scrobble(playableId: String, timestamp: Date, duration: TimeInterval?) async throws {
        _ = duration
        try await server.scrobble(id: playableId, time: timestamp)
    }

    public func reportNowPlaying(playableId: String, position: TimeInterval) async throws {
        _ = position
        // Subsonic reports now-playing via scrobble with submission=false.
        try await server.scrobble(id: playableId, time: Date(), submission: false)
    }

    public func createPlaylist(name: String) async throws -> String {
        let data = try await server.createPlaylist(name: name)
        return try SubsonicParsers.parseCreatedPlaylistId(data: data)
    }

    public func renamePlaylist(id: String, name: String) async throws {
        try await server.updatePlaylist(id: id, name: name)
    }

    public func addToPlaylist(playlistId: String, songIds: [String]) async throws {
        try await server.updatePlaylist(id: playlistId, songIdsToAdd: songIds)
    }

    public func removeFromPlaylist(playlistId: String, entryIndices: [Int]) async throws {
        try await server.updatePlaylist(id: playlistId, songIndexesToRemove: entryIndices)
    }

    public func reorderPlaylist(playlistId: String, songIds: [String]) async throws {
        let data = try await server.getPlaylist(id: playlistId)
        let playlists = try SubsonicParsers.parsePlaylistDetail(data: data)
        guard let playlist = playlists.first else { return }

        let removeIndexes = Array(playlist.songIds.indices)
        try await server.updatePlaylist(id: playlistId, songIndexesToRemove: removeIndexes)
        try await server.updatePlaylist(id: playlistId, songIdsToAdd: songIds)
    }

    public func syncPlaylistDown(id: String) async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getPlaylist(id: id)
        // Refresh song metadata/coverArt from playlist entries before linking items.
        let songs = try SubsonicParsers.parsePlaylistSongs(data: data)
        if !songs.isEmpty {
            try await ingestor.ingest(songs: songs)
        }
        let playlists = try SubsonicParsers.parsePlaylistDetail(data: data)
        try await ingestor.ingest(playlists: playlists)
    }

    public func syncPodcasts() async throws {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        do {
            let data = try await server.getPodcasts()
            let podcasts = try SubsonicParsers.parsePodcasts(data: data)
            try await ingestor.ingest(podcasts: podcasts)

            for podcast in podcasts {
                let episodesData = try await server.getPodcastEpisodes(id: podcast.id)
                let episodes = try SubsonicParsers.parsePodcastEpisodes(data: episodesData, podcastId: podcast.id)
                try await ingestor.ingest(episodes: episodes)
            }
        } catch {
            // Navidrome and some other Subsonic servers return HTTP 501 for podcasts.
        }
    }

    @discardableResult
    public func syncPlaylistCatalog() async throws -> [String] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let playlistsData = try await server.getPlaylists()
        let playlists = try SubsonicParsers.parsePlaylists(data: playlistsData)
        try await ingestor.ingest(playlists: playlists)
        return playlists.map(\.id)
    }

    public func listMusicFolders() async throws -> [RemoteMusicFolder] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        let data = try await server.getMusicFolders()
        return try SubsonicParsers.parseMusicFolders(data: data)
    }

    public func listMusicDirectory(folderId: String?) async throws -> [DirectoryEntry] {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())
        guard let folderId else {
            let folders = try await listMusicFolders()
            return folders.map { DirectoryEntry(id: $0.id, name: $0.name, kind: .folder) }
        }
        let data = try await server.getMusicDirectory(id: folderId)
        return try SubsonicParsers.parseMusicDirectory(data: data)
    }
}

extension SubsonicLibrarySyncer: LyricsProviding {
    public func fetchLyrics(playableId: String) async throws -> String? {
        try CommonLibrarySyncer.requireNetwork(isConnected: isConnected())

        if let data = try? await server.getLyricsBySongId(id: playableId),
           let text = try? SubsonicParsers.parseLyrics(data: data) {
            return text
        }

        var artist: String?
        var title: String?
        if let songData = try? await server.getSong(id: playableId),
           let song = try? SubsonicParsers.parseSong(data: songData) {
            artist = song.artistName
            title = song.title
        }

        guard let artist, let title, !artist.isEmpty, !title.isEmpty else { return nil }
        let data = try await server.getLyrics(artist: artist, title: title)
        return try SubsonicParsers.parseLyrics(data: data)
    }
}
