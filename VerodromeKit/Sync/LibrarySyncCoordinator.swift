import Foundation
import Combine

@MainActor
public final class LibrarySyncCoordinator: ObservableObject {
    public static let shared = LibrarySyncCoordinator()

    @Published public private(set) var isSyncing = false
    /// Only updated for *manual* Sync Now — background sync stays silent in the UI.
    @Published public private(set) var syncProgressText = ""
    @Published public private(set) var lastError: String?

    /// When false, progress callbacks do not publish to `syncProgressText`.
    private var publishesProgress = false

    public init() {}

    /// Manual / blocking full sync (catalog + all tracks). Used by Library settings.
    public func syncLibrary() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        publishesProgress = true
        lastError = nil
        syncProgressText = "Starting…"
        defer {
            isSyncing = false
            publishesProgress = false
        }
        do {
            try await VerodromeKit.shared.performInitialSync()
            syncProgressText = "Done"
        } catch {
            lastError = error.localizedDescription
            syncProgressText = error.localizedDescription
            throw error
        }
    }

    /// Non-blocking background catalog + optional track backfill. Safe to call repeatedly.
    /// Does not surface a banner — library UI stays usable while this runs.
    public func runBackground() {
        guard !isSyncing else { return }
        Task {
            isSyncing = true
            publishesProgress = false
            lastError = nil
            syncProgressText = ""
            defer { isSyncing = false }
            do {
                // Ingest runs on its own background ModelActor now; this pause just keeps
                // its disk and SQLite traffic away from first paint and artwork loads.
                try? await Task.sleep(nanoseconds: 750_000_000)
                try await VerodromeKit.shared.startBackgroundLibrarySync()
            } catch {
                lastError = error.localizedDescription
                await EventLogger.shared.warning("sync", "Background sync failed: \(error.localizedDescription)")
            }
        }
    }

    public func cancelSync() {
        isSyncing = false
        syncProgressText = "Cancelled"
        publishesProgress = false
    }

    public func updateProgress(_ text: String) {
        guard publishesProgress else { return }
        syncProgressText = text
    }
}
