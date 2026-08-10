import Foundation
import SwiftData

/// Writes server library data into SwiftData on its own background context.
///
/// This is a `ModelActor` on purpose: ingest work is heavy (a `beginBatch` alone fetches
/// every entity in the library into lookup dictionaries), and when it ran on the main
/// actor every "background" sync blocked the UI in multi-second stretches — the app's
/// long-standing scroll lag. All reads and writes here happen on this actor's serial
/// executor against a dedicated `ModelContext`; the main context sees the results once
/// each batch saves.
public actor SwiftDataLibraryIngester: LibraryIngesting, ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    private let accountInfo: AccountInfo
    private let apiType: ApiType
    private let onProgress: (@Sendable (String) -> Void)?

    /// When true (set by `beginSync`), finishSync prunes albums/playlists not seen during this sync.
    private var isFullSync = false
    private var seenAlbumIds = Set<String>()
    private var seenPlaylistIds = Set<String>()

    /// Repository and account resolved lazily on the actor: the init runs on the caller's
    /// executor, so no context work is allowed there.
    private var session: (repository: LibraryRepository, account: Account)?

    public init(
        modelContainer: ModelContainer,
        accountInfo: AccountInfo,
        apiType: ApiType,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.accountInfo = accountInfo
        self.apiType = apiType
        self.onProgress = onProgress
    }

    private func makeSession() throws -> (repository: LibraryRepository, account: Account) {
        if let session { return session }
        let repository = LibraryRepository(context: modelContext)
        let account = try repository.getOrCreateAccount(info: accountInfo, apiType: apiType)
        let made = (repository, account)
        session = made
        return made
    }

    public func beginSync() async throws {
        let (repository, _) = try makeSession()
        isFullSync = true
        seenAlbumIds.removeAll()
        seenPlaylistIds.removeAll()
        try repository.beginBatch()
    }

    public func finishSync() async throws {
        let (repository, account) = try makeSession()
        if isFullSync {
            let context = repository.context
            let prunedAlbums = try LibraryPruner.pruneAlbums(
                account: account,
                keepingRemoteIds: seenAlbumIds,
                context: context
            )
            let prunedPlaylists = try LibraryPruner.prunePlaylists(
                account: account,
                keepingRemoteIds: seenPlaylistIds,
                context: context
            )
            if prunedAlbums + prunedPlaylists > 0 {
                onProgress?("Pruned \(prunedAlbums) albums, \(prunedPlaylists) playlists")
            }
        }
        try backfillArtistCounts(repository: repository, account: account)
        try backfillGenreCounts(repository: repository, account: account)
        try backfillGenreArtwork(repository: repository, account: account)
        isFullSync = false
        try repository.endBatch()
    }

    public func ingest(genres: [IngestGenre]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        for item in genres {
            _ = try repository.getOrCreateGenre(
                remoteId: item.id,
                name: item.name,
                account: account,
                albumCount: item.albumCount,
                songCount: item.songCount
            )
        }
        onProgress?("Genres: \(genres.count)")
    }

    public func ingest(artists: [IngestArtist]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        var processed = 0
        for item in artists {
            let artist = try repository.getOrCreateArtist(remoteId: item.id, name: item.name, account: account)
            if let albumCount = item.albumCount { artist.albumCount = albumCount }
            if let songCount = item.songCount { artist.songCount = songCount }
            if let artId = item.artId { artist.artworkToken = artId }
            processed += 1
            if processed % 200 == 0 {
                await Task.yield()
            }
        }
        onProgress?("Artists: \(artists.count)")
    }

    public func ingest(albums: [IngestAlbum]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        var processed = 0
        for item in albums {
            seenAlbumIds.insert(item.id)
            var artist: Artist?
            if let artistId = item.artistId {
                artist = try repository.getOrCreateArtist(remoteId: artistId, name: item.artistName ?? "Unknown", account: account)
            }
            let album = try repository.getOrCreateAlbum(
                remoteId: item.id,
                title: item.name,
                account: account,
                artist: artist,
                year: item.year
            )
            if let songCount = item.songCount { album.trackCount = songCount }
            if let rating = item.rating { album.rating = rating }
            if let artId = item.artId {
                applyAlbumArtwork(artId, to: album)
            }
            if let artistName = item.artistName, !artistName.isEmpty {
                album.artistName = artistName
            }
            if let genreId = item.genreIds.first {
                let existingName = (try? repository.fetchGenres(account: account)
                    .first(where: { $0.remoteId == genreId })?.name) ?? genreId
                let genre = try repository.getOrCreateGenre(remoteId: genreId, name: existingName, account: account)
                album.genreName = genre.name
                assignGenreArtwork(genre, from: item.artId)
            } else if let genreName = item.genreName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !genreName.isEmpty {
                let genre = try repository.getOrCreateGenre(remoteId: genreName, name: genreName, account: account)
                album.genreName = genre.name
                assignGenreArtwork(genre, from: item.artId)
            }
            processed += 1
            if processed % 200 == 0 {
                await Task.yield()
            }
        }
        onProgress?("Albums: \(albums.count)")
    }

    public func ingest(songs: [IngestSong]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        var processed = 0
        for item in songs {
            var album: Album?
            var artist: Artist?
            if let artistId = item.artistId {
                artist = try repository.getOrCreateArtist(remoteId: artistId, name: item.artistName ?? "Unknown", account: account)
            }
            if let albumId = item.albumId {
                seenAlbumIds.insert(albumId)
                album = try repository.getOrCreateAlbum(
                    remoteId: albumId,
                    title: item.albumName ?? "Unknown",
                    account: account,
                    artist: artist,
                    year: nil
                )
                if let artId = item.artId, let album,
                   album.artworkToken == nil || album.artworkToken?.isEmpty == true {
                    applyAlbumArtwork(artId, to: album)
                }
                if let albumName = item.albumName, !albumName.isEmpty {
                    album?.artistName = item.artistName
                }
            }
            let song = try repository.getOrCreateSong(
                remoteId: item.id,
                title: item.title,
                account: account,
                album: album,
                artist: artist,
                track: item.trackNumber
            )
            if let duration = item.duration { song.playDuration = duration }
            // Only when the response carried a value: a parser that doesn't supply one
            // must not reset plays counted locally or a rating set from this device.
            if let playCount = item.playCount { song.playCount = playCount }
            if let rating = item.rating { song.rating = rating }
            if let isFavorite = item.isFavorite { song.isFavorite = isFavorite }
            if let bitrate = item.bitrate { song.bitrate = bitrate }
            song.contentType = item.format
            song.artistName = item.artistName
            song.albumTitle = item.albumName
            // Prefer the album's cover so every track on a record shares one artwork
            // identity. Servers such as Navidrome hand each song its own `coverArt` id
            // that serves the same picture, which made the player treat an in-album skip
            // as new art and reload it.
            if let albumArt = album?.artworkToken, !albumArt.isEmpty {
                song.artworkToken = albumArt
            } else if let artId = item.artId, !artId.isEmpty {
                song.artworkToken = artId
                // Song arrived with art before the album did — lift it so later tracks
                // (and list fallbacks) share one identity.
                if let album, album.artworkToken == nil || album.artworkToken?.isEmpty == true {
                    applyAlbumArtwork(artId, to: album)
                }
            }
            if let disc = item.discNumber { song.disc = disc }
            // Inherit album genre so genre detail can find tracks by genreName.
            if (song.genreName == nil || song.genreName?.isEmpty == true),
               let genreName = album?.genreName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !genreName.isEmpty {
                song.genreName = genreName
            }

            processed += 1
            if processed % 200 == 0 {
                await Task.yield()
            }
        }
        onProgress?("Songs: \(songs.count)")
    }

    public func ingest(playlists: [IngestPlaylist]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        for item in playlists {
            seenPlaylistIds.insert(item.id)
            let playlist = try repository.getOrCreatePlaylist(remoteId: item.id, name: item.name, account: account)
            if let artId = item.artId, !artId.isEmpty {
                playlist.artworkToken = artId
            }
            // A smart playlist stays smart even if a later response omits the marker.
            if item.isSmart { playlist.isSmart = true }
            // Taken only from what the server states, and re-derived on every sync so a
            // wrong answer can't outlive the response that caused it. Comparing `owner`
            // against the account name was tried and is not safe: the server reports its
            // own canonical spelling, and guessing wrong hides playlists that are fine to
            // edit. `readonly` already covers other people's playlists on servers that
            // report it, and a refused edit covers the ones that don't.
            playlist.isEditable = !(playlist.isSmart || item.isReadOnly)
            if !item.songIds.isEmpty {
                let songs = item.songIds.compactMap { try? repository.resolveSong(remoteId: $0, account: account) }
                try repository.replacePlaylistItems(playlist, with: songs)
                if playlist.artworkToken == nil || playlist.artworkToken?.isEmpty == true {
                    playlist.artworkToken = songs
                        .compactMap { $0.artworkToken ?? $0.album?.artworkToken }
                        .first
                }
            } else if let songCount = item.songCount, playlist.items.isEmpty {
                // Catalog responses have no entries. When we already hold a detailed track
                // list locally (after add/remove), that count is fresher than getPlaylists.
                playlist.songCount = songCount
            }
        }
        onProgress?("Playlists: \(playlists.count)")
    }

    public func ingest(podcasts: [IngestPodcast]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        for item in podcasts {
            let podcast = try repository.getOrCreatePodcast(remoteId: item.id, title: item.title, account: account)
            if let artId = item.artId { podcast.artworkToken = artId }
            if let description = item.description { podcast.descriptionText = description }
        }
        onProgress?("Podcasts: \(podcasts.count)")
    }

    public func ingest(episodes: [IngestPodcastEpisode]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        for item in episodes {
            let podcast = try repository.getOrCreatePodcast(remoteId: item.podcastId, title: "Podcast", account: account)
            let episode = try repository.getOrCreatePodcastEpisode(
                remoteId: item.id,
                title: item.title,
                account: account,
                podcast: podcast
            )
            if let duration = item.duration { episode.playDuration = duration }
            if let artId = item.artId, podcast.artworkToken == nil || podcast.artworkToken?.isEmpty == true {
                podcast.artworkToken = artId
            }
        }
    }

    public func ingest(radios: [IngestRadio]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        for item in radios {
            let radio = try repository.getOrCreateRadio(
                remoteId: item.id,
                name: item.name,
                account: account,
                streamURL: item.streamURL
            )
            radio.homepageURL = item.homepageURL
            if let artId = item.artId { radio.artworkToken = artId }
        }
        onProgress?("Radios: \(radios.count)")
    }

    public func applyNewestAlbumRanks(_ orderedRemoteIds: [String]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        // Only touch previously ranked + newly ranked rows (not the entire library).
        let previouslyRanked = try repository.fetchAlbums(newestIndexPositive: true)
        for album in previouslyRanked {
            album.newestIndex = 0
        }
        for (offset, remoteId) in orderedRemoteIds.enumerated() {
            if let album = try repository.resolveAlbum(remoteId: remoteId, account: account) {
                album.newestIndex = offset + 1
            }
        }
    }

    public func applyRecentAlbumRanks(_ orderedRemoteIds: [String]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        let previouslyRanked = try repository.fetchAlbums(recentIndexPositive: true)
        for album in previouslyRanked {
            album.recentIndex = 0
        }
        for (offset, remoteId) in orderedRemoteIds.enumerated() {
            if let album = try repository.resolveAlbum(remoteId: remoteId, account: account) {
                album.recentIndex = offset + 1
            }
        }
    }

    public func applyFavoriteAlbums(_ remoteIds: [String]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        let favored = Set(remoteIds)
        let currentlyFavorite = try repository.fetchAlbums(favoritesOnly: true)
        for album in currentlyFavorite where !favored.contains(album.remoteId) {
            album.isFavorite = false
        }
        for remoteId in remoteIds {
            if let album = try repository.resolveAlbum(remoteId: remoteId, account: account) {
                album.isFavorite = true
            }
        }
    }

    public func applyFavoriteSongs(_ remoteIds: [String]) async throws {
        let (repository, account) = try makeSession()
        try repository.beginBatch()
        defer { try? repository.endBatch() }
        let favored = Set(remoteIds)
        // Account-scoped: another library's likes must not clear this one's.
        let currentlyFavorite = try repository.fetchSongs(account: account, favoritesOnly: true)
        for song in currentlyFavorite where !favored.contains(song.remoteId) {
            song.isFavorite = false
        }
        for remoteId in remoteIds {
            if let song = try repository.resolveSong(remoteId: remoteId, account: account) {
                song.isFavorite = true
            }
        }
    }

    private func assignGenreArtwork(_ genre: Genre, from artId: String?) {
        guard genre.artworkToken == nil || genre.artworkToken?.isEmpty == true,
              let artId, !artId.isEmpty else { return }
        genre.artworkToken = artId
    }

    /// Writes the album cover and mirrors it onto tracks that still need one — or that
    /// still hold a previous token (Ampache signed URLs rotate; leaving the old URL on
    /// songs leaves their rows blank after expiry).
    private func applyAlbumArtwork(_ artId: String, to album: Album) {
        guard !artId.isEmpty else { return }
        let previous = album.artworkToken
        guard previous != artId else {
            // Same token, but songs ingested earlier may still be empty.
            for song in album.songs where song.artworkToken == nil || song.artworkToken?.isEmpty == true {
                song.artworkToken = artId
            }
            return
        }
        album.artworkToken = artId
        for song in album.songs {
            if song.artworkToken == nil || song.artworkToken?.isEmpty == true || song.artworkToken == previous {
                song.artworkToken = artId
            }
        }
    }

    /// Subsonic `getArtists` has no songCount; Ampache sometimes omits it too.
    /// Recompute from local albums so list rows stay accurate after catalog sync.
    private func backfillArtistCounts(repository: LibraryRepository, account: Account) throws {
        let artists = try repository.fetchArtists(account: account)
        guard !artists.isEmpty else { return }

        let albums = try repository.context.fetch(FetchDescriptor<Album>())
        var albumCounts: [String: Int] = [:]
        var songCounts: [String: Int] = [:]
        for album in albums {
            guard let artistKey = album.artist?.compoundRemoteId else { continue }
            albumCounts[artistKey, default: 0] += 1
            let tracks = album.trackCount > 0 ? album.trackCount : album.songs.count
            songCounts[artistKey, default: 0] += tracks
        }

        for artist in artists {
            let key = artist.compoundRemoteId
            // Prefer local album linkage when present; keep server values otherwise.
            if let albums = albumCounts[key], albums > 0 {
                artist.albumCount = albums
            }
            if let songs = songCounts[key], songs > 0 {
                artist.songCount = songs
            }
        }
    }

    /// Derive album/song counts from locally tagged albums when the server omit-
    /// ted them (or genres were created only as album-tag stubs).
    private func backfillGenreCounts(repository: LibraryRepository, account: Account) throws {
        let genres = try repository.fetchGenres(account: account)
        guard !genres.isEmpty else { return }

        let albums = try repository.context.fetch(FetchDescriptor<Album>())
        var albumCounts: [String: Int] = [:]
        var songCounts: [String: Int] = [:]
        for album in albums {
            guard let name = album.genreName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            albumCounts[name, default: 0] += 1
            let tracks = album.trackCount > 0 ? album.trackCount : album.songs.count
            songCounts[name, default: 0] += tracks
        }

        for genre in genres {
            if let albums = albumCounts[genre.name] {
                genre.albumCount = albums
            }
            if let songs = songCounts[genre.name] {
                genre.songCount = songs
            }
        }
    }

    /// Fill missing genre art from any album already tagged with that genre name.
    private func backfillGenreArtwork(repository: LibraryRepository, account: Account) throws {
        let genres = try repository.fetchGenres(account: account)
        let context = repository.context
        for genre in genres where genre.artworkToken == nil || genre.artworkToken?.isEmpty == true {
            let name = genre.name
            var descriptor = FetchDescriptor<Album>(
                predicate: #Predicate<Album> { album in
                    album.genreName == name
                }
            )
            descriptor.fetchLimit = 24
            let albums = try context.fetch(descriptor)
            if let token = albums.compactMap(\.artworkToken).first(where: { !$0.isEmpty }) {
                genre.artworkToken = token
            }
        }
    }
}
