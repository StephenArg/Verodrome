import Foundation
import MediaPlayer

@MainActor
public final class RemoteCommandCenterHandler {
    private weak var player: PlayerFacadeImpl?

    public init() {}

    public func bind(player: PlayerFacadeImpl) {
        self.player = player

        let center = MPRemoteCommandCenter.shared()
        // Drop any prior handlers (including early AppDelegate stubs).
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.stopCommand.isEnabled = true

        // Remote command callbacks are not guaranteed to be on the main queue.
        // Use dedicated play/pause (not toggle) so lock-screen buttons stay correct.
        center.playCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.play() }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.pause() }
        }
        center.stopCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.pause() }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.togglePlayPause() }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.next() }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Self.performOnMain { self?.player?.previous() }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMain { self?.player?.seek(to: event.positionTime) }
        }
    }

    nonisolated private static func performOnMain(_ work: @escaping @MainActor () -> Void) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
            return .success
        }
        var status: MPRemoteCommandHandlerStatus = .commandFailed
        DispatchQueue.main.sync {
            work()
            status = .success
        }
        return status
    }
}
