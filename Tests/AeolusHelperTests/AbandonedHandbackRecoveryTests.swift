import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#189](https://github.com/blamechris/Aeolus/issues/189): a fan the firmware refused to take
/// back, and later **did** take back, stops being refused.
///
/// ## What the issue described, and what was actually there
///
/// #189 named `LeaseAuthority.restoreAbandoned` as append-only and `docs/SAFETY.md` § 7's panic
/// pass as the first path that would need a clearing rule — *"if a previously-abandoned fan's
/// mode write is accepted on that pass, the helper has confirmation the fan went back"*. The
/// pass could not accept such a write, because it never issued one: `releaseEveryLease()`
/// restored the fans of dropped table entries, an entry exists only because `acquireLease`
/// granted one, and `acquireLease` refuses every fan in `restoreAbandoned`. The register sealed
/// off the only route to its own exit, so the clear had nothing to be driven by and the fan was
/// unrecoverable short of restarting the helper — which is #189's user-visible symptom, reached
/// through a tighter hole than it recorded.
///
/// So the fix is two halves, and each is red on its own: the panic pass sweeps the register
/// beside the table, and a restore the restorer does not name as abandoned clears it.
///
/// ## The standard for "the firmware took it"
///
/// `fans.subtracting(abandoned)` — the restorer was asked, came back, and did not name the fan.
/// That is not a weaker signal invented to make the clear easy; it is the signal
/// `HelperFanRestorer` already deregisters § 3's registry on, in the one place where
/// *forgetting* a still-manual fan is the unsafe direction. `FanRestoring` promises a return
/// and explicitly not a read-back, and `aRefusedPanicPassLeavesTheRefusalStanding` is what
/// keeps the clear from degenerating into the genuinely weaker one — "the panic pass ran".
///
/// **Since [#291](https://github.com/blamechris/Aeolus/issues/291) that signal is necessary but
/// not sufficient**: a fresh read through `ForeignManualControlSensing` must also report the fan
/// automatic, and `anAcceptedWriteThatDoesNotReadBackKeepsTheRefusal` holds that half.
///
/// Every fan reaches the register the way `Sources/` reaches it: a lease, released, with
/// `BoundedFanRestorer` spending the real `RestoreLimits.attemptBudget` against a firmware that
/// refuses. A `FanRestoring` double returning a fabricated abandoned set would put the register
/// into a state this build cannot produce.
@Suite("A confirmed handback clears the durable refusal", .timeLimit(.minutes(1)))
struct AbandonedHandbackRecoveryTests {

    /// A lease over `leasing`, released against a firmware that refuses `refusing` — which is
    /// the only route `Sources/` has into `restoreAbandoned`.
    ///
    /// The setup asserts the state it claims to have reached. Without that, a change that
    /// stopped recording the register at all would leave every test below green on an empty set.
    private static func abandoned(
        leasing: [Int], refusing: Set<Int>,
        foreignControl: any ForeignManualControlSensing = LeaseFixture.automaticFans()
    ) async throws -> (leases: LeaseAuthority, firmware: RecoverableRefusal) {
        let firmware = RecoverableRefusal(refusing: refusing)
        let leases = LeaseFixture.authority(
            restorer: BoundedFanRestorer(attempting: firmware, log: LeaseFixture.log),
            foreignControl: foreignControl)
        let connection = ConnectionID()

        let lease = try await leases.acquireLease(
            LeaseFixture.request(fans: leasing), from: connection)
        try await leases.releaseLease(id: lease.id, from: connection)

        #expect(await firmware.breachedCeiling == false)
        #expect(
            await leases.fansWithAbandonedHandbacks == refusing,
            """
            the setup did not reach the state every test in this suite is about: fan(s) \
            \(refusing) were refused every attempt and the durable register does not hold them.
            """)
        return (leases, firmware)
    }

    /// The durable refusal, asked for as a client would meet it.
    private static func expectRefused(_ leases: LeaseAuthority, fan: Int) async {
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [fan]), from: ConnectionID())
        }
    }

    // MARK: - The clear

    /// #189's acceptance, end to end: abandoned, restored on § 7's pass, granted.
    ///
    /// The attempt count is asserted because the grant alone cannot tell the two halves apart.
    /// A clear that fired without the pass having asked the firmware anything would satisfy the
    /// grant and leave the count at the budget; four attempts is the pass having reached the
    /// fan, which is the half `releaseEveryLease()`'s sweep provides.
    ///
    /// `releaseEveryLease()` is called directly rather than through
    /// `SupervisedFanAuthority.restoreAllToAutomatic`, whose body is that call and a log line —
    /// `PanicPathScopeTripwireTests` is what holds it to that, and `LeaseTeardownTests` drives
    /// the same verb the same way.
    ///
    /// **Mutation:** delete `restoreAbandoned.subtract(recovered)` from
    /// `LeaseAuthority.restore`. Run: red — the fan is still refused after a handback the
    /// firmware took.
    /// **Mutation:** restore `releaseEveryLease()`'s old seed, `reduce(into: Set<Int>())`
    /// rather than `reduce(into: restoreAbandoned)`. Run: red on the attempt count and on the
    /// grant — the pass never names fan 0, which is the state the issue was filed against.
    @Test("A fan abandoned, then handed back on § 7's pass, is leasable again")
    func aConfirmedRestoreOnThePanicPassMakesTheFanLeasableAgain() async throws {
        let (leases, firmware) = try await Self.abandoned(leasing: [0], refusing: [0])
        await Self.expectRefused(leases, fan: 0)

        // The firmware comes good. Nothing informs the lease core; § 7's pass asks it again,
        // which is the only way this process can find out.
        await firmware.takesTheWrite(for: [0])
        await leases.releaseEveryLease()

        let attempts = await firmware.attemptCount(forFan: 0)
        #expect(
            attempts == RestoreLimits.attemptBudget + 1,
            """
            the panic pass made \(attempts) attempts on fan 0, not the budget's \
            \(RestoreLimits.attemptBudget) plus one. A pass that does not reach an abandoned \
            fan cannot confirm anything about it, and a clear that fires anyway is lifting the \
            refusal on evidence about a call.
            """)
        #expect(
            await leases.fansWithAbandonedHandbacks.isEmpty,
            """
            the firmware took the write and the durable refusal is still standing. Nothing \
            else will ever lift it, so the fan is unusable for the life of the helper process \
            with docs/RECOVERY.md as the only route out — #189 exactly.
            """)
        #expect(await leases.fansMidHandback.isEmpty, "the sweep's restore has not completed")

        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await leases.leaseCount == 1)
        #expect(await firmware.breachedCeiling == false)
    }

    /// [#291](https://github.com/blamechris/Aeolus/issues/291): the write going through is not
    /// the fan going back. The firmware takes the panic pass's write this time, and the fan
    /// still reads manual — so the refusal it already carried stands.
    ///
    /// The fresh read comes from the real `StartupReconciliation` over scripted firmware, set
    /// to manual only *after* the lease was granted and abandoned: set earlier, the grant-time
    /// read would have refused the setup's own lease.
    ///
    /// **Mutation:** in `LeaseAuthority.restore`, replace
    /// `await foreignControl.fansReadingAutomatic(among: candidates)` with `candidates`.
    /// Run: red — the register is empty and the fan is granted over a mode nothing confirmed.
    @Test("A fan the firmware takes the write for but still reads manual stays refused")
    func anAcceptedWriteThatDoesNotReadBackKeepsTheRefusal() async throws {
        let modes = ScriptedControlPlane(
            fans: [0: ScriptedControlPlane.FanCondition()],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let (leases, firmware) = try await Self.abandoned(
            leasing: [0], refusing: [0],
            foreignControl: LeaseFixture.reconciliation(
                over: modes, enumeration: ScriptedFanEnumeration(indices: [0])))

        await modes.setMode(.manual, ofFan: 0)
        await firmware.takesTheWrite(for: [0])
        await leases.releaseEveryLease()

        #expect(
            await firmware.attemptCount(forFan: 0) == RestoreLimits.attemptBudget + 1,
            "the panic pass did not reach fan 0, so this test cannot say anything about the clear")
        #expect(
            await leases.fansWithAbandonedHandbacks == [0],
            """
            the firmware accepted the write and fan 0 still reads manual, and the durable \
            refusal was lifted anyway — on a write that did not throw, which is not a fan in \
            automatic (#291).
            """)
        await Self.expectRefused(leases, fan: 0)
    }

    /// The half that keeps the clear honest: a pass the firmware refuses again changes nothing.
    ///
    /// This is #189's *"decide whether a non-throwing write is enough"* answered in the
    /// direction it warns about — clearing a durable refusal on a weaker signal than the one
    /// that set it. The weaker signal available here is "the panic pass ran", and the attempt
    /// count proves the pass genuinely ran and genuinely asked: twice the budget, six writes,
    /// all refused.
    ///
    /// **Mutation:** in `LeaseAuthority.restore`, make the signal the sweep rather than the
    /// report — `cause == .allLeasesDropped ? restoreAbandoned.intersection(fans) : …`. Run:
    /// red here and in `onlyTheFanTheFirmwareTookBackIsCleared`, while both the acceptance test
    /// and the handback-window test stay green, which is what makes this one discriminate
    /// rather than echo them.
    ///
    /// **The two simpler mutants do not show that, and both were run.** Subtracting `fans`
    /// instead of `recovered` is shielded by the `guard !recovered.isEmpty` above it — with the
    /// fan refused again nothing recovered, so the guard returns before the mutated line — and
    /// an unconditional `intersection(fans)` kills the setup helper in all four tests, because
    /// the release that abandons the fan also names it. A mutant that reddens everything
    /// demonstrates nothing about which assertion carries which property.
    @Test("A panic pass the firmware refuses again leaves the refusal standing")
    func aRefusedPanicPassLeavesTheRefusalStanding() async throws {
        let (leases, firmware) = try await Self.abandoned(leasing: [0], refusing: [0])

        await leases.releaseEveryLease()

        #expect(
            await firmware.attemptCount(forFan: 0) == RestoreLimits.attemptBudget * 2,
            "the pass did not spend a second budget on fan 0, so it asked the firmware nothing")
        #expect(
            await leases.fansWithAbandonedHandbacks == [0],
            """
            six refused mode writes and the fan is leasable again. A client would be granted \
            control of a fan whose mode nothing has confirmed — CLAUDE.md rule 6, reached by \
            treating a call that returned as a write that landed.
            """)
        await Self.expectRefused(leases, fan: 0)
        #expect(await firmware.breachedCeiling == false)
    }

    /// The clear is per fan, exactly as the refusal is. Without this, "cleared" could be a
    /// blanket reset of the register the first time any fan in a sweep came back.
    ///
    /// **Mutation:** `restoreAbandoned.removeAll()` in place of
    /// `restoreAbandoned.subtract(recovered)`. Run: red **here only** — every other test in the
    /// suite abandons a single fan, so a blanket reset and a per-fan clear are the same act to
    /// them.
    @Test("Only the fan the firmware took back is cleared")
    func onlyTheFanTheFirmwareTookBackIsCleared() async throws {
        let (leases, firmware) = try await Self.abandoned(leasing: [0, 1], refusing: [0, 1])

        await firmware.takesTheWrite(for: [0])
        await leases.releaseEveryLease()

        #expect(await leases.fansWithAbandonedHandbacks == [1])
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await leases.leaseCount == 1)
        // Refused ahead of the live lease over fan 0, by the durable-first ordering
        // `acquireLease`'s straight-line region documents.
        await Self.expectRefused(leases, fan: 1)
        #expect(await firmware.breachedCeiling == false)
    }

    // MARK: - The handback window over a sweep with two sources

    /// [#188](https://github.com/blamechris/Aeolus/issues/188), reached without concurrent
    /// leases.
    ///
    /// #188's acceptance criteria assumed its hazard needed two table entries and therefore
    /// could not be tested until the single-lease guard was relaxed. § 7's sweep now has two
    /// *sources* — the table and the durable register — which reaches the same window: with a
    /// restore awaited per source, the fans of the source not yet in flight sit outside
    /// `releasing` for the whole duration of the other's restore. In the order that reads most
    /// naturally, the register first, fan 1's lease has been dropped and its handback has not
    /// been issued, so a client can take it and command a fan whose restore is about to land on
    /// top of the value it writes.
    ///
    /// Both assertions are needed and neither implies the other. The refusal catches the
    /// register-first shape; `fansMidHandback` catches the table-first shape, where fan 1 is
    /// covered and fan 0 is not, and is the direct expression of #188's own remedy — *"register
    /// every entry's fans in `releasing` before the first restore is awaited"*.
    ///
    /// **Mutation:** split `releaseEveryLease()` into `await restore(restoreAbandoned, …)`
    /// followed by a per-entry loop. Run: red on both — `fansMidHandback` is `[0]`, and fan 1 is
    /// granted.
    /// **Mutation:** the other order, the per-entry loop first and the register after it. Run:
    /// red on `fansMidHandback`, which is `[1]`; the refusal stays green, which is why it is not
    /// the only assertion.
    @Test("Every fan in § 7's sweep is inside the handback window before the first restore")
    func everyFanInThePanicSweepIsInsideTheHandbackWindow() async throws {
        let (leases, firmware) = try await Self.abandoned(leasing: [0], refusing: [0])

        // The sweep's second source: a live lease, over a fan the register does not hold.
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [1]), from: ConnectionID())

        let entered = AsyncSignal()
        let release = AsyncSignal()
        await firmware.takesTheWrite(for: [0])
        await firmware.park(signalling: entered, until: release)

        let sweep = Task { await leases.releaseEveryLease() }
        try await entered.wait()

        let midHandback = await leases.fansMidHandback
        #expect(
            midHandback == [0, 1],
            """
            mid-sweep, the handback window covers \(midHandback.sorted()) rather than both fans \
            the sweep named. A fan outside it while another fan's restore is on the wire is the \
            window `.releaseInProgress` exists to close, reopened for every source but the first.
            """)
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress),
            """
            a lease was granted over fan 1 while § 7's sweep had its handback outstanding. The \
            holder's next write and the landing restore would both be commanding the same \
            firmware, and the restore wins last.
            """
        ) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [1]), from: ConnectionID())
        }

        await release.signal()
        await sweep.value

        #expect(await leases.fansWithAbandonedHandbacks.isEmpty)
        #expect(await leases.fansMidHandback.isEmpty)
        #expect(await firmware.breachedCeiling == false)
    }
}
