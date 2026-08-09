import AppIntents
import VerodromeKit

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggle playback in Verodrome.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { VerodromeKit.shared.player?.togglePlayPause() }
        return .result()
    }
}

struct ToggleOfflineIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Offline Mode"
    static var description = IntentDescription("Switch offline mode in Verodrome.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { VerodromeKit.shared.settings.offlineModeEnabled.toggle() }
        return .result()
    }
}

struct ShufflePlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Play"

    @Parameter(title: "Enable Shuffle")
    var enable: Bool

    init() { enable = true }
    init(enable: Bool) { self.enable = enable }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            (VerodromeKit.shared.player as? PlayerFacadeImpl)?.setShuffleMode(enable ? .on : .off)
        }
        return .result()
    }
}

struct LibraryNameEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library Item")
    static var defaultQuery = LibraryNameEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct LibraryNameEntityQuery: EntityQuery {
    func entities(for identifiers: [LibraryNameEntity.ID]) async throws -> [LibraryNameEntity] {
        identifiers.map { LibraryNameEntity(id: $0, name: $0) }
    }

    func suggestedEntities() async throws -> [LibraryNameEntity] {
        await MainActor.run {
            guard let account = try? VerodromeKit.shared.activeAccount(),
                  let repo = VerodromeKit.shared.repository() else { return [] }
            let albums = (try? repo.fetchAlbums(account: account))?.prefix(12).map {
                LibraryNameEntity(id: $0.title, name: $0.title)
            } ?? []
            let playlists = (try? repo.fetchPlaylists(account: account))?.prefix(12).map {
                LibraryNameEntity(id: $0.name, name: $0.name)
            } ?? []
            let artists = (try? repo.fetchArtists(account: account))?.prefix(12).map {
                LibraryNameEntity(id: $0.name, name: $0.name)
            } ?? []
            return Array(albums + playlists + artists)
        }
    }

    func entities(matching string: String) async throws -> [LibraryNameEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await suggestedEntities() }
        return [LibraryNameEntity(id: trimmed, name: trimmed)]
    }
}

struct PlayAlbumIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Album"
    static var description = IntentDescription("Play an album by name in Verodrome.")

    @Parameter(title: "Album")
    var album: LibraryNameEntity

    init() { album = LibraryNameEntity(id: "", name: "") }
    init(album: LibraryNameEntity) { self.album = album }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            try IntentLibraryPlayback.playAlbum(named: album.name)
        }
        return .result()
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Play a playlist by name in Verodrome.")

    @Parameter(title: "Playlist")
    var playlist: LibraryNameEntity

    init() { playlist = LibraryNameEntity(id: "", name: "") }
    init(playlist: LibraryNameEntity) { self.playlist = playlist }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            try IntentLibraryPlayback.playPlaylist(named: playlist.name)
        }
        return .result()
    }
}

struct PlayArtistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Artist"
    static var description = IntentDescription("Play songs by an artist in Verodrome.")

    @Parameter(title: "Artist")
    var artist: LibraryNameEntity

    init() { artist = LibraryNameEntity(id: "", name: "") }
    init(artist: LibraryNameEntity) { self.artist = artist }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            try IntentLibraryPlayback.playArtist(named: artist.name)
        }
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skip to the next track in Verodrome.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { VerodromeKit.shared.player?.next() }
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Go to the previous track in Verodrome.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { VerodromeKit.shared.player?.previous() }
        return .result()
    }
}

struct FavoriteCurrentIntent: AppIntent {
    static var title: LocalizedStringResource = "Favorite Current Song"
    static var description = IntentDescription("Mark the currently playing song as a favorite.")

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            try IntentLibraryPlayback.favoriteCurrent()
        }
        return .result()
    }
}

@MainActor
enum IntentLibraryPlayback {
    static func playAlbum(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let account = try VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository() else {
            throw IntentPlaybackError.notReady
        }
        let albums = try repo.fetchAlbums(account: account)
        guard let album = albums.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame })
                ?? albums.first(where: { $0.title.localizedCaseInsensitiveContains(trimmed) }) else {
            throw IntentPlaybackError.notFound(trimmed)
        }
        let songs = album.songs.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
        let items = songs.map { QueueItem.from($0, albumArtworkId: album.artworkToken) }
        Task { await VerodromeKit.shared.player?.play(items: items, startAt: 0) }
    }

    static func playPlaylist(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let account = try VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository() else {
            throw IntentPlaybackError.notReady
        }
        let playlists = try repo.fetchPlaylists(account: account)
        guard let playlist = playlists.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
                ?? playlists.first(where: { $0.name.localizedCaseInsensitiveContains(trimmed) }) else {
            throw IntentPlaybackError.notFound(trimmed)
        }
        let songs = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        Task { await VerodromeKit.shared.player?.play(items: songs.map(QueueItem.from), startAt: 0) }
    }

    static func playArtist(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let account = try VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository() else {
            throw IntentPlaybackError.notReady
        }
        let artists = try repo.fetchArtists(account: account)
        guard let artist = artists.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
                ?? artists.first(where: { $0.name.localizedCaseInsensitiveContains(trimmed) }) else {
            throw IntentPlaybackError.notFound(trimmed)
        }
        let songs = try repo.fetchSongs(account: account).filter {
            $0.artist?.compoundRemoteId == artist.compoundRemoteId
                || $0.album?.artist?.compoundRemoteId == artist.compoundRemoteId
        }
        Task { await VerodromeKit.shared.player?.play(items: songs.map(QueueItem.from), startAt: 0) }
    }

    static func favoriteCurrent() throws {
        guard let playableId = VerodromeKit.shared.player?.currentItem?.playableId,
              let account = try VerodromeKit.shared.activeAccount(),
              let repo = VerodromeKit.shared.repository(),
              let song = try repo.resolveSong(remoteId: playableId, account: account) else {
            throw IntentPlaybackError.notReady
        }
        Task { try? await LibraryActions.shared.setFavorite(song: song, isFavorite: true) }
    }
}

enum IntentPlaybackError: Error, LocalizedError {
    case notReady
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "Verodrome is not ready to play."
        case .notFound(let name): "Could not find “\(name)” in your library."
        }
    }
}

struct VerodromeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(), phrases: ["\(.applicationName) play pause", "Play or pause \(.applicationName)"])
        AppShortcut(intent: ToggleOfflineIntent(), phrases: ["\(.applicationName) offline mode", "Toggle offline in \(.applicationName)"])
        AppShortcut(intent: ShufflePlayIntent(), phrases: ["\(.applicationName) shuffle", "Shuffle with \(.applicationName)"])
        AppShortcut(intent: PlayAlbumIntent(), phrases: ["Play album \(\.$album) in \(.applicationName)", "\(.applicationName) play album \(\.$album)"])
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Play playlist \(\.$playlist) in \(.applicationName)", "\(.applicationName) play playlist \(\.$playlist)"])
        AppShortcut(intent: PlayArtistIntent(), phrases: ["Play artist \(\.$artist) in \(.applicationName)", "\(.applicationName) play artist \(\.$artist)"])
        AppShortcut(intent: NextTrackIntent(), phrases: ["\(.applicationName) next", "Next track in \(.applicationName)"])
        AppShortcut(intent: PreviousTrackIntent(), phrases: ["\(.applicationName) previous", "Previous track in \(.applicationName)"])
        AppShortcut(intent: FavoriteCurrentIntent(), phrases: ["Favorite this song in \(.applicationName)", "\(.applicationName) favorite current"])
    }
}
