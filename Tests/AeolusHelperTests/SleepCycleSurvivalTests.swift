import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The half of `docs/SAFETY.md` § 4's unconfirmed register that only shows up when it is
/// *never* resolved: a handback that does not come back, and the sleeps that follow it.
///
/// A sibling of `SleepCycleAccumulationTests` rather than another test inside it, on that
/// suite's own file-length argument — and because the two pin opposite halves of one
/// mechanism. That suite drives three cycles whose wedge is released on each, so the register
/// is written and cleared entirely inside every cycle and never crosses a cycle boundary: it
/// proves the register is written *again* on cycle 3. This one never releases the wedge, so
/// the register written on cycle 1 is the same one read after the second wake: it proves the
/// register *survives*. Neither substitutes for the other, and that is measured rather than
/// argued — mutation B below is red only here, and the once-per-helper recording mutation
/// that is red only in the sibling suite is green in this one, because nothing here needs
/// cycle 2 to record anything.
///
/// ## Why the instant after the wake is the one that matters
///
/// [#209](https://github.com/blamechris/Aeolus/issues/209) is about a refusal that has to last
/// past the lid being opened. Inside the sleep window the seal refuses every lease anyway, so
/// every register assertion made there is answered by a mechanism that is not the register —
/// which is exactly how a register that never survives a wake would look correct. The seal
/// lifts on `.didWake`; what is asserted after it is the register alone.
///
/// ## What this does not claim
///
/// The fan is re-recorded on the second sleep as well, and the doc comment says so rather than
/// letting a reader infer otherwise: a restore that never returns keeps its fan in
/// `LeaseAuthority.releasing`, so every later budget expiry records the same fan again. So the
/// load-bearing assertion is the one after the **first** wake, with a second sleep and wake
/// stacked on top of it to show that neither the seal closing again nor a second expiry
/// disturbs the answer. What the second cycle does pin on its own is decision D33's boundary:
/// two expiries on one outstanding fan are still not evidence about the firmware, so the
/// durable register stays empty.
@Suite("§ 4's unconfirmed register across a wake and the sleep after it", .timeLimit(.minutes(1)))
struct SleepCycleSurvivalTests {

    /// One fan whose restore never returns, two sleeps, two wakes — and the same refusal at
    /// the end as at the beginning.
    ///
    /// **The wedge is armed once and never released**, which is what makes this different from
    /// every other multi-cycle test of § 4. `CycleWedgingRestorePlane` keeps parking every
    /// restore until `release()`, so cycle 1's per-fan restore is still parked while cycle 2
    /// sleeps and the keystone is never reached on either. That is the honest shape of the case
    /// #209 describes — a stale `io_connect_t` under a live lease, which does not heal because
    /// the machine woke up.
    ///
    /// **Fan 1 is enumerated, never leased until the last act, and is the separator.** It is
    /// granted *after* the second wake, so a stuck seal and a stuck register cannot both read as
    /// "a lease was refused". It is not granted earlier for a reason worth stating: a lease on
    /// fan 1 would be torn down by cycle 2's sleep, park on the same wedge, and put fan 1 in the
    /// register too — which is correct behaviour and would destroy the separator.
    ///
    /// **No supervisors**, unlike the sibling suite: nothing here asserts that one is running,
    /// and a 1 Hz loop over a plane whose restore verb is parked for the whole test adds
    /// nondeterminism for no property. `bindSafetyRegistries()` plus `observeSystemPower()` is
    /// the composition `aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed` already
    /// uses for a wedge of this shape.
    ///
    /// **Mutation A — the wake clearing the register.** Add `handbackUnconfirmed.removeAll()` to
    /// `LeaseAuthority.unsealAfterWake()`, the plausible "helpful" edit since that method already
    /// reopens acquisition on wake. Run: red here, 4 issues, two at each wake —
    /// `refusal → .releaseInProgress` where `.handbackUnconfirmed` was expected, and
    /// `fansWithUnconfirmedHandbacks → []`. **The measured harm is a misreported reason, not a
    /// granted lease**, and that is worth recording rather than rounding up to #209's headline:
    /// the fan is still mid-`releasing`, so `acquireLease`'s downstream guard answers instead —
    /// with *"retry in a moment"* about a restore that has already outlived the budget, which is
    /// the one thing that region's own doc comment says a client must not be told. A downstream
    /// guard masking an upstream one is why the register is asserted beside the refusal rather
    /// than behind it. Across the repository: 6 issues, the other 2 in the pre-existing
    /// single-sleep `aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed`, which was the
    /// only test that saw this before — the multi-cycle suite named for accumulation could not.
    ///
    /// **Mutation B — a second expiry promoted to the durable register.** In
    /// `recordUnconfirmedHandbacks()`, union `outstanding.intersection(handbackUnconfirmed)` into
    /// `restoreAbandoned` — the "it has now missed two whole sleeps, it has clearly failed" edit,
    /// which is decision D17 creeping back one cycle later than before. Run: red **only here**, 2
    /// issues, both after the second wake — fan 0's refusal coming back
    /// `.restoreToAutomaticFailed` and `fansWithAbandonedHandbacks.isEmpty` — against `1431 tests
    /// in 220 suites` with those two and nothing else. Nothing else in the repository sleeps
    /// twice on one outstanding fan, so nothing else can see it.
    ///
    /// **Mutation C — the seal reopening once.** A `hasUnsealed` latch on `unsealAfterWake()`.
    /// Run: red on the fan 1 grant after the second wake (`.systemSleeping` where nothing was
    /// expected to throw, then the lease count) — so the separator is load-bearing and not
    /// decoration. Caught by the two other multi-cycle tests as well, so it is corroboration
    /// rather than new cover. It is also why that grant is wrapped in `throws: Never` rather
    /// than left as a bare `try`: measured first with a bare `try`, the same mutation reported
    /// only `Caught error: .systemSleeping` against the `@Test` line, naming neither the fan nor
    /// the moment — and skipped the epilogue, leaving two parked deliveries behind the test.
    ///
    /// **Mutation D — the second cycle removed**, applied to this test rather than to the
    /// helper: delete the second `.willSleep`/`.didWake` pair. Run: red on the fault-line count
    /// (`1 == 2`) and **on nothing else** — every register and refusal assertion stays green,
    /// because a register that survived one wake survives the read after it either way. So that
    /// count is the only thing standing between this and a single-cycle test wearing a
    /// multi-cycle name, which is the defect the sibling suite was written to fix. Recorded
    /// here because an assertion whose whole job is structural is the easiest one for a later
    /// edit to drop as noise.
    @Test("A handback that never returns is still refused after a second wake")
    func aHandbackThatNeverReturnsIsStillRefusedAfterASecondWake() async throws {
        let plane = CycleWedgingRestorePlane(SystemPowerTests.machine(fanCount: 2))
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = SystemPowerTests.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), fanCount: 2,
            safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1, "fan 0's lease was not granted")

        // Armed once. Nothing in this test releases it until the epilogue, so both cycles'
        // restores park on this same wedge.
        await plane.wedgeTheNextRestore()

        let firstSleep = try await Self.sleepWithoutReleasing(observer)
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks == [0],
            """
            the first budget expiry did not record fan 0, so there is nothing for the rest of \
            this test to watch survive. Every assertion below would then be green for the \
            reason this suite exists to reject.
            """)

        try await observer.deliver(.didWake)
        await Self.expectStillRefused(helper.leases, after: "the first wake")

        let secondSleep = try await Self.sleepWithoutReleasing(observer)
        try await observer.deliver(.didWake)
        await Self.expectStillRefused(helper.leases, after: "the second wake")

        #expect(
            log.faults.count { $0.contains("handback still outstanding") } == 2,
            """
            two sleeps on one parked restore wrote \
            \(log.faults.count { $0.contains("handback still outstanding") }) fault lines. The \
            second sleep is what makes the wake assertions above a claim about survival rather \
            than about one window, so a second expiry that never happened is a green test \
            asserting nothing new.
            """)

        await Self.expectTheLateRestoreStillClearsIt(
            helper, plane, deliveries: [firstSleep, secondSleep])
    }

    /// The register after a wake, read with the seal lifted — the one instant #209 is about.
    ///
    /// Three claims, and they are separate on purpose. The refusal is what a client is told;
    /// the register is the state behind it, so a gate deleted from `acquireLease` and a register
    /// that was never written are different findings. The durable register being empty is
    /// decision D33: nothing on this path observed a refused write, only that a budget elapsed,
    /// however many times it elapsed.
    private static func expectStillRefused(
        _ leases: LeaseAuthority, after moment: String
    ) async {
        let refusal = await #expect(throws: AeolusXPCFault.self) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(
            refusal == .manualControlUnavailable(reason: .handbackUnconfirmed),
            """
            after \(moment), fan 0 came back \(String(describing: refusal)). Its restore has \
            still not returned, so nothing has confirmed what mode it is in, and the lid being \
            opened is not evidence about a write. A lease granted here is CLAUDE.md rule 6 — \
            claiming control of a fan nothing is honouring — and `.systemSleeping` here would \
            mean the seal, not the register, had been answering all along.
            """)
        #expect(
            await leases.fansWithUnconfirmedHandbacks == [0],
            "after \(moment), the register behind that refusal no longer names fan 0 alone")
        #expect(
            await leases.fansWithAbandonedHandbacks.isEmpty,
            """
            after \(moment), a budget expiry had been recorded as a firmware refusal. Two \
            expiries are still evidence about time and not about the firmware: this machine's \
            only fault is that a restore has not come back, and the durable register is the one \
            no wake and no client action clears.
            """)
    }

    /// Fan 1 is grantable, then the parked restore finally lands and clears the register — two
    /// wakes and two sleeps after it was written.
    ///
    /// Fan 1 first, because it is the separator: with the seal lifted twice and fan 0 still
    /// refused, a grant on fan 1 is what says the refusal belongs to the fan rather than to a
    /// seal that never reopened. Then the wedge lets go, which is D33's first ending arriving
    /// very late — and it still clears, so a slow machine has not lost a fan for the life of
    /// the process.
    private static func expectTheLateRestoreStillClearsIt(
        _ helper: HelperComposition<CycleWedgingRestorePlane>,
        _ plane: CycleWedgingRestorePlane,
        deliveries: [Task<Void, Never>]
    ) async {
        // `throws: Never` rather than a bare `try`, for the reason the sibling suite records:
        // a refusal here is the finding, and an error escaping the test function arrives
        // unattributed — no fan, no moment, and the epilogue below never runs, so the two
        // parked deliveries are left suspended behind the test. Measured: under a
        // once-per-helper `unsealAfterWake()` a bare `try` reported only
        // `Caught error: .systemSleeping` against the @Test line.
        await #expect(
            throws: Never.self,
            """
            fan 1 could not be leased after two wakes. Its handback was never issued and it was \
            never leased, so the only thing left to refuse it is a seal that stopped reopening — \
            which would mean the seal, not the register, is what refused fan 0 above.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [1]), from: ConnectionID())
        }
        #expect(
            await helper.leases.leaseCount == 1,
            "fan 1's lease was not granted after two wakes")

        // One release frees both cycles' parked restores: the wedge was armed once, so both are
        // waiting on the same signal. Nothing is left parked behind the test.
        await plane.release()
        for delivery in deliveries {
            await delivery.value
        }
        #expect(
            await helper.leases.fansWithUnconfirmedHandbacks.isEmpty,
            """
            the restore landed two sleeps after the budget gave up on it and the fan is still \
            refused. Nothing else clears the register, so the fan is lost for the life of the \
            process — the D17 failure decision D33 replaced, reached the long way round.
            """)
    }

    /// One `.willSleep` whose handback is parked forever: delivered on a task of its own,
    /// awaited only as far as the acknowledgement.
    ///
    /// - Returns: the delivery task, so the caller can release the wedge and drain it rather
    ///   than leaving a suspended responder behind the test.
    ///
    /// The acknowledgement signal is bound to *this* notification. `observer.didAcknowledge`
    /// latches, so a second call awaiting it would return on the first cycle's signal and every
    /// assertion after it would read a cycle that had not happened yet — green, and about the
    /// wrong sleep.
    private static func sleepWithoutReleasing(
        _ observer: ScriptedPowerObserver
    ) async throws -> Task<Void, Never> {
        let acknowledged = AsyncSignal()
        let delivery = try observer.deliverWithoutWaiting(.willSleep, acknowledged: acknowledged)
        try await acknowledged.wait()
        return delivery
    }
}
