import Foundation
import Combine

@MainActor
public final class LibrarySyncCoordinator: ObservableObject {
    public static let shared = LibrarySyncCoordinator()

    @Published public private(set) var isSyncing = false
    /// True when this sync crawls every song. Catalog refreshes and the home-list
    /// update leave this false, so Home can ignore those quicker passes.
    @Published public private(set) var isFullSync = false
    /// The step a sync is on, manual or background. Library settings always shows it.
    /// Home shows it only for a full song sync, and only while that toggle is on.
    @Published public private(set) var syncProgressText = ""
    /// Overall completion, 0...1. Nil until the first step that can size itself.
    @Published public private(set) var syncFraction: Double?
    @Published public private(set) var lastError: String?

    public init() {}

    /// Manual / blocking full sync (catalog + all tracks). Used by Library settings.
    public func syncLibrary() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        isFullSync = true
        lastError = nil
        syncProgressText = "Starting…"
        syncFraction = nil
        defer {
            isSyncing = false
            isFullSync = false
        }
        do {
            try await VerodromeKit.shared.performInitialSync()
            syncProgressText = "Done"
            syncFraction = 1
        } catch {
            lastError = error.localizedDescription
            syncProgressText = error.localizedDescription
            throw error
        }
    }

    /// Non-blocking background refresh: catalog only when needed, Home lists, and the track
    /// backfill when it is still due. Safe to call repeatedly.
    /// Home shows progress only when this pass will crawl every song.
    public func runBackground() {
        guard !isSyncing else { return }
        Task {
            isSyncing = true
            isFullSync = VerodromeKit.shared.willBackfillAllSongs()
            lastError = nil
            syncProgressText = "Starting…"
            syncFraction = nil
            defer {
                isSyncing = false
                isFullSync = false
            }
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
        isFullSync = false
        syncProgressText = "Cancelled"
    }

    public func updateProgress(_ progress: LibrarySyncProgress) {
        syncProgressText = progress.message
        // Steps that can't size themselves leave the bar where it is. Clearing it would
        // drop back to indeterminate every time a skipped phase or an ingest count
        // lands between two measured steps.
        if let fraction = progress.fraction {
            syncFraction = fraction
        }
    }
}
