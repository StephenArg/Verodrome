import SwiftUI
import VerodromeKit

/// Trailing toolbar control for picking a library list's ordering.
struct LibrarySortMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selection: LibrarySortOption
    let options: [LibrarySortOption]

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(options) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        // `SettingsStore` only writes to UserDefaults when asked, so a toolbar change
        // is lost on relaunch without this.
        .onChange(of: selection) { _, _ in
            settings.save()
        }
    }
}
