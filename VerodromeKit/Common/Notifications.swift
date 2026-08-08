import Foundation

public extension Notification.Name {
    static let queueChanged = Notification.Name("com.verodrome.queueChanged")
    static let queueIndexChanged = Notification.Name("com.verodrome.queueIndexChanged")
    static let offlineModeChanged = Notification.Name("com.verodrome.offlineModeChanged")
    static let librarySynced = Notification.Name("com.verodrome.librarySynced")
    static let accountChanged = Notification.Name("com.verodrome.accountChanged")
    static let queueCacheReevaluate = Notification.Name("com.verodrome.queueCacheReevaluate")
    static let foregroundRefresh = Notification.Name("com.verodrome.foregroundRefresh")
    /// Backend session is ready after cold-launch login (artwork / stream URLs can be minted).
    static let backendAuthenticated = Notification.Name("com.verodrome.backendAuthenticated")

    // Aliases used by player stack
    static let verodromeQueueChanged = queueChanged
    static let verodromeQueueIndexChanged = queueIndexChanged
    static let verodromeQueueCacheReevaluate = queueCacheReevaluate
    static let verodromeForegroundRefresh = foregroundRefresh
}
