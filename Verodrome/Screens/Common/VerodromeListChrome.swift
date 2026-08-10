import SwiftUI

extension View {
    /// Plain list chrome matching Library/Favorites: flat rows on `systemBackground`.
    func verodromePlainList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
    }
}
