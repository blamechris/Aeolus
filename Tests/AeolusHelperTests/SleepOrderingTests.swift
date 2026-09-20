import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The three edges [#202](https://github.com/blamechris/Aeolus/issues/202) records around
/// `docs/SAFETY.md` § 4's handback — the ones the delta re-review of #195 found true and
/// none of them a blocker, kept out of `SystemPowerTests` because none of them is about the
/// ordinary sleep that suite drives.
///
/// What they have in common is that each is a claim § 4 makes about its own record being
/// complete, and each was complete in a different sense than the claim: the seal is paired
/// with a wake that may already have happened, the fault line named the keystone without
/// having looked at it, and the unconfirmed set is whole only because one call site happens
/// to restore in a single call.
@Suite("§ 4's handback edges", .timeLimit(.minutes(1)))
struct SleepOrderingTests {

    // MARK: - Item 1: the seal must not outlive the wake it was paired with

    /// A wake answered before its own `.willSleep` body ran leaves the machine leaseable.
    ///
    /// `SystemPowerObserver.deliver(_:acknowledging:)` spawns an unstructured `Task` per
    /// event, so IOKit's serial queue orders the **spawns** and nothing orders the bodies. A
    /// `.willSleep` body starved past the kernel's ~30 s window means the machine sleeps and
    /// wakes regardless, and the `.didWake` body can reach `unsealAfterWake()` first.
    ///
    /// Delivering the two events in that order is the whole fixture: it is not a contrived
    /// sequence, it is the observable consequence of the one interleaving the seam permits.
    /// Before the fix, `unsealAfterWake()` found no seal, returned silently, and the starved
    /// `sealForSleep()` then closed the table with nothing left to open it — every lease
    /// refused as `.systemSleeping` until the *next* sleep and wake, on a machine sitting
    /// awake in front of its user.
    ///
    /// The assertion is the consequence rather than the flag: a lease is acquired, because
    /// "can this machine still be controlled" is what the seal is for and what a user would
    /// notice.
    ///
    /// **Mutation:** in `LeaseAuthority.unsealAfterWake()`, replace the
    /// `wakesAheadOfTheirSeal += 1` branch with a bare `return` (its behaviour before #202).
    /// Run: red — `.systemSleeping` on the acquire below.
    @Test("A seal whose wake was already answered does not close the table")
    func aSealArrivingAfterItsOwnWakeDoesNotRefuseEveryLease() async throws {
        let plane = SystemPowerTests.machine()
        let observer = ScriptedPowerObserver()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, safetyLog: RecordedLog())

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        // The starved ordering: the wake's body wins, and the sleep's body follows it.
        try await observer.deliver(.didWake)
        try await observer.deliver(.willSleep)

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.leases.leaseCount == 1,
            """
            manual control is refused on a machine that is demonstrably awake. The seal for \
            a sleep whose wake had already been answered closed the table with nothing left \
            to open it, so every lease is refused until the next sleep and wake.
            """)
    }

    /// And the credit is spent once, not standing forever.
    ///
    /// The counter is the fix; a counter that never decremented would be a second defect
    /// wearing the first one's clothes — § 4 would stop sealing altogether after one
    /// out-of-order episode, which is the *unsafe* direction and the one that matters.
    ///
    /// **Mutation:** delete `wakesAheadOfTheirSeal -= 1` from `sealForSleep()`. Run: red —
    /// the second sleep's seal is declined too and the parked request is granted.
    @Test("The credit from an early wake is spent once: the next sleep still seals")
    func theNextSleepAfterAnOutOfOrderEpisodeStillSeals() async throws {
        let plane = SystemPowerTests.machine()
        let observer = ScriptedPowerObserver()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, safetyLog: RecordedLog())

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        try await observer.deliver(.didWake)
        try await observer.deliver(.willSleep)

        // A second, ordinary sleep. This one has no credit to spend and must seal.
        try await observer.deliver(.willSleep)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
            """
            the table was left open across an ordinary sleep. One out-of-order episode \
            disabled the seal permanently, which is worse than the defect it was fixing: \
            a lease granted here crosses the sleep with nothing to hand its fan back.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    // MARK: - Item 2: a keystone-only wedge is observed rather than assumed

    /// A sleep with **no lease held** and a wedged keystone says the force key may still be
    /// set.
    ///
    /// This is the case that recorded nothing. `recordUnconfirmedHandbacks()` reads
    /// `releasing`, which only a lease teardown populates, so with no lease held
    /// `releaseEveryLease()` returns early, the set is empty, and the one durable register §
    /// 4 has is silent about a machine-wide restore that never cleared the Apple Silicon
    /// force key.
    ///
    /// The line it wrote instead described the empty set as *"none (the keystone restore is
    /// what is outstanding)"* — true here, and a guess: an empty set also means "every
    /// restore came back", which is the opposite fact about the same key. Now it is
    /// observed.
    ///
    /// **Mutation:** call `acknowledgement.keystoneSettled()` before issuing the keystone in
    /// `SystemPowerResponder.handBackEveryFan(reportingTo:)` — that is, report the keystone
    /// as settled without waiting for it, which is precisely what the old line assumed in
    /// reverse. Run: red on the first expectation.
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
            log.faults.contains { $0.contains("The machine-wide restore had not returned") },
            """
            the system was allowed to sleep on a wedged keystone with nothing saying so. \
            With no lease held there is no fan in any register, so this line is the only \
            record that the Apple Silicon force key was never cleared.
            """)
        #expect(
            log.faults.contains { $0.contains("none at the lease core") },
            "the line did not distinguish 'no fan was mid-handback' from 'no fan is at risk'")

        await plane.release()
        await delivery.value
    }

    /// The other branch, driven directly, because the composed graph cannot reach it.
    ///
    /// `handBackEveryFan(reportingTo:)` reports the keystone settled and *then* returns, and
    /// its caller cancels the budget on the next line — so "the keystone came back and the
    /// budget still fired" exists only in the instant between those two statements. That is a
    /// real interleaving (`SleepAcknowledgement` is an actor precisely because both paths are
    /// live) and it is not one a test can win deliberately.
    ///
    /// Driving the actor itself is what keeps the `false` branch from being text no input can
    /// reach. Without this, `describeKeystone(outstanding:)` could return the outstanding
    /// sentence unconditionally and every other test here would stay green — which is the
    /// same defect, one level up, as the guess this item replaced.
    ///
    /// **Mutation:** make `describeKeystone(outstanding:)` ignore its argument and always
    /// return the outstanding sentence. Run: red here, green everywhere else — which is the
    /// point.
    @Test("A keystone that did return is reported as having returned")
    func aSettledKeystoneIsReportedAsSettled() async throws {
        let plane = SystemPowerTests.machine()
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, safetyLog: log)
        await helper.bindSafetyRegistries()

        let acknowledgement = SleepAcknowledgement(
            SystemPowerNotification(event: .willSleep, acknowledging: {}),
            leases: helper.leases,
            budget: .milliseconds(50),
            log: SafetyLog(recording: { [log] in log.append($0, $1) }))

        await acknowledgement.keystoneSettled()
        await acknowledgement.acknowledge(.budgetExpired)

        #expect(
            log.faults.contains { $0.contains("The machine-wide restore did return") },
            "a keystone that came back was reported as still outstanding")
        #expect(
            !log.faults.contains { $0.contains("had not returned") },
            "both keystone sentences were written for one acknowledgement")
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
    /// Restoring per-lease or per-fan in a loop would put each later fan's increment *after*
    /// the previous one's suspension, and a wedge on the first would leave the rest neither
    /// restored nor recorded — § 4 acknowledging a sleep having registered one fan out of
    /// however many crossed it under manual control. #202 item 4 called that unreachable
    /// today and asked for the invariant to be recorded at the call site; this is the half
    /// that goes red if somebody refactors it.
    ///
    /// Two fans is the smallest machine that can tell "every fan" from "the first fan", which
    /// is why the fixture asks for `fanCount: 2` — on a one-fan machine a partial set and a
    /// complete one are the same set.
    ///
    /// **Mutation:** in `LeaseAuthority.releaseEveryLease()`, replace the single
    /// `await restore(fans, because: .allLeasesDropped)` with
    /// `for fan in fans.sorted() { await restore([fan], because: .allLeasesDropped) }`.
    /// Run: red — only fan 0 is recorded, because fan 1's increment sits behind fan 0's
    /// wedged write.
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
