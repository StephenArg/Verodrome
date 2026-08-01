import SwiftUI

/// Header row for a library list: an optional shuffle button on the left and a
/// filter field that stays collapsed to a circular magnifying-glass button until
/// it's tapped, so a list that's usually browsed rather than searched keeps its
/// full height for rows.
struct LibraryFilterBar: View {
    let prompt: String
    @Binding var text: String
    /// Omitted when the list has nothing to shuffle.
    var onShuffle: (() -> Void)?

    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    private let controlDiameter: CGFloat = 40
    private let spacing: CGFloat = 10
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            // The field grows into the space the shuffle button doesn't occupy, so
            // expanding never covers it.
            let leadingWidth = onShuffle == nil ? 0 : controlDiameter + spacing
            let expandedWidth = max(controlDiameter, proxy.size.width - leadingWidth)

            HStack(spacing: spacing) {
                if let onShuffle {
                    shuffleButton(action: onShuffle)
                }
                filterField
                    .frame(width: isExpanded ? expandedWidth : controlDiameter, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .frame(height: controlDiameter)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
    }

    private func shuffleButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ShuffleControlIcon()
                .frame(width: 18, height: 18)
                .foregroundStyle(Color.primary)
                .frame(width: controlDiameter, height: controlDiameter)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle all")
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isExpanded ? Color.secondary : Color.primary)
                    .frame(width: controlDiameter, height: controlDiameter)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide filter" : "Filter")

            if isExpanded {
                TextField(prompt, text: $text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .transition(.opacity)

                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                    .transition(.opacity)
                }
            }
        }
        .padding(.trailing, isExpanded ? 14 : 0)
        .frame(height: controlDiameter)
        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        .clipShape(Capsule())
    }

    /// Collapsing clears the text: a hidden field still filtering the list would
    /// leave missing rows with nothing on screen to explain them.
    private func toggle() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            isExpanded.toggle()
            if !isExpanded {
                text = ""
            }
        }
        isFocused = isExpanded
    }
}
