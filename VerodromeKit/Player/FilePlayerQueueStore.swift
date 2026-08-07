import Foundation

/// Keeps the play queue on disk between launches.
///
/// Scoped per account: a queue is a list of playable ids, and those only mean anything
/// against the library they were taken from. With no account there is nowhere to write,
/// so every call is a no-op rather than a shared file the next login would inherit.
///
/// The context and the "Added to Queue" run are separate files. Adding a track only
/// rewrites the small user-queue file; the album / playlist context stays put.
public actor FilePlayerQueueStore: PlayerQueuePersisting {
    private let directory: URL
    private var accountKey: String?

    public init(directory: URL? = nil, accountKey: String? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.accountKey = accountKey
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeQueue", isDirectory: true)
    }

    /// Points the store at another account's queue file. Switching accounts mid-session
    /// must not write one library's queue over another's.
    public func setAccount(_ key: String?) {
        accountKey = key
    }

    public func loadQueue() async -> PersistedPlayerQueue? {
        guard let fileURL = contextFileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedPlayerQueue.self, from: data)
        } catch {
            // A queue that can't be read is not worth keeping around to fail again.
            try? FileManager.default.removeItem(at: fileURL)
            await EventLogger.shared.warning("player", "Discarded unreadable stored queue: \(error.localizedDescription)")
            return nil
        }
    }

    public func saveQueue(_ snapshot: PersistedPlayerQueue) async {
        guard let fileURL = contextFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // User-queued rows have their own file; never embed them in the context write.
            var contextOnly = snapshot
            contextOnly.user = []
            let data = try JSONEncoder().encode(contextOnly)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            await EventLogger.shared.warning("player", "Couldn't store the play queue: \(error.localizedDescription)")
        }
    }

    public func loadUserQueue() async -> [QueueItem] {
        guard let fileURL = userFileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([QueueItem].self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            await EventLogger.shared.warning("player", "Discarded unreadable Added-to-Queue list: \(error.localizedDescription)")
            return []
        }
    }

    public func saveUserQueue(_ items: [QueueItem]) async {
        guard let fileURL = userFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if items.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            await EventLogger.shared.warning("player", "Couldn't store Added-to-Queue: \(error.localizedDescription)")
        }
    }

    public func clearQueue() async {
        if let contextFileURL {
            try? FileManager.default.removeItem(at: contextFileURL)
        }
        if let userFileURL {
            try? FileManager.default.removeItem(at: userFileURL)
        }
    }

    private var contextFileURL: URL? {
        guard let accountKey, !accountKey.isEmpty else { return nil }
        return directory.appendingPathComponent("queue-\(accountKey).json", isDirectory: false)
    }

    private var userFileURL: URL? {
        guard let accountKey, !accountKey.isEmpty else { return nil }
        return directory.appendingPathComponent("user-queue-\(accountKey).json", isDirectory: false)
    }
}
