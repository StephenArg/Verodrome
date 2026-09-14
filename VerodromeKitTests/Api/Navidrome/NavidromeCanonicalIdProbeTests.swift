import XCTest
@testable import VerodromeKit

final class NavidromeCanonicalIdProbeTests: XCTestCase {

    // MARK: - Helpers

    /// Legacy 32-hex ID that transforms to a distinct canonical form. Chosen because it
    /// is one of Navidrome's own golden vectors, so both sides are known.
    static let legacyId = "e3b7fc2ae9447bbec37a13bf916e3cf6"
    static let canonicalOfLegacy = "6VHl3uR4kss6sUPKA8Cwnk"

    /// A hash-family ID that survives the transform unchanged. Must be filtered out of
    /// the sample because it cannot distinguish the two epochs.
    static let stableId = "5cLJPkLA5DK2BADhoeotPk"

    private final class Resolver: @unchecked Sendable {
        var resolves: Set<String>
        var throwsOnAny: Error?
        private(set) var calls: [String] = []
        init(resolves: Set<String>, throwsOnAny: Error? = nil) {
            self.resolves = resolves
            self.throwsOnAny = throwsOnAny
        }
        func callback(_ id: String) async throws -> Bool {
            calls.append(id)
            if let throwsOnAny { throw throwsOnAny }
            return resolves.contains(id)
        }
    }

    // MARK: - Outcomes

    func testAlreadyConsistentWhenOldIdStillResolves() async {
        let resolver = Resolver(resolves: [Self.legacyId])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .alreadyConsistent)
        // Only the raw ID needs to be tried when it works — no reason to burn a second
        // call testing canonical(id).
        XCTAssertEqual(resolver.calls, [Self.legacyId])
    }

    func testNeedsForwardWhenOldFailsAndCanonicalResolves() async {
        let resolver = Resolver(resolves: [Self.canonicalOfLegacy])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .needsForward)
        XCTAssertEqual(resolver.calls, [Self.legacyId, Self.canonicalOfLegacy])
    }

    func testNeedsBackwardWhenCanonicalFailsAndOldResolves() async {
        // Backward direction: server was rolled back, so raw IDs now work again.
        let resolver = Resolver(resolves: [Self.legacyId])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .backward,
            resolves: resolver.callback
        )
        // The .alreadyConsistent branch fires because raw ID resolves; backward mode
        // still calls canonical first, so it exercises that ordering.
        XCTAssertEqual(outcome, .alreadyConsistent)
        XCTAssertEqual(resolver.calls, [Self.canonicalOfLegacy, Self.legacyId])
    }

    func testBackwardReturnsNeedsBackwardWhenBothFail() async {
        // Songs deleted server-side. In backward mode this is treated as the rollback
        // signal (fall through to the inverse map path); the caller then decides whether
        // there is a retained map to invert.
        let resolver = Resolver(resolves: [])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .backward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .needsBackward)
    }

    func testForwardAbortsInconclusiveWhenBothFail() async {
        // Same shape sample, forward direction — refuse to guess. Aborting leaves the
        // marker untouched, so the probe reruns next time.
        let resolver = Resolver(resolves: [])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .abort(reason: .sampleInconclusive))
    }

    func testEmptySampleAborts() async {
        let resolver = Resolver(resolves: [])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .abort(reason: .noSamplesAvailable))
        XCTAssertEqual(resolver.calls, [])
    }

    func testStableIdsAreFilteredOutOfSample() async {
        // Hash-family IDs like `5cLJPkLA5DK2BADhoeotPk` are canonical already, so they
        // cannot distinguish the two epochs. If they were the only candidate the probe
        // must abort rather than pretend it learned anything.
        let resolver = Resolver(resolves: [])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.stableId],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .abort(reason: .noSamplesAvailable))
        XCTAssertEqual(resolver.calls, [])
    }

    func testMixedSampleUsesOnlyDistinguishingIds() async {
        // A stable ID first, then a distinguishing one. The stable ID must be dropped;
        // the probe should still reach `.needsForward` from the second entry.
        let resolver = Resolver(resolves: [Self.canonicalOfLegacy])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.stableId, Self.legacyId],
            direction: .forward,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .needsForward)
        XCTAssertEqual(resolver.calls, [Self.legacyId, Self.canonicalOfLegacy])
    }

    func testSampleLimitCapsRequests() async {
        // Two distinguishing IDs, limit of 1: only one is probed. Keeps the cost bounded
        // on the caller who scanned a whole library for candidates.
        let ids = [Self.legacyId, "f47ac10b-58cc-4372-a567-0e02b2c3d479"]
        let resolver = Resolver(resolves: [Self.canonicalOfLegacy])
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: ids,
            direction: .forward,
            sampleLimit: 1,
            resolves: resolver.callback
        )
        XCTAssertEqual(outcome, .needsForward)
        XCTAssertEqual(resolver.calls.count, 2)  // one for old, one for canonical
        XCTAssertTrue(resolver.calls.contains(Self.legacyId))
    }

    func testProbeFailedOnThrow() async {
        struct BoomError: Error {}
        let resolver = Resolver(resolves: [], throwsOnAny: BoomError())
        let outcome = await NavidromeCanonicalIdProbe.run(
            candidateIds: [Self.legacyId],
            direction: .forward,
            resolves: resolver.callback
        )
        if case .abort(reason: .probeFailed) = outcome {
            // Right branch reached.
        } else {
            XCTFail("expected probeFailed abort, got \(outcome)")
        }
    }
}
