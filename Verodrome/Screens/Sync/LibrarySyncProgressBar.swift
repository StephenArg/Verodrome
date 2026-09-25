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

/// The library-sync status shown in Settings and, while a sync is running, at the top of Home.
struct LibrarySyncStatusView: View {
    let progressText: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
            LibrarySyncProgressBar(fraction: fraction)
            Text("This usually takes less than a minute.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Home's pinned copy of the settings sync status.
struct LibrarySyncHomeBanner: View {
    let progressText: String
    let fraction: Double?

    var body: some View {
        LibrarySyncStatusView(progressText: progressText, fraction: fraction)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(Color(.systemBackground))
    }
}
