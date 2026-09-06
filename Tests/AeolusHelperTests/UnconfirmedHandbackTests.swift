import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What `docs/SAFETY.md` § 4 leaves behind, and what happens when it runs more than once.
///
/// A sibling of `SystemPowerTests` rather than more of it, and the split is mechanical: that
/// suite is at SwiftLint's type-body limit and these tests arrived last. They compose the
/// same graph through the same `SystemPowerTests.composed` and `.machine` fixtures,
/// deliberately — the argument that suite's header makes about driving § 4 through
/// `HelperComposition` rather than a paraphrase applies here unchanged, and a second set of
/// fixtures is how two suites start testing two different helpers.
///
/// The subject is decision D33 (ADR 0007, amendment 2026-09-06,
/// [#209](https://github.com/blamechris/Aeolus/issues/209)) and the sleep *cadence* the same
/// issue measured: a handback the acknowledgement budget stopped waiting for is recorded as
/// unconfirmed rather than as a firmware refusal, and a lid close is several sleep cycles
/// rather than one.
@Suite("§ 4's handback outcomes, over more than one sleep", .timeLimit(.minutes(1)))
struct UnconfirmedHandbackTests {

    // MARK: - What the budget leaves behind

    /// The lease table is empty at the acknowledgement, and the fan left behind is refused
    /// as **unconfirmed** — not as a firmware refusal, and not as "retry in a moment".
    ///
    /// Two properties of the same wedged sleep, asserted together because they are the two
    /// halves of what § 4 owes a fan whose handback has not landed.
    ///
    /// **The ordering.** `handBackEveryFan()` drops every lease *before* it issues the
    /// keystone, and that was documented as load-bearing while nothing pinned it: swapping the
    /// two statements left the whole suite green, and on a wedged connection the swapped
    /// version sleeps the machine with every lease live and every fan in manual. So the lease
    /// count is read from **inside** the acknowledgement, exactly as the plane's attempts are
    /// in `sleepHandsTheFansBackBeforeAllowingThePowerChange` — afterwards is useless, because
    /// on a wedged connection the responder never gets there at all.
    ///
    /// **The refusal, and which one it is.** Decision D33 (ADR 0007, amendment 2026-09-06,
    /// #209). This test asserted `.restoreToAutomaticFailed` until then, on decision D17's
    /// argument that a budget expiring is the same event as a firmware refusal. It is not — a
    /// budget expiring is evidence about time. So the fan is refused `.handbackUnconfirmed`,
    /// which refuses exactly as hard while it stands, and the two inequalities in
    /// `expectUnconfirmed` are the content of the change: a client told `.releaseInProgress`
    /// retries in a moment against a restore that has outlived five seconds, and one told
    /// `.restoreToAutomaticFailed` reaches for a helper restart to clear something a restart
    /// does not clear.
    ///
    /// It is asserted twice — once while the machine still believes it is going to sleep, and
    /// again after `.didWake` with the restore still parked; the second is what says the
    /// refusal is not the sleep seal wearing another name.
    ///
    /// **Fan 1 is enumerated, never leased, and grantable throughout**, which is the invariant
    /// `handbackUnconfirmed` is documented to hold: it is a subset of the fans whose restore
    /// was actually issued. A one-fan machine cannot tell that set from "every fan this helper
    /// knows about".
    ///
    /// The lease's own fan is what wedges here, not the keystone, which is why `restoreScopes`
    /// is `[.fan(0)]` rather than `[.everyFan]` — the keystone is not reached until the wedge
    /// lets go, which is the honest shape of a stale `io_connect_t` under a live lease.
    ///
    /// **Mutation A:** in `handBackEveryFan()`, move `await leases.releaseEveryLease()` below
    /// the `do { try await writer.restoreToAutomatic(.everyFan) … }` block. Run: red on the
    /// lease count.
    /// **Mutation B:** delete the `guard unconfirmed.isEmpty` block from
    /// `LeaseAuthority.acquireLease`. Run: red.
    /// **Mutation C:** in `LeaseAuthority.recordUnconfirmedHandbacks()`, union every
    /// enumerated fan rather than `releasing.keys`. Run: red on fan 1.
    @Test("A wedged handback drops the lease first and leaves the fan unconfirmed")
    func aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed() async throws {
        let plane = WedgedRestorePlane(SystemPowerTests.machine(fanCount: 2))
        let observer = ScriptedPowerObserver()
        let witness = AcknowledgementWitness()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), fanCount: 2,
            safetyLog: log)
        observer.whenAcknowledging { [leases = helper.leases] in
            await witness.record(leaseCount: leases.leaseCount)
        }

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1)

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()

        #expect(
            await witness.leaseCount == 0,
            """
            the system was told it may sleep with a lease still live. The keystone restore \
            preceded the lease teardown, and on a wedged connection that means every fan \
            crosses the sleep in manual with a client still holding them.
            """)
        #expect(
            await plane.restoreScopes == [.fan(0)],
            "the lease's own fan is what wedged, so the keystone cannot have been reached yet")
        #expect(
            log.faults.contains { $0.contains("handback still outstanding") },
            "the system was allowed to sleep on the budget without a fault-level line")

        await Self.expectUnconfirmed(helper.leases, fan: 0, whenAsking: "while parked")

        // The machine wakes with the restore still parked. The seal is gone; the refusal is
        // not, and it is still the same refusal — which is what makes it a fact about this
        // fan rather than about the sleep window.
        try await observer.deliver(.didWake)
        await Self.expectUnconfirmed(helper.leases, fan: 0, whenAsking: "after the wake")

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks == [0],
            """
            a fan whose restore was never issued is recorded as an unconfirmed handback. The \
            set is documented as a subset of the fans mid-restore, and every claim resting on \
            that — fansAeolusIsAccountableFor not unioning it included — is false if it is not.
            """)

        // Nothing is left parked behind the test.
        await plane.release()
        await delivery.value
    }

    /// A restore that lands late clears the refusal it left behind.
    ///
    /// The half decision D33 exists for, and the one D17 could not express: the wedge lets go,
    /// the restore the helper stopped waiting for completes, and the fan becomes leasable
    /// again. Under D17 this test could not have been written — the durable refusal was
    /// append-only by construction, so a healthy machine that merely slept slowly lost the fan
    /// for the life of the process, with `docs/RECOVERY.md` as the only route out.
    ///
    /// Both registers are asserted empty rather than only the grant succeeding. A grant proves
    /// the fan left `handbackUnconfirmed`; it does not prove it was ever in it, and it does
    /// not prove it stayed out of `restoreAbandoned`.
    ///
    /// **Mutation:** delete `handbackUnconfirmed.remove(fan)` from `LeaseAuthority.restore`'s
    /// `defer`. Run: red.
    @Test("A handback that lands after the budget makes the fan grantable again")
    func aLateHandbackClearsTheUnconfirmedRefusal() async throws {
        let plane = WedgedRestorePlane(SystemPowerTests.machine())
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks == [0],
            "the budget expired with fan 0's restore outstanding and nothing recorded it")

        // The two events that decide the outcome: the parked write lands, and the machine
        // wakes. Awaiting the delivery is what makes "the restore returned" a fact rather than
        // a hope — `restore(_:because:)` clears the register in its own `defer`.
        await plane.release()
        await delivery.value
        try await observer.deliver(.didWake)

        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            """
            the restore came back and the fan is still refused. Nothing else will ever clear \
            it, so a machine that only slept slowly has lost a fan permanently — the failure \
            decision D33 replaced D17 to prevent.
            """)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            "a restore the firmware took was recorded as one it refused")

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1)
    }

    /// A restore that comes back *refused* converts the unconfirmed state into the durable one.
    ///
    /// D33's third ending, and the one that keeps `.restoreToAutomaticFailed` meaning what it
    /// says: the firmware refused every attempt, so the fan is refused durably and a helper
    /// restart is the route out. Nothing new records that — `LeaseAuthority.restore` already
    /// unions whatever the restorer reports it could not hand back, and the fan leaves
    /// `handbackUnconfirmed` in the same `defer`. *"Converts to the durable set through the
    /// path that already exists"* is the decision's own wording, and this holds it to it.
    ///
    /// `WedgedThenRefusingRestorePlane` is the double no existing one could stand in for: the
    /// budget has to expire with the restore outstanding **and** the eventual answer has to be
    /// a refusal. `BoundedFanRestorer` then spends `RestoreLimits.attemptBudget` on it — three
    /// attempts, no inter-attempt wait by design — before reporting the fan abandoned.
    ///
    /// **Mutation:** delete `restoreAbandoned.formUnion(await restorer.restoreToAutomatic(…))`
    /// from `LeaseAuthority.restore`, awaiting the restorer without recording its answer.
    /// Run: red.
    @Test("A handback the firmware refuses after the budget is refused durably")
    func aLateRefusalConvertsTheUnconfirmedStateToTheDurableOne() async throws {
        let plane = WedgedThenRefusingRestorePlane(SystemPowerTests.machine())
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()
        #expect(await helper.leases.fansWithUnconfirmedHandbacks == [0])

        await plane.release()
        await delivery.value
        try await observer.deliver(.didWake)

        #expect(
            await helper.leases.fansWithAbandonedHandbacks == [0],
            """
            the firmware refused every attempt and nothing recorded it durably. The fan is off \
            automatic control with no route back, and the next client is told to retry.
            """)
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            """
            the fan is in both registers at once. They describe incompatible facts — one says \
            the answer is still coming, the other that it came and was a refusal — and the \
            grant gate would be reporting whichever it happens to check first.
            """)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed),
            """
            a fan the firmware refused three times can be leased again, or is refused with the \
            reason that says the answer is still coming. Neither is true of it.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// The refusal a fan whose handback is unconfirmed gets, and the two it must not get.
    ///
    /// Factored out because it is asserted at two different instants in one test — sealed and
    /// unsealed — and the inequalities are the point rather than decoration: they are what
    /// stops the new case being a rename of either neighbour.
    private static func expectUnconfirmed(
        _ leases: LeaseAuthority, fan: Int, whenAsking moment: String
    ) async {
        let refusal = await #expect(throws: AeolusXPCFault.self) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
        }
        #expect(
            refusal == .manualControlUnavailable(reason: .handbackUnconfirmed),
            """
            fan \(fan) \(moment): expected the unconfirmed refusal, got \
            \(String(describing: refusal)).
            """)
        #expect(
            refusal != .manualControlUnavailable(reason: .releaseInProgress),
            """
            fan \(fan) \(moment): told to retry in a moment about a restore that has already \
            outlived the acknowledgement budget. A client acts on that by retrying forever.
            """)
        #expect(
            refusal != .manualControlUnavailable(reason: .restoreToAutomaticFailed),
            """
            fan \(fan) \(moment): told the firmware refused a write nothing has reported on \
            yet. The user's action for that reason is a helper restart, and the restore that \
            would clear this state is still running.
            """)
    }

    // MARK: - More than one sleep

    /// One helper, three sleep/wake cycles, and nothing accumulates.
    ///
    /// **A lid close is not one cycle** (#209). `docs/SAFETY.md` § 4 records the measurement:
    /// one 1 h 29 min lid-closed window on `Mac16,5` produced one clamshell sleep plus six
    /// maintenance sleeps, so § 4's whole sequence — seal, drop every lease, restore, allow —
    /// runs on the order of four times an hour. Every other test of § 4 — here and in
    /// `SystemPowerTests` — delivers exactly one `.willSleep`, which means every
    /// once-per-cycle mechanism was pinned only in its first cycle and a once-per-*process*
    /// implementation of any of them was green.
    ///
    /// **A fresh lease is taken at the top of every cycle, and that is not setup.** Without
    /// it, cycles two and three run against an empty lease table: the seal is still set and
    /// cleared, but nothing is torn down, restored or recorded. The cycle count is named
    /// **outside** the loop for the mirror-image reason — an assertion made only inside it is
    /// satisfied by a loop that runs once.
    ///
    /// The supervisors run, so this goes through `bringUp()` rather than the hand-wiring the
    /// rest of § 4's tests use. Nothing here asserts on the firmware's attempt log, which is
    /// what makes that safe: three 1 Hz loops reading a scripted plane would otherwise put
    /// reads in it that have nothing to do with sleeping.
    ///
    /// **Mutation A:** change the loop bound to `1...1`. Run: red on the acknowledgement
    /// count.
    /// **Mutation B:** give `LeaseAuthority.unsealAfterWake()` a `hasUnsealed` guard so it
    /// fires once. Run: red on cycle 2's grant.
    /// **Mutation C:** hoist `settledOutcome` out of `SleepAcknowledgement` to a scope wider
    /// than one notification. Run: red on the acknowledgement count.
    @Test("Three sleep cycles seal, reopen and acknowledge once each", .timeLimit(.minutes(1)))
    func threeSleepCyclesEachSealReopenAndAcknowledgeOnce() async throws {
        let observer = ScriptedPowerObserver()
        let helper = SystemPowerTests.composed(
            plane: SystemPowerTests.machine(), observer: observer, safetyLog: RecordedLog())

        await helper.bringUp()

        for cycle in 1...3 {
            try await Self.takeALeaseAndSleepThroughOneCycle(helper, observer, cycle: cycle)
        }

        #expect(
            observer.acknowledgements.count == 3,
            """
            three .willSleep notifications produced \(observer.acknowledgements.count) \
            acknowledgements rather than one each. The once-only guard is per notification; \
            one that spans the process answers the first sleep and leaves every later one \
            waiting on the kernel's own timeout, which this helper never sees and never logs.
            """)
        #expect(observer.acknowledgements == [.willSleep, .willSleep, .willSleep])

        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            """
            three healthy sleeps left a fan recorded as an unconfirmed handback. The register \
            is written only when the budget expires, and none of these came near it.
            """)
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            "three healthy sleeps left a fan recorded as a firmware refusal")

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.leases.leaseCount == 1,
            "fan 0 is no longer grantable after three ordinary sleeps")

        #expect(await helper.thermalSupervisor.isRunning, "§ 3 stopped across three cycles")
        #expect(await helper.reclamationSupervisor.isRunning, "§ 5 stopped across three cycles")
        #expect(
            await helper.leaseExpirySupervisor.isRunning,
            "§ 1's TTL loop stopped across three cycles")

        await helper.shutDown()
    }

    /// One cycle of the loop above: take a fresh lease, sleep, prove the seal holds, wake.
    ///
    /// Extracted so the loop reads as three cycles rather than as sixty lines, and so the
    /// mutation that matters — the bound — is on a line by itself. Both assertions carry the
    /// cycle number, because "a lease was refused" is a different finding in cycle 1 than in
    /// cycle 3: the first says the mechanism never worked, the later ones say it works once.
    private static func takeALeaseAndSleepThroughOneCycle(
        _ helper: HelperComposition<ScriptedControlPlane>,
        _ observer: ScriptedPowerObserver,
        cycle: Int
    ) async throws {
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.leases.leaseCount == 1,
            """
            cycle \(cycle): manual control could not be taken after the previous wake. A seal \
            that reopens only once refuses every lease for the rest of the process's life, \
            which is safe and useless.
            """)

        try await observer.deliver(.willSleep)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
            """
            cycle \(cycle): a lease was granted inside the sleep window. § 4 has already \
            handed every fan back, so nothing will hand this one back — the fan crosses the \
            sleep pinned.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        try await observer.deliver(.didWake)
    }
}
