import SwiftUI

/// Thin strip between a library list's filter and its rows: how many rows are below,
/// and the shuffle that plays them.
///
/// Takes plain values rather than reading the environment, so it can be hosted inside
/// the table's scrollable header, where SwiftUI environment objects don't reach.
struct LibraryShuffleCountBar: View {
    let countText: String
    /// Soft-focus the tally while a head page / sync still owns an incomplete number.
    var isCountProvisional = false
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
        isCountProvisional: Bool = false,
        isShuffleBusy: Bool = false,
        isShuffleDisabled: Bool = false,
        onShuffle: @escaping () -> Void
    ) {
        var parts = [(count, noun)]
        if let secondaryCount, let secondaryNoun {
            parts.append((secondaryCount, secondaryNoun))
        }
        self.init(
            counts: parts,
            isCountProvisional: isCountProvisional,
            isShuffleBusy: isShuffleBusy,
            isShuffleDisabled: isShuffleDisabled,
            onShuffle: onShuffle
        )
    }

    /// e.g. `[(12, "Artist"), (40, "Album"), (900, "Song")]` → "12 Artists · 40 Albums · 900 Songs".
    init(
        counts: [(Int, String)],
        isCountProvisional: Bool = false,
        isShuffleBusy: Bool = false,
        isShuffleDisabled: Bool = false,
        onShuffle: @escaping () -> Void
    ) {
        self.countText = counts.map { count, noun in
            "\(count.formatted()) \(count == 1 ? noun : noun + "s")"
        }.joined(separator: " · ")
        self.isCountProvisional = isCountProvisional
        self.isShuffleBusy = isShuffleBusy
        self.isShuffleDisabled = isShuffleDisabled
        self.onShuffle = onShuffle
    }

    init(
        countText: String,
        isCountProvisional: Bool = false,
        isShuffleBusy: Bool = false,
        isShuffleDisabled: Bool = false,
        onShuffle: @escaping () -> Void
    ) {
        self.countText = countText
        self.isCountProvisional = isCountProvisional
        self.isShuffleBusy = isShuffleBusy
        self.isShuffleDisabled = isShuffleDisabled
        self.onShuffle = onShuffle
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .blur(radius: isCountProvisional ? 5 : 0)
                .opacity(isCountProvisional ? 0.85 : 1)
                .animation(.easeOut(duration: 0.25), value: isCountProvisional)
                .accessibilityLabel(isCountProvisional ? "Counting library" : countText)

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
