import Foundation
import OSLog
import QuartzCore

/// Frame-accurate stall detector.
///
/// A `CADisplayLink` fires on the main run loop once per frame, so any gap larger than the
/// expected frame duration is time the main thread spent blocked — exactly what a user
/// perceives as "lag" or "freeze". Aggregated into one line per second so the logging
/// itself can't be the bottleneck.
///
/// Filter Xcode console: subsystem `com.verodrome`, category `PerfTrace`, search `🧊`.
@MainActor
public final class FrameHitchMonitor {
    public static let shared = FrameHitchMonitor()

    private let log = Logger(subsystem: "com.verodrome", category: "PerfTrace")
    private var link: CADisplayLink?
    private var label = ""

    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var hitchCount = 0
    private var droppedFrames = 0
    private var worstFrameMs = 0.0
    private var stallMs = 0.0

    private init() {}

    /// Begins frame monitoring attributed to `label` (usually a screen name).
    public func start(label: String) {
        guard PerfTrace.isEnabled else { return }
        stop()
        self.label = label
        reset(at: CACurrentMediaTime())
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        log.notice("🧊 Frames.start | \(label, privacy: .public)")
    }

    public func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        flush(force: true)
        log.notice("🧊 Frames.stop | \(self.label, privacy: .public)")
        label = ""
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // Duration the system expects for this frame (handles 60/120Hz and ProMotion ramps).
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)

        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else {
            windowStart = now
            return
        }

        let delta = now - lastTimestamp
        frames += 1

        // Anything beyond ~1.5 expected frames means we missed at least one vsync.
        if delta > expected * 1.5 {
            let missed = Int((delta / expected).rounded()) - 1
            if missed > 0 {
                hitchCount += 1
                droppedFrames += missed
                stallMs += (delta - expected) * 1000
                worstFrameMs = max(worstFrameMs, delta * 1000)
            }
        }

        if now - windowStart >= 1.0 {
            flush(force: false)
            reset(at: now)
        }
    }

    private func reset(at time: CFTimeInterval) {
        windowStart = time
        frames = 0
        hitchCount = 0
        droppedFrames = 0
        worstFrameMs = 0
        stallMs = 0
    }

    private func flush(force: Bool) {
        guard frames > 0 || force else { return }
        guard droppedFrames > 0 else {
            log.notice(
                "🧊 Frames \(self.label, privacy: .public) | \(self.frames, privacy: .public) frames, no drops"
            )
            return
        }
        let worst = Int(worstFrameMs.rounded())
        let stalled = Int(stallMs.rounded())
        log.warning(
            "🧊 Frames \(self.label, privacy: .public) | frames=\(self.frames, privacy: .public) dropped=\(self.droppedFrames, privacy: .public) hitches=\(self.hitchCount, privacy: .public) worstFrame=\(worst, privacy: .public)ms stalled=\(stalled, privacy: .public)ms"
        )
    }
}

/// Cheap named counters, flushed once per second.
///
/// Use for events that fire per cell / per body evaluation, where one log line each would
/// both flood the console and change the thing being measured. Comparing a counter against
/// what you *expect* is how you catch a lazy container that isn't being lazy.
///
/// Filter Xcode console: subsystem `com.verodrome`, category `PerfTrace`, search `🔢`.
public enum PerfCounters {
    private static let log = Logger(subsystem: "com.verodrome", category: "PerfTrace")
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var maxima: [String: Int] = [:]
    private static var flushScheduled = false

    public static func bump(_ name: String, by amount: Int = 1) {
        guard PerfTrace.isEnabled else { return }
        lock.lock()
        counts[name, default: 0] += amount
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()
        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { flush() }
        }
    }

    /// Records a high-water mark rather than a sum (e.g. largest decoded image seen).
    public static func peak(_ name: String, value: Int) {
        guard PerfTrace.isEnabled else { return }
        lock.lock()
        maxima[name] = max(maxima[name] ?? 0, value)
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()
        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { flush() }
        }
    }

    public static func flush() {
        lock.lock()
        let snapshot = counts
        let peaks = maxima
        counts.removeAll(keepingCapacity: true)
        maxima.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()

        guard !snapshot.isEmpty || !peaks.isEmpty else { return }
        let counted = snapshot
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
        let peaked = peaks
            .sorted { $0.key < $1.key }
            .map { "\($0.key)≤\($0.value)" }
        let line = (counted + peaked).joined(separator: " ")
        log.notice("🔢 \(line, privacy: .public)")
    }
}
