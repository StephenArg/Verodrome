import Foundation

/// Confirms with the server whether local IDs have to be rewritten before touching a
/// single row on disk. The version gate is the trigger; this is the authority.
///
/// The threat model is symmetric: applying the transform against a server that has not
/// migrated corrupts every ID just as thoroughly as failing to apply it against a server
/// that has. Both directions come down to a handful of `getSong` calls against IDs the
/// server should be able to reason about.
public enum NavidromeCanonicalIdProbe {

    /// What the probe concluded. `.abort` is the only outcome that stops the caller from
    /// setting the marker — everything else is a definitive answer worth persisting.
    public enum Outcome: Sendable, Equatable {
        /// Pre-existing IDs still resolve, so local storage already matches the server.
        /// No migration; set the marker and move on.
        case alreadyConsistent
        /// Old IDs are dead and the canonical transform brings them back. Run the
        /// forward migration.
        case needsForward
        /// The reverse: canonical IDs are dead and the raw pre-existing IDs work again.
        /// This is the restored-from-backup case; apply the inverse map.
        case needsBackward
        /// The sample was empty (no local songs to test) or every song came back
        /// unresolvable from both angles. Either way, leave data alone rather than risk
        /// corrupting IDs on a hunch.
        case abort(reason: AbortReason)

        public enum AbortReason: Sendable, Equatable {
            /// No songs with local files to sample. There is nothing offline that would
            /// benefit from a migration, so the marker can be set safely without work.
            case noSamplesAvailable
            /// Songs were sampled but neither the raw ID nor the canonical(id) form
            /// resolved for any of them. The songs may have been deleted server-side, or
            /// the server is in an unexpected state; refuse to guess.
            case sampleInconclusive
            /// The probe itself failed (network, auth, malformed responses). Retry later.
            case probeFailed(underlying: String)
        }
    }

    /// Direction hint from the version gate. Steers which side of the two comparisons
    /// gets checked first: forward expects the old IDs to be dead, backward expects the
    /// canonical form to be dead.
    public enum Direction: Sendable {
        case forward
        case backward
    }

    /// A single sample point tried against both ID shapes.
    struct SampleResult: Sendable {
        let oldId: String
        let oldResolves: Bool
        let canonicalResolves: Bool

        var isCanonicalDistinct: Bool { NavidromeCanonicalID.canonical(oldId) != oldId }
    }

    /// The upper bound on how many songs we sample. Kept small because each is one
    /// synchronous Subsonic round trip; on a good link the probe finishes in well under
    /// a second even if every sample has to actually be tried.
    public static let defaultSampleSize = 5

    /// Run the probe.
    ///
    /// - Parameters:
    ///   - candidateIds: All song `remoteId`s worth testing, preferring those with a
    ///     local downloaded file (`Song.relFilePath != nil`) — those are what the
    ///     migration exists to save. Callers should pass the list ordered by that
    ///     preference; this method will trim to `sampleLimit` from the front.
    ///   - direction: What the version gate expects. Only steers the ordering of the
    ///     two per-sample calls; the outcome is derived from the observed responses.
    ///   - sampleLimit: How many IDs to test. Defaults to `defaultSampleSize`.
    ///   - resolves: Reports whether one ID resolves via `getSong`. Returning `true`
    ///     means the server produced a song row, `false` means it returned a
    ///     data-not-found error (Subsonic error 70 / HTTP 404), and `throw`s propagate
    ///     as a `probeFailed` abort.
    public static func run(
        candidateIds: [String],
        direction: Direction,
        sampleLimit: Int = defaultSampleSize,
        resolves: (String) async throws -> Bool
    ) async -> Outcome {
        // Only bother sampling IDs that actually change under the transform — a
        // hash-family ID that survives the migration cannot distinguish the two epochs.
        let distinct = candidateIds.filter { NavidromeCanonicalID.canonical($0) != $0 }
        let sample = Array(distinct.prefix(sampleLimit))
        guard !sample.isEmpty else { return .abort(reason: .noSamplesAvailable) }

        var results: [SampleResult] = []
        results.reserveCapacity(sample.count)
        for oldId in sample {
            let canonical = NavidromeCanonicalID.canonical(oldId)
            let oldFirst: Bool
            switch direction {
            case .forward: oldFirst = true
            case .backward: oldFirst = false
            }

            do {
                let oldResolves: Bool
                let canonicalResolves: Bool
                if oldFirst {
                    oldResolves = try await resolves(oldId)
                    // If the raw ID already works, we already know the answer for this
                    // sample and can skip the second call.
                    canonicalResolves = oldResolves ? true : try await resolves(canonical)
                } else {
                    canonicalResolves = try await resolves(canonical)
                    oldResolves = canonicalResolves ? false : try await resolves(oldId)
                }
                results.append(SampleResult(
                    oldId: oldId,
                    oldResolves: oldResolves,
                    canonicalResolves: canonicalResolves
                ))
            } catch {
                // A transient network / auth failure aborts the whole probe. The caller
                // reruns on next `ensureActiveLibrarySyncer`.
                return .abort(reason: .probeFailed(underlying: String(describing: error)))
            }
        }

        // A single unambiguous sample is enough: the transform is deterministic, so if
        // one song's IDs behave a certain way, every other song's do too. The extra
        // samples exist only to survive the edge case where a sampled song was deleted
        // server-side between our last sync and now.
        if results.contains(where: { $0.oldResolves && !$0.canonicalResolves }) {
            // Raw ID works AND canonical(id) doesn't — local storage matches the server.
            return .alreadyConsistent
        }
        if results.contains(where: { $0.oldResolves && $0.canonicalResolves }) {
            // Both shapes resolve. Only happens if the server accepts either — which
            // Navidrome briefly does around the migration boundary for hash-family IDs
            // (they are canonical already). Treat as consistent, since the raw ID works.
            return .alreadyConsistent
        }
        if results.contains(where: { !$0.oldResolves && $0.canonicalResolves }) {
            // Raw ID dead, canonical works: the server has migrated forward and we haven't.
            return .needsForward
        }
        if results.contains(where: { $0.oldResolves && !$0.canonicalResolves }) == false,
           results.contains(where: { !$0.oldResolves && $0.canonicalResolves }) == false,
           results.contains(where: { !$0.oldResolves && !$0.canonicalResolves }) {
            // Every sample failed both ways. Ambiguous; the backward branch does try the
            // inverse but there is no cached map yet, so the caller aborts safely.
            if direction == .backward {
                return .needsBackward
            }
            return .abort(reason: .sampleInconclusive)
        }
        // Fallback: shouldn't happen but stay on the safe side.
        return .abort(reason: .sampleInconclusive)
    }
}
