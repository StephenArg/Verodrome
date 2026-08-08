import SwiftUI

/// Thin strip between a library list's filter and its rows: how many rows are below,
/// and the shuffle that plays them.
///
/// Takes plain values rather than reading the environment, so it can be hosted inside
/// the table's scrollable header, where SwiftUI environment objects don't reach.
struct LibraryShuffleCountBar: View {
    let count: Int
    /// Singular/plural noun for the rows being counted ("song").
    let noun: String
    var isShuffleBusy = false
    /// Shuffle draws from the whole library, which no backend's random endpoint can
    /// narrow to a typed filter — so it steps aside while one is active.
    var isShuffleDisabled = false
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count.formatted()) \(count == 1 ? noun : noun + "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(action: onShuffle) {
                HStack(spacing: 6) {
                    if isShuffleBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        ShuffleControlIcon()
                            .frame(width: 16, height: 16)
                    }
                    Text("Shuffle")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                .opacity(isShuffleDisabled ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isShuffleBusy || isShuffleDisabled)
            .accessibilityLabel("Shuffle all")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
