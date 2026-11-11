import AVFoundation
import Foundation

@MainActor
public final class AudioSessionHandler {
    /// Longest interruption whose end still resumes playback by itself. Covers a call,
    /// Siri or a short video. Past it, music coming back is a surprise, so it waits for
    /// the play button.
    static let resumeWindow: TimeInterval = 10 * 60

    private var observers: [NSObjectProtocol] = []
    /// When the interruption in progress paused playback, so its end resumes only that.
    /// `nil` when nothing was playing as it began.
    private var interruptedPlaybackAt: Date?
    /// Read as an interruption begins.
    public var isPlaying: () -> Bool = { false }
    /// `true` when an interruption begins. `false` when one ends and the playback it
    /// paused should come back.
    public var onInterrupt: ((Bool) -> Void)?

    public func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {}
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type, options: options, reason: reason) }
        })
    }

    /// iOS sends `.shouldResume` whenever the interrupting audio lets go (a Safari video
    /// ending, a call hanging up), even if nothing was playing here when it began. Acting
    /// on that alone starts music the user paused hours ago.
    ///
    /// An end isn't guaranteed either: another app can hold the audio and never send
    /// one. A begin that paused music would then stay armed indefinitely, and some
    /// unrelated video ending hours later would bring the music back. So the end only
    /// resumes within `resumeWindow` of the begin.
    func handleInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions,
        reason: AVAudioSession.InterruptionReason? = nil,
        now: Date = Date()
    ) {
        if type == .began {
            let wasPlaying = isPlaying()
            interruptedPlaybackAt = wasPlaying ? now : nil
            log("Interruption began (playing=\(wasPlaying), reason=\(Self.describe(reason))) — \(wasPlaying ? "will resume if it ends within \(Int(Self.resumeWindow / 60)) min" : "nothing to resume")")
            onInterrupt?(true)
        } else if type == .ended {
            let shouldResume = options.contains(.shouldResume)
            let began = interruptedPlaybackAt
            // Every end closes the interruption, so a later one can't inherit its state.
            interruptedPlaybackAt = nil
            guard let began else {
                log("Interruption ended (shouldResume=\(shouldResume)) — staying paused: nothing was playing when it began")
                return
            }
            let age = now.timeIntervalSince(began)
            guard shouldResume else {
                log("Interruption ended after \(Int(age))s without shouldResume — staying paused")
                return
            }
            guard age <= Self.resumeWindow else {
                log("Interruption ended after \(Int(age / 60)) min — staying paused (longer than \(Int(Self.resumeWindow / 60)) min)")
                return
            }
            log("Interruption ended after \(Int(age))s — resuming")
            onInterrupt?(false)
        }
    }

    public func deactivateObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Releases the shared playback session so the process can die (or sleep) without
    /// holding an active audio claim. Observers are removed first so a deactivate
    /// notification cannot bounce back into the player.
    public func deactivate() {
        deactivateObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func log(_ message: String) {
        Task { await EventLogger.shared.info("playback", message) }
    }

    private static func describe(_ reason: AVAudioSession.InterruptionReason?) -> String {
        guard let reason else { return "none" }
        switch reason {
        case .default: return "default"
        case .builtInMicMuted: return "builtInMicMuted"
        case .routeDisconnected: return "routeDisconnected"
        default: return "\(reason.rawValue)"
        }
    }
}
