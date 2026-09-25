import Foundation
import SwiftData
import Combine

@MainActor
public final class VerodromeKit: ObservableObject {
    public static let shared = VerodromeKit()

    public let settings = SettingsStore.shared
    public let settingsStore = SettingsStore.shared
    public let observableSettings = ObservableSettings()
    public let networkMonitor = NetworkMonitor.shared
    public let accountStore = AccountStore.shared
    public let librarySync = LibrarySyncCoordinator.shared
    public let eventLogger = EventLogger.shared

    public private(set) var storage: PersistentStorage?
    public private(set) var backendProxy = BackendProxy()
    public private(set) var player: PlayerFacadeImpl?
    private var audioOrchestrator: AudioPlayer?
    public private(set) var queueHandler: PlayQueueHandler?
    public private(set) var queueStore: FilePlayerQueueStore?
    public private(set) var queueCachePolicy: QueueCachePolicyManager?
    public private(set) var popularPrefetch: ArtistPopularSongsPrefetcher?
    public private(set) var downloadManager: DownloadManager?
    public private(set) var playlistDownloads: PlaylistDownloadCoordinator?
    public private(set) var downloadNetworkPolicy: DownloadNetworkPolicy?
    public private(set) var artworkDownloadManager: ArtworkDownloadManager?
    public private(set) var playableCache: FilePlayableCache?
    public private(set) var lyricsCache: LyricsCache?
    public private(set) var libraryMutationOutbox: LibraryMutationOutbox?
    public private(set) var libraryMutationSyncer: LibraryMutationSyncer?
    public private(set) var scrobbleSyncer: ScrobbleSyncer?
    public private(set) var audioSessionHandler = AudioSessionHandler()
    public private(set) var nowPlayingHandler = NowPlayingInfoCenterHandler()
    public private(set) var remoteCommandHandler = RemoteCommandCenterHandler()
    public private(set) var isInitialized = false
    public private(set) var activeLibrarySyncer: (any LibrarySyncer)?
    /// The ingester behind `activeLibrarySyncer`, so on-demand fetches outside a sync can
    /// still persist what they pulled.
    public private(set) var activeLibraryIngester: (any LibraryIngesting)?
    public let artworkResolver = ArtworkResolver.shared

    @Published public var syncProgressMessage: String = ""
    @Published public var launchPhase: LaunchPhase = .loading
    /// Full-screen overlay while canonical IDs are probed/rewritten. The rewrite itself
    /// is main-actor SwiftData work, so this flag is published and a frame is yielded
    /// *before* that work so the overlay can actually paint.
    @Published public private(set) var isRemappingCanonicalIds = false
    @Published public private(set) var idMigrationStatusText = "Updating library IDs…"
    /// Coalesces overlapping `ensureActiveLibrarySyncer` calls (initialize, Home, background
    /// sync) so the ID gate cannot present/dismiss the overlay three times on one launch.
    private var inFlightEnsureSyncer: Task<(any LibrarySyncer)?, Error>?
    private var overlayRetainCount = 0
    /// Overlapping REST calls can all come back `40` at once; one sign-out is enough.
    private var isLoggingOutForInvalidCredentials = false
    private var credentialsRejectedObserver: (any NSObjectProtocol)?

    public enum LaunchPhase: Equatable {
        case loading, login, syncing, main
    }

    private init() {}

    public var userSettings: UserSettings { settings.loadUserSettings() }
    public var appSettings: AppSettings { settings.loadAppSettings() }

    public func initialize(inMemory: Bool = false) async {
        if isInitialized { return }
        observeCredentialFailures()
        // Bind account settings before anything reads `observableSettings.account`.
        // Without this, cold launch leaves the in-memory copy at `.default`, the
        // canonical-ID gate sees a nil server type, and streaming keeps pre-0.64 IDs.
        if let key = accountStore.activeAccountKey() {
            observableSettings.reload(accountKey: key)
        }
        let storage = inMemory ? PersistentStorage(inMemory: true) : PersistentStorage.shared
        self.storage = storage
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromePlayables", isDirectory: true)
        let cache = FilePlayableCache(root: cacheRoot)
        self.playableCache = cache

        let lyricsRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeLyrics", isDirectory: true)
        let lyrics = LyricsCache(root: lyricsRoot)
        self.lyricsCache = lyrics

        let urlProvider = BackendURLProvider(backend: backendProxy)
        let downloader = DownloadManager(urlProvider: urlProvider, cache: cache, isOffline: settings.offlineModeEnabled)
        self.downloadManager = downloader

        let artRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerodromeArtwork", isDirectory: true)
        let artManager = ArtworkDownloadManager(urlProvider: urlProvider, cacheDirectory: artRoot)
        self.artworkDownloadManager = artManager
        artworkResolver.attach(manager: artManager)

        let queueStore = FilePlayerQueueStore(accountKey: accountStore.activeAccountKey()?.storageKey)
        self.queueStore = queueStore
        let queue = PlayQueueHandler(persister: queueStore)
        self.queueHandler = queue
        let backendPlayer = BackendAudioPlayer(urlProvider: urlProvider, cache: cache)
        let audio = AudioPlayer(queueHandler: queue, backend: backendPlayer, settings: { [weak self] in
            self?.settings.loadUserSettings() ?? .default
        })
        self.audioOrchestrator = audio
        let facade = PlayerFacadeImpl(audioPlayer: audio)
        self.player = facade
        facade.attachNowPlaying(nowPlayingHandler)
        facade.attachArtworkResolver(artworkResolver)

        // Bring the last session's queue back before anything else reads the player, so
        // the mini player and queue screen are populated on the first frame. The track
        // itself is loaded further down, once the backend can hand out a stream URL.
        await queue.loadFromDisk()

        let policy = QueueCachePolicyManager(
            queue: queue,
            cache: cache,
            downloader: downloader,
            artwork: artManager,
            settings: { [weak self] in self?.settings.loadUserSettings() ?? .default }
        )
        self.queueCachePolicy = policy

        let popularPrefetch = ArtistPopularSongsPrefetcher()
        self.popularPrefetch = popularPrefetch
        popularPrefetch.start()
        policy.onWindowItems = { [weak popularPrefetch] items in
            popularPrefetch?.prefetch(queueItems: items)
        }
        await ArtistPopularSongsCache.shared.loadAll()
        policy.start()

        let playlistDownloads = PlaylistDownloadCoordinator(
            downloader: downloader,
            syncerProvider: { [weak self] in self?.activeLibrarySyncer }
        )
        self.playlistDownloads = playlistDownloads

        let networkPolicy = DownloadNetworkPolicy(
            downloader: downloader,
            monitor: networkMonitor,
            settingProvider: { [weak self] in self?.settings.automaticDownloadNetwork ?? .wifiOnly }
        )
        networkPolicy.setAllowedHandler { [weak playlistDownloads] in
            await playlistDownloads?.reconcile()
        }
        self.downloadNetworkPolicy = networkPolicy
        await networkPolicy.apply()

        let mutationOutbox = LibraryMutationOutbox(accountKey: accountStore.activeAccountKey()?.storageKey)
        self.libraryMutationOutbox = mutationOutbox
        let mutationSyncer = LibraryMutationSyncer(
            outbox: mutationOutbox,
            monitor: networkMonitor,
            isOfflineMode: { [weak self] in self?.settings.offlineModeEnabled ?? false },
            syncerProvider: { [weak self] in self?.activeLibrarySyncer },
            repositoryProvider: { [weak self] in self?.repository() },
            accountProvider: { [weak self] in try? self?.activeAccount() },
            onScrobbleFlush: { [weak self] in await self?.scrobbleSyncer?.flush() }
        )
        self.libraryMutationSyncer = mutationSyncer

        let bg = BackgroundLibrarySyncer(
            syncerProvider: { [weak self] in self?.activeLibrarySyncer },
            autoDownloadProvider: { [weak self] in
                guard let downloader = self?.downloadManager else { return nil }
                return AutoDownloadSyncer(downloader: downloader)
            },
            autoCacheNewestProvider: { [weak self] in
                guard let key = self?.accountStore.activeAccountKey() else { return false }
                return self?.settings.loadAccountSettings(for: key).autoCacheNewest ?? false
            },
            playlistDownloadsProvider: { [weak self] in self?.playlistDownloads }
        )
        BackgroundFetchSyncer.shared = BackgroundFetchSyncer(
            librarySyncer: bg,
            policyPrune: { [weak policy] in Task { @MainActor in policy?.pruneStale() } }
        )

        audioSessionHandler.activate()
        audioSessionHandler.onInterrupt = { [weak facade] began in
            if began, facade?.isPlaying == true { facade?.togglePlayPause() }
            else if !began, facade?.isPlaying == false { facade?.togglePlayPause() }
        }
        remoteCommandHandler.bind(player: facade)
        refreshLaunchPhase()
        await AlbumExplicitTrackSync.backfillIfNeeded()
        isInitialized = true

        if accountStore.activeAccountKey() != nil {
            _ = try? await ensureActiveLibrarySyncer()
            // Re-auth with a stale password signs the account out. Don't keep restoring
            // a queue or kicking a sync for a session that is already gone.
            guard accountStore.activeAccountKey() != nil else { return }
            await restoreParkedTrack()
            // The download queue is memory only, so downloads the last session left
            // unfinished — or parked waiting for Wi-Fi — have to be put back on it.
            await playlistDownloads.resumePending()
            // Offline favorites / playlist edits from a previous session.
            await mutationSyncer.flush()
            // Cold launch: refresh catalog in background and resume track backfill if incomplete.
            librarySync.runBackground()
        }
    }

    /// Loads the restored queue's track paused, so the app comes back where it left off
    /// without playing on its own. Deliberately after authentication: a song's stream URL
    /// is minted per session and can't be restored from the stored queue.
    private func restoreParkedTrack() async {
        guard let queue = queueHandler, let audio = audioOrchestrator, queue.currentItem != nil else { return }
        await audio.restoreSession(at: queue.playbackPosition)
        player?.syncPublishedState()
    }

    /// Drops the playing queue when the library behind it goes away. The stored queue is
    /// left alone: it belongs to the account being left, and `repointQueueStore` decides
    /// whether that account is coming back.
    private func clearActiveQueue() {
        audioOrchestrator?.clearQueue(forgetStored: false)
        player?.syncPublishedState()
    }

    /// Hands the queue store to another account, or to none. Queued writes are drained
    /// first, so a snapshot of the account being left cannot land in the next one's file.
    private func repointQueueStore(to key: AccountInfo.Key?, forgetCurrent: Bool) async {
        await queueHandler?.flushPendingWrites()
        if forgetCurrent {
            await queueStore?.clearQueue()
            await libraryMutationOutbox?.clear()
        }
        await queueStore?.setAccount(key?.storageKey)
        await libraryMutationOutbox?.setAccount(key?.storageKey)
    }

    public func refreshLaunchPhase() {
        // Enter main immediately when logged in; catalog/track sync runs in the background.
        if accountStore.activeAccountKey() == nil {
            launchPhase = .login
        } else {
            launchPhase = .main
        }
    }

    /// Writes the scrub position and drains pending queue files. Call when leaving the
    /// foreground so a force-quit cannot take the last few seconds of progress with it.
    public func persistForBackground() async {
        player?.persistPlaybackPosition()
        await queueHandler?.flushPendingWrites()
    }

    /// Best-effort teardown when the process is about to die. Stops audio and releases
    /// the session first so silence lands quickly; persistence is kicked but not awaited
    /// because `applicationWillTerminate` will not wait for structured concurrency.
    public func haltForTermination() {
        player?.haltPlayback()
        nowPlayingHandler.clear()
        audioSessionHandler.deactivate()
        queueCachePolicy?.stop()
        Task { await downloadManager?.cancelAll() }
        Task { await queueHandler?.flushPendingWrites() }
    }

    public func login(credentials: LoginCredentials) async throws {
        let infoServer = try await backendProxy.login(credentials: credentials)
        let apiType = ApiType(backendProxy.apiType)
        let info = AccountInfo(serverURL: credentials.serverURL.absoluteString, username: credentials.username)
        let storedCreds = AccountCredentials(
            serverURL: info.serverURL,
            username: credentials.username,
            passwordToken: credentials.password
        )
        try accountStore.saveCredentials(storedCreds, for: info)
        accountStore.setActiveAccount(info)
        await repointQueueStore(to: info.key, forgetCurrent: false)
        observableSettings.reload(accountKey: info.key)
        rememberServerType(infoServer)
        observableSettings.updateAccount { $0.apiType = apiType }
        settings.isLibrarySynced = false
        settings.save()
        observableSettings.updateApp {
            $0.isLibrarySynced = false
            $0.tracksBackfillVersion = 0
        }
        if let storage {
            _ = try LibraryRepository(storage: storage).getOrCreateAccount(info: info, apiType: apiType)
        }
        launchPhase = .main
        NotificationCenter.default.post(name: .accountChanged, object: info)
        NotificationCenter.default.post(name: .backendAuthenticated, object: nil)
        _ = try? await ensureActiveLibrarySyncer()
        librarySync.runBackground()
    }

    /// Whether a background sync will crawl every song, not just the catalog and home lists.
    ///
    /// The song crawl runs once per backfill version, and only while the network is up.
    /// Home uses this so its progress bar stays hidden for the quicker pass.
    public func willBackfillAllSongs() -> Bool {
        settings.loadAppSettings().tracksBackfillVersion < AppSettings.currentTracksBackfillVersion
            && networkMonitor.isConnected
    }

    /// Whether the background pass has to walk the whole catalog before Home.
    ///
    /// Once a library is stored and its track backfill has run, the catalog belongs to
    /// Sync Now: paging every album on each launch was most of the routine refresh.
    /// New albums still land through the newest list below.
    func needsCatalogSync() -> Bool {
        guard settings.isLibrarySynced,
              settings.loadAppSettings().tracksBackfillVersion >= AppSettings.currentTracksBackfillVersion,
              let account = try? activeAccount(),
              let hasAlbums = try? repository()?.hasAlbums(account: account)
        else { return true }
        return !hasAlbums
    }

    /// Background refresh: catalog when `needsCatalogSync`, then Home lists, then the
    /// track backfill when it is still due. Does not block the UI.
    public func startBackgroundLibrarySync() async throws {
        guard let storage else { throw BackendError.unsupported }
        let syncer = try await ensureActiveLibrarySyncer()
        guard let syncer else { throw BackendError.notAuthenticated }

        // Push offline writes before a catalog pull can overwrite them.
        await libraryMutationSyncer?.flush()

        let progress: LibrarySyncProgressHandler = { [weak self] update in
            Task { @MainActor in
                self?.syncProgressMessage = update.message
                self?.librarySync.updateProgress(update)
            }
        }

        if needsCatalogSync() {
            try await syncer.syncCatalog(progress: progress)

            if let account = try? activeAccount() {
                _ = try? DuplicateMaintenance.resolveAll(account: account, context: storage.mainContext)
            }

            settings.isLibrarySynced = true
            settings.save()
            observableSettings.markLibrarySynced(version: max(1, settings.loadAppSettings().librarySyncVersion))
        }
        launchPhase = .main

        // Populate Home section ranks (newest / recent / favorites) without blocking browse.
        // Three unsized calls, so the bar holds at the end of the catalog phase rather
        // than sitting under a stale stage name.
        progress(LibrarySyncProgress(message: "Updating home…", fraction: LibrarySyncPhase.catalog.end))
        _ = try? await syncer.syncNewestAlbums(limit: 40, tracks: .missing)
        _ = try? await syncer.syncRecentAlbums(limit: 40)
        try? await syncer.syncFavoriteAlbums()
        popularPrefetch?.warmupLikelyArtists()

        guard willBackfillAllSongs() else { return }

        // Yield so Home / player UI can breathe before the heavy track crawl.
        try? await Task.sleep(nanoseconds: 500_000_000)

        do {
            try await syncer.syncAllSongs(progress: progress)
            await resolveDuplicatesInBackground()
            observableSettings.updateApp { $0.tracksBackfillVersion = AppSettings.currentTracksBackfillVersion }
        } catch {
            // Leave tracksBackfillVersion behind so the next cold launch / online period resumes.
            await EventLogger.shared.warning("sync", "Track backfill paused: \(error.localizedDescription)")
        }
    }

    /// Manual full sync (catalog + all tracks). Used by Library settings "Sync Now".
    public func performInitialSync() async throws {
        guard let storage else { throw BackendError.unsupported }
        let syncer = try await ensureActiveLibrarySyncer()
        guard let syncer else { throw BackendError.notAuthenticated }

        await libraryMutationSyncer?.flush()

        let progress: LibrarySyncProgressHandler = { [weak self] update in
            Task { @MainActor in
                self?.syncProgressMessage = update.message
                self?.librarySync.updateProgress(update)
            }
        }

        try await syncer.syncInitial(progress: progress)

        syncProgressMessage = "Resolving duplicates…"
        librarySync.updateProgress(LibrarySyncProgress(message: "Resolving duplicates…", fraction: 1))
        await resolveDuplicatesInBackground()

        settings.isLibrarySynced = true
        settings.save()
        observableSettings.markLibrarySynced(version: 1)
        observableSettings.updateApp { $0.tracksBackfillVersion = AppSettings.currentTracksBackfillVersion }
        launchPhase = .main
    }

    /// Manually merge duplicate library entities for the active account.
    @discardableResult
    public func resolveDuplicates() throws -> Int {
        guard let storage, let account = try activeAccount() else { return 0 }
        return try DuplicateMaintenance.resolveAll(account: account, context: storage.mainContext)
    }

    /// Duplicate resolution scans the whole library, so the sync flows run it on the
    /// background actor with the account re-resolved in that context.
    private func resolveDuplicatesInBackground() async {
        guard let storage, let key = accountStore.activeAccountKey() else { return }
        _ = try? await storage.backgroundActor.perform { context in
            let repository = LibraryRepository(context: context)
            guard let account = try repository.fetchAccount(key: key) else { return 0 }
            return try DuplicateMaintenance.resolveAll(account: account, context: context)
        }
    }

    public func logout() {
        backendProxy.logout()
        activeLibrarySyncer = nil
        activeLibraryIngester = nil
        ShareActions.shared.reset()
        // The account is about to be removed, so its stored queue goes with it.
        clearActiveQueue()
        Task { await repointQueueStore(to: nil, forgetCurrent: true) }
        settings.isLibrarySynced = false
        settings.save()
        observableSettings.updateApp {
            $0.isLibrarySynced = false
            $0.tracksBackfillVersion = 0
        }
        if let key = accountStore.activeAccountKey(),
           let stored = accountStore.allAccounts().first(where: { $0.info.key == key }) {
            accountStore.removeAccount(stored.info)
        } else {
            accountStore.setActiveAccount(nil)
        }
        launchPhase = .login
    }

    private func observeCredentialFailures() {
        guard credentialsRejectedObserver == nil else { return }
        credentialsRejectedObserver = NotificationCenter.default.addObserver(
            forName: .credentialsRejected,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                VerodromeKit.shared.logoutForInvalidCredentials()
            }
        }
    }

    /// Drops the session when the server says the stored username/password are wrong.
    /// Login probes (`BackendProxy.login`) are excluded so a typo on Add Account cannot
    /// sign out the account that is already working.
    func logoutForInvalidCredentials(matching error: Error? = nil) {
        if let error, !CredentialFailure.matches(error) { return }
        guard accountStore.activeAccountKey() != nil else { return }
        guard !isLoggingOutForInvalidCredentials else { return }
        isLoggingOutForInvalidCredentials = true
        defer { isLoggingOutForInvalidCredentials = false }

        if let credentials = accountStore.credentials {
            accountStore.rememberLoginPrefill(
                serverURL: credentials.serverURL,
                username: credentials.username
            )
        }
        accountStore.rememberError(
            "The server rejected this account's username or password. Please sign in again."
        )
        Task { await EventLogger.shared.warning("auth", "Server rejected stored credentials; signing out.") }
        accountStore.logout()
    }

    /// Switches the active account, re-authenticates the backend, and updates library-synced state.
    public func switchToAccount(_ info: AccountInfo) async throws {
        guard let stored = accountStore.allAccounts().first(where: { $0.info.key == info.key }) else {
            throw BackendError.notAuthenticated
        }
        accountStore.setActiveAccount(info)
        observableSettings.reload(accountKey: info.key)
        // The playing queue points at the previous library. Empty it, leaving that
        // account's stored queue for when the user comes back to it.
        clearActiveQueue()
        await repointQueueStore(to: info.key, forgetCurrent: false)

        guard let login = LoginCredentials(
            serverURLString: stored.credentials.serverURL,
            username: stored.credentials.username,
            password: stored.credentials.passwordToken
        ) else {
            throw BackendError.invalidURL
        }
        do {
            rememberServerType(try await backendProxy.login(credentials: login))
        } catch {
            logoutForInvalidCredentials(matching: error)
            throw error
        }
        _ = try await ensureActiveLibrarySyncer()
        await queueHandler?.loadFromDisk()
        await restoreParkedTrack()
        await libraryMutationSyncer?.flush()

        let hasLocalLibrary: Bool
        if let account = try activeAccount(), let repo = repository() {
            let hasArtists = !(try repo.fetchArtists(account: account)).isEmpty
            let hasAlbums = !(try repo.fetchAlbums(account: account)).isEmpty
            hasLocalLibrary = hasArtists || hasAlbums
        } else {
            hasLocalLibrary = false
        }
        settings.isLibrarySynced = hasLocalLibrary
        settings.save()
        if hasLocalLibrary {
            observableSettings.markLibrarySynced(version: max(1, settings.loadAppSettings().librarySyncVersion))
        } else {
            observableSettings.updateApp { $0.isLibrarySynced = false }
        }
        refreshLaunchPhase()
        NotificationCenter.default.post(name: .accountChanged, object: info)
        // Refresh catalog + resume backfill for the newly active account.
        librarySync.runBackground()
    }

    /// Removes a stored account. If it was active, falls back to another account or login.
    public func removeAccount(_ info: AccountInfo) async {
        let wasActive = accountStore.activeAccountKey() == info.key
        accountStore.removeAccount(info)
        if wasActive {
            activeLibrarySyncer = nil
            activeLibraryIngester = nil
            backendProxy.logout()
            ShareActions.shared.reset()
            // The removed account keeps no queue; `switchToAccount` below points the
            // store at whichever account takes over.
            clearActiveQueue()
            await repointQueueStore(to: nil, forgetCurrent: true)
            if let next = accountStore.allAccounts().first {
                try? await switchToAccount(next.info)
            } else {
                settings.isLibrarySynced = false
                settings.save()
                launchPhase = .login
            }
        }
        NotificationCenter.default.post(name: .accountChanged, object: nil)
    }

    /// Ensures backend auth + library syncer exist for the active account (e.g. after cold launch).
    @discardableResult
    public func ensureActiveLibrarySyncer() async throws -> (any LibrarySyncer)? {
        if let inFlightEnsureSyncer {
            return try await inFlightEnsureSyncer.value
        }
        let task = Task { @MainActor in
            try await self.performEnsureActiveLibrarySyncer()
        }
        inFlightEnsureSyncer = task
        defer { inFlightEnsureSyncer = nil }
        return try await task.value
    }

    private func performEnsureActiveLibrarySyncer() async throws -> (any LibrarySyncer)? {
        if let activeLibrarySyncer, backendProxy.isAuthenticated {
            await refreshServerTypeIfNeeded()
            // Re-check the ID migration gate even when a syncer already exists: a user
            // can upgrade Navidrome while the app sits in the foreground, and the
            // syncer that was minted at launch would otherwise never learn about it.
            // Same-epoch fast path is one settings read, so this is effectively free.
            await runCanonicalIdMigrationIfNeeded(syncer: activeLibrarySyncer)
            return activeLibrarySyncer
        }
        guard let storage else { return nil }
        guard let key = accountStore.activeAccountKey(),
              let stored = accountStore.allAccounts().first(where: { $0.info.key == key }) else {
            return nil
        }
        var didAuthenticate = false
        if !backendProxy.isAuthenticated {
            guard let login = LoginCredentials(
                serverURLString: stored.credentials.serverURL,
                username: stored.credentials.username,
                password: stored.credentials.passwordToken
            ) else {
                throw BackendError.invalidURL
            }
            do {
                rememberServerType(try await backendProxy.login(credentials: login))
                didAuthenticate = true
            } catch {
                logoutForInvalidCredentials(matching: error)
                throw error
            }
        } else {
            await refreshServerTypeIfNeeded()
        }
        // The ingester runs on its own ModelActor so sync writes never touch the main
        // thread; the account row is resolved lazily inside that actor's context.
        let ingester = SwiftDataLibraryIngester(
            modelContainer: storage.container,
            accountInfo: stored.info,
            apiType: ApiType(backendProxy.apiType),
            // Batch sizes for whatever just hit the database ("Songs: 17"). Deliberately
            // not forwarded to the coordinator: one lands per album during the track
            // crawl, so it would overwrite the syncer's album counter with a number that
            // jumps around and tracks nothing the user can follow.
            onProgress: { [weak self] message in
                Task { @MainActor in
                    self?.syncProgressMessage = message
                }
            }
        )
        let syncer = backendProxy.createLibrarySyncer(ingestor: ingester)
        activeLibrarySyncer = syncer
        activeLibraryIngester = ingester
        let scrobble = ScrobbleSyncer(
            uploader: LibrarySyncerScrobbleUploader(syncer: syncer),
            timing: { [weak self] in self?.settings.scrobbleTiming ?? .default }
        )
        scrobble.onScrobble = { playableId in
            LibraryActions.shared.recordPlay(playableId: playableId)
        }
        scrobbleSyncer = scrobble
        audioOrchestrator?.attachScrobbleSyncer(scrobble)
        if didAuthenticate {
            NotificationCenter.default.post(name: .backendAuthenticated, object: nil)
        }
        // Canonical-ID migration runs strictly before any sync / queue-load consumer
        // reads from the library. Placed here rather than at the top of the function so
        // the syncer is already available to drive the probe's `getSong` calls, but
        // before `libraryMutationSyncer.flush()` (which reads local IDs) and before
        // this function returns the syncer to its caller.
        await runCanonicalIdMigrationIfNeeded(syncer: syncer)
        // Syncer just became available — push anything queued while offline.
        await libraryMutationSyncer?.flush()
        return syncer
    }

    /// Show the blocking overlay and wait a beat so SwiftUI can commit it before this
    /// actor starts the SwiftData rewrite (which would otherwise freeze a still-hidden overlay).
    public func presentCanonicalIdMigrationOverlay(_ message: String = "Updating library IDs…") async {
        overlayRetainCount += 1
        idMigrationStatusText = message
        let firstShow = !isRemappingCanonicalIds
        isRemappingCanonicalIds = true
        // Yield a frame only when the overlay actually appears, so SwiftUI can paint
        // it before SwiftData blocks the main actor. Repeat presents must not sleep
        // or overlapping callers stack 50ms delays into a multi-second flash.
        if firstShow {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func dismissCanonicalIdMigrationOverlay() {
        overlayRetainCount = max(0, overlayRetainCount - 1)
        if overlayRetainCount == 0 {
            isRemappingCanonicalIds = false
        }
    }

    /// Runs the Navidrome canonical-ID gate and, if a remap happened, reloads the
    /// in-memory play queue so restored/queued tracks use the new IDs. The on-disk
    /// queue JSON is rewritten by the migrator; `PlayQueueHandler` is loaded earlier
    /// during `initialize` and would otherwise keep streaming the old IDs.
    private func runCanonicalIdMigrationIfNeeded(syncer: any LibrarySyncer) async {
        let outcome = await NavidromeIdMigrationHook.runIfNeeded(kit: self, syncer: syncer)
        switch outcome {
        case .migratedForward, .migratedBackward, .resumed:
            await queueHandler?.loadFromDisk()
        default:
            break
        }
    }

    public func getMeta(for info: AccountInfo) -> MetaManager {
        MetaManagerRegistry.shared.manager(for: info)
    }

    public func activeAccount() throws -> Account? {
        guard let storage, let key = accountStore.activeAccountKey() else { return nil }
        return try LibraryRepository(storage: storage).fetchAccount(key: key)
    }

    public func repository() -> LibraryRepository? {
        guard let storage else { return nil }
        return LibraryRepository(storage: storage)
    }

    /// Persists the handshake/ping product name (and version) so Home can title itself
    /// after relaunch and the canonical-ID gate can decide whether to probe without
    /// re-pinging on every call. Writes the `SettingsStore` row directly — relying on
    /// `observableSettings.updateAccount` is a no-op until that object has been bound
    /// to the active account, which is too late for cold launch.
    private func rememberServerType(_ info: ServerInfo) {
        if let key = accountStore.activeAccountKey() {
            var copy = settings.loadAccountSettings(for: key)
            copy.serverTypeName = info.name
            copy.serverVersion = info.version
            settings.saveAccountSettings(copy, for: key)
            observableSettings.reload(accountKey: key)
        }
        accountStore.rememberServerTypeName(info.name)
    }

    private func refreshServerTypeIfNeeded() async {
        guard backendProxy.isAuthenticated else { return }
        let needsType = accountStore.needsServerTypeName
        let needsVersion: Bool = {
            guard let key = accountStore.activeAccountKey() else { return false }
            return settings.loadAccountSettings(for: key).serverVersion == nil
        }()
        guard needsType || needsVersion,
              let info = try? await backendProxy.serverInfo() else { return }
        rememberServerType(info)
    }
}
