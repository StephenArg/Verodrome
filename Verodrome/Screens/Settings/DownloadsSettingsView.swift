import SwiftUI
import VerodromeKit

struct DownloadsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var offlineBytes: Int64 = 0
    @State private var offlineCount = 0
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Storage Used") {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text(byteFormatter.string(fromByteCount: offlineBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Downloaded Tracks") {
                    Text("\(offlineCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("On This Device")
            } footer: {
                Text("Songs, albums, and playlists you downloaded for offline listening. Temporary queue cache is listed under Storage.")
            }

            Section {
                Picker("Download Over", selection: $settings.automaticDownloadNetwork) {
                    ForEach(AutomaticDownloadNetwork.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: settings.automaticDownloadNetwork) { _, _ in
                    settings.save()
                    Task { await VerodromeKit.shared.downloadNetworkPolicy?.apply() }
                }

                Picker("Transcode Lossless", selection: $settings.downloadTranscodeQuality) {
                    ForEach(AudioTranscodeQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: settings.downloadTranscodeQuality) { _, _ in settings.save() }
            } header: {
                Text("Music")
            } footer: {
                Text("Albums, playlists, and songs wait for Wi-Fi when Only on Wi-Fi is selected. Tap Download Now on a waiting track to start it over cellular. Transcode Lossless applies to new downloads and queue prefetch; existing offline files are not re-fetched.")
            }

            Section {
                Picker("Download Artwork", selection: $settings.artworkDownloadSetting) {
                    ForEach(ArtworkDownloadSetting.allCases, id: \.self) { setting in
                        Text(setting.label).tag(setting)
                    }
                }
                .onChange(of: settings.artworkDownloadSetting) { _, value in
                    settings.save()
                    if let key = AccountStore.shared.activeAccountKey() {
                        var account = settings.loadAccountSettings(for: key)
                        account.artworkDownloadSetting = value
                        settings.saveAccountSettings(account, for: key)
                    }
                }
            } header: {
                Text("Artwork")
            } footer: {
                Text("Cover art is cached as it is displayed. Clear the cache from Storage.")
            }
        }
        .verodromePlainList()
        .navigationTitle("Downloads")
        .task {
            await refreshStorageStats()
        }
        .refreshable {
            await refreshStorageStats()
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }

    private func refreshStorageStats() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let cache = VerodromeKit.shared.playableCache
        let stats = await Task.detached(priority: .utility) {
            cache?.playableCacheStats() ?? .empty
        }.value
        offlineBytes = stats.offlineBytes
        offlineCount = stats.offlineCount
    }
}

private extension ArtworkDownloadSetting {
    var label: String {
        switch self {
        case .never: "Never"
        case .wifiOnly: "Wi‑Fi Only"
        case .always: "Always"
        }
    }
}
