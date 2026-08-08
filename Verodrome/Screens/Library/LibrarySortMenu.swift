import SwiftUI
import VerodromeKit

/// Trailing toolbar control for picking a library list's ordering.
///
/// Built from plain `Button`s rather than a `Picker`: the picker style pads every row
/// out to a wide menu even when the labels are short.
struct LibrarySortMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selection: LibrarySortOption
    let options: [LibrarySortOption]
    /// Songs-only. When set, a second section toggles a downloaded-only filter.
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }

            if let downloadedOnly {
                Section {
                    Toggle("Downloaded", isOn: Binding(
                        get: { downloadedOnly.wrappedValue },
                        set: {
                            downloadedOnly.wrappedValue = $0
                            settings.save()
                        }
                    ))
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
