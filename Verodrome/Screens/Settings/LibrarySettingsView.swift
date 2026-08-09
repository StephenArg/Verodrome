import SwiftUI
import VerodromeKit

struct LibrarySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @State private var isSyncing = false
    @State private var duplicateMessage: String?

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Library Synced") {
                    Text(settings.isLibrarySynced ? "Yes" : "No").foregroundStyle(.secondary)
                }
                Button(isSyncing ? "Syncing…" : "Sync Now") { syncNow() }
                    .disabled(isSyncing || librarySync.isSyncing)
                // Covers the background sync too, which holds the same lock and is what
                // disables the button — without this it looked like nothing was happening.
                if librarySync.isSyncing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(librarySync.syncProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LibrarySyncProgressBar(fraction: librarySync.syncFraction)
                        Text("This usually takes less than a minute.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Resolve Duplicates") {
                    let count = (try? VerodromeKit.shared.resolveDuplicates()) ?? 0
                    duplicateMessage = count == 0 ? "No duplicates found." : "Merged \(count) duplicates."
                }
                if let duplicateMessage {
                    Text(duplicateMessage).font(.caption).foregroundStyle(.secondary)
                }
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
                Text("Downloads")
            } footer: {
                Text("Albums, playlists, and songs wait for Wi-Fi when Only on Wi-Fi is selected. Tap Download Now on a waiting track to start it over cellular. Transcode Lossless applies to new downloads and queue prefetch; existing offline files are not re-fetched.")
            }

            Section("Library") {
                NavigationLink { LibraryEditorView() } label: {
                    Text("Customize Library Categories")
                }
            }

            Section("Home") {
                NavigationLink { HomeEditorView() } label: {
                    Text("Customize Home Sections")
                }
            }
        }
        .navigationTitle("Library")
    }

    private func syncNow() {
        isSyncing = true
        Task {
            try? await librarySync.syncLibrary()
            settings.isLibrarySynced = true
            isSyncing = false
        }
    }
}
