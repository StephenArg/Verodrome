import Foundation

/// Persisted `[oldId: newId]` map for one canonical-ID epoch transition. Written to disk
/// **before** any DB or file remap happens, so a crash mid-migration can be resumed on
/// the next launch, and kept afterwards as the inverse map for the backward branch.
///
/// One file per account (keyed by `AccountInfo.Key.storageKey`), which mirrors how the
/// mutation outbox and play queue are scoped. Multiple entity types share one file:
/// entities are namespaced by kind so a song and an album that happen to share the same
/// pre-migration ID never collide.
public struct NavidromeIdMap: Codable, Sendable, Equatable {

    /// Which entity type an entry belongs to. Matches the SwiftData model names.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case song
        case album
        case artist
        case playlist
        case directory
        case podcast
        case podcastEpisode
        case radio
    }

    /// One old→new pair for a specific entity kind.
    public struct Entry: Codable, Sendable, Equatable, Hashable {
        public let kind: Kind
        public let oldId: String
        public let newId: String

        public init(kind: Kind, oldId: String, newId: String) {
            self.kind = kind
            self.oldId = oldId
            self.newId = newId
        }
    }

    /// The version the map was built against — the "to" epoch. When the marker rolls back
    /// to a lower epoch, this tells the migration which map to invert.
    public var toVersion: String
    /// The version the map came from (best-effort — nil when unknown). Sanity-checked
    /// against the reported version when applying the inverse.
    public var fromVersion: String?
    /// When the map was persisted. Informational.
    public var createdAt: Date
    /// True after the DB rewrite has succeeded end-to-end. A false value on disk means
    /// the last run crashed part-way through and the entries below still need to be
    /// applied — resume, don't rebuild.
    public var applied: Bool
    public var entries: [Entry]

    public init(
        toVersion: String,
        fromVersion: String? = nil,
        createdAt: Date = .now,
        applied: Bool = false,
        entries: [Entry] = []
    ) {
        self.toVersion = toVersion
        self.fromVersion = fromVersion
        self.createdAt = createdAt
        self.applied = applied
        self.entries = entries
    }

    /// Compact per-kind lookup, keyed by old ID. Multiple kinds may share the same
    /// old-ID string (e.g. two entities that happened to encode to the same base62), so
    /// callers must scope by kind before looking up.
    public func forwardLookup(kind: Kind) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(entries.count)
        for entry in entries where entry.kind == kind {
            out[entry.oldId] = entry.newId
        }
        return out
    }

    /// Inverse map for the epoch-regression path. Applying the returned pairs undoes
    /// the forward rewrite exactly, so a restored-from-backup Navidrome sees its old IDs
    /// again.
    public func inverse() -> NavidromeIdMap {
        var flipped: [Entry] = []
        flipped.reserveCapacity(entries.count)
        for entry in entries {
            flipped.append(Entry(kind: entry.kind, oldId: entry.newId, newId: entry.oldId))
        }
        return NavidromeIdMap(
            toVersion: fromVersion ?? "unknown",
            fromVersion: toVersion,
            createdAt: .now,
            applied: false,
            entries: flipped
        )
    }
}

/// Reads and writes `id-epoch-map-{account}.json` under Application Support. One instance
/// per migration invocation — this is not a live cache; the DB is the source of truth
/// after a successful run.
public struct NavidromeIdMapStore: Sendable {
    public let directory: URL
    public let accountKey: String

    public init(accountKey: String, directory: URL? = nil) {
        self.accountKey = accountKey
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Under Application Support so the file survives cache eviction — losing this file
    /// makes the backward branch unrecoverable without a full re-sync.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeIdMigration", isDirectory: true)
    }

    public var fileURL: URL {
        directory.appendingPathComponent("id-epoch-map-\(accountKey).json")
    }

    /// Load the map from disk. Returns nil when nothing is stored, or when the file is
    /// present but unreadable (which is treated as absent so the migration can rebuild
    /// rather than throw).
    public func load() -> NavidromeIdMap? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(NavidromeIdMap.self, from: data)
    }

    /// Persist atomically. Creates the directory on demand.
    public func save(_ map: NavidromeIdMap) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(map)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Deletes the map. Used when a run is aborted before applying, so the next launch
    /// starts fresh instead of resuming a torn map.
    public func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
