import Combine
import Foundation

/// Tells `DownloadManager` whether pinned downloads may run, and nudges the playlist
/// reconcile when the answer turns to yes.
///
/// "Wi‑Fi only" means the path is actually on Wi‑Fi/Ethernet — not merely
/// `!isExpensive`, which stays false on plenty of cellular plans and would let album
/// downloads burn mobile data.
@MainActor
public final class DownloadNetworkPolicy {
    private let downloader: DownloadManager
    private let monitor: NetworkMonitor
    private let settingProvider: @MainActor () -> AutomaticDownloadNetwork
    private var onAllowed: (@MainActor () async -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var wasAllowed: Bool?

    public init(
        downloader: DownloadManager,
        monitor: NetworkMonitor = .shared,
        settingProvider: @escaping @MainActor () -> AutomaticDownloadNetwork
    ) {
        self.downloader = downloader
        self.monitor = monitor
        self.settingProvider = settingProvider

        // Any of these can change whether a transfer is allowed.
        monitor.$isWiFi
            .combineLatest(monitor.$isExpensive, monitor.$isConstrained, monitor.$isConnected)
            .sink { [weak self] _, _, _, _ in
                Task { @MainActor in await self?.apply() }
            }
            .store(in: &cancellables)
    }

    /// Called when a previously blocked policy starts allowing downloads, so a playlist
    /// that gained tracks while on cellular can catch up the moment Wi-Fi returns.
    public func setAllowedHandler(_ handler: @escaping @MainActor () async -> Void) {
        onAllowed = handler
    }

    /// Pushes the current policy into the download queue. Safe to call on any change —
    /// the queue only releases deferred work when the answer actually opens up.
    public func apply() async {
        let wifiOnly = settingProvider() == .wifiOnly
        let isUnmetered = monitor.isUnmeteredForDownloads
        await downloader.setNetworkPolicy(wifiOnlyAutomatic: wifiOnly, isUnmetered: isUnmetered)

        let isAllowed = (!wifiOnly || isUnmetered) && monitor.isConnected
        defer { wasAllowed = isAllowed }
        // Only on the transition. Reconciling on every path update would re-walk the
        // library each time NWPathMonitor reports an unrelated detail change.
        guard isAllowed, wasAllowed == false else { return }
        await onAllowed?()
    }
}
