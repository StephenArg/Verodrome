import Foundation

/// Orchestrates a single canonical-ID migration attempt: gate → probe → plan → apply →
/// mark done, plus the backward-regression / abort branches. The individual pieces
/// (`CanonicalIdEpochDecision`, `NavidromeCanonicalIdProbe`, `NavidromeIdMigration`,
/// `NavidromeIdMapStore`) are testable in isolation; this type stitches them together in
/// the exact order the plan calls for.
///
/// The coordinator is deliberately **DB-agnostic** — it takes closures for the two work
/// units it can't do on its own (planning+applying a forward migration, applying the
/// inverse of a retained map). Wiring those closures to `LibraryRepository`, the file
/// migrator, and the aux stores happens in `NavidromeIdMigrationHook`, at the call site
/// above `ensureActiveLibrarySyncer`'s early return.
///
/// Isolation: the coordinator is main-actor-bound because the closures it invokes touch
/// `ObservableSettings`, `LibraryRepository`, and other main-actor state. `run` still
/// suspends the main actor during network / file I/O, so it does not block UI work.
@MainActor
public struct NavidromeIdMigrationCoordinator {

    /// Everything the coordinator needs, factored so tests can hand in fakes without
    /// wiring up a full backend.
    public struct Dependencies {
        /// Currently reported server version (last observed `ping` / `getSong`).
        public var reportedVersion: () -> String?
        /// The version at which local IDs were last confirmed to match the server's
        /// scheme. `nil` means never verified.
        public var markerVersion: () -> String?
        /// Server type name — non-Navidrome servers skip the entire flow.
        public var serverTypeName: () -> String?
        /// Records that this reported version is now the source of truth for local IDs.
        /// Called once at the end of a successful path (seed / already-consistent /
        /// forward / backward / forced re-sync).
        public var writeMarker: (String) -> Void
        /// Called when the coordinator decides it cannot safely continue without a
        /// full library re-sync — a backward-epoch regression with no retained map, or
        /// a map whose "from" side doesn't line up. The implementation should clear
        /// per-account library state so the next `ensureActiveLibrarySyncer` re-hydrates
        /// from scratch.
        public var forceFullResync: () async -> Void
        /// Samples a handful of song IDs, preferring downloaded ones, for the probe.
        /// Fewer than requested is fine — the probe tolerates small samples.
        public var sampleCandidateSongIds: (_ limit: Int) -> [String]
        /// Answers "does the server currently recognize this ID?" — implemented as a
        /// `getSong` call. Throws on transport errors so the probe can distinguish
        /// "server said no" from "we could not ask".
        public var songResolves: (String) async throws -> Bool
        /// The map store scoped to the current account. The coordinator uses it to
        /// resume torn maps and to look up the retained map for the backward branch.
        public var mapStore: NavidromeIdMapStore
        /// Plan-and-apply the forward migration end-to-end: build the `[old:new]` map
        /// from the DB, write it to `mapStore`, apply it to SwiftData / files / aux
        /// stores, mark it applied, and re-save. Returns the number of unique IDs
        /// rewritten. Throws on any failure — the coordinator treats a throw as a
        /// probe-abort so the next launch will re-try.
        public var planAndApplyForward: (_ toVersion: String, _ fromVersion: String?) async throws -> Int
        /// Apply a specific map (used for backward regressions with a retained forward
        /// map, and for resuming a torn map on launch). Returns unique-ID count applied.
        public var applyMap: (NavidromeIdMap) async throws -> Int
        /// Optional event sink — the hook logs the outcome.
        public var log: (String) -> Void
        /// Show a blocking overlay for the duration of a real ID check (probe + remap).
        public var presentBusyOverlay: (String) async -> Void
        /// Hide the overlay presented by `presentBusyOverlay`. No-op if nothing is showing.
        public var dismissBusyOverlay: () -> Void

        public init(
            reportedVersion: @escaping () -> String?,
            markerVersion: @escaping () -> String?,
            serverTypeName: @escaping () -> String?,
            writeMarker: @escaping (String) -> Void,
            forceFullResync: @escaping () async -> Void,
            sampleCandidateSongIds: @escaping (Int) -> [String],
            songResolves: @escaping (String) async throws -> Bool,
            mapStore: NavidromeIdMapStore,
            planAndApplyForward: @escaping (String, String?) async throws -> Int,
            applyMap: @escaping (NavidromeIdMap) async throws -> Int,
            log: @escaping (String) -> Void = { _ in },
            presentBusyOverlay: @escaping (String) async -> Void = { _ in },
            dismissBusyOverlay: @escaping () -> Void = {}
        ) {
            self.reportedVersion = reportedVersion
            self.markerVersion = markerVersion
            self.serverTypeName = serverTypeName
            self.writeMarker = writeMarker
            self.forceFullResync = forceFullResync
            self.sampleCandidateSongIds = sampleCandidateSongIds
            self.songResolves = songResolves
            self.mapStore = mapStore
            self.planAndApplyForward = planAndApplyForward
            self.applyMap = applyMap
            self.log = log
            self.presentBusyOverlay = presentBusyOverlay
            self.dismissBusyOverlay = dismissBusyOverlay
        }
    }

    /// The externally observable result of one `run`. Exposed for logging and tests.
    public enum Outcome: Equatable {
        /// Non-Navidrome server or same epoch — nothing to do.
        case noop
        /// First-time marker seed against a pre-0.64 server; no probe fired.
        case seededMarker
        /// The probe confirmed local IDs are already canonical; marker updated.
        case alreadyConsistent
        /// Forward migration applied. `entriesApplied` is the number of unique IDs
        /// rewritten across all kinds.
        case migratedForward(entriesApplied: Int)
        /// Backward regression handled by inverting the retained map.
        case migratedBackward(entriesApplied: Int)
        /// Backward regression detected but no map was on disk to invert — the caller
        /// forced a full re-sync (and orphaned downloads will be pruned by the existing
        /// cache-management passes).
        case forcedResync
        /// Probe could not decide (transport failure, empty sample, etc.). Marker is
        /// left as-is so the next `ensureActiveLibrarySyncer` re-tries.
        case probeAborted
        /// A resumable run picked up an unapplied map from a previous launch and
        /// finished applying it.
        case resumed(entriesApplied: Int)
    }

    public let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Run one migration attempt. Safe to call on every `ensureActiveLibrarySyncer`
    /// invocation — the same-epoch fast path is one settings read.
    public func run() async -> Outcome {
        let deps = dependencies

        // Non-Navidrome backends never touch the flow. Ampache / gonic don't do the
        // ID transform and don't need the probe.
        if let serverType = deps.serverTypeName()?.lowercased(),
           serverType.contains("ampache") || serverType.contains("gonic") {
            return .noop
        }

        // 0. Resume an interrupted run first. A map that exists but is not yet applied
        //    means the previous launch crashed after the plan but before the apply. The
        //    reported version does not matter here — the previous run had already
        //    committed to this transition; finish it.
        if let stored = deps.mapStore.load(), stored.applied == false, !stored.entries.isEmpty {
            return await withBusyOverlay("Updating library IDs…") {
                do {
                    let entries = try await deps.applyMap(stored)
                    var completed = stored
                    completed.applied = true
                    try? deps.mapStore.save(completed)
                    deps.writeMarker(stored.toVersion)
                    deps.log("navidrome id migration resumed: applied \(entries) entries to \(stored.toVersion)")
                    return .resumed(entriesApplied: entries)
                } catch {
                    deps.log("navidrome id migration resume failed: \(error.localizedDescription); will retry next launch")
                    return .probeAborted
                }
            }
        }

        // 1. Cheap gate — decides whether to probe at all. Same epoch is a no-op both
        //    for old servers and for already-migrated ones, and costs one settings read.
        let decision = CanonicalIdEpochDecision.decide(
            serverTypeName: deps.serverTypeName(),
            reportedVersion: deps.reportedVersion(),
            markerVersion: deps.markerVersion()
        )

        switch decision {
        case .skip:
            // Cached version is already in the same ID epoch as the live server.
            return .noop
        case .seedMarker:
            if let v = deps.reportedVersion() { deps.writeMarker(v) }
            return .seededMarker
        case .probeForward:
            return await withBusyOverlay("Checking library IDs…") {
                await handleProbe(direction: .forward)
            }
        case .probeBackward:
            return await withBusyOverlay("Checking library IDs…") {
                await handleProbe(direction: .backward)
            }
        }
    }

    // MARK: - Probe branches

    /// Probe first, only touch data on a decisive answer. `direction` disambiguates
    /// which side of the transform the probe should check — `.forward` verifies that
    /// `canonical(oldId)` resolves, `.backward` verifies that the old id still does.
    private func handleProbe(direction: NavidromeCanonicalIdProbe.Direction) async -> Outcome {
        let deps = dependencies
        let sample = deps.sampleCandidateSongIds(NavidromeCanonicalIdProbe.defaultSampleSize)
        guard !sample.isEmpty else {
            // Empty library — nothing to migrate *yet*. Do not write the marker: the
            // next launch that actually has songs still needs to probe, otherwise a
            // 0.64 label with unfixed IDs sticks forever.
            deps.log("navidrome id probe has no local songs yet; leaving marker unchanged")
            return .noop
        }

        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: sample,
            direction: direction,
            resolves: deps.songResolves
        )

        switch outcome {
        case .alreadyConsistent:
            if let v = deps.reportedVersion() { deps.writeMarker(v) }
            return .alreadyConsistent

        case .needsForward:
            await deps.presentBusyOverlay("Updating library IDs…")
            return await runForwardMigration()

        case .needsBackward:
            await deps.presentBusyOverlay("Updating library IDs…")
            return await runBackwardMigration()

        case .abort(let reason):
            // All local IDs are already canonical (the probe filters those out), so
            // there is nothing to rewrite. Persist the marker or the next launch
            // treats the cache as blank and checks again.
            if reason == .noSamplesAvailable {
                if let v = deps.reportedVersion() { deps.writeMarker(v) }
                return .alreadyConsistent
            }
            deps.log("navidrome id probe inconclusive; leaving marker unchanged")
            return .probeAborted
        }
    }

    /// Overlay around a real check. Nested presents only update the status text.
    private func withBusyOverlay(
        _ message: String,
        _ work: () async -> Outcome
    ) async -> Outcome {
        await dependencies.presentBusyOverlay(message)
        defer { dependencies.dismissBusyOverlay() }
        return await work()
    }

    /// Delegate to the hook to build+persist+apply. The hook is responsible for the
    /// write-map-before-apply ordering that makes the run resumable.
    private func runForwardMigration() async -> Outcome {
        let deps = dependencies
        let toVersion = deps.reportedVersion() ?? "unknown"
        let fromVersion = deps.markerVersion()
        do {
            let entries = try await deps.planAndApplyForward(toVersion, fromVersion)
            deps.writeMarker(toVersion)
            deps.log("navidrome id migration forward: \(entries) entries applied to \(toVersion)")
            return .migratedForward(entriesApplied: entries)
        } catch {
            deps.log("navidrome id migration forward failed: \(error.localizedDescription)")
            return .probeAborted
        }
    }

    /// Backward regression — the reported version dropped below the last-verified epoch.
    /// The forward transform is not analytically invertible (overflowing IDs go through
    /// MD5), so the only safe path is the retained forward map inverted, or a full
    /// re-sync if no map is on disk.
    private func runBackwardMigration() async -> Outcome {
        let deps = dependencies
        let toVersion = deps.reportedVersion() ?? "unknown"

        guard let retained = deps.mapStore.load(), !retained.entries.isEmpty else {
            // No map on disk (migration predates this file, app was reinstalled, or the
            // map was manually deleted). Clearing the marker on its own would re-loop
            // through the same regression next launch, so combine it with a full
            // re-sync: the syncer will pull the current (pre-0.64) IDs and the existing
            // cache-prune pass will orphan downloads that no longer match.
            await deps.forceFullResync()
            deps.writeMarker(toVersion)
            deps.log("navidrome id backward regression with no retained map; forced full resync")
            return .forcedResync
        }

        // Sanity check: only invert if the retained map's "from" side actually matches
        // the epoch we are regressing towards. A mismatch (e.g. multi-hop regression
        // across two forward migrations) means we cannot trust the mapping.
        if let expectedFrom = retained.fromVersion,
           let epochNow = NavidromeVersion.epoch(of: toVersion),
           let epochFrom = NavidromeVersion.epoch(of: expectedFrom),
           epochNow != epochFrom {
            await deps.forceFullResync()
            deps.writeMarker(toVersion)
            deps.log("navidrome id backward regression map version mismatch (\(expectedFrom) vs \(toVersion)); forced full resync")
            return .forcedResync
        }

        let inverse = retained.inverse()
        do {
            let entries = try await deps.applyMap(inverse)
            // Overwrite the retained map with the inverse marked applied, so a future
            // forward move can invert *again* if needed.
            var completed = inverse
            completed.applied = true
            try? deps.mapStore.save(completed)
            deps.writeMarker(toVersion)
            deps.log("navidrome id migration backward: \(entries) entries applied to \(toVersion)")
            return .migratedBackward(entriesApplied: entries)
        } catch {
            deps.log("navidrome id backward migration failed: \(error.localizedDescription)")
            return .probeAborted
        }
    }
}
