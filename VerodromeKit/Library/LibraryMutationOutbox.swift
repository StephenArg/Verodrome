import Foundation

/// A library write that could not reach the server and should be replayed later.
public enum PendingLibraryMutation: Codable, Equatable, Sendable {
    case setFavorite(entityId: String, type: LibraryEntityType, isFavorite: Bool)
    case setRating(entityId: String, type: LibraryEntityType, rating: Int)
    /// `localId` is the placeholder `Playlist.remoteId` created while offline; remapped
    /// to the server id after `createPlaylist` succeeds.
    case createPlaylist(localId: String, name: String)
    case renamePlaylist(playlistId: String, name: String)
    case addToPlaylist(playlistId: String, songIds: [String])
    /// Song ids, not entry indices — indices drift while offline.
    case removeFromPlaylist(playlistId: String, songIds: [String])
    case reorderPlaylist(playlistId: String, songIds: [String])

    /// Playlist id referenced by this mutation, if any.
    var playlistId: String? {
        switch self {
        case .createPlaylist(let localId, _): return localId
        case .renamePlaylist(let playlistId, _),
             .addToPlaylist(let playlistId, _),
             .removeFromPlaylist(let playlistId, _),
             .reorderPlaylist(let playlistId, _):
            return playlistId
        case .setFavorite, .setRating:
            return nil
        }
    }
}

/// Durable per-account queue of library mutations waiting for the network.
///
/// Favorites and ratings coalesce to last-write-wins for the same entity. Playlist
/// edits stay ordered — add/remove/reorder are not safe to collapse across each other.
public actor LibraryMutationOutbox {
    private let directory: URL
    private var accountKey: String?
    private var pending: [PendingLibraryMutation] = []
    private var loaded = false

    public init(directory: URL? = nil, accountKey: String? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.accountKey = accountKey
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeMutationOutbox", isDirectory: true)
    }

    public func setAccount(_ key: String?) {
        accountKey = key
        pending = []
        loaded = false
    }

    public func enqueue(_ mutation: PendingLibraryMutation) {
        loadIfNeeded()
        switch mutation {
        case .setFavorite(let entityId, let type, _):
            pending.removeAll {
                if case .setFavorite(let id, let t, _) = $0 { return id == entityId && t == type }
                return false
            }
        case .setRating(let entityId, let type, _):
            pending.removeAll {
                if case .setRating(let id, let t, _) = $0 { return id == entityId && t == type }
                return false
            }
        case .renamePlaylist(let playlistId, _):
            pending.removeAll {
                if case .renamePlaylist(let id, _) = $0 { return id == playlistId }
                return false
            }
        case .reorderPlaylist(let playlistId, _):
            pending.removeAll {
                if case .reorderPlaylist(let id, _) = $0 { return id == playlistId }
                return false
            }
        case .createPlaylist, .addToPlaylist, .removeFromPlaylist:
            break
        }
        pending.append(mutation)
        persist()
    }

    public func all() -> [PendingLibraryMutation] {
        loadIfNeeded()
        return pending
    }

    public var isEmpty: Bool {
        loadIfNeeded()
        return pending.isEmpty
    }

    /// True when a local favorite/rating write for this song hasn't reached the server yet.
    /// A server pull must not overwrite that optimistic state.
    public func hasPendingSongMetadata(songId: String) -> Bool {
        loadIfNeeded()
        return pending.contains { mutation in
            switch mutation {
            case .setFavorite(let entityId, .song, _),
                 .setRating(let entityId, .song, _):
                return entityId == songId
            default:
                return false
            }
        }
    }

    /// Replaces the queue after a flush attempt (successful prefix removed, rest kept).
    public func replaceAll(_ mutations: [PendingLibraryMutation]) {
        loadIfNeeded()
        pending = mutations
        persist()
    }

    /// Rewrites playlist ids after an offline-created playlist receives a server id.
    public func remapPlaylistId(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        loadIfNeeded()
        pending = pending.map { mutation in
            switch mutation {
            case .createPlaylist(let localId, let name):
                return localId == oldId ? .createPlaylist(localId: newId, name: name) : mutation
            case .renamePlaylist(let playlistId, let name):
                return playlistId == oldId ? .renamePlaylist(playlistId: newId, name: name) : mutation
            case .addToPlaylist(let playlistId, let songIds):
                return playlistId == oldId ? .addToPlaylist(playlistId: newId, songIds: songIds) : mutation
            case .removeFromPlaylist(let playlistId, let songIds):
                return playlistId == oldId ? .removeFromPlaylist(playlistId: newId, songIds: songIds) : mutation
            case .reorderPlaylist(let playlistId, let songIds):
                return playlistId == oldId ? .reorderPlaylist(playlistId: newId, songIds: songIds) : mutation
            case .setFavorite, .setRating:
                return mutation
            }
        }
        persist()
    }

    public func clear() {
        pending = []
        loaded = true
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            pending = []
            return
        }
        do {
            pending = try JSONDecoder().decode([PendingLibraryMutation].self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            pending = []
            Task { await EventLogger.shared.warning("library", "Discarded unreadable mutation outbox: \(error.localizedDescription)") }
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if pending.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let data = try JSONEncoder().encode(pending)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Task { await EventLogger.shared.warning("library", "Couldn't store mutation outbox: \(error.localizedDescription)") }
        }
    }

    private var fileURL: URL? {
        guard let accountKey else { return nil }
        return directory.appendingPathComponent("\(accountKey).json")
    }
}
