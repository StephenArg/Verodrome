import Foundation
import SwiftData

@MainActor
public final class SwiftDataLibraryIngester: LibraryIngesting {
    private let repository: LibraryRepository
    private let account: Account
    public var onProgress: (@Sendable (String) -> Void)?

    /// When true (set by `beginSync`), finishSync prunes albums/playlists not seen during this sync.
    private var isFullSync = false
    private var seenAlbumIds = Set<String>()
    private var seenPlaylistIds = Set<String>()

    public init(repository: LibraryRepository, account: Account) {
        self.repository = repository
        self.account = account
    }

    public func beginSync() async throws {
        isFullSync = true
        seenAlbumIds.removeAll()
        seenPlaylistIds.removeAll()
    }

    public func finishSync() async throws {
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
        try backfillGenreArtwork()
        isFullSync = false
        try repository.save()
    }

    public func ingest(genres: [IngestGenre]) async throws {
        for item in genres {
            _ = try repository.getOrCreateGenre(remoteId: item.id, name: item.name, account: account)
        }
        onProgress?("Genres: \(genres.count)")
    }

    public func ingest(artists: [IngestArtist]) async throws {
        var processed = 0
        for item in artists {
            let artist = try repository.getOrCreateArtist(remoteId: item.id, name: item.name, account: account)
            if let albumCount = item.albumCount { artist.albumCount = albumCount }
            if let artId = item.artId { artist.artworkToken = artId }
            processed += 1
            if processed % 100 == 0 {
                await Task.yield()
            }
            if processed % 500 == 0 {
                try repository.save()
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try repository.save()
        onProgress?("Artists: \(artists.count)")
    }

    public func ingest(albums: [IngestAlbum]) async throws {
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
            if let artId = item.artId { album.artworkToken = artId }
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
            if processed % 50 == 0 {
                await Task.yield()
            }
            if processed % 500 == 0 {
                try repository.save()
                onProgress?("Albums: \(processed)/\(albums.count)")
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try repository.save()
        onProgress?("Albums: \(albums.count)")
    }

    public func ingest(songs: [IngestSong]) async throws {
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
                if let artId = item.artId, album?.artworkToken == nil {
                    album?.artworkToken = artId
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
            if let bitrate = item.bitrate { song.bitrate = bitrate }
            song.contentType = item.format
            song.artistName = item.artistName
            song.albumTitle = item.albumName
            if let artId = item.artId {
                song.artworkToken = artId
            } else if song.artworkToken == nil {
                song.artworkToken = album?.artworkToken
            }
            if let disc = item.discNumber { song.disc = disc }

            processed += 1
            // Keep the main actor responsive so the player clock/gestures stay alive
            // during large backfills. Save infrequently — each save checkpoints WAL
            // and refreshes observers.
            if processed % 50 == 0 {
                await Task.yield()
            }
            if processed % 1000 == 0 {
                try repository.save()
                onProgress?("Songs: \(processed)/\(songs.count)")
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try repository.save()
        onProgress?("Songs: \(songs.count)")
    }

    public func ingest(playlists: [IngestPlaylist]) async throws {
        for item in playlists {
            seenPlaylistIds.insert(item.id)
            let playlist = try repository.getOrCreatePlaylist(remoteId: item.id, name: item.name, account: account)
            if let artId = item.artId, !artId.isEmpty {
                playlist.artworkToken = artId
            }
            if let songCount = item.songCount {
                playlist.songCount = songCount
            }
            if !item.songIds.isEmpty {
                let songs = item.songIds.compactMap { try? repository.resolveSong(remoteId: $0, account: account) }
                try repository.replacePlaylistItems(playlist, with: songs)
                if playlist.artworkToken == nil {
                    playlist.artworkToken = songs
                        .compactMap { $0.artworkToken ?? $0.album?.artworkToken }
                        .first
                }
            }
        }
        try repository.save()
        onProgress?("Playlists: \(playlists.count)")
    }

    public func ingest(podcasts: [IngestPodcast]) async throws {
        for item in podcasts {
            let podcast = try repository.getOrCreatePodcast(remoteId: item.id, title: item.title, account: account)
            if let artId = item.artId { podcast.artworkToken = artId }
            if let description = item.description { podcast.descriptionText = description }
        }
        onProgress?("Podcasts: \(podcasts.count)")
    }

    public func ingest(episodes: [IngestPodcastEpisode]) async throws {
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
        try repository.save()
    }

    public func ingest(radios: [IngestRadio]) async throws {
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
        try repository.save()
        onProgress?("Radios: \(radios.count)")
    }

    public func applyNewestAlbumRanks(_ orderedRemoteIds: [String]) async throws {
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
        try repository.save()
    }

    public func applyRecentAlbumRanks(_ orderedRemoteIds: [String]) async throws {
        let previouslyRanked = try repository.fetchAlbums(recentIndexPositive: true)
        for album in previouslyRanked {
            album.recentIndex = 0
        }
        for (offset, remoteId) in orderedRemoteIds.enumerated() {
            if let album = try repository.resolveAlbum(remoteId: remoteId, account: account) {
                album.recentIndex = offset + 1
            }
        }
        try repository.save()
    }

    public func applyFavoriteAlbums(_ remoteIds: [String]) async throws {
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
        try repository.save()
    }

    private func assignGenreArtwork(_ genre: Genre, from artId: String?) {
        guard genre.artworkToken == nil || genre.artworkToken?.isEmpty == true,
              let artId, !artId.isEmpty else { return }
        genre.artworkToken = artId
    }

    /// Fill missing genre art from any album already tagged with that genre name.
    private func backfillGenreArtwork() throws {
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
