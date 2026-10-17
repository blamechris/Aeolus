import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The snapshot's `targetRPM` through the composed helper (ADR 0014's #410 snapshot-target
/// amendment): the target § 5 holds for the snapshot's live lease, stated only while the same
/// snapshot reads the fan in manual and § 5 has not marked it reclaimed. `HeldTargetRuleTests` is
/// the rule as a table; this is the rule as a client meets it, over a `.built`
/// `ScriptedControlPlane` on a `TestClock`, with § 5's cycles run by hand, not by its supervisor.
///
/// On a `.notBuilt` plane, every shipped build, no lease is granted, so § 5 is never asked and
/// every fan reports `nil`: `theSnapshotAsksSectionFiveOnceAndOnlyUnderALease` here, and the
/// read path's own pins, `ReadOnlyFanAuthorityTests.fansAreAutomaticAndUncontrollable` and, on
/// this machine's SMC, `HelperHardwareTests`.
@Suite("The snapshot states the target § 5 holds", .timeLimit(.minutes(1)))
struct HeldTargetCompositionTests {

    /// **S2.** An `apply` of 9,000 RPM, above fan 0's declared 5,777, is clamped by the permit,
    /// written at 5,777, reported to § 5 at 5,777, and stated by the snapshot at 5,777: the step
    /// put on the wire, never the client's request.
    ///
    /// **Mutation:** in `LeaseApplier.step`, report `CommandedTarget(fanIndex: index, rpm: rpm)`,
    /// the request, to § 5 in place of `commanded`. Run: red, the snapshot states 9,000.
    /// **Mutation:** in `ReadOnlyFanReport.statingHeldTarget`, state `target: nil`. Run: red, the
    /// snapshot states nothing.
    @Test("An apply above the maximum is stated at the clamped target")
    func anApplyAboveTheMaximumIsStatedAtTheClampedTarget() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()

        try await machine.apply(rpm: 9_000, under: lease)

        let commanded = await machine.firmware.attempts.compactMap { attempt -> Double? in
            if case .commandTarget(fan: 0, let rpm) = attempt { return rpm }
            return nil
        }
        #expect(commanded == [5_777], "the firmware was commanded \(commanded), not the clamp")
        let snapshot = try await machine.helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(snapshot.activeLease?.id == lease, "no lease was reported beside the target")
        #expect(fan.mode == .manualFixed && !fan.isReclaimedBySystem)
        #expect(
            fan.targetRPM == 5_777,
            "the snapshot states \(String(describing: fan.targetRPM)) for a fan held at 5,777")
    }

    /// **S3.** The system takes fan 0 back after `apply`, and the snapshot follows § 5:
    ///
    /// 1. **Before § 5's cycle:** `F0Md` reads automatic, § 5 still holds the target under the
    ///    live lease and has not judged the fan. No target, mode automatic, no mark.
    /// 2. **After § 5's cycle:** § 5 marked the fan reclaimed by the system and its re-assert took
    ///    it back into manual at the recorded target. No target, beside the mark.
    /// 3. **After the next cycle:** the re-assert converged and the mark cleared. The target is
    ///    back.
    ///
    /// Checkpoint 2 reads the fan in manual, so the mark is the only condition that withholds the
    /// target there; checkpoint 1's fan is the only one the mode alone withholds it from.
    ///
    /// **Mutation:** delete `heldTarget`'s guard on `observedMode`. Run: red at checkpoint 1.
    /// **Mutation:** delete its guard on `reclaimedBySystem`. Run: red at checkpoint 2.
    @Test("A reclaimed fan states no target until § 5's re-assert converges")
    func aReclaimedFanStatesNoTargetUntilTheReassertConverges() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        try await machine.apply(rpm: 3_000, under: lease)
        #expect(try await Self.fan(0, of: machine).targetRPM == 3_000, "no target after apply")

        // The system takes the fan: nothing in Aeolus wrote this, so nothing records an attempt.
        await machine.firmware.setMode(.automatic, ofFan: 0)
        let taken = try await Self.fan(0, of: machine)
        #expect(taken.mode == .automatic && !taken.isReclaimedBySystem)
        #expect(
            taken.targetRPM == nil,
            "checkpoint 1: \(String(describing: taken.targetRPM)) beside an automatic mode")

        await machine.helper.reclamationWatchdog.cycle()
        let judged = try await Self.fan(0, of: machine)
        #expect(judged.isReclaimedBySystem, "§ 5's cycle did not mark the fan reclaimed")
        #expect(judged.mode == .manualFixed, "§ 5's re-assert did not take the fan back")
        #expect(
            judged.targetRPM == nil,
            "checkpoint 2: \(String(describing: judged.targetRPM)) beside the reclamation mark")

        await machine.helper.reclamationWatchdog.cycle()
        let converged = try await Self.fan(0, of: machine)
        #expect(!converged.isReclaimedBySystem, "the converged cycle left the mark")
        #expect(converged.mode == .manualFixed)
        #expect(
            converged.targetRPM == 3_000,
            "checkpoint 3: \(String(describing: converged.targetRPM)) after the re-assert held")
        #expect(try await machine.helper.authority.snapshot().activeLease?.id == lease)
    }

    /// **The kept fan, and the re-adopted one (#423).** Fans 0 and 1 are engaged by one `apply`,
    /// and fan 0 is commanded and recorded at 2,400. Then the firmware refuses fan 1's command and
    /// every mode write, so the undo hands both back, § 5's record first, and both hand-backs are
    /// refused: both fans are kept in manual under the live lease, and § 5 holds no record of
    /// either. The snapshot states no target for them. Once the firmware takes writes again, a
    /// re-apply re-adopts both, registers them with § 5 and commands them, and the snapshot states
    /// each fan's own target.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, delete the `manualControlHandedBack(fanAt:under:)`
    /// notice. Run: red, the kept fan 0 stated at 2,400.
    @Test("A kept fan states no target, and a re-adopted one states its own")
    func aKeptFanStatesNoTargetAndAReAdoptedOneItsOwn() async throws {
        let cool = LeaseFixture.nominalDieTemperatures
        let machine = await LevelSixMachine(
            stages: [
                .nominal(temperatures: cool),
                .nominal(
                    temperatures: cool, writes: .refused(reason: "F<n>Md refused"),
                    targetWrites: .refused(reason: "F<n>Tg refused")),
                .nominal(temperatures: cool),
            ],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1])
        await machine.writes.interfere(beforeCommandTarget: 2) { await machine.firmware.advance() }

        let refused = await LevelSixMachine.answer {
            try await machine.helper.authority.apply(
                Self.settings([0: 2_400, 1: 2_400]), leaseID: lease, from: machine.holder)
        }
        #expect(refused != nil, "the apply that keeps the fans was answered applied")
        #expect(
            try await machine.firmware.firmwareMode(ofFan: 0) == .manual, "fan 0 was handed back")
        await machine.firmware.advance()

        let kept = try await Self.fan(0, of: machine)
        #expect(kept.mode == .manualFixed && !kept.isReclaimedBySystem)
        #expect(try await machine.helper.authority.snapshot().activeLease?.id == lease)
        #expect(
            kept.targetRPM == nil,
            "the kept fan states \(String(describing: kept.targetRPM)), which nothing holds it at")

        let reApplied = await LevelSixMachine.answer {
            try await machine.helper.authority.apply(
                Self.settings([0: 2_000, 1: 2_100]), leaseID: lease, from: machine.holder)
        }
        #expect(reApplied == nil, "the re-apply was answered \(String(describing: reApplied))")
        #expect(try await Self.fan(0, of: machine).targetRPM == 2_000)
        #expect(try await Self.fan(1, of: machine).targetRPM == 2_100)
    }

    /// The snapshot asks § 5 once, after the lease view and only when it reports a lease, and
    /// under that lease's id. Before a lease, nothing is asked; that is the `.notBuilt` case,
    /// where no lease is ever granted.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.snapshot()`, ask
    /// `recordedTargets(under: view.lease?.id ?? UUID())` whatever the view reports. Run: red, § 5
    /// asked with no lease.
    @Test("The snapshot asks § 5 once, and only under the lease it reports")
    func theSnapshotAsksSectionFiveOnceAndOnlyUnderALease() async throws {
        let helper = HelperRestorerTests.composed(clock: TestClock())
        await helper.bindSafetyRegistries()
        let reporting = CountingReporting()
        let authority = SupervisedFanAuthority(
            reading: helper.reading, leases: helper.leases, reconciliation: helper.reconciliation,
            keystone: helper.plane, writeCapability: helper.plane, telemetry: helper.sightings,
            control: NoLevelSix(), reclamation: reporting, log: HelperRestorerTests.helperLog)

        let unleased = try await authority.snapshot()
        let askedUnleased = await reporting.asked
        #expect(unleased.activeLease == nil)
        #expect(askedUnleased.isEmpty, "§ 5 was asked \(askedUnleased) with no lease")

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        let leased = try await authority.snapshot()
        let askedLeased = await reporting.asked
        #expect(leased.activeLease?.id == lease.id)
        #expect(askedLeased == [lease.id], "§ 5 was asked \(askedLeased)")
        #expect(leased.fans.allSatisfy { $0.targetRPM == nil }, "a fan read automatic has a target")
    }

    /// **The lease id.** § 5's records are read under the lease asked about and no other: a record
    /// under another lease, whatever its fan, is not that lease's target, and a record with nothing
    /// commanded is no target at all.
    ///
    /// **Mutation:** in `Registry.recordedTargets(under:)`, drop the `filter` on the record's
    /// lease, so it filters on the fan alone. Run: red, fan 1's record reported under `lease`.
    @Test("A record under another lease's id is not reported")
    func aRecordUnderAnotherLeaseIsNotReported() {
        let lease = UUID()
        let other = UUID()
        var registry = ReclamationWatchdog<ScriptedControlPlane>.Registry()
        for (fan, holder) in [(0, lease), (1, other), (2, lease)] {
            _ = registry.register(
                holder, fanAt: fan, live: true, since: registry.generation(ofFan: fan))
        }
        _ = registry.command(CommandedTarget(fanIndex: 0, rpm: 3_000), ofFan: 0)
        _ = registry.command(CommandedTarget(fanIndex: 1, rpm: 4_000), ofFan: 1)

        #expect(registry.recordedTargets(under: lease) == [0: 3_000])
        #expect(registry.recordedTargets(under: other) == [1: 4_000])
        #expect(registry.recordedTargets(under: UUID()).isEmpty)
    }

    // MARK: - Fixtures

    /// Fan `index` in a fresh snapshot of `machine`'s authority.
    private static func fan(_ index: Int, of machine: LevelSixMachine) async throws -> FanState {
        try #require(try await machine.helper.authority.snapshot().fans.first { $0.index == index })
    }

    /// One fixed setting per fan, in fan order.
    private static func settings(_ targets: [Int: Double]) -> [FanSetting] {
        targets.sorted { $0.key < $1.key }.map {
            FanSetting(fanIndex: $0.key, control: .fixed(rpm: $0.value))
        }
    }
}

/// § 5 as the snapshot's role, answering nothing and counting each lease it is asked about.
private actor CountingReporting: ReclamationReporting {
    private(set) var asked: [UUID] = []

    func recordedTargets(under lease: UUID) -> [Int: Double] {
        asked.append(lease)
        return [:]
    }
}
