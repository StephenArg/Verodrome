import Combine
import Foundation
import Network

@MainActor
public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    @Published public private(set) var isConnected = true
    @Published public private(set) var isExpensive = false
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

    private func apply(path: NWPath) {
        // NWPathMonitor fires on every path detail change; assigning unconditionally
        // would publish a stream of no-op updates to every subscriber.
        let connected = path.status == .satisfied
        if connected != isConnected { isConnected = connected }
        if path.isExpensive != isExpensive { isExpensive = path.isExpensive }
        interfaceType = path.availableInterfaces.first?.type
    }
}
