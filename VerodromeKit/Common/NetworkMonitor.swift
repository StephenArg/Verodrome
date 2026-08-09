import Combine
import Foundation
import Network

@MainActor
public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    @Published public private(set) var isConnected = true
    @Published public private(set) var isExpensive = false
    /// True when the active path is Wi‑Fi or wired Ethernet.
    ///
    /// Prefer this over `!isExpensive` for "Wi‑Fi only" gates: cellular paths often
    /// report `isExpensive == false` (unlimited plans, some carriers), which would
    /// incorrectly allow large downloads.
    @Published public private(set) var isWiFi = false
    @Published public private(set) var isConstrained = false
    public private(set) var interfaceType: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.verodrome.network-monitor")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.apply(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Wi‑Fi / Ethernet and not marked expensive or Low Data Mode constrained.
    ///
    /// Personal hotspots usually appear as Wi‑Fi *and* expensive — those stay blocked
    /// so someone else's cellular data isn't used for album downloads.
    public var isUnmeteredForDownloads: Bool {
        Self.evaluateUnmeteredForDownloads(
            isConnected: isConnected,
            isWiFi: isWiFi,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        )
    }

    nonisolated public static func evaluateUnmeteredForDownloads(
        isConnected: Bool,
        isWiFi: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> Bool {
        isConnected && isWiFi && !isExpensive && !isConstrained
    }

    private func apply(path: NWPath) {
        // NWPathMonitor fires on every path detail change; assigning unconditionally
        // would publish a stream of no-op updates to every subscriber.
        let connected = path.status == .satisfied
        // `usesInterfaceType` reflects what the path actually routes over. Reading
        // `availableInterfaces.first` is wrong: cellular often leads that list even
        // while traffic is going out over Wi‑Fi.
        let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        if connected != isConnected { isConnected = connected }
        if path.isExpensive != isExpensive { isExpensive = path.isExpensive }
        if path.isConstrained != isConstrained { isConstrained = path.isConstrained }
        if wifi != isWiFi { isWiFi = wifi }
        interfaceType = path.availableInterfaces.first?.type
    }
}
