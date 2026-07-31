import SwiftUI
import VerodromeKit

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.themePreference) {
                    ForEach(ThemePreference.allCases, id: \.self) { pref in
                        Text(pref.rawValue.capitalized).tag(pref)
                    }
                }
                .onChange(of: settings.themePreference) { _, _ in
                    settings.save()
                    theme.applyTheme()
                }
            }
        }
        .navigationTitle("General")
    }
}
