import Combine
import Foundation
import Network

@MainActor
public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    public private(set) var isConnected = true
    public private(set) var isExpensive = false
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
        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        interfaceType = path.availableInterfaces.first?.type
    }
}
