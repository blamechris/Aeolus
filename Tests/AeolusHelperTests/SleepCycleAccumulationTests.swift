import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 4 run three times through one helper with the **budget expiring on every
/// one of them**, which is the half `UnconfirmedHandbackTests` could not assert.
///
/// A third sibling of `SystemPowerTests` rather than more of either, on the mechanical split
/// those two already record: that suite is at SwiftLint's type-body limit, and
/// `UnconfirmedHandbackTests` is at the file length that produced it. The graph, the machine
/// and the doubles are shared — `SystemPowerTests.composed`, `SystemPowerTests.machine` and
/// `CycleWedgingRestorePlane` — deliberately, for the reason that suite's header gives: a second
/// set of fixtures is how two suites start testing two different helpers.
///
/// ## What this adds, and why the existing multi-cycle test is not enough
///
/// `UnconfirmedHandbackTests.threeSleepCyclesEachSealReopenAndAcknowledgeOnce` (#234) drives
/// three **healthy** cycles: the seal is proven per cycle, the acknowledgement count is proven
/// once each, and the two handback registers are asserted **empty**. That last pair is the
/// problem, and it is this repository's most-repeated defect rather than a nitpick — *a test
/// that cannot fail.* On a healthy sleep the budget never expires, so
/// `LeaseAuthority.recordUnconfirmedHandbacks()` is never called, so both registers are empty
/// for a reason that has nothing to do with correctness. Both halves of that are measured rather
/// than asserted: with `recordUnconfirmedHandbacks()` reduced to `return []`, and again with it
/// unioning `restoreAbandoned` as decision D17 did,
/// `threeSleepCyclesEachSealReopenAndAcknowledgeOnce` passes and the test below fails.
///
/// [#209](https://github.com/blamechris/Aeolus/issues/209)'s failure scenario is precisely the
/// case those assertions cannot see: the handback is fine on cycle 1 and the budget expires on
/// cycle *N*, unattended. So every cycle here wedges. The register is written, the refusal it
/// produces is asserted **apart from the seal's**, the outstanding restore then lands and clears
/// it, and the next cycle starts from a fan that is grantable again — three times, with the
/// cycle number in every message, because "the register was not written" is a different finding
/// on cycle 1 than on cycle 3. The first says the mechanism never worked; the later ones say it
/// works once.
///
/// ## Which of decision D33's three endings this covers, and which it does not
///
/// The header above argues about *frequency*, and frequency is not the only axis. D33 (ADR 0007,
/// amendment 2026-09-06) gives an unconfirmed handback three endings, and they are covered to
/// three different depths — stated here rather than left for a reader to work out from the
/// assertions:
///
/// - **The outstanding restore lands, and the register clears.** Driven three times below, which
///   is the ending a machine that merely slept slowly actually reaches.
/// - **The restore never returns, and the register stands.** Covered across a wake and the sleep
///   after it by `SleepCycleSurvivalTests` — deliberately a sibling suite, because a wedge
///   released inside every cycle (as here) cannot express it.
/// - **The restore comes back refused after `RestoreLimits.attemptBudget`, and converts to the
///   durable `.restoreToAutomaticFailed`.** Covered for **one sleep only**, by
///   `UnconfirmedHandbackTests.aLateRefusalConvertsTheUnconfirmedStateToTheDurableOne` with
///   `WedgedThenRefusingRestorePlane`. Nothing drives a durable refusal earned on cycle 1 into a
///   cycle 2, so "a fan refused durably on an unattended cycle is still refused durably on the
///   next one" rests on the register being append-only by inspection rather than by assertion.
///   That is left open on purpose: what a durable refusal should do across a wake is #209's
///   criterion 3, the maintainer's clearability decision, and a test written before it is a test
///   that would have to be rewritten by it. The two assertions below that read
///   `fansWithAbandonedHandbacks` say the durable register was **not** produced; neither says
///   what happens once it is.
///
/// ## The cadence this is sized against, and the correction to it
///
/// #209 opened on a `pmset` capture reading one lid close as seven sleep cycles, and inferred
/// roughly thirty unattended chances a night to earn a refusal. Row 14's hardware capture
/// (2026-09-16, [SMC-RESEARCH.md](../../docs/SMC-RESEARCH.md), landed in #247) measured the
/// delivery instead: IOKit delivers **one** `.willSleep`/`.didWake` pair per lid close, to an
/// unprivileged process and the root helper alike — the inference was high by about 7×.
///
/// That correction does not retire this test, and it is worth saying why. A mechanism asserted
/// only in its first cycle is unpinned at *any* frequency: the helper is a long-lived root
/// daemon, so cycle 3 arrives on the third lid close of the day whether or not it arrives four
/// times an hour. What frequency governs is how urgent the *state* question is — exactly the
/// maintainer decision #209's criterion 3 holds open, and which nothing here settles.
@Suite("§ 4's handback registers across repeated sleep cycles", .timeLimit(.minutes(1)))
struct SleepCycleAccumulationTests {

    /// One helper, three sleeps, the budget expiring on each — and cycle 3 recorded, refused
    /// and cleared exactly as cycle 1 was.
    ///
    /// **The per-cycle register is returned out of the loop rather than asserted inside it**,
    /// and that is the whole reason the loop bound is a mutation this test can feel. An
    /// assertion made only inside a loop is satisfied by a loop that runs once; a list of what
    /// each cycle recorded is not. `[[0], [0], [0]]` is a claim about three cycles that
    /// `[[0]]` cannot satisfy, and it is a claim about *state* rather than about a counter —
    /// the fan each cycle actually left outstanding.
    ///
    /// **Fan 1 is enumerated, never leased, and is what separates the seal from the register.**
    /// Inside the sleep window fan 0 is refused `.handbackUnconfirmed` and fan 1 is refused
    /// `.systemSleeping`, and both are asserted every cycle. A one-fan machine cannot tell
    /// those apart — either refusal alone reads as "a lease was refused during a sleep" — which
    /// is how a seal that never reopens and a register that never clears both look correct.
    ///
    /// **The supervisors run, so this goes through `bringUp()`**, exactly as the healthy-path
    /// multi-cycle test does. Nothing here asserts on the firmware's attempt log, which is what
    /// makes that safe: three 1 Hz loops over a scripted plane would otherwise put reads in it
    /// that have nothing to do with sleeping.
    ///
    /// **Mutation A — the loop bound.** `for cycle in 1...3` → `1...1`. Run: red, three issues —
    /// `(perCycle → [Set([0])]) == [Set([0]), Set([0]), Set([0])]`, the acknowledgement list, and
    /// the fault-line count at 1 rather than 3.
    ///
    /// **Mutation B — decision D17 restored.** In `LeaseAuthority.recordUnconfirmedHandbacks()`,
    /// `restoreAbandoned.formUnion(outstanding)` in place of `handbackUnconfirmed`. Run: red —
    /// `fansWithAbandonedHandbacks.isEmpty` fails inside cycle 1 and fan 0's refusal comes back
    /// `.restoreToAutomaticFailed` rather than `.handbackUnconfirmed`. **This is the mutation
    /// `threeSleepCyclesEachSealReopenAndAcknowledgeOnce` cannot see**: measured, it stays green
    /// under B, because on a healthy sleep the budget never expires and neither register is ever
    /// written. That gap is why this test exists.
    ///
    /// **Mutation C — the clearing path.** Delete `handbackUnconfirmed.remove(fan)` from
    /// `LeaseAuthority.restore`'s `defer`. Run: red on cycle 1's clearing assertion.
    /// `aLateHandbackClearsTheUnconfirmedRefusal` also catches this for a single sleep, so C is
    /// corroboration rather than new cover — recorded as such rather than claimed.
    ///
    /// **Mutation D — the seal reopening once.** Give `unsealAfterWake()` a `hasUnsealed` guard.
    /// Run: red on **cycle 3's** grant, not cycle 2's, and the arithmetic is worth having written
    /// down: cycle 1's wake unseals and sets the flag, cycle 2's grant is taken before its own
    /// wake, and it is cycle 2's failed unseal that refuses cycle 3. The healthy-path multi-cycle
    /// test catches this one too, and it is what `expectThreeCyclesLeftNothingBehind`'s own grant
    /// is measured against: red **twice** there — `an error was thrown when none was expected:
    /// ".systemSleeping"` at the `throws: Never` wrapper, then `leaseCount == 1` on the line after
    /// it. The second is the load-bearing one: it says execution carried on past the refusal into
    /// the three `isRunning` assertions and the caller's `shutDown()`. A bare `try` there instead
    /// reported a single unattributed issue at the `@Test` line and ran none of that.
    ///
    /// **Mutation E — the register never written.** Reduce `recordUnconfirmedHandbacks()` to
    /// `return []`. Run: red on all three cycles' fan-0 refusal — which comes back
    /// `.systemSleeping` instead of `.handbackUnconfirmed` — and on `perCycle`
    /// (`[Set([]), Set([]), Set([])]`). That substitution is exactly what fan 1 is here to
    /// separate: a suite that asked only "was a lease refused inside the window?" would read the
    /// seal's answer as the register's and pass. Measured green in
    /// `threeSleepCyclesEachSealReopenAndAcknowledgeOnce`.
    ///
    /// **Mutation G — the register written once per helper.** `guard !hasRecordedOnce else
    /// { return [] }` at the top of `recordUnconfirmedHandbacks()`, so § 4's budget path records
    /// on the first sleep of a helper's life and never again. Run: red **only here**, three
    /// issues — `perCycle → [Set([0]), Set([]), Set([])]`, and cycles 2 and 3's fan-0 refusal
    /// coming back `.systemSleeping` — with the rest of the repository green (`1431 tests in 220
    /// suites … with 3 issues`, 34.6 s). **This is the mutation the rest of the list does not
    /// contain**, and it is the one the suite's whole premise rests on: A is this test's own loop
    /// bound, C and D are admitted above as caught elsewhere, and B and E redden the single-sleep
    /// tests too. G is caught by nothing else, `threeSleepCyclesEachSealReopenAndAcknowledgeOnce`
    /// and all three single-sleep unconfirmed tests included. What stays green under it is the
    /// three fault lines — § 4 logs the expiry whether or not the set it recorded was empty, so
    /// the log line is not a substitute for the register.
    ///
    /// **Mutation F — the keystone issued once per helper.** A per-responder latch before
    /// `restoreToAutomatic(.everyFan)` in `SystemPowerResponder.handBackEveryFan()`, so the
    /// machine-wide half of § 4 fires on the first sleep of a helper's life and never again.
    /// Run: red **only here** — `scopes → [.fan(0), .everyFan, .fan(0), .fan(0)]` at the
    /// `restoreScopes` assertion, with the whole rest of the repository green (`1431 tests in
    /// 220 suites … with 1 issue`, 31.0 s on a quiet machine). This is the mutation the register
    /// assertions cannot feel: the per-fan teardown stays perfect under it, so a suite that
    /// only read the registers would report three healthy cycles. A *process*-wide latch is a
    /// different and much weaker mutation — it also reddens three cycle-1 tests in
    /// `SystemPowerTests`, because those compose their own helper in the same process — which is
    /// why the latch is per responder.
    @Test("Three wedged sleep cycles each record, refuse and clear the same fan")
    func threeWedgedCyclesEachRecordRefuseAndClearTheSameFan() async throws {
        let plane = CycleWedgingRestorePlane(SystemPowerTests.machine(fanCount: 2))
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), fanCount: 2,
            safetyLog: log)

        await helper.bringUp()

        var perCycle: [Set<Int>] = []
        for cycle in 1...3 {
            perCycle.append(
                try await Self.sleepThroughOneWedgedCycle(
                    helper, observer, plane, cycle: cycle))
        }

        #expect(
            perCycle == [[0], [0], [0]],
            """
            the budget expired with fan 0's restore outstanding on three cycles and recorded \
            \(perCycle) rather than [[0], [0], [0]]. A register written only on the first \
            sleep of a helper's life leaves every later one silent: the machine sleeps, a fan \
            nothing confirmed went back to automatic control is leasable, and § 4's own record \
            of what it could not finish stops existing after the first lid close.
            """)
        #expect(
            observer.acknowledgements == [.willSleep, .willSleep, .willSleep],
            """
            three .willSleep notifications produced \(observer.acknowledgements) rather than \
            one acknowledgement each. Only .willSleep is acknowledged — IOKit does not ask a \
            woken process for permission to have woken — so a wake in this list is as wrong as \
            a missing sleep.
            """)
        #expect(
            log.faults.count { $0.contains("handback still outstanding") } == 3,
            """
            three budget expiries wrote \
            \(log.faults.count { $0.contains("handback still outstanding") }) fault lines. A \
            bound that stops reporting after the first sleep is indistinguishable, in log \
            show, from a handback that started working.
            """)

        await Self.expectBothHalvesOfTheHandbackRanEveryCycle(plane)
        await Self.expectThreeCyclesLeftNothingBehind(helper)

        await helper.shutDown()
    }

    /// Both acts of § 4's handback, on every cycle, read off the firmware rather than the
    /// registers.
    ///
    /// § 4 issues two restores that `SystemPowerResponder`'s doc calls different acts: the lease
    /// teardown's per-fan restore, and the machine-wide keystone that also clears the Apple
    /// Silicon force key. Every other assertion here reads a `LeaseAuthority` register and the
    /// keystone writes none of them — it consumes no lease and touches no lease state — so a
    /// keystone issued once per helper leaves them, and the healthy-path multi-cycle test, green.
    /// This is the one assertion that reads the wire, which is why mutation F is red only here.
    private static func expectBothHalvesOfTheHandbackRanEveryCycle(
        _ plane: CycleWedgingRestorePlane
    ) async {
        let scopes = await plane.restoreScopes
        #expect(
            scopes == [.fan(0), .everyFan, .fan(0), .everyFan, .fan(0), .everyFan],
            """
            three cycles issued \(scopes) rather than the lease's own fan followed by the \
            keystone, three times over. A keystone issued on the first sleep of a helper's life \
            and never again sleeps every later lid close with Ftst still set and any fan in \
            foreign manual control still in manual — and the per-fan half would still be \
            perfect, so no register assertion here would notice.
            """)
    }

    /// What three wedged-then-resolved cycles must leave: three empty registers, a grantable
    /// fan, and every supervisor still running.
    ///
    /// Extracted for SwiftLint's `function_body_length`: the test above is now the cadence and
    /// this is the end state.
    ///
    /// **The two empty-register assertions are the ones that are only meaningful here.** Asserted
    /// after three cycles that each *wrote* the unconfirmed register, they say it was written and
    /// then cleared; asserted after three healthy cycles, as
    /// `threeSleepCyclesEachSealReopenAndAcknowledgeOnce` does, they are satisfied by a helper in
    /// which nothing can ever write them. Same two lines, and the difference is entirely in what
    /// ran before them.
    private static func expectThreeCyclesLeftNothingBehind(
        _ helper: HelperComposition<CycleWedgingRestorePlane>
    ) async {
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            "the last cycle's restore landed and the fan is still recorded as unconfirmed")
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            """
            a budget expiry was recorded as a firmware refusal. Nothing on this path observed \
            a refused write — what was observed is that 50 ms passed — and the durable register \
            is the one no wake and no client action clears. Three cycles of it is #209's \
            failure scenario: manual control permanently unavailable on a fan whose machine's \
            only fault was sleeping slowly.
            """)
        #expect(
            await helper.leases.fansMidHandback.isEmpty,
            "a restore that returned left its releasing entry behind, three cycles running")

        // `throws: Never` rather than a bare `try`: a bare one skips the `isRunning` assertions
        // below *and* the caller's `shutDown()`, leaking three 1 Hz supervisor loops over a
        // scripted plane for the rest of the process. Measured under mutation D above.
        await #expect(
            throws: Never.self,
            """
            fan 0 could not be leased again after three wedged-then-resolved sleeps. Its restore \
            landed on every one of them, so either a cycle's unconfirmed register outlived the \
            restore that resolved it, or the seal stopped reopening — both refuse every lease for \
            the rest of the process's life, which is safe and useless.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(
            await helper.leases.leaseCount == 1,
            "fan 0 is no longer grantable after three wedged-then-resolved sleeps")

        #expect(await helper.thermalSupervisor.isRunning, "§ 3 stopped across three cycles")
        #expect(await helper.reclamationSupervisor.isRunning, "§ 5 stopped across three cycles")
        #expect(
            await helper.leaseExpirySupervisor.isRunning,
            "§ 1's TTL loop stopped across three cycles")
    }

    /// One wedged cycle: take a lease, sleep into the budget, prove what was recorded and what
    /// was refused, let the restore land, wake.
    ///
    /// - Returns: the fans this cycle's budget recorded as unconfirmed handbacks, read at the
    ///   instant the system was told it may sleep. Read there and not afterwards, because
    ///   afterwards it is empty by design — the outstanding restore clears it — so a test that
    ///   looked later could not tell a register that was written and cleared from one that was
    ///   never written.
    private static func sleepThroughOneWedgedCycle(
        _ helper: HelperComposition<CycleWedgingRestorePlane>,
        _ observer: ScriptedPowerObserver,
        _ plane: CycleWedgingRestorePlane,
        cycle: Int
    ) async throws -> Set<Int> {
        // `throws: Never` rather than a bare `try`, so a refusal here names the cycle it
        // happened on instead of escaping as an unattributed error from the test function.
        // Which cycle first refuses is the entire finding: cycle 1 says the mechanism never
        // worked, and a later one says it works a bounded number of times — mutation D above
        // is red on cycle 3, and the arithmetic that puts it there is the whole diagnosis.
        await #expect(
            throws: Never.self,
            """
            cycle \(cycle): manual control could not be taken after the previous wake. Either \
            the seal reopens only once, or the previous cycle's unconfirmed register was never \
            cleared by the restore that landed — both refuse every lease for the rest of the \
            process's life, which is safe and useless.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(await helper.leases.leaseCount == 1, "cycle \(cycle): no lease was granted")

        await plane.wedgeTheNextRestore()

        // A signal bound to *this* notification. `observer.didAcknowledge` latches, so awaiting
        // it on cycle 2 would return on cycle 1's signal and every assertion below would read
        // a cycle that had not happened yet.
        let acknowledged = AsyncSignal()
        let delivery = try observer.deliverWithoutWaiting(.willSleep, acknowledged: acknowledged)
        try await acknowledged.wait()

        let recorded = await helper.leases.fansWithUnconfirmedHandbacks
        #expect(
            await helper.leases.fansWithAbandonedHandbacks.isEmpty,
            """
            cycle \(cycle): the budget expiring was recorded as a firmware refusal. Decision \
            D33 (ADR 0007, amendment 2026-09-06) turns on the two being different facts, and \
            the durable one is what #209 measured the exposure of.
            """)

        // The two refusals of one window, asserted apart. Fan 0's is about the fan; fan 1's is
        // about the machine, and it lifts on the wake.
        await expectRefusal(
            .handbackUnconfirmed, from: helper.leases, fan: 0, cycle: cycle,
            because: """
                the fan whose handback the budget gave up waiting for is leasable, or is \
                refused with a reason that says the answer is still coming in a moment. It has \
                already outlived the budget.
                """)
        await expectRefusal(
            .systemSleeping, from: helper.leases, fan: 1, cycle: cycle,
            because: """
                a lease was granted over a fan on a machine that has already been told it may \
                sleep — or refused for a reason belonging to another fan. § 4 has handed every \
                fan back, so nothing will hand this one back.
                """)

        // The restore § 4 stopped waiting for comes back. This is D33's first ending, and the
        // one a machine that merely slept slowly actually reaches.
        await plane.release()
        await delivery.value
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            """
            cycle \(cycle): the outstanding restore landed and the fan is still refused. \
            Nothing else clears the register, so the fan is lost for the life of the process — \
            the failure decision D33 replaced D17 to prevent, and #209's own scenario.
            """)

        try await observer.deliver(.didWake)
        return recorded
    }

    /// The refusal one fan gets at one instant of one cycle, as an equality.
    ///
    /// An equality and not a pair of inequalities against the neighbouring reasons, for the
    /// reason `UnconfirmedHandbackTests.expectUnconfirmed` records: a review noted that the
    /// inequalities were implied by it, so neither could ever go red on its own.
    private static func expectRefusal(
        _ reason: ManualControlAvailability.Reason,
        from leases: LeaseAuthority,
        fan: Int,
        cycle: Int,
        because explanation: String
    ) async {
        let refusal = await #expect(throws: AeolusXPCFault.self) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
        }
        #expect(
            refusal == .manualControlUnavailable(reason: reason),
            """
            cycle \(cycle), fan \(fan): expected \(reason), got \
            \(String(describing: refusal)) — \(explanation)
            """)
    }
}
