import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 5 in the window that opens when a fan is registered and closes when
/// the first target is commanded on it.
///
/// A fourth suite next to `ReclamationWatchdogTests`, `…RecoveryTests` and
/// `…StalenessTests`, split on subject the way those were: every test here drives a fan that
/// `ReclamationWatchdog.manualControlEngaged(_:)` knows about and `commandedTarget(_:)` does
/// not, which is a state with rules of its own rather than a corner of the signal suite.
///
/// **Why the window is a subject at all.** `manualControlEngaged(_:)` is called at the same
/// point as the `F<n>Md` write, and its doc comment mandates which side: after. That leaves
/// a real interval — E3 writes `F<n>Tg` next, and this mechanism runs on an independent
/// 1 Hz loop — in which a cycle examines a fan the firmware has only half agreed to hand
/// over. All three of `primaryDivergence(of:against:)`'s answers are reachable in it, they
/// behave differently, and only one of them was covered when the window was first documented
/// as safe.
///
/// The terminal action on the far side of these tests is not merely a fan restored, it is
/// `finaliseRelease(fanAt:because:)` revoking **every lease on the machine** and a `.fault`
/// line blaming the operating system. That is why the lease assertion, not the restore
/// assertion, is the point of each one.
@Suite("The reclamation watchdog's registration window")
struct ReclamationRegistrationWindowTests {

    /// **The registration contract, asserted from the side that is safe.**
    ///
    /// `manualControlEngaged(_:)` is called at the same point as the `F<n>Md` write, and its
    /// doc comment now says which side: after. This is the window that ordering leaves open
    /// — the fan is off automatic control and registered here, but no target has been
    /// commanded yet, because E3 writes `F<n>Tg` next. A supervisor cycle can land in it, and
    /// what it must do is nothing at all.
    ///
    /// The lease assertion is the point. `finaliseRelease(fanAt:because:)` does not revoke
    /// one lease, it revokes **every** lease on the machine, so a fan judged reclaimed inside
    /// this window costs a client the control it was granted milliseconds earlier — and the
    /// log blames the operating system for it. The *other* ordering produces exactly that,
    /// and `ReclamationWatchdogRecoveryTests.aFanWithNoCommandedTargetIsRestored` is that
    /// same registry entry read as `.automatic` instead.
    ///
    /// This is the `.targetDiverged` third of the window — the firmware answers manual with
    /// a readable target and only the commanded side is missing. It is the one third that
    /// needed no grace, and the one this file's original claim was true of;
    /// `anUnreadableTargetBeforeTheFirstCommandKeepsTheLease` below is one of the two it was
    /// not true of.
    ///
    /// Mutation-checked: making `primaryDivergence(of:against:)` treat an absent commanded
    /// target as divergence — `guard let commanded else { return nil }` becoming
    /// `guard let commanded else { return .modeReclaimed }` — turns all four assertions red.
    @Test("A fan registered before its first target keeps its lease through a cycle")
    func aFanRegisteredBeforeItsFirstTargetKeepsItsLease() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        let lease = try await machine.lease(fans: [0])
        try await machine.holdWithoutCommanding(fan: 0)

        await machine.watchdog.cycle()

        // Asserted first, because everything below it is an absence. Without this the test
        // cannot tell "examined and found converged" from "never looked at the fan at all",
        // and a tightened entry guard in `examine(fanAt:)` would pass it unnoticed.
        #expect(
            await machine.attempts.contains(.readControlState(fan: 0)),
            "the fan was never examined, so the assertions below prove nothing")
        #expect(
            await machine.leases.activeLease()?.id == lease.id,
            "registering a fan cost the client the lease it had just been granted")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.ledger.reclaimedFans.isEmpty)
    }

    /// **The half of the registration window `guard let commanded` never reached.**
    ///
    /// `primaryDivergence(of:against:)` answers `.targetUnreadable` before it looks at the
    /// commanded target at all, so on a fan registered after its `F<n>Md` write and awaiting
    /// its first `F<n>Tg` write, a single unreadable target read used to take the terminal
    /// action on the spot: ledger marked, fan restored, and **every lease on the machine**
    /// revoked — none of the tolerance `cycleCouldNotSee(fanAt:detail:)` grants a fan that
    /// could not be read at all. Reproduced on this fixture before the fix, with a `.fault`
    /// line telling an operator the system had taken a fan nothing had yet been commanded on.
    ///
    /// `targetRPM: .nan` is how the mock spells an unreadable `F<n>Tg`:
    /// `ScriptedControlPlane` applies `FanControlPlaneValue.finite(_:describing:)`, the same
    /// rule the real seam applies, so the readback arrives as `.unreadable` rather than as a
    /// fabricated number.
    ///
    /// Mutation-checked: deleting the `guard !gracedBeforeItsFirstCommand(…) else { return }`
    /// line from `examine(fanAt:)` turns the lease, restore, registry and ledger assertions
    /// red together.
    @Test("An unreadable target before the first command does not cost the client its lease")
    func anUnreadableTargetBeforeTheFirstCommandKeepsTheLease() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .manual, targetRPM: .nan)])
        let lease = try await machine.lease(fans: [0])
        try await machine.holdWithoutCommanding(fan: 0)

        await machine.watchdog.cycle()

        #expect(
            await machine.leases.activeLease()?.id == lease.id,
            "one unreadable target read cost the client every lease on the machine")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.ledger.reclaimedFans.isEmpty)
        #expect(
            machine.safetyLog.lines(containing: "no target commanded on it yet").count == 1,
            "the grace was silent, so an operator sees a fan go quiet with no reason given")
    }

    /// The grace is a budget, not an amnesty.
    ///
    /// A fan whose firmware never agrees it is Aeolus's has to *end up* on automatic control
    /// with the user told, exactly as the re-assert budget and the blindness threshold do.
    /// Driven `1...N` with the expectation derived per cycle, so the assertion is non-vacuous
    /// at every value of the constant — including 1, where it says the first divergent cycle
    /// acts. Deleting `gracedBeforeItsFirstCommand`'s
    /// `guard cycles < ReclamationLimits.blindCyclesBeforeDivergence` makes the grace
    /// unbounded, and the final cycle's restore never happens.
    ///
    /// The *upward* direction is
    /// `ReclamationLimitsTests.theBlindCycleThresholdIsBoundedAbove`, which is what stops
    /// this window being widened into minutes by tuning the constant this loop derives its
    /// own bound from.
    ///
    /// One log line for the whole grace, not one per cycle: #124's constraint on a 1 Hz
    /// supervisor, and the reason `gracedBeforeItsFirstCommand(_:of:fanAt:)` logs the
    /// transition rather than the state.
    @Test("The grace before the first command runs out, and the fan is handed back")
    func theGraceBeforeTheFirstCommandIsBounded() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .manual, targetRPM: .nan)])
        try await machine.lease(fans: [0])
        try await machine.holdWithoutCommanding(fan: 0)

        for cycle in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
            let expected = cycle == ReclamationLimits.blindCyclesBeforeDivergence
            #expect(
                await machine.didRestore(fan: 0) == expected,
                """
                after \(cycle) of \(ReclamationLimits.blindCyclesBeforeDivergence) graced \
                cycles the fan should \(expected ? "" : "not ")have been handed back
                """)
        }

        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.leases.activeLease() == nil)
        #expect(
            machine.safetyLog.lines(containing: "no target commanded on it yet").count == 1,
            "the grace logged once per cycle rather than once per episode")
    }
}
