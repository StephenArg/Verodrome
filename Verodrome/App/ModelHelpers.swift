import Foundation
import SwiftData
import VerodromeKit

enum PreviewSeeder {
    /// Stable id for the DEBUG login-screen account. Never used for a real server.
    static let demoServerHash = "demo-server"

    /// Demo data is DEBUG-only and never seeded when a real account is active,
    /// so it cannot mask live sync results.
    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        #if !DEBUG
        return
        #else
        if AccountStore.shared.isLoggedIn || AccountStore.shared.activeAccountKey() != nil {
            return
        }
        var descriptor = FetchDescriptor<Artist>()
        descriptor.fetchLimit = 1
        if (try? context.fetch(descriptor))?.isEmpty == false { return }

        let account = Account(
            serverUrl: "https://demo.verodrome.app",
            serverHash: demoServerHash,
            userHash: "demo-user",
            userName: "demo",
            apiType: .subsonic
        )
        context.insert(account)

        let artists = [
            Artist(remoteId: "a1", name: "Nova Pulse", account: account),
            Artist(remoteId: "a2", name: "Echo Harbor", account: account),
            Artist(remoteId: "a3", name: "Static Garden", account: account)
        ]
        artists.forEach { context.insert($0) }

        let albums = [
            Album(remoteId: "alb1", title: "Midnight Circuit", account: account, artist: artists[0]),
            Album(remoteId: "alb2", title: "Glass Horizon", account: account, artist: artists[1]),
            Album(remoteId: "alb3", title: "Signal Bloom", account: account, artist: artists[2])
        ]
        albums.forEach { album in
            album.year = 2024
            album.trackCount = 8
            album.duration = 2400
            context.insert(album)
        }

        for album in albums {
            for track in 1...album.trackCount {
                let song = Song(remoteId: "\(album.remoteId)-\(track)", title: "Track \(track)", account: account)
                song.artist = album.artist
                song.album = album
                song.track = track
                song.playDuration = Double(180 + track * 7)
                song.artistName = album.displayArtist
                song.albumTitle = album.title
                context.insert(song)
            }
        }

        [Playlist(remoteId: "p1", name: "Focus Flow", account: account),
         Playlist(remoteId: "p2", name: "Evening Drive", account: account)].forEach {
            $0.songCount = 12
            context.insert($0)
        }

        [Genre(remoteId: "g1", name: "Electronic", account: account),
         Genre(remoteId: "g2", name: "Ambient", account: account)].forEach { context.insert($0) }

        let podcast = Podcast(remoteId: "pod1", title: "Sound Design Weekly", account: account)
        podcast.author = "Verodrome FM"
        podcast.episodeCount = 24
        context.insert(podcast)

        let radio = Radio(remoteId: "r1", title: "Verodrome Chill", account: account)
        radio.streamURL = "https://stream.example/chill"
        context.insert(radio)

        try? context.save()
        #endif
    }

    /// Drops leftover DEBUG demo rows after a real login. Cascade deletes playlists,
    /// artists, albums, and the rest attached to the demo account.
    @MainActor
    static func purgeDemoDataIfNeeded(in context: ModelContext) {
        let demoHash = demoServerHash
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.serverHash == demoHash }
        )
        guard let demos = try? context.fetch(descriptor), !demos.isEmpty else { return }
        for account in demos {
            context.delete(account)
        }
        try? context.save()
    }
}

extension Song {
    var displayArtist: String { artistName ?? artist?.name ?? "Unknown Artist" }
    var displayAlbum: String { albumTitle ?? album?.title ?? "Unknown Album" }
    var displayDuration: TimeInterval { playDuration > 0 ? playDuration : 0 }
}

extension Album {
    var displayArtist: String { artistName ?? artist?.name ?? "Unknown Artist" }
}

/// An artist's songs as a queue: one album after another in the artist screen's album
/// order, each in disc / track order. Shuffle mixes the whole thing; turning it off
/// puts the albums back in sequence.
@MainActor
enum ArtistDiscography {
    /// Newest first — the order the artist screen lists them in.
    static func albums(of artist: Artist) -> [Album] {
        artist.albums.sorted {
            ($0.year ?? 0, $0.sortTitle) > ($1.year ?? 0, $1.sortTitle)
        }
    }

    /// Every track on the artist's albums — guest-credited ones included — plus the
    /// artist's songs on other albums. Walks each album's tracks, so call it from a tap
    /// rather than a view body.
    static func songs(of artist: Artist, albums: [Album]) -> [Song] {
        var seen = Set<String>()
        let pool = (albums.flatMap(\.songs) + artist.songs).filter {
            seen.insert($0.compoundRemoteId).inserted
        }
        return ordered(pool, albums: albums)
    }

    /// Groups `songs` by album in `albums` order. Songs on albums not in that list
    /// (compilations, guest spots) follow, newest first.
    static func ordered(_ songs: [Song], albums: [Album]) -> [Song] {
        var rankById: [String: Int] = [:]
        var rankByTitle: [String: Int] = [:]
        for (rank, album) in albums.enumerated() {
            if rankById[album.compoundRemoteId] == nil { rankById[album.compoundRemoteId] = rank }
            if rankByTitle[album.title] == nil { rankByTitle[album.title] = rank }
        }
        let otherAlbums = albums.count
        let keyed = songs.map { song in
            // Title only when the album link isn't loaded — a compilation can share a
            // title with one of the artist's own albums.
            let rank = song.album.map { rankById[$0.compoundRemoteId] ?? otherAlbums }
                ?? song.albumTitle.flatMap { rankByTitle[$0] }
                ?? otherAlbums
            let isOther = rank == otherAlbums
            return (
                song: song,
                key: (
                    rank,
                    isOther ? -(song.year ?? 0) : 0,
                    isOther ? (song.albumTitle ?? "") : "",
                    song.disc ?? 0,
                    song.track ?? 0
                )
            )
        }
        return keyed.sorted { $0.key < $1.key }.map(\.song)
    }

    /// Albums whose tracks haven't all been stored yet.
    static func albumsMissingTracks(_ albums: [Album]) -> [Album] {
        albums.filter { $0.songs.isEmpty || $0.songs.count < $0.trackCount }
    }

    /// Fetches tracks for the artist's albums that aren't fully stored — after syncing
    /// the artist itself when no albums are known yet — so a queue built afterwards
    /// holds the whole discography. Offline, whatever is already local stays as it is.
    static func fetchMissingTracks(for artist: Artist) async {
        let needsAlbums = artist.albums.isEmpty
        guard needsAlbums || !albumsMissingTracks(artist.albums).isEmpty,
              let syncer = try? await VerodromeKit.shared.ensureActiveLibrarySyncer() else { return }
        if needsAlbums {
            try? await syncer.sync(artistId: artist.remoteId)
        }
        for album in albumsMissingTracks(artist.albums) {
            guard !Task.isCancelled else { return }
            try? await syncer.sync(albumId: album.remoteId)
        }
    }
}
