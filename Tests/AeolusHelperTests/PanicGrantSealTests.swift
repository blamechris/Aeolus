import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// No lease is granted while § 7's panic verb runs
/// ([#350](https://github.com/blamechris/Aeolus/issues/350)).
///
/// The verb releases every lease, issues `.everyFan` on a plane that can write, and reads back.
/// Until #350 nothing refused a grant in between, so after A6 a lease granted and applied inside
/// the verb would be undone by the restore still in flight and outlive it. All three acts now run
/// inside `LeaseAuthority.sealingGrants(during:)`, and `acquireLease` refuses `.releaseInProgress`
/// while it is open. docs/records/handback-ledger.md § "The machine-wide restore seal" argues each
/// test's property; this suite is the evidence.
///
/// Composed for `PanicVerbMachineWideRestoreTests`' reason — what is under test is the order
/// `SupervisedFanAuthority`'s body uses the lease core in — over `ScopeParkingPlane`, so the verb
/// is parked inside the restore the seal exists for rather than argued to be. Every park is a
/// continuation; nothing here blocks a thread. The supervisors are not started.
///
/// Where the seal's position is held by text rather than behaviour — the three acts inside the
/// closure, and each runtime machine-wide restore behind its interlock — the tests are in
/// `PanicPathScopeTripwireTests`.
@Suite("No lease is granted while the panic verb runs", .timeLimit(.minutes(1)))
struct PanicGrantSealTests {

    private typealias Fixture = AvailabilityFixture

    /// The daemon's wiring over firmware whose restores can be parked by scope. `manual` fans
    /// read manual both in the firmware and in the snapshot's own mode read, which is the
    /// firmware's through `PlaneBackedProvider` (#360).
    private static func composed(
        fanCount: Int = 1, manual: Set<Int> = []
    ) -> HelperComposition<ScopeParkingPlane> {
        var fans: [Int: ScriptedControlPlane.FanCondition] = [:]
        for fan in 0..<fanCount {
            fans[fan] = manual.contains(fan) ? .init(mode: .manual) : .automatic(at: 2_400)
        }
        let firmware = ScriptedControlPlane(
            fans: fans, stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        return HelperComposition(
            plane: ScopeParkingPlane(firmware),
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: fanCount),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: Fixture.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Fixture.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// Starts the panic verb and returns once it is parked on the `parked`-th restore.
    private static func panicParked(
        in helper: HelperComposition<ScopeParkingPlane>, count parked: Int = 1
    ) async -> ObservableWork<Void> {
        let panic = observing {
            try await helper.authority.restoreAllToAutomatic(from: ConnectionID())
        }
        await yieldUntil("the panic verb to park on its restore") {
            await helper.plane.parkedRestores == parked
        }
        return panic
    }

    /// The snapshot's reason for `fan`, for the agreement assertions. `.available` maps to an
    /// `.unknown` the grant can never throw, so agreement with a granted lease is still red.
    private static func shownReason(
        ofFanAt fan: Int, in helper: HelperComposition<ScopeParkingPlane>
    ) async throws -> ManualControlAvailability.Reason {
        let snapshot = try await helper.authority.snapshot()
        guard case .unavailable(let reason) = try Fixture.availability(ofFanAt: fan, in: snapshot)
        else { return .unknown("available") }
        return reason
    }

    /// Whether a grant over `fan` is granted now, recording why when it is not.
    private static func grants(
        _ fan: Int, in helper: HelperComposition<ScopeParkingPlane>, because what: String
    ) async -> Bool {
        do {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
            return true
        } catch {
            Issue.record("\(what), and a grant over fan \(fan) was refused: \(error)")
            return false
        }
    }

    // MARK: - The machine-wide restore

    /// A grant from another connection while `.everyFan` is in flight is refused, and the
    /// snapshot says the same thing; once the verb returns, a grant goes through.
    ///
    /// **Mutation:** delete the `machineWideRestoresInFlight == 0` guard from `acquireLease`. Run:
    /// red — "the grant path granted a lease over fan 0". **Mutation:** move the `.built` block and
    /// `confirmAcceptedHandbacks()` out of the `sealingGrants` closure, below it. Run: red, the
    /// same line. **Mutation:** in `restatingAvailability`, drop the
    /// `reportingMachineWideRestore` call. Run: red on the agreement only. **Mutation:** delete
    /// the `defer` that decrements the count. Run: red on the last grant only.
    @Test("A grant during the machine-wide restore is refused, and the snapshot agrees")
    func aGrantDuringTheMachineWideRestoreIsRefused() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        await helper.plane.park(.everyFan)
        let panic = await Self.panicParked(in: helper)
        #expect(await helper.plane.restoreScopes == [.everyFan], "the verb is parked elsewhere")

        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        #expect(refused == .releaseInProgress)
        let shown = try await Self.shownReason(ofFanAt: 0, in: helper)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) while a grant over the same fan is refused \(refused): a \
            client is offered control the panic verb's seal refuses.
            """)

        await helper.plane.releaseAll()
        _ = try await finished("the panic verb to return once its restore is let through", panic)
        #expect(
            await Self.grants(0, in: helper, because: "the panic verb has returned"),
            "the seal outlived the panic verb, so no lease can be granted for the process's life")
    }

    /// A grant already parked on its foreign-control read — its last suspension point — when the
    /// panic verb begins is refused once it resumes: the guard is below every `await`.
    ///
    /// **Mutation:** move the seal's guard above the `---- No await ----` marker, to just above
    /// `let exempted = try await refuseIfForeignManualControl(`. Run: red here — "granted a lease
    /// over fan 0" — while `aGrantDuringTheMachineWideRestoreIsRefused` stays green, which is what
    /// proves the two tests discriminate.
    @Test("A grant parked on its last read when the panic verb begins is refused")
    func aGrantInFlightWhenThePanicBeginsIsRefused() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        await helper.plane.reads.modeReads(.held)
        let grant = observing {
            try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        let readParked = await yieldUntil("the grant to park on fan 0's foreign-control read") {
            await helper.plane.reads.heldModeReads == 1
        }
        #expect(readParked)

        await helper.plane.park(.everyFan)
        let panic = await Self.panicParked(in: helper)
        await helper.plane.reads.modeReads(.answered)

        do {
            _ = try await finished("the parked grant to resume", grant)
            Issue.record(
                """
                granted a lease over fan 0 while the panic verb's machine-wide restore was in \
                flight: the grant had passed the seal's check before the verb began.
                """)
        } catch let fault as AeolusXPCFault {
            #expect(fault == .manualControlUnavailable(reason: .releaseInProgress))
        }

        await helper.plane.releaseAll()
        _ = try await finished("the panic verb to return", panic)
    }

    /// While the sweep's own restore of fan 0 is in flight, a grant over fan 1 — which the sweep
    /// does not cover, so it is not in `releasing` — is refused by the seal.
    ///
    /// **Mutation:** in `restoreAllToAutomatic`, move `await leases.releaseEveryLease()` out of
    /// the closure, above `sealingGrants`. Run: red — "the grant path granted a lease over fan 1".
    @Test("A grant over a fan the panic sweep does not cover is refused while the sweep runs")
    func aGrantDuringThePanicSweepIsRefused() async throws {
        let helper = Self.composed(fanCount: 2)
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await helper.plane.park(.fan(0))
        let panic = await Self.panicParked(in: helper)
        #expect(await helper.leases.leaseCount == 0, "the sweep has not emptied the table yet")
        #expect(
            await helper.leases.fansMidHandback == [0],
            "fan 1 is mid-handback too, so its own guard would refuse it whatever the seal does")

        let refused = await Fixture.refusalForGrant(over: 1, from: helper.leases)
        #expect(refused == .releaseInProgress)
        #expect(try await Self.shownReason(ofFanAt: 1, in: helper) == refused)

        await helper.plane.releaseAll()
        _ = try await finished("the panic verb to return", panic)
    }

    /// Two panic verbs overlap: when the first returns, the second still holds the seal.
    ///
    /// **Mutation:** make `machineWideRestoresInFlight` a `Bool` — set in `sealingGrants`, cleared
    /// in its `defer`, read as the guard's and the view's condition. Run: red — "the grant path
    /// granted a lease over fan 0" once the first verb returns.
    @Test("Overlapping panic verbs hold the seal until the last one returns")
    func overlappingPanicsHoldTheSealUntilTheLastEnds() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        await helper.plane.park(.everyFan)
        let first = await Self.panicParked(in: helper, count: 1)
        let second = await Self.panicParked(in: helper, count: 2)

        await helper.plane.releaseOne()
        let oneReturned = await yieldUntil("one of the two panic verbs to return") {
            let finishedCount =
                (await first.isFinished.isSet ? 1 : 0) + (await second.isFinished.isSet ? 1 : 0)
            return finishedCount == 1
        }
        #expect(oneReturned)
        #expect(await helper.plane.parkedRestores == 1, "the second verb is not still parked")

        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        #expect(refused == .releaseInProgress)
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == refused)

        await helper.plane.releaseAll()
        _ = try await finished("the first panic verb to return", first)
        _ = try await finished("the second panic verb to return", second)
        #expect(await Self.grants(0, in: helper, because: "both panic verbs have returned"))
    }

    /// A grant made after the seal opens and before the sweep empties the table is refused by
    /// the seal, not as another client's lease: nothing inserts while the seal is open, so the
    /// lease it can see is one the sweep is about to drop, and the snapshot already says
    /// `.releaseInProgress` about it.
    ///
    /// The window is the panic verb's own — its closure leaves the lease core between
    /// `sealingGrants` incrementing and `releaseEveryLease()` emptying the table — and nothing
    /// in `Sources/` parks inside it, so this hands `sealingGrants(during:)` a closure that parks
    /// at that point and then sweeps, as the verb's does.
    ///
    /// **Mutation:** move the seal's guard in `acquireLease` back below `guard table.isEmpty`.
    /// Run: red — the grant is refused `.leaseHeldByAnotherClient` while the snapshot says
    /// `.releaseInProgress`.
    @Test("A lease the sealed sweep is about to drop is not reported as another client's")
    func aGrantBetweenTheSealAndTheSweepIsRefusedByTheSeal() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        let sealed = AsyncSignal()
        let sweep = AsyncSignal()
        let leases = helper.leases
        let panic = observing {
            await leases.sealingGrants {
                await sealed.signal()
                _ = try? await sweep.wait()
                await leases.releaseEveryLease()
            }
        }
        try await sealed.wait()
        #expect(await helper.leases.leaseCount == 1, "the table is empty, so this asks nothing")

        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        #expect(refused == .releaseInProgress)
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == refused)

        await sweep.signal()
        _ = try await finished("the sealed sweep to return", panic)
        #expect(await helper.leases.leaseCount == 0)
    }

    // MARK: - What the seal does not overwrite

    /// A fan another program holds keeps `.foreignManualControl` while the seal is open, in the
    /// snapshot and at the grant: the seal's rung re-states `.available` and nothing else.
    ///
    /// **Mutation:** in `reportingMachineWideRestore(of:given:)`, drop
    /// `fan.manualControlAvailability == .available` from the guard, so every fan is re-stated.
    /// Run: red — the snapshot says `.releaseInProgress` about a fan another program holds.
    @Test("A refusal the seal must not overwrite stands while the panic verb runs")
    func aForeignFanKeepsItsRefusalWhileTheSealIsOpen() async throws {
        let helper = Self.composed(fanCount: 2, manual: [1])
        await helper.bindSafetyRegistries()
        await helper.plane.park(.everyFan)
        let panic = await Self.panicParked(in: helper)

        let refused = await Fixture.refusalForGrant(over: 1, from: helper.leases)
        #expect(refused == .foreignManualControl)
        let shown = try await Self.shownReason(ofFanAt: 1, in: helper)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) about a fan another program holds: the seal's rung \
            overwrote a refusal that is still true once the panic verb returns.
            """)
        #expect(
            try await Self.shownReason(ofFanAt: 0, in: helper) == .releaseInProgress,
            "the seal is not open, so this test is not asking about it")

        await helper.plane.releaseAll()
        _ = try await finished("the panic verb to return", panic)
    }
}
