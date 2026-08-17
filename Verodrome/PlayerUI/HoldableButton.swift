import SwiftUI

/// Button that fires `onTap` on a quick press, or `onHoldStart` / `onHoldEnd` when
/// the finger stays down past `holdDelay`. Used for skip (tap) vs speed-hold.
struct HoldableButton<Label: View>: View {
    var isEnabled: Bool = true
    /// Delay before a press becomes a hold (keeps short taps as taps).
    var holdDelayNanoseconds: UInt64 = 350_000_000
    var onTap: () -> Void
    var onHoldStart: () -> Void
    var onHoldEnd: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false

    var body: some View {
        label()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, holdTask == nil, !isHolding else { return }
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: holdDelayNanoseconds)
                            guard !Task.isCancelled else { return }
                            isHolding = true
                            onHoldStart()
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        if isHolding {
                            isHolding = false
                            onHoldEnd()
                        } else if isEnabled {
                            onTap()
                        }
                    }
            )
            .disabled(!isEnabled)
            // If the view goes away mid-hold (e.g. player dismissed), restore rate.
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
                if isHolding {
                    isHolding = false
                    onHoldEnd()
                }
            }
    }
}

/// Detects a still-finger hold on the receiver and reports the initial touch
/// location. Uses a `DragGesture(minimumDistance: 0)` as a passive touch tracker
/// so the timer starts on touch-down (a `LongPressGesture.sequenced(before:)`
/// would starve if the finger never moves, delaying the fire indefinitely).
/// Attached with `.simultaneousGesture` so tap / double-tap / swipe on the same
/// view still recognize.
struct HoldSpeedModifier: ViewModifier {
    var enabled: Bool
    var duration: TimeInterval = 0.2
    var maxDistance: CGFloat = 14
    var onStart: (CGPoint) -> Void
    var onEnd: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var pressLocation: CGPoint = .zero
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if holdTask == nil, !isHolding {
                            pressLocation = value.startLocation
                            let delayNanos = UInt64(duration * 1_000_000_000)
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: delayNanos)
                                guard !Task.isCancelled else { return }
                                isHolding = true
                                onStart(pressLocation)
                            }
                        }
                        // Cancel the arming timer once the user has clearly moved:
                        // that's a swipe, not a hold.
                        if !isHolding {
                            let dx = abs(value.translation.width)
                            let dy = abs(value.translation.height)
                            if dx > maxDistance || dy > maxDistance {
                                holdTask?.cancel()
                                holdTask = nil
                            }
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        if isHolding {
                            isHolding = false
                            onEnd()
                        }
                    },
                including: enabled ? .all : .subviews
            )
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
                if isHolding {
                    isHolding = false
                    onEnd()
                }
            }
    }
}

extension View {
    func holdSpeed(
        enabled: Bool,
        duration: TimeInterval = 0.2,
        maxDistance: CGFloat = 14,
        onStart: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        modifier(HoldSpeedModifier(
            enabled: enabled,
            duration: duration,
            maxDistance: maxDistance,
            onStart: onStart,
            onEnd: onEnd
        ))
    }
}
