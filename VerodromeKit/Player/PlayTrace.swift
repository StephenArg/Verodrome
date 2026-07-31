import Foundation
import OSLog

/// Timing breadcrumbs for play / shuffle latency.
/// Filter Xcode console with subsystem `com.verodrome` category `PlayTrace`,
/// or search for `▶️` / `⏱️` / `✅`.
public enum PlayTrace {
    private static let log = Logger(subsystem: "com.verodrome", category: "PlayTrace")
    private static let lock = NSLock()
    private static var sessionCounter = 0
    private static var activeSession = 0
    private static var sessionStart: CFAbsoluteTime = 0
    private static var lastMark: CFAbsoluteTime = 0

    @discardableResult
    public static func begin(_ reason: String, details: String = "") -> Int {
        lock.lock()
        sessionCounter += 1
        let id = sessionCounter
        activeSession = id
        let now = CFAbsoluteTimeGetCurrent()
        sessionStart = now
        lastMark = now
        lock.unlock()
        let extra = details.isEmpty ? "" : " | \(details)"
        log.notice("▶️ [\(id, privacy: .public)] BEGIN \(reason, privacy: .public)\(extra, privacy: .public)")
        return id
    }

    public static func mark(_ step: String, details: String = "", session: Int? = nil) {
        lock.lock()
        let id = session ?? activeSession
        guard id == activeSession, id != 0 else {
            lock.unlock()
            let extra = details.isEmpty ? "" : " | \(details)"
            log.notice("⏱️ [?] \(step, privacy: .public)\(extra, privacy: .public)")
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let deltaMs = Int(((now - lastMark) * 1000).rounded())
        let totalMs = Int(((now - sessionStart) * 1000).rounded())
        lastMark = now
        lock.unlock()
        let extra = details.isEmpty ? "" : " | \(details)"
        log.notice(
            "⏱️ [\(id, privacy: .public)] +\(deltaMs, privacy: .public)ms (Σ\(totalMs, privacy: .public)ms) \(step, privacy: .public)\(extra, privacy: .public)"
        )
    }

    public static func end(_ step: String = "audio started / play pipeline done", details: String = "") {
        lock.lock()
        let id = activeSession
        let now = CFAbsoluteTimeGetCurrent()
        let totalMs = id == 0 ? 0 : Int(((now - sessionStart) * 1000).rounded())
        let deltaMs = id == 0 ? 0 : Int(((now - lastMark) * 1000).rounded())
        lastMark = now
        lock.unlock()
        let extra = details.isEmpty ? "" : " | \(details)"
        log.notice(
            "✅ [\(id, privacy: .public)] END +\(deltaMs, privacy: .public)ms Σ\(totalMs, privacy: .public)ms \(step, privacy: .public)\(extra, privacy: .public)"
        )
    }

    public static func error(_ step: String, details: String = "") {
        lock.lock()
        let id = activeSession
        let totalMs = id == 0 ? 0 : Int(((CFAbsoluteTimeGetCurrent() - sessionStart) * 1000).rounded())
        lock.unlock()
        let extra = details.isEmpty ? "" : " | \(details)"
        log.error(
            "❌ [\(id, privacy: .public)] Σ\(totalMs, privacy: .public)ms \(step, privacy: .public)\(extra, privacy: .public)"
        )
    }
}
