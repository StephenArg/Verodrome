import XCTest
@testable import VerodromeKit

@MainActor
final class NavidromeIdMigrationCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nd-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Small state-holder so tests can inspect what closures wrote.
    private final class Recorder {
        var markerWritten: String?
        var forcedResync = 0
        var planCalls: [(String, String?)] = []
        var appliedMaps: [NavidromeIdMap] = []
        var overlayMessages: [String] = []
    }

    /// Cached 0.64+ version + live 0.64+ server: one settings read, no probe, no overlay.
    func testSameEpochIsNoOp() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.64.1",
            marker: "0.64.0",
            serverType: "navidrome",
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .noop)
        XCTAssertNil(recorder.markerWritten)
        XCTAssertEqual(recorder.planCalls.count, 0)
        XCTAssertTrue(recorder.overlayMessages.isEmpty)
    }

    /// Pre-0.64 server + no marker: seed without probing so old-server users never pay a
    /// request.
    func testFirstTimeMarkerSeedForOldServer() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.63.2",
            marker: nil,
            serverType: "navidrome",
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .seededMarker)
        XCTAssertEqual(recorder.markerWritten, "0.63.2")
        XCTAssertEqual(recorder.planCalls.count, 0)
        XCTAssertTrue(recorder.overlayMessages.isEmpty)
    }

    /// Same-epoch skip on an old server must not probe-forward.
    func testOldServerSameEpochIsNoOp() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.63.2",
            marker: "0.63.0",
            serverType: "navidrome",
            sample: ["e3b7fc2ae9447bbec37a13bf916e3cf6"],
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .noop)
        XCTAssertEqual(recorder.planCalls.count, 0)
        XCTAssertNil(recorder.markerWritten)
        XCTAssertTrue(recorder.overlayMessages.isEmpty)
    }

    /// Blank / pre-0.64 cache + 0.64 server: overlay, probe, remap, then write the
    /// live version.
    func testForwardMigrationDelegatesAndUpdatesMarker() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.64.0",
            marker: "0.63.0",
            serverType: "navidrome",
            sample: ["e3b7fc2ae9447bbec37a13bf916e3cf6"],
            resolves: { id in
                id == "6VHl3uR4kss6sUPKA8Cwnk"
            },
            recorder: recorder,
            planReturns: 42
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .migratedForward(entriesApplied: 42))
        XCTAssertEqual(recorder.planCalls.count, 1)
        XCTAssertEqual(recorder.planCalls[0].0, "0.64.0")
        XCTAssertEqual(recorder.planCalls[0].1, "0.63.0")
        XCTAssertEqual(recorder.markerWritten, "0.64.0")
        XCTAssertEqual(recorder.overlayMessages.first, "Checking library IDs…")
    }

    /// Nil marker + 0.64 server with already-canonical local IDs: finished check,
    /// write the marker so the next launch skips.
    func testAlreadyCanonicalSampleWritesMarker() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.64.0",
            marker: nil,
            serverType: "navidrome",
            sample: ["6VHl3uR4kss6sUPKA8Cwnk"],
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .alreadyConsistent)
        XCTAssertEqual(recorder.markerWritten, "0.64.0")
        XCTAssertEqual(recorder.planCalls.count, 0)
    }

    /// No local songs yet: leave the marker alone so a later launch with a library
    /// still checks instead of inheriting a hollow 0.64 label.
    func testEmptySampleOnForwardDoesNotWriteMarker() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.64.0",
            marker: nil,
            serverType: "navidrome",
            sample: [],
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .noop)
        XCTAssertNil(recorder.markerWritten)
        XCTAssertEqual(recorder.planCalls.count, 0)
    }

    /// Backward regression with no retained map on disk: coordinator forces the full
    /// re-sync rather than corrupt IDs. Sample uses a legacy 32-char hex ID because the
    /// probe filters out IDs that don't change under `canonical` — a shorter placeholder
    /// like "OLD" would collapse the sample to empty and abort.
    func testBackwardRegressionWithoutRetainedMapForcesResync() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "0.63.0",
            marker: "0.64.0",
            serverType: "navidrome",
            sample: ["e3b7fc2ae9447bbec37a13bf916e3cf6"],
            resolves: { _ in false },
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .forcedResync)
        XCTAssertEqual(recorder.forcedResync, 1)
        XCTAssertEqual(recorder.markerWritten, "0.63.0")
    }

    /// Backward regression with a retained map: inverse is applied, marker updated, map
    /// re-persisted with `applied = true` (now representing the inverse direction so a
    /// subsequent forward move can re-invert).
    func testBackwardRegressionWithRetainedMapApplied() async throws {
        let recorder = Recorder()
        let mapStore = NavidromeIdMapStore(accountKey: "test", directory: tempDir)
        let legacy = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        let canonical = "6VHl3uR4kss6sUPKA8Cwnk"
        let retained = NavidromeIdMap(
            toVersion: "0.64.0",
            fromVersion: "0.63.1",
            createdAt: .now,
            applied: true,
            entries: [.init(kind: .song, oldId: legacy, newId: canonical)]
        )
        try mapStore.save(retained)

        let coord = makeCoordinator(
            reported: "0.63.1",
            marker: "0.64.0",
            serverType: "navidrome",
            sample: [legacy],
            resolves: { _ in false },
            recorder: recorder,
            mapStore: mapStore,
            applyReturns: 1
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .migratedBackward(entriesApplied: 1))
        XCTAssertEqual(recorder.appliedMaps.count, 1)
        XCTAssertEqual(recorder.appliedMaps.first?.entries.first?.oldId, canonical)
        XCTAssertEqual(recorder.appliedMaps.first?.entries.first?.newId, legacy)
        XCTAssertEqual(recorder.markerWritten, "0.63.1")

        let updated = mapStore.load()
        XCTAssertEqual(updated?.applied, true)
        XCTAssertEqual(updated?.entries.first?.oldId, canonical)
    }

    /// A map on disk with `applied = false` is a torn run from the previous launch —
    /// resume it, mark applied, update marker. No probe.
    func testResumesTornMapBeforeConsultingProbe() async throws {
        let recorder = Recorder()
        let mapStore = NavidromeIdMapStore(accountKey: "test", directory: tempDir)
        let torn = NavidromeIdMap(
            toVersion: "0.64.0", fromVersion: "0.63.1", createdAt: .now, applied: false,
            entries: [.init(kind: .song, oldId: "OLD", newId: "NEW")]
        )
        try mapStore.save(torn)

        let coord = makeCoordinator(
            reported: "0.64.0", marker: nil, serverType: "navidrome",
            sample: [],
            resolves: { _ in XCTFail("probe consulted despite torn map"); return false },
            recorder: recorder,
            mapStore: mapStore,
            applyReturns: 1
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .resumed(entriesApplied: 1))
        XCTAssertEqual(recorder.markerWritten, "0.64.0")
        XCTAssertEqual(mapStore.load()?.applied, true)
    }

    /// Non-Navidrome servers never touch the flow at all.
    func testAmpacheNeverProbes() async {
        let recorder = Recorder()
        let coord = makeCoordinator(
            reported: "6.6.0",
            marker: nil,
            serverType: "Ampache",
            recorder: recorder
        )
        let outcome = await coord.run()
        XCTAssertEqual(outcome, .noop)
        XCTAssertNil(recorder.markerWritten)
    }

    // MARK: - Helper

    private func makeCoordinator(
        reported: String?,
        marker: String?,
        serverType: String?,
        sample: [String] = [],
        resolves: @escaping (String) async throws -> Bool = { _ in true },
        recorder: Recorder,
        mapStore: NavidromeIdMapStore? = nil,
        planReturns: Int = 0,
        applyReturns: Int = 0
    ) -> NavidromeIdMigrationCoordinator {
        let store = mapStore ?? NavidromeIdMapStore(accountKey: "test", directory: tempDir)
        let deps = NavidromeIdMigrationCoordinator.Dependencies(
            reportedVersion: { reported },
            markerVersion: { marker },
            serverTypeName: { serverType },
            writeMarker: { version in recorder.markerWritten = version },
            forceFullResync: { recorder.forcedResync += 1 },
            sampleCandidateSongIds: { _ in sample },
            songResolves: resolves,
            mapStore: store,
            planAndApplyForward: { toV, fromV in
                recorder.planCalls.append((toV, fromV))
                return planReturns
            },
            applyMap: { map in
                recorder.appliedMaps.append(map)
                return applyReturns
            },
            presentBusyOverlay: { message in
                recorder.overlayMessages.append(message)
            }
        )
        return NavidromeIdMigrationCoordinator(dependencies: deps)
    }
}
