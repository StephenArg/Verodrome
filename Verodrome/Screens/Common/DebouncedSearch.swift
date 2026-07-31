import SwiftUI

/// Debounces a `@State` string so a closure fires only after the value stops
/// changing for `delay`. Used to throttle `.searchable` text refetches.
@MainActor
struct DebouncedSearch: ViewModifier {
    @Binding var text: String
    var delay: Duration = .milliseconds(250)
    var onChange: (String) -> Void

    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, newValue in
                task?.cancel()
                task = Task {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    onChange(newValue)
                }
            }
    }
}

extension View {
    /// Debounce a `.searchable` binding by `delay` before invoking `onChange`.
    func debouncedSearch(
        text: Binding<String>,
        delay: Duration = .milliseconds(250),
        onChange: @escaping (String) -> Void
    ) -> some View {
        modifier(DebouncedSearch(text: text, delay: delay, onChange: onChange))
    }
}
