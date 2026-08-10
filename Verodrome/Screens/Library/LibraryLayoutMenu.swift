import SwiftUI
import VerodromeKit

/// Trailing toolbar control for picking album / library layout.
struct LibraryLayoutMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selection: LibraryDisplayType

    var body: some View {
        Menu {
            Picker("Layout", selection: $selection) {
                ForEach(LibraryDisplayType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage)
                        .tag(type)
                }
            }
        } label: {
            Label("Layout", systemImage: "square.grid.2x2")
        }
        .onChange(of: selection) { _, _ in
            settings.save()
        }
    }
}
