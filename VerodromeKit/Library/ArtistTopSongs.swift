import Foundation

/// Visibility rules for the artist-page Popular section.
///
/// The server list is Last.fm via `getTopSongs`; this helper only decides whether
/// that list is worth showing and how many rows to keep.
public enum ArtistTopSongs {
    public static let sectionTitle = "Popular"
    /// How many ranked rows the artist page shows before "Show More".
    public static let displayLimit = 5
    /// How many library matches to keep from `getTopSongs` (the expanded list).
    public static let keptLimit = 9
    /// Hide the section unless this many of the top-song list exist in the library.
    public static let minimumLibraryMatches = 3
    /// Hide (and skip the fetch) unless the artist has more than this many songs.
    public static let minimumArtistSongs = 10
    /// Ask the server for the expanded cap — it already filters to library tracks.
    public static let fetchCount = keptLimit

    /// Last.fm `getTopSongs` is Subsonic-only. Ampache has no equivalent.
    public static func isSupported(on apiType: ApiType?) -> Bool {
        apiType != .ampache
    }

    public static func shouldFetch(artistSongCount: Int) -> Bool {
        artistSongCount > minimumArtistSongs
    }

    /// Full list to cache and expand into, or empty when the section should stay hidden.
    public static func visibleSongs<T>(from matches: [T], artistSongCount: Int) -> [T] {
        guard shouldFetch(artistSongCount: artistSongCount) else { return [] }
        guard matches.count >= minimumLibraryMatches else { return [] }
        return Array(matches.prefix(keptLimit))
    }

    /// Rows on screen: five until the user asks for the rest.
    public static func displayedSongs<T>(from kept: [T], expanded: Bool) -> [T] {
        Array(kept.prefix(expanded ? keptLimit : displayLimit))
    }

    public static func showsMoreControl(keptCount: Int) -> Bool {
        keptCount > displayLimit
    }

    /// Ranked identity of a Popular list — used to skip a UI refresh when revalidate
    /// returns the same tracks in the same order.
    public static func rankedIds(of songs: [IngestSong]) -> [String] {
        songs.map(\.id)
    }

    public static func listsMatch(_ lhs: [IngestSong], _ rhs: [IngestSong]) -> Bool {
        rankedIds(of: lhs) == rankedIds(of: rhs)
    }

    public static func fetchVisible(
        artistId: String,
        artistName: String,
        songCount: Int,
        provider: any TopSongProviding
    ) async throws -> [IngestSong] {
        let matches = try await provider.topSongs(
            artistId: artistId,
            artistName: artistName,
            count: fetchCount
        )
        return visibleSongs(from: matches, artistSongCount: songCount)
    }
}

/// In-memory + on-disk cache of an artist's Popular list, keyed by compound artist id.
///
/// Memory hits are synchronous so revisiting an artist in the same session paints the
/// section on the first frame. Disk fills that map after a cold launch.
@MainActor
public final class ArtistPopularSongsCache {
    public static let shared = ArtistPopularSongsCache()

    private var memory: [String: [IngestSong]] = [:]
    private let store: ArtistPopularSongsStore

    public init(store: ArtistPopularSongsStore = ArtistPopularSongsStore()) {
        self.store = store
    }

    /// Instant if this artist was opened this session (or after `load` finished).
    public func cached(forArtistCompoundId id: String) -> [IngestSong]? {
        memory[id]
    }

    public func load(forArtistCompoundId id: String) async -> [IngestSong]? {
        if let cached = memory[id] { return cached }
        let songs = await store.songs(for: id)
        if let songs { memory[id] = songs }
        return songs
    }

    /// Pulls every disk entry into memory so `cached` is instant after a cold launch.
    public func loadAll() async {
        let entries = await store.allEntries()
        for (id, songs) in entries where memory[id] == nil {
            memory[id] = songs
        }
    }

    public func store(_ songs: [IngestSong], forArtistCompoundId id: String) async {
        memory[id] = songs
        await store.store(songs, for: id)
    }

    public func remove(forArtistCompoundId id: String) async {
        memory[id] = nil
        await store.remove(id)
    }

    public func removeAll() async {
        memory = [:]
        await store.removeAll()
    }

    public func entryCount() async -> Int {
        await loadAll()
        return memory.count
    }

    public func byteSize() async -> Int64 {
        await store.byteSize()
    }
}

/// JSON map of compound artist id → Popular tracks, kept between launches.
public actor ArtistPopularSongsStore {
    private let fileURL: URL
    private var entries: [String: [IngestSong]]?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeArtistPopular", isDirectory: true)
            .appendingPathComponent("popular.json", isDirectory: false)
    }

    public func songs(for key: String) -> [IngestSong]? {
        loaded()[key]
    }

    public func allEntries() -> [String: [IngestSong]] {
        loaded()
    }

    public func store(_ songs: [IngestSong], for key: String) {
        var current = loaded()
        current[key] = songs
        entries = current
        write(current)
    }

    public func remove(_ key: String) {
        var current = loaded()
        guard current.removeValue(forKey: key) != nil else { return }
        entries = current
        write(current)
    }

    public func removeAll() {
        entries = [:]
        write([:])
    }

    public func byteSize() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
    }

    private func loaded() -> [String: [IngestSong]] {
        if let entries { return entries }
        let decoded: [String: [IngestSong]]
        if let data = try? Data(contentsOf: fileURL),
           let parsed = try? JSONDecoder().decode([String: [IngestSong]].self, from: data) {
            decoded = parsed
        } else {
            decoded = [:]
        }
        entries = decoded
        return decoded
    }

    private func write(_ entries: [String: [IngestSong]]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Popular lists are cheap to refetch; a failed write only costs one getTopSongs.
        }
    }
}
