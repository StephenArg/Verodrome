import Foundation
import SwiftData
import VerodromeKit

enum PreviewSeeder {
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
            serverHash: "demo-server",
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
}

extension Song {
    var displayArtist: String { artistName ?? artist?.name ?? "Unknown Artist" }
    var displayAlbum: String { albumTitle ?? album?.title ?? "Unknown Album" }
    var displayDuration: TimeInterval { playDuration > 0 ? playDuration : 0 }
}

extension Album {
    var displayArtist: String { artistName ?? artist?.name ?? "Unknown Artist" }
}
