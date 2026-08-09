import SwiftUI
import UIKit

/// Scrubber that only commits seeks when the user finishes dragging (or taps the track).
/// Binding a SwiftUI `Slider` directly to `seek(to:)` re-enters AudioStreaming's
/// seek request on every view update and can pin `progress` at the seek time (often 0).
struct SeekableTimeSlider: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    /// When set, the filled track (and thumb) use this color instead of the label color.
    /// Used while hold-to-speed-skip is active so the bar matches the theme accent.
    var accentTint: Color? = nil
    /// Fires with the thumb position while the user drags, and with `nil` once the
    /// drag ends or is cancelled.
    var onScrub: (TimeInterval?) -> Void = { _ in }
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        SeekableTimeSliderUIKit(
            currentTime: currentTime,
            duration: duration,
            accentTint: accentTint.map { UIColor($0) },
            onScrub: onScrub,
            onSeek: onSeek
        )
        .frame(height: 24)
    }
}

/// UIKit slider (Amperfy-style): never fights the thumb while tracking, seeks on release only.
/// Styled to match the target player: thin track, prominent circular thumb in the
/// label color. Tapping anywhere on the track jumps to that position.
struct SeekableTimeSliderUIKit: UIViewRepresentable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    var accentTint: UIColor? = nil
    let onScrub: (TimeInterval?) -> Void
    let onSeek: (TimeInterval) -> Void

    private static let trackHeight: CGFloat = 4
    private static let thumbDiameter: CGFloat = 13
    /// Slightly larger thumb while the finger is down scrubbing.
    private static let scrubbingThumbDiameter: CGFloat = 18
    private static let remainingTrackColor = UIColor.label.withAlphaComponent(0.28)

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(max(duration, 1))
        slider.value = Float(currentTime)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchUpInside)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchUpOutside)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchCancel)

        context.coordinator.accentTint = accentTint
        Self.applyImages(to: slider, accentTint: accentTint)
        // Track and thumb are pre-rendered bitmaps, so the label color baked into
        // them has to be redrawn when the appearance flips.
        slider.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak coordinator = context.coordinator] (slider: UISlider, _) in
            Self.applyImages(to: slider, accentTint: coordinator?.accentTint)
        }

        // Tap-to-seek: UISlider only moves the thumb when dragging by default.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapTrack(_:)))
        tap.numberOfTapsRequired = 1
        slider.addGestureRecognizer(tap)
        context.coordinator.tapGesture = tap

        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onScrub = onScrub
        context.coordinator.liveTime = currentTime
        let maxValue = Float(max(duration, 1))
        let tintChanged = !Self.sameColor(context.coordinator.accentTint, accentTint)
        if tintChanged {
            context.coordinator.accentTint = accentTint
        }
        if abs(uiView.maximumValue - maxValue) > 0.01 {
            uiView.maximumValue = maxValue
            Self.applyImages(to: uiView, accentTint: accentTint)
        } else if tintChanged {
            Self.applyImages(to: uiView, accentTint: accentTint)
        }
        // Match Amperfy: never fight the thumb while the user is dragging, unless the
        // drag was cancelled for being idle — then the thumb tracks playback again.
        if !uiView.isTracking || context.coordinator.isScrubCancelled {
            let next = Float(min(max(currentTime, 0), TimeInterval(maxValue)))
            if abs(uiView.value - next) > 0.05 {
                uiView.value = next
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrub: onScrub, onSeek: onSeek)
    }

    final class Coordinator: NSObject {
        /// A held-but-motionless drag this long is treated as unintentional and dropped.
        private static let idleCancelInterval: TimeInterval = 1

        var onScrub: (TimeInterval?) -> Void
        var onSeek: (TimeInterval) -> Void
        /// Latest playback position, used to restore the thumb when a drag is cancelled.
        var liveTime: TimeInterval = 0
        var accentTint: UIColor?
        private(set) var isScrubCancelled = false
        weak var tapGesture: UITapGestureRecognizer?
        private var idleTimer: Timer?

        init(onScrub: @escaping (TimeInterval?) -> Void, onSeek: @escaping (TimeInterval) -> Void) {
            self.onScrub = onScrub
            self.onSeek = onSeek
        }

        deinit {
            idleTimer?.invalidate()
        }

        @objc func touchDown(_ sender: UISlider) {
            isScrubCancelled = false
            onScrub(TimeInterval(sender.value))
            restartIdleTimer(for: sender)
        }

        @objc func valueChanged(_ sender: UISlider) {
            // Once cancelled, the rest of the gesture is ignored: keep the thumb pinned
            // to playback so a resting finger can't drag the track along with it.
            if isScrubCancelled {
                sender.value = Float(liveTime)
                return
            }
            onScrub(TimeInterval(sender.value))
            restartIdleTimer(for: sender)
        }

        @objc func touchUp(_ sender: UISlider) {
            idleTimer?.invalidate()
            idleTimer = nil
            let value = TimeInterval(sender.value)
            let wasCancelled = isScrubCancelled
            isScrubCancelled = false
            onScrub(nil)
            guard !wasCancelled else {
                sender.value = Float(liveTime)
                return
            }
            onSeek(value)
        }

        private func restartIdleTimer(for slider: UISlider) {
            idleTimer?.invalidate()
            let timer = Timer(timeInterval: Self.idleCancelInterval, repeats: false) { [weak self, weak slider] _ in
                guard let self, let slider else { return }
                self.cancelScrub(on: slider)
            }
            // Common modes so the timer still fires if the run loop enters tracking mode.
            RunLoop.main.add(timer, forMode: .common)
            idleTimer = timer
        }

        private func cancelScrub(on slider: UISlider) {
            guard !isScrubCancelled else { return }
            isScrubCancelled = true
            idleTimer = nil
            slider.setValue(Float(liveTime), animated: true)
            onScrub(nil)
        }

        @objc func tapTrack(_ gesture: UITapGestureRecognizer) {
            guard let slider = gesture.view as? UISlider, gesture.state == .ended else { return }
            // Don't steal a drag that started on the thumb.
            if slider.isTracking { return }

            let location = gesture.location(in: slider)
            let trackRect = slider.trackRect(forBounds: slider.bounds)
            let thumbRect = slider.thumbRect(forBounds: slider.bounds, trackRect: trackRect, value: slider.minimumValue)
            let thumbWidth = thumbRect.width
            let usableWidth = max(trackRect.width - thumbWidth, 1)
            let x = location.x - trackRect.minX - thumbWidth / 2
            let fraction = max(0, min(1, x / usableWidth))
            let value = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
            slider.setValue(value, animated: true)
            onSeek(TimeInterval(value))
        }
    }

    // MARK: - Asset rendering

    private static func applyImages(to slider: UISlider, accentTint: UIColor?) {
        // Resolve against the slider's own traits: an image renderer otherwise picks
        // up whatever appearance happens to be current when it runs.
        let traits = slider.traitCollection
        let filled = (accentTint ?? UIColor.label).resolvedColor(with: traits)
        slider.setMinimumTrackImage(
            makeTrackImage(height: trackHeight, color: filled),
            for: .normal
        )
        slider.setMaximumTrackImage(
            makeTrackImage(height: trackHeight, color: remainingTrackColor.resolvedColor(with: traits)),
            for: .normal
        )
        slider.setThumbImage(
            makeThumbImage(size: thumbDiameter, color: filled),
            for: .normal
        )
        slider.setThumbImage(
            makeThumbImage(size: scrubbingThumbDiameter, color: filled),
            for: .highlighted
        )
    }

    private static func sameColor(_ lhs: UIColor?, _ rhs: UIColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (l?, r?): return l === r || l.isEqual(r)
        }
    }

    private static func makeTrackImage(height: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: 3, height: height) // width is stretched by UISlider
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2)
            color.setFill()
            path.fill()
        }
        // Ensure the renderer produced a stretchable image (UISlider tiles it horizontally).
        .resizableImage(withCapInsets: .zero, resizingMode: .stretch)
    }

    private static func makeThumbImage(size: CGFloat, color: UIColor) -> UIImage {
        let inset: CGFloat = 4
        let outer = CGSize(width: size + inset * 2, height: size + inset * 2)
        let renderer = UIGraphicsImageRenderer(size: outer)
        return renderer.image { _ in
            let circle = CGRect(x: inset, y: inset, width: size, height: size)
            color.setFill()
            UIBezierPath(ovalIn: circle).fill()
        }
    }
}
