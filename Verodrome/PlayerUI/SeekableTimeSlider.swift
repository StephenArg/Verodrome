import SwiftUI
import UIKit

/// Scrubber that only commits seeks when the user finishes dragging (or taps the track).
/// Binding a SwiftUI `Slider` directly to `seek(to:)` re-enters AudioStreaming's
/// seek request on every view update and can pin `progress` at the seek time (often 0).
struct SeekableTimeSlider: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        SeekableTimeSliderUIKit(
            currentTime: currentTime,
            duration: duration,
            onSeek: onSeek
        )
        .frame(height: 28)
    }
}

/// UIKit slider (Amperfy-style): never fights the thumb while tracking, seeks on release only.
/// Styled to match the target player: thin track, prominent white circular thumb.
/// Tapping anywhere on the track jumps to that position.
struct SeekableTimeSliderUIKit: UIViewRepresentable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(max(duration, 1))
        slider.value = Float(currentTime)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchUpInside)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchUpOutside)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: .touchCancel)

        // Thin track.
        let trackHeight: CGFloat = 3
        slider.setMinimumTrackImage(Self.makeTrackImage(height: trackHeight, color: .white), for: .normal)
        slider.setMaximumTrackImage(Self.makeTrackImage(height: trackHeight, color: UIColor(white: 1, alpha: 0.22)), for: .normal)

        // Prominent white circular thumb.
        slider.setThumbImage(Self.makeThumbImage(size: 16), for: .normal)
        slider.setThumbImage(Self.makeThumbImage(size: 16), for: .highlighted)

        // Tap-to-seek: UISlider only moves the thumb when dragging by default.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapTrack(_:)))
        tap.numberOfTapsRequired = 1
        slider.addGestureRecognizer(tap)
        context.coordinator.tapGesture = tap

        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        context.coordinator.onSeek = onSeek
        let maxValue = Float(max(duration, 1))
        if abs(uiView.maximumValue - maxValue) > 0.01 {
            uiView.maximumValue = maxValue
            // Re-apply track images since max-value changes can invalidate them.
            let trackHeight: CGFloat = 3
            uiView.setMinimumTrackImage(Self.makeTrackImage(height: trackHeight, color: .white), for: .normal)
            uiView.setMaximumTrackImage(Self.makeTrackImage(height: trackHeight, color: UIColor(white: 1, alpha: 0.22)), for: .normal)
        }
        // Match Amperfy: never fight the thumb while the user is dragging.
        if !uiView.isTracking {
            let next = Float(min(max(currentTime, 0), TimeInterval(maxValue)))
            if abs(uiView.value - next) > 0.05 {
                uiView.value = next
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek)
    }

    final class Coordinator: NSObject {
        var onSeek: (TimeInterval) -> Void
        weak var tapGesture: UITapGestureRecognizer?

        init(onSeek: @escaping (TimeInterval) -> Void) {
            self.onSeek = onSeek
        }

        @objc func touchUp(_ sender: UISlider) {
            onSeek(TimeInterval(sender.value))
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

    private static func makeThumbImage(size: CGFloat) -> UIImage {
        let inset: CGFloat = 4
        let outer = CGSize(width: size + inset * 2, height: size + inset * 2)
        let renderer = UIGraphicsImageRenderer(size: outer)
        return renderer.image { _ in
            let circle = CGRect(x: inset, y: inset, width: size, height: size)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: circle).fill()
        }
    }
}
