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
            }

            Section {
                Button("Resolve Duplicates") {
                    let count = (try? VerodromeKit.shared.resolveDuplicates()) ?? 0
                    duplicateMessage = count == 0 ? "No duplicates found." : "Merged \(count) duplicates."
                }
                if let duplicateMessage {
                    Text(duplicateMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Merges songs, albums, and artists the server returned more than once.")
            }
        }
        .verodromePlainList()
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
