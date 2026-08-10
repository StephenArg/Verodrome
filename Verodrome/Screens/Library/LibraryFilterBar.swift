import SwiftUI

/// Filter field used by library lists and detail accessories. Always open: the list it
/// heads is long enough that filtering is a normal way to use it, and a field that is
/// already there costs one tap less than one that has to be revealed.
struct LibraryFilterBar: View {
    let prompt: String
    @Binding var text: String
    /// When true (default), adds the inset used above a full-width library table.
    /// Detail accessories sit inside an already-padded header and pass `false`.
    var showsOuterPadding: Bool = true

    @FocusState private var isFocused: Bool

    private let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .focused($isFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // A TextField's intrinsic width tracks its text, which would push the
                // clear button out of the field once enough is typed.
                .frame(minWidth: 0, maxWidth: .infinity)

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
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, showsOuterPadding ? 16 : 0)
        .padding(.vertical, showsOuterPadding ? 8 : 0)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}
