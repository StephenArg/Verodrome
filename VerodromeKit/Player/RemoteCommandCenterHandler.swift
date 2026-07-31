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
        center.seekForwardCommand.removeTarget(nil)
        center.seekBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackRateCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        // Tap next/previous = skip track. Hold (with seek* enabled) = speed change.
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.seekForwardCommand.isEnabled = true
        center.seekBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        // Sticky rate control where the system surfaces it (Watch / some Now Playing UIs).
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1.0, 2.0]

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
            Self.performOnMain {
                // A remote skip should leave temporary hold-speed behind.
                self?.player?.setPlaybackRate(1)
                self?.player?.next()
            }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Self.performOnMain {
                self?.player?.setPlaybackRate(1)
                self?.player?.previous()
            }
        }
        // Lock-screen / Control Center hold on next/previous delivers begin/end seek
        // events (tap still goes to nextTrack / previousTrack above).
        center.seekForwardCommand.addTarget { [weak self] event in
            Self.handleSeekEvent(event, rate: 2, player: self?.player)
        }
        center.seekBackwardCommand.addTarget { [weak self] event in
            Self.handleSeekEvent(event, rate: 0.5, player: self?.player)
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMain { self?.player?.seek(to: event.positionTime) }
        }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMain {
                self?.applyRate(Float(event.playbackRate))
            }
        }
    }

    /// Hold next → 2×, hold previous → 0.5×; release → 1×.
    nonisolated private static func handleSeekEvent(
        _ event: MPRemoteCommandEvent,
        rate: Float,
        player: PlayerFacadeImpl?
    ) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPSeekCommandEvent else {
            return .commandFailed
        }
        return performOnMain {
            guard let player else { return }
            // Live streams have nothing useful to speed through.
            if player.currentItem?.isLiveStream == true {
                player.setPlaybackRate(1)
                return
            }
            switch event.type {
            case .beginSeeking:
                if !player.isPlaying {
                    player.play()
                }
                player.setPlaybackRate(rate)
            case .endSeeking:
                player.setPlaybackRate(1)
            @unknown default:
                break
            }
        }
    }

    @MainActor
    private func applyRate(_ rate: Float) {
        if rate != 1, player?.isPlaying != true {
            player?.play()
        }
        player?.setPlaybackRate(rate)
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
