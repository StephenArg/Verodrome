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
