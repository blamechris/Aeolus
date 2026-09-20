import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The three edges [#202](https://github.com/blamechris/Aeolus/issues/202) records around
/// `docs/SAFETY.md` § 4's handback — the ones the delta re-review of #195 found true and none
/// of them a blocker.
///
/// What they have in common is that each is a claim § 4 makes about its own record being
/// complete, and each was complete in a different sense than the claim: the seal is paired
/// with a wake that may already have happened, the fault line named the keystone without
/// having looked at it, and the unconfirmed set is whole only because one call site happens to
/// restore in a single call.
@Suite("§ 4's handback edges", .timeLimit(.minutes(1)))
struct SleepOrderingTests {

    // MARK: - Item 1: the seal is paired by generation, not by counting

    private static func helper(
        fanCount: Int = 1
    ) -> (
        HelperComposition<ScriptedControlPlane>, ScriptedPowerObserver
    ) {
        let observer = ScriptedPowerObserver()
        let helper = SystemPowerTests.composed(
            plane: SystemPowerTests.machine(fanCount: fanCount), observer: observer,
            fanCount: fanCount, safetyLog: RecordedLog())
        return (helper, observer)
    }

    /// A wake answered before its own `.willSleep` body ran leaves the machine leaseable.
    ///
    /// `SystemPowerObserver.deliver(_:acknowledging:)` spawns an unstructured `Task` per
    /// event, so IOKit's serial queue orders the **spawns** and nothing orders the bodies. A
    /// `.willSleep` body starved past the kernel's ~30 s window means the machine sleeps and
    /// wakes regardless, and the `.didWake` body can reach `unsealAfterWake(generation:)`
    /// first. Sealing then would refuse every lease on a machine that is awake in front of its
    /// user until the next sleep and wake.
    ///
    /// **Mutation:** drop the `generation > latestWakeGeneration` guard from
    /// `LeaseAuthority.sealForSleep(generation:)`. Run: red — `.systemSleeping` below.
    @Test("A seal whose wake was already answered does not close the table")
    func aSealArrivingAfterItsOwnWakeDoesNotRefuseEveryLease() async throws {
        let (helper, observer) = Self.helper()
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        // The starvation, modelled exactly: the sleep is *stamped* first — IOKit delivered it
        // first, on its serial queue — and its body runs last. Minting before delivering is
        // what separates stamp order from body order, and that separation IS the defect.
        // Delivering the two in order would describe a sleep that genuinely followed a wake,
        // which is an ordinary cycle and must seal.
        let starvedSleep = observer.mint(.willSleep)
        try await observer.deliver(.didWake)
        await observer.deliver(starvedSleep)

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.leases.leaseCount == 1,
            """
            manual control is refused on a machine that is demonstrably awake. The seal for a \
            sleep whose wake had already been answered closed the table with nothing left to \
            open it.
            """)
    }

    /// **The test that the first fix for item 1 could not pass**, and the reason that fix was
    /// thrown away rather than patched.
    ///
    /// That version banked a credit per early wake and spent one per seal. The arithmetic
    /// balanced only for the sequence a machine cannot produce — two `.willSleep`s with no
    /// wake between them. Insert the wake that physically must be there and it latches: a
    /// *declined* seal leaves the table unsealed, so the next ordinary wake takes the no-seal
    /// branch and banks a **fresh** credit, the count never returns to zero, and the seal is
    /// never set again for the life of the process. A fail-safe defect (over-refusal) became a
    /// fail-dangerous one — a lease granted, and its fan pinned, across every later sleep.
    ///
    /// Generations cannot latch, because they are compared and never spent.
    ///
    /// **Mutation:** restore the counter — `wakesAheadOfTheirSeal`, `+= 1` in the no-seal
    /// branch of `unsealAfterWake`, `-= 1` and `return` in `sealForSleep`. Run: red here,
    /// green on every other test in this file, which is precisely how it shipped.
    @Test("didWake, willSleep, didWake, willSleep — the second ordinary sleep still seals")
    func anUnpairedWakeDoesNotDisableTheSealForever() async throws {
        let (helper, observer) = Self.helper()
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        // One unpaired wake — a helper that restarted inside a sleep window hears exactly
        // this — and then two ordinary, correctly ordered cycles.
        try await observer.deliver(.didWake)
        try await observer.deliver(.willSleep)
        try await observer.deliver(.didWake)
        try await observer.deliver(.willSleep)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
            """
            the table was left open across an ordinary sleep. One unpaired wake disabled the \
            seal permanently, which is worse than the defect it was fixing: a lease granted \
            here crosses the sleep with nothing to hand its fan back, and every subsequent \
            sleep does the same.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// Three ordinary cycles after an unpaired wake, asserting the seal every time.
    ///
    /// The test above catches the latch at its first opportunity; this one says the mechanism
    /// is steady rather than merely surviving one round. It is the shape the sibling
    /// multi-cycle suites use for the same reason — this area's defects have a habit of
    /// appearing on cycle 2 or 3 rather than cycle 1.
    @Test("The seal keeps arming across repeated cycles after an unpaired wake")
    func theSealKeepsArmingAcrossRepeatedCycles() async throws {
        let (helper, observer) = Self.helper()
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        try await observer.deliver(.didWake)

        for cycle in 1...3 {
            try await observer.deliver(.willSleep)
            await #expect(
                throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
                "cycle \(cycle) slept with the table open"
            ) {
                _ = try await helper.leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
            }
            try await observer.deliver(.didWake)
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
            #expect(
                await helper.leases.leaseCount == 1, "cycle \(cycle) woke still refusing")
            // No explicit release: the next cycle's `.willSleep` drops every lease, which is
            // the behaviour under test rather than a convenience.
        }
    }

    /// A stale wake does not reopen a table a newer sleep has closed.
    ///
    /// The mirror of the case this mechanism exists for. If episode 2's `.willSleep` body runs
    /// before episode 1's starved `.didWake` body, that late wake is *older* than the seal
    /// standing — and the machine is, at that moment, going to sleep. Clearing on any wake at
    /// all would open the table exactly when § 4 needs it shut.
    ///
    /// **Mutation:** drop `generation > sealGeneration` from
    /// `LeaseAuthority.unsealAfterWake(generation:)`. Run: red — the lease is granted.
    @Test("A wake older than the seal standing does not reopen the table")
    func aStaleWakeDoesNotReopenANewerSeal() async throws {
        let (helper, observer) = Self.helper()
        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        // Mint the wake's notification first, so it carries the lower generation, and deliver
        // it after the sleep that outranks it.
        let staleWake = observer.mint(.didWake)
        try await observer.deliver(.willSleep)
        await observer.deliver(staleWake)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
            """
            a wake from an earlier episode reopened the table while a newer sleep was under \
            way. The machine is going to sleep and a lease granted now pins its fan across it.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    // MARK: - Item 2: the keystone is observed, in all four of its states

    /// The #68 wedge, with a lease held: the keystone is **never issued**.
    ///
    /// `handBackEveryFan(reportingTo:)` awaits `releaseEveryLease()` first, and on a wedged
    /// `io_connect_t` that never returns — so `restoreToAutomatic(.everyFan)` is not reached.
    /// A two-state flag reported this as "had not returned", beside a sentence promising that
    /// the parked restore might yet land and clear the force key. Nothing was parked, and
    /// nothing in that sleep will ever clear it.
    ///
    /// The assertion on `restoreScopes` is what makes this a fact rather than a reading of the
    /// code: `.everyFan` is absent, so the keystone demonstrably never went out.
    ///
    /// **Mutation:** move `keystoneReached(.outstanding)` in `handBackEveryFan(reportingTo:)`
    /// to before `await leases.releaseEveryLease()`. Run: red — the line claims a parked
    /// keystone that was never issued.
    @Test("A wedged lease teardown reports the keystone as never issued")
    func aWedgedTeardownReportsTheKeystoneAsNeverIssued() async throws {
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
            await plane.restoreScopes == [.fan(0)],
            "the keystone was issued after all, so this is not the case under test")
        #expect(
            log.faults.contains { $0.contains("was never issued") },
            "a keystone that was never issued was reported as one that had not returned")
        #expect(
            !log.faults.contains { $0.contains("the parked restore may yet land — and that") },
            """
            § 4 told its own log that a recovery is pending. No keystone was issued, so \
            nothing will clear the Apple Silicon force key until the next helper start.
            """)

        await plane.release()
        await delivery.value
    }

    /// A sleep with **no lease held** and a wedged keystone: issued, and outstanding.
    ///
    /// The case #202 item 2 names. `releaseEveryLease()` returns early with no lease to drop,
    /// so the keystone *is* reached and then wedges — and `recordUnconfirmedHandbacks()` reads
    /// an empty `releasing`, leaving this line as the only record that the force key was never
    /// cleared.
    ///
    /// **Mutation:** delete the `.outstanding` report and start `keystone` at `.landed`.
    /// Run: red on both expectations.
    @Test("A keystone-only wedge reports the force key as possibly still set")
    func aKeystoneOnlyWedgeIsRecordedAsSuch() async throws {
        let plane = WedgedRestorePlane(SystemPowerTests.machine())
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()
        #expect(await helper.leases.leaseCount == 0, "the fixture took a lease it should not")

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()

        #expect(
            await plane.restoreScopes == [.everyFan],
            "the keystone was not the thing outstanding, so this is not the case under test")
        #expect(
            log.faults.contains { $0.contains("issued and had not returned") },
            """
            the system was allowed to sleep on a wedged keystone with nothing saying so. With \
            no lease held there is no fan in any register, so this line is the only record \
            that the Apple Silicon force key was never cleared.
            """)
        #expect(
            log.faults.contains { $0.contains("none at the lease core") },
            "the line did not distinguish 'no fan was mid-handback' from 'no fan is at risk'")

        await plane.release()
        await delivery.value
    }

    /// The production reporting path, driven end to end, for both outcomes a returning
    /// keystone can have.
    ///
    /// This is deliberately the `.handedBack` acknowledgement rather than the budget one. The
    /// budget path can only see a *returned* keystone in the instant between
    /// `keystoneReached(.landed)` and `budget.cancel()` — a real interleaving, and not one a
    /// test can win deliberately — so pinning the reporting path there would mean driving
    /// `SleepAcknowledgement` by hand and asserting that a value the test supplied comes back.
    /// That is a fixture testing itself. The handback line reaches the same
    /// `describeKeystone(_:)` deterministically.
    ///
    /// The refused case is not hypothetical: on a build with no SMC write path the keystone is
    /// refused on **every** sleep, so this is what `log show` actually says today.
    ///
    /// **Mutation:** delete the `keystoneReached(.landed)` and `keystoneReached(.refused)`
    /// calls from `handBackEveryFan(reportingTo:)` — the production call sites, which nothing
    /// else reaches. Run: red here; every other test in this file stays green.
    @Test(
        "A returning keystone is reported as landed or refused, whichever it did",
        arguments: [
            (ScriptedControlPlane.WriteBehaviour.honoured, "landed, so the force key was cleared"),
            (.refused(reason: "no write path"), "came back refused"),
        ])
    func aReturningKeystoneIsReportedByTheProductionPath(
        _ writes: ScriptedControlPlane.WriteBehaviour, _ expected: String
    ) async throws {
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: SystemPowerTests.machine(writes: writes), observer: observer, safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        try await observer.deliver(.willSleep)

        #expect(
            log.lines(containing: expected).count == 1,
            """
            the handback line did not report what the keystone actually did. On a build with \
            no write path the keystone is refused every time, so a line that says only "the \
            handback finished" reads as success on a machine whose force key was never \
            cleared.
            """)
    }

    // MARK: - Item 4: the unconfirmed set is whole, not just its first fan

    /// Every fan a dropped lease covered is mid-handback, not only the one whose write wedged.
    ///
    /// `releaseEveryLease()` makes **one** `restore(_:because:)` call over the union of every
    /// dropped lease's fans, and `restore` increments `releasing` for the whole set *before*
    /// its suspension point. So the entire set is mid-handback the instant it awaits, and
    /// `recordUnconfirmedHandbacks()` sees all of it even though the first fan's write never
    /// returns.
    ///
    /// Restoring per fan in a loop would put each later fan's increment *after* the previous
    /// one's suspension, and a wedge on the first would leave the rest neither restored nor
    /// recorded — § 4 acknowledging a sleep having registered one fan out of however many
    /// crossed it under manual control.
    ///
    /// Two fans is the smallest machine that can tell "every fan" from "the first fan", which
    /// is why the fixture asks for `fanCount: 2`.
    ///
    /// **Mutation:** in `LeaseAuthority.releaseEveryLease()`, replace the single
    /// `await restore(fans, because: .allLeasesDropped)` with
    /// `for fan in fans.sorted() { await restore([fan], because: .allLeasesDropped) }`.
    /// Run: red here — and, as `TeardownSweepTripwireTests`' own doc comment predicts, red in
    /// that suite and in `everyFanInThePanicSweepIsInsideTheHandbackWindow` too. The
    /// non-redundant half here is the two-fan behavioural assertion below; the tripwire
    /// matches the loop's *shape*, not its consequence.
    @Test("A wedge on the first fan still records every fan the lease covered")
    func aWedgeOnOneFanStillRecordsTheWholeLease() async throws {
        let plane = WedgedRestorePlane(SystemPowerTests.machine(fanCount: 2))
        let observer = ScriptedPowerObserver()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), fanCount: 2,
            safetyLog: RecordedLog())

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1)

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()

        #expect(
            await helper.leases.fansMidHandback == [0, 1],
            """
            a fan the dropped lease covered is not mid-handback. Its restore was never \
            issued, so nothing will hand it back and nothing records that it crossed the \
            sleep under manual control.
            """)
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks == [0, 1],
            """
            § 4 acknowledged the sleep having recorded only part of what it dropped. A lease \
            over the unrecorded fan would be granted on a machine where nothing confirmed \
            that fan went back to automatic control.
            """)

        await plane.release()
        await delivery.value
    }
}
