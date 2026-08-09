import Foundation

enum AmpacheParsers {
    struct HandshakeResult: Sendable {
        let token: String
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

    /// Ampache renders the handshake with `Api::keyed_array`, so every field is an
    /// element holding CDATA text — `<auth><![CDATA[token]]></auth>` — rather than an
    /// attribute. The session id in `<auth>` is the only credential later calls need;
    /// there is no api key in the response.
    static func parseHandshake(data: Data) throws -> HandshakeResult {
        try checkForError(data: data)
        let parser = GenericXmlParser()
        let root = try parser.parse(data: data)

        guard let auth = root.firstChild(named: "auth") ?? root.descendants(named: "auth").first else {
            throw XmlParseError.unexpectedStructure("handshake missing auth element")
        }

        guard let token = (auth.text.nilIfEmpty ?? auth.attributes["token"]) else {
            throw XmlParseError.unexpectedStructure("handshake missing session token")
        }

        let version = childText(root, "api")
            ?? childText(root, "version")
            ?? auth.attributes["version"]
            ?? "unknown"

        return HandshakeResult(
            token: token,
            version: version,
            serverName: childText(root, "server")
        )
    }

    /// Size of the whole collection a paged response is a window onto. Ampache repeats
    /// it on every page; nil when the server omits it.
    static func parseTotalCount(data: Data) throws -> Int? {
        let root = try GenericXmlParser().parse(data: data)
        return intValue(childText(root, "total_count"))
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
                artistName: artistNode.flatMap(nestedName) ?? childText(node, "artist"),
                year: intValue(childText(node, "year") ?? node.attributes["year"]),
                songCount: intValue(childText(node, "songcount") ?? node.attributes["songcount"]),
                artId: node.attributes["art"] ?? childText(node, "art"),
                genreIds: node.children(named: "genre").compactMap { $0.attributes["id"] ?? $0.text.nilIfEmpty },
                rating: rating(node)
            )
        }
    }

    static func parseSongs(data: Data, favoriteAbsentMeans: Bool? = nil) throws -> [IngestSong] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "song").map { node in
            let albumNode = node.firstChild(named: "album")
            let artistNode = node.firstChild(named: "artist")
            return IngestSong(
                id: node.attributes["id"] ?? "",
                title: childText(node, "title") ?? node.attributes["title"] ?? "",
                albumId: albumNode?.attributes["id"] ?? node.attributes["album"],
                albumName: albumNode.flatMap(nestedName) ?? childText(node, "album"),
                artistId: artistNode?.attributes["id"] ?? node.attributes["artist"],
                artistName: artistNode.flatMap(nestedName) ?? childText(node, "artist"),
                trackNumber: intValue(childText(node, "track") ?? node.attributes["track"]),
                discNumber: intValue(childText(node, "disk") ?? childText(node, "disc") ?? node.attributes["disk"]),
                duration: timeInterval(childText(node, "time") ?? node.attributes["time"]),
                artId: node.attributes["art"] ?? childText(node, "art"),
                // Ampache reports bits/sec; the rest of the app stores/displays kbps.
                bitrate: Self.kilobitsPerSecond(intValue(childText(node, "bitrate") ?? node.attributes["bitrate"])),
                // API 6 names this `format`; `type` on a song element is the older spelling.
                format: childText(node, "format") ?? childText(node, "type") ?? node.attributes["type"],
                playCount: intValue(childText(node, "playcount") ?? node.attributes["playcount"]),
                rating: rating(node),
                isFavorite: favoriteFlag(node, absentMeans: favoriteAbsentMeans)
            )
        }
    }

    /// Ampache `flag` / `flagged` is 0/1 (sometimes true/false). Nil when the payload
    /// doesn't include it, unless `absentMeans` supplies an authoritative default.
    private static func favoriteFlag(_ node: XmlNode, absentMeans: Bool?) -> Bool? {
        let raw = childText(node, "flag")
            ?? node.attributes["flag"]
            ?? childText(node, "flagged")
            ?? node.attributes["flagged"]
        guard let raw else { return absentMeans }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "1" || normalized == "true" || normalized == "yes" { return true }
        if normalized == "0" || normalized == "false" || normalized == "no" { return false }
        return absentMeans
    }

    static func parsePlaylists(data: Data) throws -> [IngestPlaylist] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)
        return root.descendants(named: "playlist").map { node in
            // With `include=1` the entries arrive as `<playlisttrack>` elements nested in
            // `<items>`; without it `<items>` is just the count. `<song>` is the older
            // spelling and stays as a fallback.
            let songIds = (node.descendants(named: "playlisttrack") + node.descendants(named: "song"))
                .compactMap { $0.attributes["id"] ?? $0.text.nilIfEmpty }
            let id = node.attributes["id"] ?? ""
            return IngestPlaylist(
                id: id,
                name: childText(node, "name") ?? node.attributes["name"] ?? "",
                songCount: intValue(childText(node, "items") ?? childText(node, "songcount") ?? node.attributes["songcount"]) ?? songIds.count,
                owner: childText(node, "owner") ?? node.attributes["owner"],
                isPublic: (childText(node, "type") ?? node.attributes["type"]) == "public",
                // Ampache returns smart playlists from the same endpoint, distinguished only
                // by a prefixed id such as `smart_3`.
                isSmart: id.hasPrefix("smart_"),
                songIds: songIds,
                artId: node.attributes["art"] ?? childText(node, "art")
            )
        }
    }

    /// Tracks of a single playlist. `playlist_songs` returns them at the document root,
    /// so this is `parseSongs` with the empty-id rows dropped — a playlist that has lost
    /// a file still lists the slot, and an entry with no id can't be resolved.
    static func parsePlaylistSongs(data: Data) throws -> [IngestSong] {
        try parseSongs(data: data).filter { !$0.id.isEmpty }
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
        let nodes = root.descendants(named: "podcast_episode") + root.descendants(named: "episode")
        return nodes.map { node in
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

    /// `shares`, `share_create` and `share_edit` all answer with the same `<share>`
    /// elements.
    ///
    /// Ampache stores expiry as a whole number of days from creation rather than as an
    /// instant, so the absolute date has to be reconstructed; `0` days means never.
    static func parseShares(data: Data) throws -> [ShareRef] {
        try checkForError(data: data)
        let root = try GenericXmlParser().parse(data: data)

        return root.descendants(named: "share").compactMap { node -> ShareRef? in
            guard let id = node.attributes["id"], !id.isEmpty else { return nil }

            let created = unixDate(childText(node, "creation_date"))
            let objectName = childText(node, "name")

            return ShareRef(
                id: id,
                url: childText(node, "public_url").flatMap(URL.init(string:)),
                description: childText(node, "description"),
                contentsLabel: objectName,
                resourceType: childText(node, "object_type").flatMap(ShareResourceType.init(rawValue:)),
                owner: childText(node, "user"),
                created: created,
                expires: ShareExpiry.date(created: created, expireDays: intValue(childText(node, "expire_days"))),
                lastVisited: unixDate(childText(node, "lastvisit_date")),
                visitCount: intValue(childText(node, "counter")) ?? 0,
                isDownloadable: boolValue(childText(node, "allow_download")),
                entryCount: 1
            )
        }
    }

    /// Ampache writes `0` for "no such date" as well as for the epoch itself, and the
    /// epoch is never a real creation or visit time here.
    private static func unixDate(_ raw: String?) -> Date? {
        guard let raw, let seconds = TimeInterval(raw), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func boolValue(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func childText(_ node: XmlNode, _ name: String) -> String? {
        node.firstChild(named: name)?.text.nilIfEmpty
    }

    /// API 6 nests related objects as `<artist id="5"><name>…</name>…</artist>`, where
    /// older responses put the label in the element's own text.
    private static func nestedName(_ node: XmlNode) -> String? {
        childText(node, "name") ?? node.text.nilIfEmpty
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        return Int(raw)
    }

    /// Ampache song `bitrate` is bits/sec; Verodrome stores kbps like Subsonic.
    private static func kilobitsPerSecond(_ bitsPerSecond: Int?) -> Int? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return bitsPerSecond }
        return max(1, bitsPerSecond / 1000)
    }

    /// The user's own 0–5 rating. `preciserating` is the same value as a decimal on
    /// older servers; `averagerating` is deliberately ignored because it's everyone
    /// else's opinion, not this user's.
    private static func rating(_ node: XmlNode) -> Int? {
        let raw = childText(node, "rating")
            ?? node.attributes["rating"]
            ?? childText(node, "preciserating")
            ?? node.attributes["preciserating"]
        guard let raw, let value = Double(raw) else { return nil }
        return max(0, min(5, Int(value.rounded())))
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
