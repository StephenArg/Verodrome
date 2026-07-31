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
                Button("Resolve Duplicates") {
                    let count = (try? VerodromeKit.shared.resolveDuplicates()) ?? 0
                    duplicateMessage = count == 0 ? "No duplicates found." : "Merged \(count) duplicates."
                }
                if let duplicateMessage {
                    Text(duplicateMessage).font(.caption).foregroundStyle(.secondary)
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
