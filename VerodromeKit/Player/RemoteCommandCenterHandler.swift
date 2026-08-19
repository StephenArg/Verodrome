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
        center.changeShuffleModeCommand.removeTarget(nil)
        center.changeRepeatModeCommand.removeTarget(nil)

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
        center.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackSpeed.options.map { NSNumber(value: $0) }
        center.changeShuffleModeCommand.isEnabled = true
        center.changeRepeatModeCommand.isEnabled = true

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
                // Leave temporary hold-speed behind; keep the sticky session rate.
                self?.player?.endIntervalHold()
                self?.player?.restoreSessionPlaybackRate()
                self?.player?.next()
            }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Self.performOnMain {
                self?.player?.endIntervalHold()
                self?.player?.restoreSessionPlaybackRate()
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
                self?.applySessionRate(Float(event.playbackRate))
            }
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMain {
                switch event.shuffleType {
                case .off:
                    self?.player?.setShuffleMode(.off)
                case .items, .collections:
                    self?.player?.setShuffleMode(.on)
                @unknown default:
                    break
                }
            }
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMain {
                switch event.repeatType {
                case .off:
                    self?.player?.setRepeatMode(.off)
                case .one:
                    self?.player?.setRepeatMode(.one)
                case .all:
                    if self?.player?.canRepeatAll == true {
                        self?.player?.setRepeatMode(.all)
                    } else {
                        self?.player?.toggleRepeat()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// Hold next → interval jumps or 2×; hold previous → interval jumps or 0.5×.
    /// CarPlay Mini Skips (when connected) uses the interval; otherwise this is speed.
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
                player.endIntervalHold()
                player.restoreSessionPlaybackRate()
                return
            }
            switch event.type {
            case .beginSeeking:
                if CarPlayConnection.isActive, SettingsStore.shared.carPlayMiniSkipEnabled {
                    let delta = SettingsStore.shared.carPlayMiniSkipInterval.timeInterval
                    player.beginIntervalHold(rate >= 1 ? delta : -delta)
                } else {
                    player.endIntervalHold()
                    if !player.isPlaying {
                        player.play()
                    }
                    player.setPlaybackRate(rate)
                }
            case .endSeeking:
                player.endIntervalHold()
                player.restoreSessionPlaybackRate()
            @unknown default:
                break
            }
        }
    }

    @MainActor
    private func applySessionRate(_ rate: Float) {
        if rate != 1, player?.isPlaying != true {
            player?.play()
        }
        player?.setSessionPlaybackRate(rate)
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

/// Set by the CarPlay scene so remote Next/Previous hold can use CarPlay skip settings.
@MainActor
public enum CarPlayConnection {
    public static var isActive = false
}
