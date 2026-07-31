import SwiftUI
import VerodromeKit

struct SyncView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var librarySync: LibrarySyncCoordinator
    @State private var didStart = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: librarySync.isSyncing)

            VStack(spacing: 8) {
                Text("Syncing Library")
                    .font(.title.bold())
                Text(librarySync.syncProgressText.isEmpty ? "Preparing your music…" : librarySync.syncProgressText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .controlSize(.large)

            Spacer()

            Button("Cancel", role: .cancel) {
                librarySync.cancelSync()
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 32)
        }
        .padding()
        .task {
            guard !didStart else { return }
            didStart = true
            do {
                try await librarySync.syncLibrary()
                settings.isLibrarySynced = true
            } catch {
                librarySync.cancelSync()
            }
        }
    }
}
