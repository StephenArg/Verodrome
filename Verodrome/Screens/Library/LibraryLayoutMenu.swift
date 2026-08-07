import SwiftUI
import VerodromeKit

/// Trailing toolbar control for picking album / library layout.
struct LibraryLayoutMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selection: LibraryDisplayType

    var body: some View {
        Menu {
            Picker("Layout", selection: $selection) {
                Label(LibraryDisplayType.grid3.displayName, systemImage: LibraryDisplayType.grid3.systemImage)
                    .tag(LibraryDisplayType.grid3)
                Label(LibraryDisplayType.grid2.displayName, systemImage: LibraryDisplayType.grid2.systemImage)
                    .tag(LibraryDisplayType.grid2)
                Label(LibraryDisplayType.list.displayName, systemImage: LibraryDisplayType.list.systemImage)
                    .tag(LibraryDisplayType.list)
            }
        } label: {
            Label("Layout", systemImage: "square.grid.2x2")
        }
        .onChange(of: selection) { _, _ in
            settings.save()
        }
    }
}
