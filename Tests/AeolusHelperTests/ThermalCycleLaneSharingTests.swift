import FanKit
import Testing

@testable import AeolusHelper

/// § 3's lane views split nothing that was one (ADR 0012's 2026-10-18 amendment): one
/// `DegradationMemo` across § 3's telemetry and the cache's source (#124), and one read loop
/// behind § 3's read-back and reconciliation's (#295).
///
/// `ThermalCycleLaneTripwireTests` counts the loop's copies at the source; this suite holds both
/// by behaviour, in the composed graph and over the scripted firmware.
@Suite("§ 3's lane views share the memo and the read loop", .timeLimit(.minutes(1)))
struct ThermalCycleLaneSharingTests {

    /// A degraded set — twenty of the thirty-four curated keys answering — is logged once
    /// across a grant's cache flight, at `.supervisor`, and § 3's cycle after it, in the lane:
    /// the two read through views of one `CuratedCriticalTemperatures`, so one memo.
    ///
    /// **Mutation:** in `HelperComposition.init`, give § 3 `telemetry: CuratedCriticalTemperatures(
    /// plane: plane.admitted(at: .thermalCycle), set: criticalSensors, log: safetyLog)`. Run: red —
    /// the degraded set is logged twice. (`HelperCompositionTests` counts the second construction
    /// too.)
    /// **Mutation:** in `CuratedCriticalTemperatures.admitted(at:)`, return
    /// `CuratedCriticalTemperatures(plane: plane.admitted(at: admission), set: set, log: log)`.
    /// Run: red — twice.
    @Test("A degraded set is logged once across a cache flight and § 3's cycle")
    func aDegradedSetIsLoggedOnce() async throws {
        let lines = RecordedLog()
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], stages: [.partial(answering: 20, at: 44)])
        let helper = HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { level, line in lines.append(level, line) }),
            teardown: TeardownSeams(sources: RecordingSignalSources()))

        _ = try await helper.sightings.sighting()
        await helper.thermalEmergency.cycle()

        let admissions = await firmware.admittedAttempts.compactMap { call -> PlaneAdmission? in
            if case .readCriticalTemperatures = call.attempt { return call.admission }
            return nil
        }
        #expect(admissions == [.supervisor, .thermalCycle], "the two reads were \(admissions)")
        let degraded = lines.lines(containing: "Critical temperature cycle degraded")
        #expect(degraded.count == 1, "the one degraded set was logged \(degraded.count) times")
    }

    /// § 3's lane reader is reconciliation's own loop over the lane view: for the same fans it
    /// answers what reconciliation answers — manual, automatic, a mode that will not read, and a
    /// fan the machine does not have — and each asks through its own admission.
    ///
    /// **Mutation:** in `StartupReconciliation.handbackReadBack(admittedAt:)`, build the reader
    /// over `plane` rather than `plane.admitted(at: admission)`. Run: red — the lane reader reads
    /// at `.supervisor`.
    @Test("The lane reader reads what reconciliation reads, through the lane")
    func theLaneReaderReadsWhatReconciliationReads() async throws {
        var stage = ScriptedControlPlane.Stage.nominal()
        stage.unreadableModes = [2]
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .automatic(at: 1_800), 2: .nominal],
            stages: [stage])
        let reconciliation = LeaseFixture.reconciliation(over: plane)
        let lane = reconciliation.handbackReadBack(admittedAt: .thermalCycle)
        let fans: Set<Int> = [0, 1, 2, 3]

        let fromLane = await lane.handbackReadings(of: fans)
        let fromReconciliation = await reconciliation.handbackReadings(of: fans)

        #expect(fromLane == fromReconciliation)
        #expect(fromLane[0] == .manual)
        #expect(fromLane[1] == .automatic)
        for fan in [2, 3] {
            guard case .unreadable = fromLane[fan] else {
                Issue.record("fan \(fan) read \(String(describing: fromLane[fan]))")
                continue
            }
        }

        let admissions = await plane.admittedAttempts.map(\.admission)
        #expect(
            admissions
                == Array(repeating: .thermalCycle, count: 4)
                + Array(repeating: .supervisor, count: 4),
            "\(admissions)")
    }
}
