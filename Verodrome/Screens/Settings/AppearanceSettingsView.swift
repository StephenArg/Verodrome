import SwiftUI
import VerodromeKit

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.themePreference) {
                    ForEach(ThemePreference.allCases, id: \.self) { pref in
                        Text(pref.rawValue.capitalized).tag(pref)
                    }
                }
                .onChange(of: settings.themePreference) { _, _ in
                    settings.save()
                    theme.applyTheme()
                }
            }

            Section {
                HStack {
                    Text("Accent Color")
                    Spacer(minLength: 12)
                    ColorPicker("", selection: accentColorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .disabled(account.activeAccountKey() == nil)
                }
                Button("Reset Accent Color") {
                    theme.setAccountThemeColor(nil)
                }
                .disabled(account.activeAccountKey() == nil)
            } header: {
                Text("Accent")
            } footer: {
                Text("The accent color is stored per account, so each server you sign in to can have its own.")
            }

            Section("App Icon") {
                NavigationLink { AppIconSettingsView() } label: {
                    Text("App Icon")
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Appearance")
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: {
                if let key = account.activeAccountKey(),
                   let hex = settings.loadAccountSettings(for: key).themeColorHex,
                   let color = Color(hex: hex) {
                    return color
                }
                return theme.accentColor
            },
            set: { theme.setAccountThemeColor($0) }
        )
    }
}
