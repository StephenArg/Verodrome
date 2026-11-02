import AVFoundation
import Foundation

@MainActor
public final class AudioSessionHandler {
    private var observers: [NSObjectProtocol] = []
    /// Whether the interruption in progress paused playback, so its end resumes only that.
    private var resumesWhenInterruptionEnds = false
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
            MainActor.assumeIsolated { self?.handleInterruption(type, options: options) }
        })
    }

    /// iOS sends `.shouldResume` whenever the interrupting audio lets go (a Safari video
    /// ending, a call hanging up), even if nothing was playing here when it began. Acting
    /// on that alone starts music the user paused hours ago.
    func handleInterruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        if type == .began {
            resumesWhenInterruptionEnds = isPlaying()
            onInterrupt?(true)
        } else if type == .ended {
            let resume = resumesWhenInterruptionEnds && options.contains(.shouldResume)
            // Every end closes the interruption, so a later one can't inherit its state.
            resumesWhenInterruptionEnds = false
            if resume { onInterrupt?(false) }
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
}
