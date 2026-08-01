import Foundation

enum AmpacheParsers {
    struct HandshakeResult: Sendable {
        let token: String
        let apiKey: String
        let version: String
        let serverName: String?
    }

    static func checkForError(data: Data) throws {
        let parser = GenericXmlParser()
        let root = try parser.parse(data: data)

        if let errorNode = root.firstChild(named: "error") ?? root.descendants(named: "error").first {
            let code = Int(errorNode.attributes["code"] ?? "")
            let message = errorNode.text.isEmpty ? (errorNode.attributes["message"] ?? "Unknown Ampache error") : errorNode.text
            throw XmlParseError.serverError(code: code, message: message)
        }
    }

    static func parseHandshake(data: Data) throws -> HandshakeResult {
        try checkForError(data: data)
        let parser = GenericXmlParser()
        let root = try parser.parse(data: data)

        guard let auth = root.firstChild(named: "auth") ?? root.descendants(named: "auth").first else {
            throw XmlParseError.unexpectedStructure("handshake missing auth element")
        }

        guard let token = auth.attributes["token"], let apiKey = auth.attributes["apikey"] else {
            throw XmlParseError.unexpectedStructure("handshake missing token or apikey")
        }

        let version = auth.attributes["version"] ?? auth.attributes["server_version"] ?? "unknown"
        let serverName = auth.attributes["session_expire"] != nil ? auth.attributes["session_expire"] : auth.attributes["update"]

        return HandshakeResult(
            token: token,
            apiKey: apiKey,
            version: version,
            serverName: serverName
        )
    }

    static func parseGenres(data: Data) throws -> [IngestGenre] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "genre").map { node in
            IngestGenre(
                id: node.attributes["id"] ?? node.text,
                name: childText(node, "name") ?? node.attributes["name"] ?? node.text,
                albumCount: intValue(
                    childText(node, "albums")
                        ?? childText(node, "albumcount")
                        ?? node.attributes["albums"]
                        ?? node.attributes["albumcount"]
                ),
                songCount: intValue(
                    childText(node, "songs")
                        ?? childText(node, "songcount")
                        ?? node.attributes["songs"]
                        ?? node.attributes["songcount"]
                )
            )
        }
    }

    static func parseArtists(data: Data) throws -> [IngestArtist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "artist").map { node in
            IngestArtist(
                id: node.attributes["id"] ?? "",
                name: childText(node, "name") ?? node.attributes["name"] ?? "",
                albumCount: intValue(
                    childText(node, "albumcount")
                        ?? childText(node, "albums")
                        ?? node.attributes["albumcount"]
                        ?? node.attributes["albums"]
                ),
                songCount: intValue(
                    childText(node, "songcount")
                        ?? childText(node, "songs")
                        ?? node.attributes["songcount"]
                        ?? node.attributes["songs"]
                ),
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
    }

    static func parseAlbums(data: Data) throws -> [IngestAlbum] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "album").map { node in
            let artistNode = node.firstChild(named: "artist")
            return IngestAlbum(
                id: node.attributes["id"] ?? "",
                name: childText(node, "name") ?? node.attributes["name"] ?? "",
                artistId: artistNode?.attributes["id"] ?? node.attributes["artist"],
                artistName: artistNode?.text ?? childText(node, "artist"),
                year: intValue(childText(node, "year") ?? node.attributes["year"]),
                songCount: intValue(childText(node, "songcount") ?? node.attributes["songcount"]),
                artId: node.attributes["art"] ?? childText(node, "art"),
                genreIds: node.children(named: "genre").compactMap { $0.attributes["id"] ?? $0.text.nilIfEmpty }
            )
        }
    }

    static func parseSongs(data: Data) throws -> [IngestSong] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "song").map { node in
            let albumNode = node.firstChild(named: "album")
            let artistNode = node.firstChild(named: "artist")
            return IngestSong(
                id: node.attributes["id"] ?? "",
                title: childText(node, "title") ?? node.attributes["title"] ?? "",
                albumId: albumNode?.attributes["id"] ?? node.attributes["album"],
                albumName: albumNode?.text ?? childText(node, "album"),
                artistId: artistNode?.attributes["id"] ?? node.attributes["artist"],
                artistName: artistNode?.text ?? childText(node, "artist"),
                trackNumber: intValue(childText(node, "track") ?? node.attributes["track"]),
                discNumber: intValue(childText(node, "disk") ?? childText(node, "disc") ?? node.attributes["disk"]),
                duration: timeInterval(childText(node, "time") ?? node.attributes["time"]),
                artId: node.attributes["art"] ?? childText(node, "art"),
                bitrate: intValue(childText(node, "bitrate") ?? node.attributes["bitrate"]),
                format: childText(node, "type") ?? node.attributes["type"]
            )
        }
    }

    static func parsePlaylists(data: Data) throws -> [IngestPlaylist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "playlist").map { node in
            let songIds = node.descendants(named: "song").compactMap { $0.attributes["id"] ?? $0.text.nilIfEmpty }
            return IngestPlaylist(
                id: node.attributes["id"] ?? "",
                name: childText(node, "name") ?? node.attributes["name"] ?? "",
                songCount: intValue(childText(node, "songcount") ?? node.attributes["songcount"]) ?? songIds.count,
                owner: childText(node, "owner") ?? node.attributes["owner"],
                isPublic: (childText(node, "type") ?? node.attributes["type"]) == "public",
                songIds: songIds,
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
    }

    /// Songs nested under a playlist detail response (includes art URLs).
    static func parsePlaylistSongs(data: Data) throws -> [IngestSong] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let playlist = root.firstChild(named: "playlist") ?? root.descendants(named: "playlist").first else {
            return []
        }
        return playlist.descendants(named: "song").map { node in
            IngestSong(
                id: node.attributes["id"] ?? node.text.nilIfEmpty ?? "",
                title: childText(node, "title") ?? childText(node, "name") ?? node.attributes["title"] ?? "",
                albumId: childText(node, "album") ?? node.attributes["album_id"] ?? node.attributes["album"],
                albumName: childText(node, "album") ?? node.attributes["album"],
                artistId: childText(node, "artist") ?? node.attributes["artist_id"],
                artistName: childText(node, "artist") ?? node.attributes["artist"],
                trackNumber: intValue(childText(node, "track") ?? node.attributes["track"]),
                discNumber: intValue(childText(node, "disk") ?? node.attributes["disk"]),
                duration: timeInterval(childText(node, "time") ?? node.attributes["time"]),
                artId: node.attributes["art"] ?? childText(node, "art"),
                bitrate: intValue(childText(node, "bitrate") ?? node.attributes["bitrate"]),
                format: childText(node, "type") ?? node.attributes["type"]
            )
        }.filter { !$0.id.isEmpty }
    }

    static func parsePodcasts(data: Data) throws -> [IngestPodcast] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "podcast").map { node in
            IngestPodcast(
                id: node.attributes["id"] ?? "",
                title: childText(node, "title") ?? childText(node, "name") ?? node.attributes["name"] ?? "",
                description: childText(node, "description"),
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
    }

    static func parsePodcastEpisodes(data: Data, podcastId: String) throws -> [IngestPodcastEpisode] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "episode").map { node in
            IngestPodcastEpisode(
                id: node.attributes["id"] ?? "",
                podcastId: podcastId,
                title: childText(node, "title") ?? childText(node, "name") ?? "",
                publishDate: dateValue(childText(node, "pubdate") ?? node.attributes["pubdate"]),
                duration: timeInterval(childText(node, "time") ?? node.attributes["time"]),
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
    }

    static func parseRadios(data: Data) throws -> [IngestRadio] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "live_stream").map { node in
            IngestRadio(
                id: node.attributes["id"] ?? "",
                name: childText(node, "name") ?? node.attributes["name"] ?? "",
                streamURL: childText(node, "url") ?? node.attributes["url"],
                homepageURL: childText(node, "site_url") ?? node.attributes["site_url"],
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
        .filter { !$0.id.isEmpty }
    }

    static func parseSearchArtists(data: Data) throws -> [SearchArtist] {
        try parseArtists(data: data).map { SearchArtist(id: $0.id, name: $0.name) }
    }

    static func parseSearchAlbums(data: Data) throws -> [SearchAlbum] {
        try parseAlbums(data: data).map { SearchAlbum(id: $0.id, name: $0.name, artistName: $0.artistName) }
    }

    static func parseSearchSongs(data: Data) throws -> [SearchSong] {
        try parseSongs(data: data).map {
            SearchSong(id: $0.id, title: $0.title, artistName: $0.artistName, albumName: $0.albumName)
        }
    }

    static func parseCreatedPlaylistId(data: Data) throws -> String {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        if let playlist = root.firstChild(named: "playlist") ?? root.descendants(named: "playlist").first,
           let id = playlist.attributes["id"] {
            return id
        }
        throw XmlParseError.unexpectedStructure("create playlist response missing id")
    }

    /// Extracts lyrics text from an Ampache `get_song` response (`<lyrics>` child).
    static func parseSongLyrics(data: Data) throws -> String? {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        guard let song = root.descendants(named: "song").first else { return nil }
        let text = childText(song, "lyrics")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Helpers

    private static func childText(_ node: XmlNode, _ name: String) -> String? {
        node.firstChild(named: name)?.text.nilIfEmpty
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        return Int(raw)
    }

    private static func timeInterval(_ raw: String?) -> TimeInterval? {
        guard let raw, let value = Double(raw) else { return nil }
        return value
    }

    private static func dateValue(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
