import Combine
import Foundation

/// Replays queued library mutations once the network (and offline mode) allow it.
@MainActor
public final class LibraryMutationSyncer {
    private let outbox: LibraryMutationOutbox
    private let syncerProvider: @MainActor () -> (any LibrarySyncer)?
    private let repositoryProvider: @MainActor () -> LibraryRepository?
    private let accountProvider: @MainActor () -> Account?
    private let monitor: NetworkMonitor
    private let isOfflineMode: @MainActor () -> Bool
    private let onScrobbleFlush: (@MainActor () async -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var offlineModeObserver: NSObjectProtocol?
    private var isFlushing = false
    private var wasOnline: Bool?

    public init(
        outbox: LibraryMutationOutbox,
        monitor: NetworkMonitor = .shared,
        isOfflineMode: @escaping @MainActor () -> Bool,
        syncerProvider: @escaping @MainActor () -> (any LibrarySyncer)?,
        repositoryProvider: @escaping @MainActor () -> LibraryRepository?,
        accountProvider: @escaping @MainActor () -> Account?,
        onScrobbleFlush: (@MainActor () async -> Void)? = nil
    ) {
        self.outbox = outbox
        self.monitor = monitor
        self.isOfflineMode = isOfflineMode
        self.syncerProvider = syncerProvider
        self.repositoryProvider = repositoryProvider
        self.accountProvider = accountProvider
        self.onScrobbleFlush = onScrobbleFlush

        monitor.$isConnected
            .sink { [weak self] connected in
                Task { @MainActor in
                    guard let self else { return }
                    let online = connected && !self.isOfflineMode()
                    let was = self.wasOnline
                    self.wasOnline = online
                    // Flush on the transition back online, not on every path tick.
                    if online, was == false {
                        await self.flush()
                    }
                }
            }
            .store(in: &cancellables)

        offlineModeObserver = NotificationCenter.default.addObserver(
            forName: .offlineModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let online = self.monitor.isConnected && !self.isOfflineMode()
                let was = self.wasOnline
                self.wasOnline = online
                if online, was == false {
                    await self.flush()
                }
            }
        }
    }

    deinit {
        if let offlineModeObserver {
            NotificationCenter.default.removeObserver(offlineModeObserver)
        }
    }

    /// Whether the outbox may talk to the server right now.
    public var canFlush: Bool {
        monitor.isConnected && !isOfflineMode() && syncerProvider() != nil
    }

    /// Applies every pending mutation that the server will accept. Stops on the first
    /// transient network failure so the remainder stay queued.
    public func flush() async {
        guard !isFlushing else { return }
        guard canFlush, let syncer = syncerProvider() else { return }
        isFlushing = true
        defer { isFlushing = false }

        await onScrobbleFlush?()

        while true {
            let pending = await outbox.all()
            guard let head = pending.first else { return }

            do {
                try await apply(head, syncer: syncer)
                // `createPlaylist` remaps ids inside the outbox but leaves the create
                // entry at the front (now bearing the server id). Drop it either way.
                var rest = await outbox.all()
                if !rest.isEmpty { rest.removeFirst() }
                await outbox.replaceAll(rest)
            } catch {
                if Self.isRetriableNetworkError(error) {
                    await EventLogger.shared.warning(
                        "library",
                        "Paused mutation outbox flush: \(error.localizedDescription)"
                    )
                    return
                }
                noteRejectedPlaylist(for: head, error: error)
                var rest = pending
                rest.removeFirst()
                await outbox.replaceAll(rest)
                await EventLogger.shared.warning(
                    "library",
                    "Dropped failed library mutation: \(error.localizedDescription)"
                )
            }
        }
    }

    private func apply(_ mutation: PendingLibraryMutation, syncer: any LibrarySyncer) async throws {
        switch mutation {
        case .setFavorite(let entityId, let type, let isFavorite):
            try await syncer.setFavorite(entityId: entityId, type: type, isFavorite: isFavorite)
        case .setRating(let entityId, let type, let rating):
            try await syncer.setRating(entityId: entityId, type: type, rating: rating)
        case .createPlaylist(let localId, let name):
            let serverId = try await syncer.createPlaylist(name: name)
            await adoptServerPlaylistId(localId: localId, serverId: serverId)
        case .renamePlaylist(let playlistId, let name):
            try await syncer.renamePlaylist(id: playlistId, name: name)
        case .addToPlaylist(let playlistId, let songIds):
            try await syncer.addToPlaylist(playlistId: playlistId, songIds: songIds)
            try? await syncer.syncPlaylistDown(id: playlistId)
        case .removeFromPlaylist(let playlistId, let songIds):
            try await removeSongs(songIds, from: playlistId, syncer: syncer)
        case .reorderPlaylist(let playlistId, let songIds):
            try await syncer.reorderPlaylist(playlistId: playlistId, songIds: songIds)
            try? await syncer.syncPlaylistDown(id: playlistId)
        }
    }

    private func removeSongs(
        _ songIds: [String],
        from playlistId: String,
        syncer: any LibrarySyncer
    ) async throws {
        // Refresh so entry indices match the server before addressing by position.
        try? await syncer.syncPlaylistDown(id: playlistId)
        guard let repository = repositoryProvider(),
              let account = accountProvider(),
              let playlist = try? repository.fetchPlaylist(
                compoundRemoteId: Playlist.makeCompoundRemoteId(account: account, remoteId: playlistId)
              )
        else { return }
        let ordered = playlist.items.sorted { $0.order < $1.order }.compactMap(\.song)
        let wanted = Set(songIds)
        let indices = ordered.indices.filter { wanted.contains(ordered[$0].remoteId) }
        guard !indices.isEmpty else { return }
        try await syncer.removeFromPlaylist(playlistId: playlistId, entryIndices: indices)
        try? await syncer.syncPlaylistDown(id: playlistId)
    }

    private func adoptServerPlaylistId(localId: String, serverId: String) async {
        if localId != serverId,
           let repository = repositoryProvider(),
           let account = accountProvider(),
           let playlist = try? repository.fetchPlaylist(
            compoundRemoteId: Playlist.makeCompoundRemoteId(account: account, remoteId: localId)
           ) {
            playlist.remoteId = serverId
            playlist.compoundRemoteId = Playlist.makeCompoundRemoteId(account: account, remoteId: serverId)
            try? repository.save()
        }
        await outbox.remapPlaylistId(from: localId, to: serverId)
    }

    private func noteRejectedPlaylist(for mutation: PendingLibraryMutation, error: Error) {
        guard let playlistId = mutation.playlistId,
              let repository = repositoryProvider(),
              let account = accountProvider(),
              let playlist = try? repository.fetchPlaylist(
                compoundRemoteId: Playlist.makeCompoundRemoteId(account: account, remoteId: playlistId)
              )
        else { return }
        _ = LibraryActions.shared.notePlaylistEditRejected(playlist, error: error)
    }

    nonisolated public static func isRetriableNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let syncerError = error as? LibrarySyncerError, case .offline = syncerError { return true }
        if let backend = error as? BackendError, case .network = backend { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain
    }
}
