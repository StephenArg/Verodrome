import SwiftUI
import VerodromeKit

struct CarPlaySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Mini Skips", isOn: $settings.carPlayMiniSkipEnabled)
                    .onChange(of: settings.carPlayMiniSkipEnabled) { _, _ in settings.save() }
                if settings.carPlayMiniSkipEnabled {
                    Picker("Interval", selection: $settings.carPlayMiniSkipInterval) {
                        ForEach(MiniSkipInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    .onChange(of: settings.carPlayMiniSkipInterval) { _, _ in settings.save() }
                }
            } header: {
                Text("Next & Previous")
            } footer: {
                Text("When on, holding Next or Previous jumps by the interval, with a short play at each stop. Turn this off to hold Next for double speed and Previous for half speed. A tap still changes tracks.")
            }
        }
        .verodromePlainList()
        .navigationTitle("CarPlay")
    }
}
