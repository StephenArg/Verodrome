import SwiftUI

/// Sync progress: a determinate bar with a percentage once a step reports its position
/// on the overall bar, and an indeterminate spinner until one does.
struct LibrarySyncProgressBar: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            VStack(spacing: 4) {
                ProgressView(value: fraction)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }
}
