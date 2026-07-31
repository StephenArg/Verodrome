import BackgroundTasks
import Foundation

@MainActor
public final class BackgroundLibrarySyncer {
    public static let taskIdentifier = BackgroundFetchSyncer.taskIdentifier

    private let syncerProvider: () -> (any LibrarySyncer)?
    private let autoDownloadProvider: () -> AutoDownloadSyncer?
    private let autoCacheNewestProvider: () -> Bool
    private let newestLimit: Int

    public init(
        syncerProvider: @escaping () -> (any LibrarySyncer)? = { nil },
        autoDownloadProvider: @escaping () -> AutoDownloadSyncer? = { nil },
        autoCacheNewestProvider: @escaping () -> Bool = { false },
        newestLimit: Int = 40
    ) {
        self.syncerProvider = syncerProvider
        self.autoDownloadProvider = autoDownloadProvider
        self.autoCacheNewestProvider = autoCacheNewestProvider
        self.newestLimit = newestLimit
    }

    public func syncNewest() async {
        guard let syncer = syncerProvider() else { return }
        let songIds = (try? await syncer.syncNewestAlbums(limit: newestLimit)) ?? []

        if let account = try? VerodromeKit.shared.activeAccount(),
           let storage = VerodromeKit.shared.storage {
            do {
                let remotePlaylistIds = try await syncer.syncPlaylistCatalog()
                _ = try LibraryPruner.prunePlaylists(
                    account: account,
                    keepingRemoteIds: Set(remotePlaylistIds),
                    context: storage.mainContext
                )
            } catch {
                await EventLogger.shared.warning("sync", "Playlist reconcile failed: \(error.localizedDescription)")
            }
        }

        guard autoCacheNewestProvider(), !songIds.isEmpty else { return }
        await autoDownloadProvider()?.download(playableIds: songIds, kind: .song)
    }

    public static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleNext()
            let work = Task { @MainActor in
                await BackgroundFetchSyncer.shared?.run()
            }
            refresh.expirationHandler = { work.cancel() }
            Task {
                _ = await work.result
                refresh.setTaskCompleted(success: true)
            }
        }
    }

    public static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
