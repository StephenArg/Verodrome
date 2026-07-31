import SwiftUI
import VerodromeKit

struct ArtworkSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var cacheBytes: Int64 = 0
    @State private var cacheFileCount = 0
    @State private var isRefreshing = false
    @State private var isClearing = false
    @State private var showClearConfirm = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Artwork Download", selection: $settings.artworkDownloadSetting) {
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
            }

            Section {
                LabeledContent("Storage Used") {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text(byteFormatter.string(fromByteCount: cacheBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Cached Files") {
                    Text("\(cacheFileCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Clear Artwork Cache", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(isClearing || (cacheBytes == 0 && cacheFileCount == 0))
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Cached cover art on this device. Clearing frees space; artwork will download again when needed.")
            }
        }
        .navigationTitle("Artwork")
        .task {
            await refreshCacheStats()
        }
        .refreshable {
            await refreshCacheStats()
        }
        .confirmationDialog(
            "Clear Artwork Cache?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(byteFormatter.string(fromByteCount: cacheBytes)) of downloaded cover art from this device.")
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }

    private func refreshCacheStats() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let stats = await ArtworkResolver.shared.diskCacheStats()
        cacheBytes = stats.totalBytes
        cacheFileCount = stats.fileCount
    }

    private func clearCache() async {
        isClearing = true
        statusMessage = nil
        defer { isClearing = false }
        do {
            ArtworkImageCache.shared.removeAll()
            try await ArtworkResolver.shared.clearCaches()
            await refreshCacheStats()
            statusMessage = "Artwork cache cleared."
        } catch {
            statusMessage = "Couldn’t clear cache: \(error.localizedDescription)"
        }
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
