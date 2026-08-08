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
                    // Always a Label so the title column stays put whether or not the
                    // checkmark is drawn — bare Text sits flush left and drifts.
                    checkmarkLabel(option.displayName, checked: selection == option)
                }
            }

            if let downloadedOnly {
                Section {
                    Button {
                        downloadedOnly.wrappedValue.toggle()
                        settings.save()
                    } label: {
                        checkmarkLabel("Downloaded", checked: downloadedOnly.wrappedValue)
                    }
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

    /// Reserves the leading checkmark column even when unchecked, so titles line up.
    private func checkmarkLabel(_ title: String, checked: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark")
                .opacity(checked ? 1 : 0)
        }
    }
}
