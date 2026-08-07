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
                    .onChange(of: settings.smartQueuePrefetchEnabled) { _, _ in
                        settings.save()
                        // Switching off drains the cache it built; switching on fills the
                        // window for the queue that is already playing.
                        NotificationCenter.default.post(name: .queueCacheReevaluate, object: nil)
                    }

                Picker("Stale Threshold", selection: $settings.smartQueueStaleHours) {
                    ForEach(staleOptions, id: \.self) { hours in
                        Text("\(hours) hours").tag(hours)
                    }
                }
                .disabled(!settings.smartQueuePrefetchEnabled)
                .onChange(of: settings.smartQueueStaleHours) { _, _ in settings.save() }
            }

            Section {
                Picker("Cache Limit", selection: $settings.cacheLimitBytes) {
                    ForEach(PlayableCacheLimit.allCases) { limit in
                        Text(limit.label).tag(limit.rawValue)
                    }
                }
                .onChange(of: settings.cacheLimitBytes) { _, _ in
                    settings.save()
                    // A lower cap should free space immediately, not wait for the next skip.
                    NotificationCenter.default.post(name: .queueCacheReevaluate, object: nil)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Temporary queue cache is trimmed to this size. Songs you download for offline stay until you remove them.")
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
