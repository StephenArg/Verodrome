import Foundation

public protocol BackendAPI: AnyObject, Sendable {
    var accountInfo: AccountInfo { get }
}

public protocol LibrarySyncing: AnyObject, Sendable {
    func syncLibrary(force: Bool) async throws
}

public protocol AccountDownloadCoordinating: AnyObject, Sendable {
    func enqueuePendingDownloads() async
}

@MainActor
public final class MetaManager {
    public let accountInfo: AccountInfo
    public var backendApi: (any BackendAPI)?
    public var librarySyncer: (any LibrarySyncing)?
    public var downloadManager: (any AccountDownloadCoordinating)?

    public init(accountInfo: AccountInfo) {
        self.accountInfo = accountInfo
    }

    public func attach(
        backendApi: (any BackendAPI)? = nil,
        librarySyncer: (any LibrarySyncing)? = nil,
        downloadManager: (any AccountDownloadCoordinating)? = nil
    ) {
        self.backendApi = backendApi
        self.librarySyncer = librarySyncer
        self.downloadManager = downloadManager
    }

    public func refreshIfNeeded() async {
        guard let librarySyncer else { return }
        try? await librarySyncer.syncLibrary(force: false)
        await downloadManager?.enqueuePendingDownloads()
    }
}

@MainActor
public final class MetaManagerRegistry {
    public static let shared = MetaManagerRegistry()

    private var managers: [String: MetaManager] = [:]

    private init() {}

    public func manager(for accountInfo: AccountInfo) -> MetaManager {
        if let existing = managers[accountInfo.id] {
            return existing
        }
        let manager = MetaManager(accountInfo: accountInfo)
        managers[accountInfo.id] = manager
        return manager
    }

    public func removeManager(for accountInfo: AccountInfo) {
        managers.removeValue(forKey: accountInfo.id)
    }

    public func activeManager(accountStore: AccountStore = .shared) -> MetaManager? {
        guard let key = accountStore.activeAccountKey(),
              let stored = accountStore.allAccounts().first(where: { $0.info.key == key }) else {
            return nil
        }
        return manager(for: stored.info)
    }
}
