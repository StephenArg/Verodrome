import Foundation

/// One artist the Popular warmup may fetch, identified by the compound cache key.
public struct ArtistPopularPrefetchTarget: Hashable, Sendable {
    public let compoundId: String
    public let remoteId: String
    public let name: String
    public let songCount: Int

    public init(compoundId: String, remoteId: String, name: String, songCount: Int) {
        self.compoundId = compoundId
        self.remoteId = remoteId
        self.name = name
        self.songCount = songCount
    }
}

/// Background fill of `ArtistPopularSongsCache` for likely next artists.
///
/// Warmup and the play-queue window only call the server on a cache miss. Opening an
/// artist page revalidates separately and does not go through this type.
@MainActor
public final class ArtistPopularSongsPrefetcher {
    public static let shared = ArtistPopularSongsPrefetcher()
    public static let warmupLimit = 20
    /// Extra favorite rows to scan so 20 unique artists can still fill when many
    /// starred tracks share an artist — without fetching the whole catalog.
    public static let favoriteScanLimit = 40

    private let cache: ArtistPopularSongsCache
    private let settings: () -> UserSettings
    private let isConnected: () -> Bool
    private let provider: () async -> (any TopSongProviding)?
    private let repository: () -> LibraryRepository?
    private let account: () -> Account?
    private let recentEntries: () -> [RecentQueueEntry]

    private var pending: [ArtistPopularPrefetchTarget] = []
    private var pendingIds: Set<String> = []
    private var inFlight: Set<String> = []
    private var isPumping = false
    private var didStart = false

    public convenience init(cache: ArtistPopularSongsCache = .shared) {
        self.init(
            cache: cache,
            settings: { SettingsStore.shared.loadUserSettings() },
            isConnected: { NetworkMonitor.shared.isConnected },
            provider: {
                (try? await VerodromeKit.shared.ensureActiveLibrarySyncer()) as? any TopSongProviding
            },
            repository: { VerodromeKit.shared.repository() },
            account: { try? VerodromeKit.shared.activeAccount() },
            recentEntries: { RecentQueueStore.shared.entries }
        )
    }

    public init(
        cache: ArtistPopularSongsCache,
        settings: @escaping () -> UserSettings,
        isConnected: @escaping () -> Bool,
        provider: @escaping () async -> (any TopSongProviding)?,
        repository: @escaping () -> LibraryRepository?,
        account: @escaping () -> Account?,
        recentEntries: @escaping () -> [RecentQueueEntry]
    ) {
        self.cache = cache
        self.settings = settings
        self.isConnected = isConnected
        self.provider = provider
        self.repository = repository
        self.account = account
        self.recentEntries = recentEntries
    }

    public func start() {
        guard !didStart else { return }
        didStart = true
        NotificationCenter.default.addObserver(
            forName: .librarySynced,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.warmupLikelyArtists() }
        }
    }

    /// Home recents, favorites, and locally recorded album queues — cache-miss only.
    public func warmupLikelyArtists() {
        guard autoCacheEnabled else { return }
        enqueue(likelyArtistTargets())
    }

    /// Artists of songs already in the play-queue prefetch window.
    public func prefetch(queueItems: [QueueItem]) {
        guard autoCacheEnabled else { return }
        enqueue(queueArtistTargets(from: queueItems))
    }

    public func enqueue(_ targets: [ArtistPopularPrefetchTarget]) {
        guard autoCacheEnabled else { return }
        for target in targets {
            guard ArtistTopSongs.shouldFetch(artistSongCount: target.songCount) else { continue }
            guard cache.cached(forArtistCompoundId: target.compoundId) == nil else { continue }
            guard !inFlight.contains(target.compoundId) else { continue }
            guard pendingIds.insert(target.compoundId).inserted else { continue }
            pending.append(target)
        }
        pump()
    }

    /// Fetch and store when this artist has never been cached. Used by tests and the pump.
    @discardableResult
    public func prefetchIfNeeded(_ target: ArtistPopularPrefetchTarget) async -> Bool {
        guard autoCacheEnabled else { return false }
        guard ArtistTopSongs.shouldFetch(artistSongCount: target.songCount) else { return false }
        if await cache.load(forArtistCompoundId: target.compoundId) != nil { return false }
        guard isConnected(), !settings().isOfflineMode else { return false }
        guard let provider = await provider() else { return false }
        do {
            let visible = try await ArtistTopSongs.fetchVisible(
                artistId: target.remoteId,
                artistName: target.name,
                songCount: target.songCount,
                provider: provider
            )
            await cache.store(visible, forArtistCompoundId: target.compoundId)
            return true
        } catch {
            return false
        }
    }

    private var autoCacheEnabled: Bool {
        let user = settings()
        return user.showArtistTopSongs
            && user.autoCacheArtistPopularSongs
            && ArtistTopSongs.isSupported(on: account()?.apiType)
    }

    private func pump() {
        guard !isPumping else { return }
        isPumping = true
        Task { await runQueue() }
    }

    private func runQueue() async {
        defer { isPumping = false }
        while let target = dequeue() {
            inFlight.insert(target.compoundId)
            _ = await prefetchIfNeeded(target)
            inFlight.remove(target.compoundId)
        }
    }

    private func dequeue() -> ArtistPopularPrefetchTarget? {
        guard !pending.isEmpty else { return nil }
        let target = pending.removeFirst()
        pendingIds.remove(target.compoundId)
        return target
    }

    func likelyArtistTargets() -> [ArtistPopularPrefetchTarget] {
        guard let repository = repository() else { return [] }
        var seen = Set<String>()
        var targets: [ArtistPopularPrefetchTarget] = []

        func consider(_ artist: Artist?) {
            guard targets.count < Self.warmupLimit else { return }
            guard let artist, seen.insert(artist.compoundRemoteId).inserted else { return }
            guard ArtistTopSongs.shouldFetch(artistSongCount: artist.songCount) else { return }
            targets.append(
                ArtistPopularPrefetchTarget(
                    compoundId: artist.compoundRemoteId,
                    remoteId: artist.remoteId,
                    name: artist.name,
                    songCount: artist.songCount
                )
            )
        }

        if let recent = try? repository.fetchAlbums(recentIndexPositive: true) {
            for album in recent {
                consider(album.artist)
                if targets.count >= Self.warmupLimit { return targets }
            }
        }
        if let favorites = try? repository.fetchFavoriteAlbums(limit: Self.favoriteScanLimit) {
            for album in favorites {
                consider(album.artist)
                if targets.count >= Self.warmupLimit { return targets }
            }
        }
        if targets.count < Self.warmupLimit,
           let songs = try? repository.fetchFavoriteSongs(limit: Self.favoriteScanLimit) {
            for song in songs {
                consider(song.artist)
                if targets.count >= Self.warmupLimit { return targets }
            }
        }
        for entry in recentEntries() where entry.kind == .album {
            if let album = try? repository.fetchAlbum(compoundRemoteId: entry.compoundRemoteId) {
                consider(album.artist)
                if targets.count >= Self.warmupLimit { return targets }
            }
        }
        return targets
    }

    private func queueArtistTargets(from items: [QueueItem]) -> [ArtistPopularPrefetchTarget] {
        guard let repository = repository(), let account = account() else { return [] }
        var seen = Set<String>()
        var targets: [ArtistPopularPrefetchTarget] = []
        for item in items where item.kind == .song {
            guard let song = try? repository.resolveSong(remoteId: item.playableId, account: account),
                  let artist = song.artist,
                  seen.insert(artist.compoundRemoteId).inserted
            else { continue }
            guard ArtistTopSongs.shouldFetch(artistSongCount: artist.songCount) else { continue }
            targets.append(
                ArtistPopularPrefetchTarget(
                    compoundId: artist.compoundRemoteId,
                    remoteId: artist.remoteId,
                    name: artist.name,
                    songCount: artist.songCount
                )
            )
        }
        return targets
    }
}
