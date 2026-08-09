import AVFoundation
import Foundation

@MainActor
public final class AudioSessionHandler {
    private var observers: [NSObjectProtocol] = []
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
            if type == .began {
                self?.onInterrupt?(true)
            } else if type == .ended {
                let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) }
                if options?.contains(.shouldResume) == true { self?.onInterrupt?(false) }
            }
        })
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
