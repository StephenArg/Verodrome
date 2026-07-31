import Foundation
import OSLog

/// UI / list performance gauges.
///
/// Filter Xcode console: subsystem `com.verodrome`, category `PerfTrace`,
/// or search for `📊` / `🐢` / `🏁` / `🎨`.
///
/// Usage:
/// ```swift
/// let token = PerfTrace.begin("Home.appear")
/// // …
/// PerfTrace.end(token)
///
/// let rows = PerfTrace.measure("Songs.makeRows", details: "count=\(n)") {
///     songs.map(SongRowItem.init)
/// }
/// ```
public enum PerfTrace {
    private static let log = Logger(subsystem: "com.verodrome", category: "PerfTrace")
    private static let lock = NSLock()
    private static var counter = 0
    private static var open: [Int: (name: String, start: CFAbsoluteTime)] = [:]

    /// Soft budget for interactive UI work (list mapping, sectioning). Above this → 🐢 warning.
    public static let warnThresholdMs = 50
    /// Hard budget for work that should stay off the critical path.
    public static let criticalThresholdMs = 200

    @discardableResult
    public static func begin(_ name: String, details: String = "") -> Int {
        lock.lock()
        counter += 1
        let id = counter
        open[id] = (name, CFAbsoluteTimeGetCurrent())
        lock.unlock()
        let extra = details.isEmpty ? "" : " | \(details)"
        log.notice("📊 [\(id, privacy: .public)] BEGIN \(name, privacy: .public)\(extra, privacy: .public)")
        return id
    }

    public static func end(_ token: Int, details: String = "") {
        lock.lock()
        guard let entry = open.removeValue(forKey: token) else {
            lock.unlock()
            log.notice("📊 [?] END unknown token \(token, privacy: .public)")
            return
        }
        let ms = Int(((CFAbsoluteTimeGetCurrent() - entry.start) * 1000).rounded())
        lock.unlock()
        emit(name: entry.name, ms: ms, details: details, ended: true)
    }

    /// Instant point-in-time event (no duration).
    public static func event(_ name: String, details: String = "") {
        let extra = details.isEmpty ? "" : " | \(details)"
        log.notice("📌 \(name, privacy: .public)\(extra, privacy: .public)")
    }

    /// Times a synchronous block and returns its result.
    @discardableResult
    public static func measure<T>(
        _ name: String,
        details: String = "",
        body: () throws -> T
    ) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try body()
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        emit(name: name, ms: ms, details: details, ended: false)
        return value
    }

    /// Times an async block and returns its result.
    @discardableResult
    public static func measureAsync<T>(
        _ name: String,
        details: String = "",
        body: () async throws -> T
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try await body()
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        emit(name: name, ms: ms, details: details, ended: false)
        return value
    }

    private static func emit(name: String, ms: Int, details: String, ended: Bool) {
        let extra = details.isEmpty ? "" : " | \(details)"
        let prefix = ended ? "🏁" : "📊"
        if ms >= criticalThresholdMs {
            log.error(
                "🐢 \(prefix) \(name, privacy: .public) \(ms, privacy: .public)ms (critical)\(extra, privacy: .public)"
            )
        } else if ms >= warnThresholdMs {
            log.warning(
                "🐢 \(prefix) \(name, privacy: .public) \(ms, privacy: .public)ms\(extra, privacy: .public)"
            )
        } else {
            log.notice(
                "\(prefix, privacy: .public) \(name, privacy: .public) \(ms, privacy: .public)ms\(extra, privacy: .public)"
            )
        }
    }
}

/// Aggregated artwork-load probe — avoids flooding the console while scrolling.
///
/// Emits a summary every ~500ms while loads are happening:
/// `🎨 Art.load | mem=12 disk=3 net=1 slow=1 max=84ms size=300`
/// Individual slow loads (≥ warn threshold) still log immediately.
public enum ArtworkPerf {
    public enum Source: String, Sendable {
        case mem
        case disk
        case network
        case miss
        case cancel
    }

    private static let log = Logger(subsystem: "com.verodrome", category: "PerfTrace")
    private static let lock = NSLock()
    private static var mem = 0
    private static var disk = 0
    private static var network = 0
    private static var miss = 0
    private static var cancel = 0
    private static var slow = 0
    private static var totalMs = 0
    private static var maxMs = 0
    private static var samples = 0
    private static var lastSize = 0
    private static var flushScheduled = false
    private static var lastContext = ""

    /// Record one artwork resolution. Cheap; batches into periodic summaries.
    public static func record(
        source: Source,
        size: Int,
        ms: Int,
        context: String = "",
        details: String = ""
    ) {
        lock.lock()
        switch source {
        case .mem: mem += 1
        case .disk: disk += 1
        case .network: network += 1
        case .miss: miss += 1
        case .cancel: cancel += 1
        }
        samples += 1
        totalMs += max(0, ms)
        maxMs = max(maxMs, ms)
        lastSize = size
        if !context.isEmpty { lastContext = context }
        let shouldFlush = !flushScheduled
        if shouldFlush { flushScheduled = true }
        let isSlow = ms >= PerfTrace.warnThresholdMs && (source == .disk || source == .network)
        if isSlow { slow += 1 }
        lock.unlock()

        if isSlow {
            let extra = details.isEmpty ? "" : " \(details)"
            log.warning(
                "🐢 🎨 Art.\(source.rawValue, privacy: .public) \(ms, privacy: .public)ms | size=\(size, privacy: .public) ctx=\(context, privacy: .public)\(extra, privacy: .public)"
            )
        }

        if shouldFlush {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                flush()
            }
        }
    }

    public static func flush() {
        lock.lock()
        defer {
            mem = 0; disk = 0; network = 0; miss = 0; cancel = 0
            slow = 0; totalMs = 0; maxMs = 0; samples = 0
            flushScheduled = false
            lock.unlock()
        }
        guard samples > 0 else { return }
        let avg = totalMs / max(samples, 1)
        let ctx = lastContext.isEmpty ? "" : " ctx=\(lastContext)"
        log.notice(
            "🎨 Art.load | mem=\(mem, privacy: .public) disk=\(disk, privacy: .public) net=\(network, privacy: .public) miss=\(miss, privacy: .public) cancel=\(cancel, privacy: .public) slow=\(slow, privacy: .public) samples=\(samples, privacy: .public) avg=\(avg, privacy: .public)ms max=\(maxMs, privacy: .public)ms size=\(lastSize, privacy: .public)\(ctx, privacy: .public)"
        )
    }
}
