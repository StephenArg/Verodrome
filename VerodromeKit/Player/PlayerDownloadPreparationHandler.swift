import Foundation

@MainActor
public final class PlayerDownloadPreparationHandler {
    private let policy: QueueCachePolicyManager
    public init(policy: QueueCachePolicyManager) { self.policy = policy }
    public func prepareForCurrentQueue() { policy.reevaluate() }
}
