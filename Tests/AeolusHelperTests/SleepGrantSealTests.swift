import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// No lease is granted while `docs/SAFETY.md` § 4's handback runs, whatever the sleep seal
/// decided and whatever the wake does ([#364](https://github.com/blamechris/Aeolus/issues/364)).
///
/// The sleep seal is the episode's: set before the teardown, lifted by a newer wake. The
/// teardown — `releaseEveryLease()`, then the `.everyFan` keystone — has an extent of its own,
/// and the two coincide only when it starts after the seal and ends before the wake. Each test
/// breaks one of those: a seal declined because its wake was already answered, a keystone that
/// outlives its wake, and a lease's sweep that outlives its wake. Until #364 a grant in each was
/// granted, and after A6 the pending restore would undo it. `allowSleepAfterHandback` now runs
/// the teardown inside `LeaseAuthority.sealingGrants(during:)`, the seal § 7 uses (#350);
/// docs/records/handback-ledger.md § "§ 4's handback runs inside it (#364)" argues it.
///
/// Composed over `ScopeParkingPlane`, so the teardown is parked inside the restore rather than
/// argued to be. Every park is a continuation, nothing blocks a thread, and every test lets
/// through what it parks and waits for the delivery to return. The snapshot provider answers
/// `F<n>Md` automatic for every fan, so the snapshot's own mode read agrees with the firmware's
/// and the agreement assertions ask about the seal alone. The supervisors are not started.
@Suite("No lease is granted while the sleep handback runs", .timeLimit(.minutes(1)))
struct SleepGrantSealTests {

    private typealias Fixture = AvailabilityFixture

    /// The daemon's wiring over firmware whose restores park by scope, with § 4 observed.
    ///
    /// `clock` defaults to a `ManualClock()` nobody advances, for the reason
    /// `SystemPowerTests.composed` gives (#411): § 4's acknowledgement budget sleeps on it, and
    /// so does nothing else here. The two cases that rest on a 50 ms budget firing pass the wall
    /// clock and say so. The declined-seal case's 30 s budget is meant never to answer, which a
    /// clock nobody moves guarantees and a wall clock stalled past 30 s does not.
    private static func composed(
        fanCount: Int, budget: Duration, clock: some MonotonicClock = ManualClock()
    ) -> (HelperComposition<ScopeParkingPlane>, ScriptedPowerObserver) {
        let observer = ScriptedPowerObserver()
        var modes: [String: Result<SensorReading, SensorReadFailure>] = [:]
        for fan in 0..<fanCount { modes["F\(fan)Md"] = .reading("F\(fan)Md", 0) }
        let helper = HelperComposition(
            plane: ScopeParkingPlane(SystemPowerTests.machine(fanCount: fanCount)),
            snapshotProvider: fanProvider(fanCount: fanCount, extraKeys: modes),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            powerObserver: observer,
            acknowledgementBudget: budget,
            log: Fixture.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Fixture.safetyLog)
        return (helper, observer)
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

    // MARK: - A declined seal

    /// A seal declined because its wake was already answered: the starved teardown runs on an
    /// awake machine, a grant while it runs is refused `.releaseInProgress`, and the snapshot
    /// says the same. Once it returns, a grant goes through. #364's acceptance.
    ///
    /// Two arguments, because the teardown has two halves. With no lease the keystone is what
    /// parks, and fan 0 is asked. With a lease over fan 0 taken after the wake, the sweep parks on
    /// fan 0's restore, and fan 1 — which the sweep does not cover — is asked. The budget is long
    /// enough never to answer, so nothing here depends on the acknowledgement.
    ///
    /// **Mutation:** in `allowSleepAfterHandback`, call `handBackEveryFan(reportingTo:)` bare,
    /// outside `sealingGrants`. Run: red on both arguments — "the grant path granted a lease".
    /// **Mutation:** keep the call bare and wrap only the `.everyFan` `do`/`catch` in
    /// `handBackEveryFan` in `leases.sealingGrants`. Run: red on the leased argument only, which
    /// is what the second argument is for. **Mutation:** delete `sealingGrants`' `defer`. Run: red
    /// on the last grant only. **Mutation:** delete the `machineWideRestoreInFlight` rung from
    /// `ReadOnlyFanReport.firstRefusal(of:observedMode:given:reconciliation:)`. Run: red on the
    /// agreement only.
    @Test(
        "A grant while a declined seal's teardown runs is refused, and the snapshot agrees",
        arguments: [false, true])
    func aGrantDuringADeclinedSealsTeardownIsRefused(leased: Bool) async throws {
        let (helper, observer) = Self.composed(fanCount: 2, budget: .seconds(30))
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        // Stamped first and run last — `SleepOrderingTests`' starvation — so the seal is declined
        // and the teardown runs after its own wake.
        let starvedSleep = observer.mint(.willSleep)
        try await observer.deliver(.didWake)
        if leased {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        let parked: FanRestoreScope = leased ? .fan(0) : .everyFan
        await helper.plane.park(parked)
        let teardown = observing { await observer.deliver(starvedSleep) }
        await yieldUntil("the starved teardown to park on its restore") {
            await helper.plane.parkedRestores == 1
        }
        #expect(await helper.plane.restoreScopes == [parked], "the teardown parked elsewhere")

        let asked = leased ? 1 : 0
        let refused = await Fixture.refusalForGrant(over: asked, from: helper.leases)
        #expect(refused == .releaseInProgress)
        let shown = try await Self.shownReason(ofFanAt: asked, in: helper)
        #expect(
            shown == refused,
            """
            the snapshot says \(shown) while a grant over the same fan is refused \(refused): a \
            client is offered control the sleep handback's seal refuses.
            """)

        await helper.plane.releaseAll()
        _ = try await finished("the starved teardown to return once let through", teardown)
        #expect(
            await Self.grants(asked, in: helper, because: "the starved teardown has returned"),
            "the seal outlived the teardown, so no lease can be granted for the process's life")
    }

    // MARK: - A teardown that outlives its wake

    /// A keystone that outlives its wake: with no lease the teardown reaches `.everyFan` at once,
    /// the budget lets the machine sleep with it parked, and the wake lifts the sleep seal. A grant
    /// is refused `.systemSleeping` before the wake and `.releaseInProgress` after it, and the
    /// snapshot agrees after it.
    ///
    /// The sleep seal was *set* here, so this is the route a seal keyed on the declined case
    /// leaves open. Whether a grant here would be undone after A6 depends on ADR 0014 D7's turn
    /// order, which is not built; it is refused either way, because a lease over a machine whose
    /// keystone is wedged is control nothing can honour. Before the wake both say
    /// `.systemSleeping`: the ladder's step 11 is above step 10, as the grant checks the sleep seal
    /// before this one ([#269](https://github.com/blamechris/Aeolus/issues/269)).
    ///
    /// **Mutation:** call `handBackEveryFan(reportingTo:)` bare. Run: red after the wake.
    /// **Mutation:** give `sealForSleep(generation:)` a discardable `Bool` result, true when it
    /// declined, and wrap the teardown only when it is true. Run: red here and in the sweep test
    /// below, green in the declined-seal test above. **Mutation:** set
    /// `machineWideRestoresInFlight = 0` in `unsealAfterWake(generation:)`. Run: red after the
    /// wake. **Mutation:** in `ReadOnlyFanReport.firstRefusal`, move the
    /// `machineWideRestoreInFlight` rung above the `sleepSealed` one. Run: red before the wake —
    /// the snapshot says `.releaseInProgress`.
    @Test("A keystone parked across its wake still refuses a grant after the wake")
    func aKeystoneThatOutlivesItsWakeStillRefusesAGrant() async throws {
        // The wall clock, opting out of `composed`'s frozen default (#411): the claim rests on the
        // 50 ms budget firing while the restore is parked, and a stall only makes it fire sooner.
        let (helper, observer) = Self.composed(
            fanCount: 1, budget: .milliseconds(50), clock: SystemMonotonicClock())
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()
        await helper.plane.park(.everyFan)

        let sleep = observing { try await observer.deliver(.willSleep) }
        // Parked first, then acknowledged: the acknowledgement is a 50 ms wall-clock budget's.
        await yieldUntil("the keystone to park") { await helper.plane.parkedRestores == 1 }
        try await observer.didAcknowledge.wait()
        #expect(
            await helper.plane.restoreScopes == [.everyFan],
            "the keystone is not what is parked, so this is not the case under test")
        let sleeping = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        #expect(sleeping == .systemSleeping)
        #expect(
            try await Self.shownReason(ofFanAt: 0, in: helper) == sleeping,
            "before the wake the snapshot states the restore seal over the sleep seal")

        try await observer.deliver(.didWake)
        let refused = await Fixture.refusalForGrant(over: 0, from: helper.leases)
        #expect(
            refused == .releaseInProgress,
            """
            after the wake fan 0 came back \(refused) with the keystone still parked: the restore \
            the sleep handback issued is pending, and a lease granted now is one it undoes.
            """)
        #expect(try await Self.shownReason(ofFanAt: 0, in: helper) == refused)

        await helper.plane.releaseAll()
        _ = try await finished("the keystone to return once let through", sleep)
        #expect(await Self.grants(0, in: helper, because: "the keystone has returned"))
    }

    /// A sweep that outlives its wake: a lease over fan 0 whose restore parks, the budget lets
    /// the machine sleep, and the wake lifts the sleep seal with the sweep still parked and the
    /// keystone not yet issued. Fan 0 is refused `.handbackUnconfirmed`, fan 1
    /// `.releaseInProgress`, and the snapshot agrees about both. Once the sweep returns, the
    /// keystone follows it — the restore a grant over fan 1 would have met — and fan 1 is granted.
    ///
    /// `UnconfirmedHandbackTests` and `SleepCycleSurvivalTests` granted fan 1 in this window and
    /// asserted it as correct until #364; both now assert this refusal instead.
    ///
    /// **Mutation:** call `handBackEveryFan(reportingTo:)` bare. Run: red after the wake.
    /// **Mutation:** the declined-only wrap above. Run: red. **Mutation:** wrap only the
    /// `.everyFan` `do`/`catch`. Run: red — the sweep is parked with the gate open.
    @Test("A sweep parked across its wake refuses a grant over a fan it does not cover")
    func aSweepThatOutlivesItsWakeRefusesAGrantOverAnotherFan() async throws {
        // The wall clock, opting out of `composed`'s frozen default (#411): the claim rests on the
        // 50 ms budget firing while the restore is parked, and a stall only makes it fire sooner.
        let (helper, observer) = Self.composed(
            fanCount: 2, budget: .milliseconds(50), clock: SystemMonotonicClock())
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        await helper.plane.park(.fan(0))

        let sleep = observing { try await observer.deliver(.willSleep) }
        // Parked first, then acknowledged, for the reason the keystone test gives.
        await yieldUntil("the sweep to park on fan 0") { await helper.plane.parkedRestores == 1 }
        try await observer.didAcknowledge.wait()
        #expect(
            await helper.plane.restoreScopes == [.fan(0)],
            "the lease's own restore is not what is parked, so this is not the case under test")
        #expect(await Fixture.refusalForGrant(over: 1, from: helper.leases) == .systemSleeping)

        try await observer.deliver(.didWake)
        for (fan, expected) in [
            (0, ManualControlAvailability.Reason.handbackUnconfirmed), (1, .releaseInProgress),
        ] {
            let refused = await Fixture.refusalForGrant(over: fan, from: helper.leases)
            #expect(refused == expected, "fan \(fan) after the wake came back \(refused)")
            let shown = try await Self.shownReason(ofFanAt: fan, in: helper)
            #expect(shown == refused, "the snapshot says \(shown) about fan \(fan)")
        }

        await helper.plane.releaseAll()
        _ = try await finished("the sweep and the keystone to return once let through", sleep)
        #expect(
            await helper.plane.restoreScopes == [.fan(0), .everyFan],
            "the keystone did not follow the sweep, so this did not show what fan 1 would meet")
        #expect(await Self.grants(1, in: helper, because: "the teardown has returned"))
    }
}
