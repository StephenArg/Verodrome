import Foundation

public enum RecentQueueKind: String, Codable, Sendable {
    case album
    case playlist
}

public struct RecentQueueEntry: Codable, Sendable, Equatable, Identifiable {
    public var kind: RecentQueueKind
    public var compoundRemoteId: String
    public var title: String
    public var subtitle: String?
    public var artworkToken: String?
    public var playedAt: Date

    public var id: String { "\(kind.rawValue)|\(compoundRemoteId)" }

    public init(
        kind: RecentQueueKind,
        compoundRemoteId: String,
        title: String,
        subtitle: String? = nil,
        artworkToken: String? = nil,
        playedAt: Date = Date()
    ) {
        self.kind = kind
        self.compoundRemoteId = compoundRemoteId
        self.title = title
        self.subtitle = subtitle
        self.artworkToken = artworkToken
        self.playedAt = playedAt
    }
}

/// Last 20 album and playlist queues the user started. Shuffle All and other
/// implicit queues are not recorded — only explicit `record(album:)` / `record(playlist:)`.
@MainActor
public final class RecentQueueStore: ObservableObject {
    public static let shared = RecentQueueStore(
        accountKey: { AccountStore.shared.activeAccountKey()?.storageKey }
    )
    public static let limit = 20
    private static let keyPrefix = "recents.albumPlaylistQueues."

    @Published public private(set) var entries: [RecentQueueEntry] = []

    private let defaults: UserDefaults
    private let accountKey: () -> String?

    public init(
        defaults: UserDefaults = .standard,
        accountKey: @escaping () -> String? = { nil }
    ) {
        self.defaults = defaults
        self.accountKey = accountKey
        entries = Self.load(from: defaults, key: Self.storageKey(accountKey()))
    }

    public func reload() {
        let loaded = Self.load(from: defaults, key: Self.storageKey(accountKey()))
        if loaded != entries {
            entries = loaded
        }
    }

    public func record(album: Album) {
        record(
            RecentQueueEntry(
                kind: .album,
                compoundRemoteId: album.compoundRemoteId,
                title: album.title,
                subtitle: album.artistName ?? album.artist?.name,
                artworkToken: album.artworkToken
            )
        )
    }

    public func record(playlist: Playlist) {
        record(
            RecentQueueEntry(
                kind: .playlist,
                compoundRemoteId: playlist.compoundRemoteId,
                title: playlist.name,
                subtitle: playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs",
                artworkToken: playlist.displayArtworkToken
            )
        )
    }

    public func record(_ entry: RecentQueueEntry) {
        let id = entry.compoundRemoteId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        var next = entries
        next.removeAll { $0.id == entry.id }
        var updated = entry
        updated.playedAt = Date()
        next.insert(updated, at: 0)
        if next.count > Self.limit {
            next = Array(next.prefix(Self.limit))
        }
        entries = next
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey(accountKey()))
    }

    private static func storageKey(_ accountKey: String?) -> String {
        "\(keyPrefix)\(accountKey ?? "none")"
    }

    private static func load(from defaults: UserDefaults, key: String) -> [RecentQueueEntry] {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([RecentQueueEntry].self, from: data) else {
            return []
        }
        return Array(saved.prefix(limit))
    }
}
