import SwiftUI
import VerodromeKit

struct PlayerSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var player: PlayerViewModel

    private let staleOptions = [12, 18, 24]

    var body: some View {
        Form {
            Section("Streaming") {
                Picker("Format", selection: $settings.streamFormat) {
                    ForEach(StreamFormatPreference.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
            }

            Section("Smart Queue Prefetch") {
                Toggle("Enable Smart Queue Prefetch", isOn: $settings.smartQueuePrefetchEnabled)
                    .onChange(of: settings.smartQueuePrefetchEnabled) { _, _ in settings.save() }

                Picker("Stale Threshold", selection: $settings.smartQueueStaleHours) {
                    ForEach(staleOptions, id: \.self) { hours in
                        Text("\(hours) hours").tag(hours)
                    }
                }
                .disabled(!settings.smartQueuePrefetchEnabled)
                .onChange(of: settings.smartQueueStaleHours) { _, _ in settings.save() }
            }

            Section("Offline") {
                Toggle("Offline Mode", isOn: Binding(
                    get: { player.isOfflineMode },
                    set: { _ in player.toggleOfflineMode() }
                ))
            }
        }
        .navigationTitle("Player")
    }
}
