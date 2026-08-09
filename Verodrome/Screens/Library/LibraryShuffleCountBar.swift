import SwiftUI

/// Thin strip between a library list's filter and its rows: how many rows are below,
/// and the shuffle that plays them.
///
/// Takes plain values rather than reading the environment, so it can be hosted inside
/// the table's scrollable header, where SwiftUI environment objects don't reach.
struct LibraryShuffleCountBar: View {
    let countText: String
    var isShuffleBusy = false
    /// Shuffle draws from the whole library, which no backend's random endpoint can
    /// narrow to a typed filter — so it steps aside while one is active.
    var isShuffleDisabled = false
    let onShuffle: () -> Void

    init(
        count: Int,
        noun: String,
        secondaryCount: Int? = nil,
        secondaryNoun: String? = nil,
        isShuffleBusy: Bool = false,
        isShuffleDisabled: Bool = false,
        onShuffle: @escaping () -> Void
    ) {
        var parts = ["\(count.formatted()) \(count == 1 ? noun : noun + "s")"]
        if let secondaryCount, let secondaryNoun {
            parts.append(
                "\(secondaryCount.formatted()) \(secondaryCount == 1 ? secondaryNoun : secondaryNoun + "s")"
            )
        }
        self.countText = parts.joined(separator: " · ")
        self.isShuffleBusy = isShuffleBusy
        self.isShuffleDisabled = isShuffleDisabled
        self.onShuffle = onShuffle
    }

    init(
        countText: String,
        isShuffleBusy: Bool = false,
        isShuffleDisabled: Bool = false,
        onShuffle: @escaping () -> Void
    ) {
        self.countText = countText
        self.isShuffleBusy = isShuffleBusy
        self.isShuffleDisabled = isShuffleDisabled
        self.onShuffle = onShuffle
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
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
