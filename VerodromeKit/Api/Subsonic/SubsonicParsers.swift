import Foundation

enum SubsonicParsers {
    static func checkForError(data: Data) throws {
        let parser = GenericXmlParser()
        let root = try parser.parse(data: data)

        guard root.name == "subsonic-response" else { return }

        if root.attributes["status"] == "failed" {
            if let errorNode = root.firstChild(named: "error") {
                let code = Int(errorNode.attributes["code"] ?? "")
                let message = errorNode.attributes["message"] ?? errorNode.text
                throw XmlParseError.serverError(code: code, message: message)
            }
            throw XmlParseError.serverError(code: nil, message: "Subsonic request failed")
        }
    }

    /// A ping response is a bare `<subsonic-response type="navidrome" serverVersion="…"/>`,
    /// so everything worth reading is an attribute on the root. The child-element lookups
    /// are kept as a fallback for servers that nest them instead.
    ///
    /// `serverVersion` is the product version ("0.61.2"); `version` is the Subsonic API
    /// version, which `apiVersion` already carries.
    static func parseServerInfo(data: Data) throws -> ServerInfo {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)

        let versionNode = root.firstChild(named: "version") ?? root.firstChild(named: "openSubsonic")
        let version = root.attributes["serverVersion"]
            ?? versionNode?.text.nilIfEmpty
            ?? versionNode?.attributes["version"]
            ?? root.attributes["version"]
            ?? "unknown"

        let name = root.attributes["type"]
            ?? root.firstChild(named: "type")?.text.nilIfEmpty
            ?? "Subsonic"

        return ServerInfo(name: name, version: version, apiVersion: SubsonicServerApi.apiVersion)
    }

    static func parseGenres(data: Data) throws -> [IngestGenre] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let genres = root.firstChild(named: "genres")
        let nodes = genres?.children(named: "genre") ?? root.descendants(named: "genre")
        return nodes.compactMap { node in
            let name = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return IngestGenre(
                id: name,
                name: name,
                albumCount: intValue(node.attributes["albumCount"]),
                songCount: intValue(node.attributes["songCount"])
            )
        }
    }

    static func parseArtists(data: Data) throws -> [IngestArtist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let indexes = root.descendants(named: "index")
        let artistNodes: [XmlNode]
        if indexes.isEmpty {
            artistNodes = root.descendants(named: "artist")
        } else {
            artistNodes = indexes.flatMap { $0.descendants(named: "artist") }
        }

        return artistNodes.map { node in
            IngestArtist(
                id: node.attributes["id"] ?? "",
                name: node.attributes["name"] ?? node.text,
                albumCount: intValue(node.attributes["albumCount"]),
                // Not in classic ArtistID3; some servers (and getArtist detail) expose it.
                songCount: intValue(node.attributes["songCount"]),
                artId: node.attributes["coverArt"]
            )
        }
    }

    static func parseAlbumList(data: Data) throws -> [IngestAlbum] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let list = root.firstChild(named: "albumList2") ?? root.firstChild(named: "albumList")
        let albums = list?.children(named: "album") ?? root.descendants(named: "album")

        return albums.map { node in
            IngestAlbum(
                id: node.attributes["id"] ?? "",
                name: node.attributes["name"] ?? node.attributes["title"] ?? "",
                artistId: node.attributes["artistId"],
                artistName: node.attributes["artist"],
                year: intValue(node.attributes["year"]),
                songCount: intValue(node.attributes["songCount"]),
                artId: node.attributes["coverArt"],
                genreIds: [],
                genreName: node.attributes["genre"],
                rating: rating(node.attributes["userRating"])
            )
        }
        .filter { !$0.id.isEmpty }
    }

    /// Albums from `getStarred2` / `getStarred`.
    static func parseStarredAlbums(data: Data) throws -> [IngestAlbum] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let starred = root.firstChild(named: "starred2") ?? root.firstChild(named: "starred")
        let albums = starred?.children(named: "album") ?? []
        return albums.map { node in
            IngestAlbum(
                id: node.attributes["id"] ?? "",
                name: node.attributes["name"] ?? node.attributes["title"] ?? "",
                artistId: node.attributes["artistId"],
                artistName: node.attributes["artist"],
                year: intValue(node.attributes["year"]),
                songCount: intValue(node.attributes["songCount"]),
                artId: node.attributes["coverArt"],
                genreIds: [],
                genreName: node.attributes["genre"],
                rating: rating(node.attributes["userRating"])
            )
        }
        .filter { !$0.id.isEmpty }
    }

    static func parseAlbumDetail(data: Data) throws -> (albums: [IngestAlbum], songs: [IngestSong]) {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let albumNode = root.firstChild(named: "album") else {
            return ([], [])
        }

        let album = IngestAlbum(
            id: albumNode.attributes["id"] ?? "",
            name: albumNode.attributes["name"] ?? albumNode.attributes["title"] ?? "",
            artistId: albumNode.attributes["artistId"],
            artistName: albumNode.attributes["artist"],
            year: intValue(albumNode.attributes["year"]),
            songCount: intValue(albumNode.attributes["songCount"]),
            artId: albumNode.attributes["coverArt"],
            genreName: albumNode.attributes["genre"],
            rating: rating(albumNode.attributes["userRating"])
        )

        let songs = albumNode.children(named: "song").map { song($0, in: album) }
        return ([album], songs)
    }

    /// Songs from any response that lists them as flat `<song>` nodes, such as
    /// `getRandomSongs` or `getSongsByGenre`.
    static func parseSongList(data: Data) throws -> [IngestSong] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "song")
            .map { song($0) }
            .filter { !$0.id.isEmpty }
    }

    static func parsePlaylists(data: Data) throws -> [IngestPlaylist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let playlistsNode = root.firstChild(named: "playlists")
        let playlistNodes = playlistsNode?.children(named: "playlist") ?? root.descendants(named: "playlist")

        return playlistNodes.map { node in
            let entries = node.children(named: "entry").compactMap { $0.attributes["id"] }
            return IngestPlaylist(
                id: node.attributes["id"] ?? "",
                name: node.attributes["name"] ?? "",
                songCount: intValue(node.attributes["songCount"]) ?? entries.count,
                owner: node.attributes["owner"],
                isPublic: node.attributes["public"] == "true",
                isSmart: isSmartPlaylist(node),
                isReadOnly: isReadOnlyPlaylist(node),
                songIds: entries,
                artId: node.attributes["coverArt"]
            )
        }
    }

    static func parsePlaylistDetail(data: Data) throws -> [IngestPlaylist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let playlistNode = root.firstChild(named: "playlist") else { return [] }
        let songIds = playlistNode.children(named: "entry").compactMap { $0.attributes["id"] }
        return [
            IngestPlaylist(
                id: playlistNode.attributes["id"] ?? "",
                name: playlistNode.attributes["name"] ?? "",
                songCount: songIds.count,
                owner: playlistNode.attributes["owner"],
                isPublic: playlistNode.attributes["public"] == "true",
                isSmart: isSmartPlaylist(playlistNode),
                isReadOnly: isReadOnlyPlaylist(playlistNode),
                songIds: songIds,
                artId: playlistNode.attributes["coverArt"]
            )
        ]
    }

    /// OpenSubsonic `readonly`: the playlist cannot be edited by the signed-in user, which
    /// covers both server-generated lists and other people's playlists. Absent means the
    /// server doesn't report it, and the spec says to assume editable.
    private static func isReadOnlyPlaylist(_ node: XmlNode) -> Bool {
        node.attributes["readonly"] == "true"
    }

    /// Nothing in the protocol says "smart", but `validUntil` — the point at which the
    /// server will regenerate the contents — is only meaningful for a list the server
    /// builds itself, so its presence is the closest thing to a marker.
    private static func isSmartPlaylist(_ node: XmlNode) -> Bool {
        !(node.attributes["validUntil"]?.isEmpty ?? true)
    }

    /// Songs embedded as `<entry>` nodes inside a playlist detail response (includes coverArt).
    static func parsePlaylistSongs(data: Data) throws -> [IngestSong] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let playlistNode = root.firstChild(named: "playlist") else { return [] }
        return playlistNode.children(named: "entry").map { song($0) }
    }

    static func parseSearch(data: Data) throws -> (artists: [SearchArtist], albums: [SearchAlbum], songs: [SearchSong]) {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let result = root.firstChild(named: "searchResult3") ?? root.firstChild(named: "searchResult") else {
            return ([], [], [])
        }

        let artists = result.children(named: "artist").map {
            SearchArtist(id: $0.attributes["id"] ?? "", name: $0.attributes["name"] ?? "")
        }
        let albums = result.children(named: "album").map {
            SearchAlbum(id: $0.attributes["id"] ?? "", name: $0.attributes["name"] ?? "", artistName: $0.attributes["artist"])
        }
        let songs = result.children(named: "song").map {
            SearchSong(
                id: $0.attributes["id"] ?? "",
                title: $0.attributes["title"] ?? "",
                artistName: $0.attributes["artist"],
                albumName: $0.attributes["album"]
            )
        }
        return (artists, albums, songs)
    }

    static func parsePodcasts(data: Data) throws -> [IngestPodcast] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let channels = root.firstChild(named: "podcasts")?.children(named: "channel") ?? root.descendants(named: "channel")
        return channels.compactMap { node in
            if let status = node.attributes["status"], status == "error" { return nil }
            let id = node.attributes["id"] ?? ""
            guard !id.isEmpty else { return nil }
            return IngestPodcast(
                id: id,
                title: node.attributes["title"] ?? node.text,
                description: node.attributes["description"],
                artId: firstNonEmpty(
                    node.attributes["coverArt"],
                    node.attributes["originalImageUrl"]
                )
            )
        }
    }

    static func parsePodcastEpisodes(data: Data, podcastId: String) throws -> [IngestPodcastEpisode] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let episodes = root.firstChild(named: "episodes")?.children(named: "episode") ?? root.descendants(named: "episode")
        return episodes.map { node in
            IngestPodcastEpisode(
                id: node.attributes["id"] ?? "",
                podcastId: podcastId,
                title: node.attributes["title"] ?? "",
                publishDate: dateValue(node.attributes["publishDate"] ?? node.attributes["created"]),
                duration: timeInterval(node.attributes["duration"]),
                artId: firstNonEmpty(
                    node.attributes["coverArt"],
                    node.attributes["originalImageUrl"]
                )
            )
        }
    }

    static func parseRadios(data: Data) throws -> [IngestRadio] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let stations = root.firstChild(named: "internetRadioStations")?.children(named: "internetRadioStation")
            ?? root.descendants(named: "internetRadioStation")
        return stations.map { node in
            IngestRadio(
                id: node.attributes["id"] ?? "",
                name: node.attributes["name"] ?? "",
                streamURL: node.attributes["streamUrl"],
                homepageURL: node.attributes["homePageUrl"],
                artId: node.attributes["coverArt"]
            )
        }
        .filter { !$0.id.isEmpty }
    }

    static func parseMusicFolders(data: Data) throws -> [RemoteMusicFolder] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        let folders = root.firstChild(named: "musicFolders")?.children(named: "musicFolder") ?? []
        return folders.map { RemoteMusicFolder(id: $0.attributes["id"] ?? "", name: $0.attributes["name"] ?? "") }
    }

    static func parseMusicDirectory(data: Data) throws -> [DirectoryEntry] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let directory = root.firstChild(named: "directory") else { return [] }

        let childNodes = directory.children
        return childNodes.compactMap { node in
            if node.name == "child" {
                let isDir = node.attributes["isDir"] == "true"
                return DirectoryEntry(
                    id: node.attributes["id"] ?? "",
                    name: node.attributes["title"] ?? node.attributes["name"] ?? "",
                    kind: isDir ? .folder : .song,
                    coverArtId: node.attributes["coverArt"],
                    artistName: node.attributes["artist"],
                    albumName: node.attributes["album"],
                    duration: timeInterval(node.attributes["duration"])
                )
            }

            let kind: DirectoryEntryKind?
            switch node.name {
            case "artist": kind = .artist
            case "album": kind = .album
            case "song": kind = .song
            case "directory", "folder": kind = .folder
            default: kind = nil
            }
            guard let kind else { return nil }
            return DirectoryEntry(
                id: node.attributes["id"] ?? node.attributes["name"] ?? node.text,
                name: node.attributes["name"] ?? node.attributes["title"] ?? node.text,
                kind: kind,
                coverArtId: node.attributes["coverArt"],
                artistName: node.attributes["artist"],
                albumName: node.attributes["album"],
                duration: timeInterval(node.attributes["duration"])
            )
        }
    }

    static func parseCreatedPlaylistId(data: Data) throws -> String {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        if let playlist = root.firstChild(named: "playlist"), let id = playlist.attributes["id"] {
            return id
        }
        throw XmlParseError.unexpectedStructure("createPlaylist response missing id")
    }

    /// Parses classic `getLyrics` or OpenSubsonic `getLyricsBySongId` / structured lyrics.
    /// Synced lines are rendered as LRC (`[mm:ss.xx]text`) so timestamps survive the
    /// plain-text lyrics pipeline.
    static func parseLyrics(data: Data) throws -> String? {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)

        // OpenSubsonic structured lyrics: <lyricsList><structuredLyrics><line>...</line></structuredLyrics></lyricsList>
        // Preferred over the classic element because a response can carry both and
        // only this one can be timestamped.
        if let list = root.firstChild(named: "lyricsList") {
            let structured = list.descendants(named: "structuredLyrics")
            var lines: [String] = []
            for block in structured {
                let offset = Int(block.attributes["offset"] ?? "") ?? 0
                let lineNodes = block.children(named: "line")
                if !lineNodes.isEmpty {
                    for node in lineNodes {
                        guard let start = node.attributes["start"], let milliseconds = Int(start) else {
                            lines.append(node.text)
                            continue
                        }
                        lines.append(LyricsParser.timestamp(forMilliseconds: milliseconds + offset) + node.text)
                    }
                } else {
                    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { lines.append(text) }
                }
            }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }

        if let lyricsNode = root.firstChild(named: "lyrics") {
            let text = lyricsNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        return nil
    }

    static func parseSong(data: Data) throws -> IngestSong? {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let songNode = root.firstChild(named: "song") else { return nil }
        return song(songNode)
    }

    /// Maps a `<song>` / `<entry>` node, which carries the same attributes wherever it
    /// appears. `album` supplies the fields a song nested in an album detail response
    /// leaves off, since the parent already states them.
    private static func song(_ node: XmlNode, in album: IngestAlbum? = nil) -> IngestSong {
        IngestSong(
            id: node.attributes["id"] ?? "",
            title: node.attributes["title"] ?? "",
            albumId: album?.id ?? node.attributes["albumId"],
            albumName: album?.name ?? node.attributes["album"],
            artistId: node.attributes["artistId"] ?? album?.artistId,
            artistName: node.attributes["artist"] ?? album?.artistName,
            trackNumber: intValue(node.attributes["track"]),
            discNumber: intValue(node.attributes["discNumber"]),
            duration: timeInterval(node.attributes["duration"]),
            artId: node.attributes["coverArt"] ?? album?.artId,
            bitrate: intValue(node.attributes["bitRate"]),
            format: node.attributes["suffix"] ?? node.attributes["contentType"],
            playCount: intValue(node.attributes["playCount"]),
            rating: rating(node.attributes["userRating"])
        )
    }

    /// The signed-in user's 0–5 rating. Parsed as a double because most servers send
    /// "4" but some send "4.0", which `Int(_:)` rejects outright.
    private static func rating(_ raw: String?) -> Int? {
        guard let raw, let value = Double(raw) else { return nil }
        return max(0, min(5, Int(value.rounded())))
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        return Int(raw)
    }

    private static func timeInterval(_ raw: String?) -> TimeInterval? {
        guard let raw, let value = Double(raw) else { return nil }
        return value
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func dateValue(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
