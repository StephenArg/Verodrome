import SwiftUI

extension View {
    /// Plain list chrome matching Library/Favorites: flat rows on the app background.
    /// Plain lists also need `verodromePlainRow()` on their rows.
    func verodromePlainList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VerodromeTheme.background)
    }

    /// Row fill for plain lists. Plain rows otherwise paint `systemBackground`, which shows
    /// as white strips across the light-mode page. Opaque rather than clear so a swiped or
    /// lifted row doesn't draw through to whatever is behind it.
    func verodromePlainRow() -> some View {
        listRowBackground(VerodromeTheme.background)
    }

    /// The app background behind a whole screen, under the navigation bar included. For
    /// screens that aren't a list, and for UIKit-backed ones whose own background starts
    /// below the bar.
    func verodromeScreenBackground() -> some View {
        background(VerodromeTheme.background)
    }
}
