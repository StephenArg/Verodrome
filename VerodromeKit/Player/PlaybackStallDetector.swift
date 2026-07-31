import Foundation

/// Watches the engine's playback clock to decide whether a stream has died.
///
/// AudioStreaming cannot be relied on to report this itself: when a request never
/// completes it parks in `.waitingForData` indefinitely without emitting any delegate
/// callback, and `errorOccurred` drops errors whose source no longer matches the current
/// reading entry. A frozen clock is the only signal that covers every case, and it catches
/// both "first audio never arrived" and a mid-track drop.
struct PlaybackStallDetector {
    /// Smallest progress delta treated as real movement rather than reporting jitter.
    static let progressEpsilon: Double = 0.05

    /// True once the engine has reported real forward progress for the current entry.
    /// While false, a `.paused` engine is holding an entry that `resume()` cannot revive.
    private(set) var hasStartedAudio = false

    /// Kept at 0 for a fresh load so the first genuine advance has to clear the epsilon —
    /// AudioStreaming reports `progress == 0` for the whole pre-roll.
    private var lastProgress: Double = 0
    private var lastAdvance: Date
    private let timeout: TimeInterval

    init(timeout: TimeInterval, now: Date = Date()) {
        self.timeout = timeout
        self.lastAdvance = now
    }

    /// A new entry is loading: nothing has played yet.
    mutating func reset(now: Date = Date()) {
        hasStartedAudio = false
        lastProgress = 0
        lastAdvance = now
    }

    /// The engine already has audio flowing (e.g. a gapless hand-off the engine performed
    /// on its own), so the new entry starts out healthy.
    mutating func adoptPlayingEntry(now: Date = Date()) {
        reset(now: now)
        hasStartedAudio = true
    }

    /// Keeps the stream considered healthy while the clock legitimately freezes or jumps
    /// (pause, resume, seek), without forgetting that audio already started.
    mutating func extendWindow(now: Date = Date()) {
        lastProgress = 0
        lastAdvance = now
    }

    /// Feeds the engine's reported progress in. Returns `true` when the stream has gone
    /// long enough without advancing that it should be treated as dead.
    mutating func update(progress: Double, isPlaying: Bool, now: Date = Date()) -> Bool {
        guard isPlaying else {
            // Paused: hold the window open so resuming isn't instantly declared stalled.
            lastAdvance = now
            return false
        }
        if progress.isFinite, progress > lastProgress + Self.progressEpsilon {
            lastProgress = progress
            lastAdvance = now
            hasStartedAudio = true
            return false
        }
        return now.timeIntervalSince(lastAdvance) >= timeout
    }

    /// Nominally loading or playing, but no audio has been produced for `grace` seconds —
    /// long enough that it will not start on its own. Lets connectivity recovery step in
    /// before the full stall timeout elapses.
    func isSilentlyStuck(grace: TimeInterval, now: Date = Date()) -> Bool {
        !hasStartedAudio && now.timeIntervalSince(lastAdvance) >= grace
    }
}
