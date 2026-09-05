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

    /// **The budget is spent, not reset — and a clean cycle in the middle does not refill
    /// it.**
    ///
    /// `examine(fanAt:)`'s converged branch resets the dwell and the re-assert attempts and
    /// deliberately leaves `uncommandedDivergentCycles` alone. Nothing asserted that: adding
    /// `held[index]?.uncommandedDivergentCycles = 0` beside those two left the whole suite
    /// green, so the property was true of the code and unclaimed by the tests.
    ///
    /// It matters because the fan it describes is a real one. A `F<n>Tg` that is merely
    /// flaky — readable one second, unreadable the next — would refill the grace on every
    /// readable cycle under that mutation, and the fan would stay off automatic control for
    /// as long as the flapping lasted with the terminal action never reached. That is the
    /// unbounded hold `theGraceBeforeTheFirstCommandIsBounded` rules out in the other
    /// direction.
    ///
    /// The expectation is derived per cycle from the number of *divergent* cycles seen so
    /// far, not from the cycle index, so it is non-vacuous at every value of
    /// `blindCyclesBeforeDivergence` — including 1, where the clean read arrives after the
    /// budget is already spent.
    ///
    /// Mutation-checked: adding that reset to the converged branch turns the final cycle's
    /// assertion red, and the registry and lease assertions with it.
    @Test("A converged cycle in the middle of the grace does not refill it")
    func aConvergedCycleDoesNotRefillTheGrace() async throws {
        let flaky = FanControlState(
            index: 0,
            mode: .manual,
            target: .unreadable(reason: "F0Tg: the read returned nothing"),
            actualRPM: .rpm(2_400))
        let clean = FanControlState(
            index: 0, mode: .manual, target: .rpm(2_400), actualRPM: .rpm(2_400))

        // One divergent cycle, one clean read, then divergent for the rest of the budget.
        // The clean read is in the middle on purpose: it is the cycle the mutation reaches.
        let readings =
            [flaky, clean]
            + Array(repeating: flaky, count: ReclamationLimits.blindCyclesBeforeDivergence - 1)

        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = ScriptedReadingsSensing(plane, reading: readings)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 2_400)], sensing: sensing)
        try await machine.lease(fans: [0])
        try await machine.holdWithoutCommanding(fan: 0)

        var divergentCycles = 0
        var examinedCycles = 0

        for reading in readings {
            // Counted only while the fan is still registered: once the terminal action has
            // run there is nothing left to examine, and the readings that follow are served
            // to nobody.
            if await !machine.watchdog.fansUnderManualControl.isEmpty {
                examinedCycles += 1
                if case .unreadable = reading.target { divergentCycles += 1 }
            }

            await machine.watchdog.cycle()

            #expect(
                await sensing.readCount == examinedCycles,
                "the fan was not examined this cycle, so the assertion below proves nothing")

            let expected = divergentCycles >= ReclamationLimits.blindCyclesBeforeDivergence
            #expect(
                await machine.didRestore(fan: 0) == expected,
                """
                after \(divergentCycles) divergent of \
                \(ReclamationLimits.blindCyclesBeforeDivergence) graced cycles the fan \
                should \(expected ? "" : "not ")have been handed back
                """)
        }

        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.leases.activeLease() == nil)
    }

    /// **Registering a fan that is already held does not refill its grace either.**
    ///
    /// `manualControlEngaged(_:)` built a fresh `HeldFan` unconditionally, so a second call
    /// on a fan already in the registry put `uncommandedDivergentCycles` back to zero. That
    /// makes the budget refillable by the caller it exists to bound: re-register on every
    /// other cycle and the fan is held off automatic control indefinitely, the terminal
    /// action never reached and the lease never revoked — measured at twenty registrations
    /// buying forty divergent cycles and no restore.
    ///
    /// Registration is idempotent now, so the cycle after the re-registration is the one
    /// that spends the last of the budget, exactly as it would have been without it.
    ///
    /// Mutation-checked: restoring the unconditional `held[fan.index] = HeldFan()` turns the
    /// restore, registry and lease assertions red together.
    @Test("Re-registering a held fan mid-grace does not refill the budget")
    func reRegisteringMidGraceDoesNotRefillIt() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .manual, targetRPM: .nan)])
        try await machine.lease(fans: [0])
        try await machine.holdWithoutCommanding(fan: 0)

        // Spend all but the last cycle of the grace.
        for _ in 1..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }
        #expect(
            await machine.didRestore(fan: 0) == false,
            "the grace ran out before the re-registration under test, which proves nothing")

        // The re-registration: E3 engaging manual control on a fan it already holds.
        try await machine.holdWithoutCommanding(fan: 0)
        await machine.watchdog.cycle()

        #expect(
            await machine.didRestore(fan: 0),
            "re-registering the fan refilled a budget that belongs to one registration")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.leases.activeLease() == nil)
    }

    /// **Registering a fan that is already held does not forget what was commanded on it.**
    ///
    /// The other half of the same unconditional `HeldFan()`. `primaryDivergence(of:against:)`
    /// reaches `.targetDiverged` only behind `guard let commanded`, so a re-registration that
    /// wiped `commanded` left a fan whose `F<n>Tg` disagrees with what Aeolus wrote reading
    /// as *converged* — the strongest signal § 5 has, silenced until the next
    /// `commandedTarget(_:)` arrives, on a fan that is pinned at a speed this mechanism has
    /// just forgotten it asked for. `CLAUDE.md` rule 6.
    ///
    /// The firmware here holds 2,400 while 3,000 was commanded, so the very next cycle must
    /// see the divergence and re-assert. Asserting the re-assert rather than reading
    /// `lastCommanded(ofFan:)` back is the point: what matters is that the signal still
    /// fires, not that a field survived.
    ///
    /// Mutation-checked: restoring the unconditional `held[fan.index] = HeldFan()` leaves the
    /// fan reading converged, so the stored command, the wire and the ledger all go red
    /// together — measured, three issues on this test and none on any other.
    @Test("Re-registering a held fan keeps what was commanded on it")
    func reRegisteringKeepsWhatWasCommanded() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 3_000)

        // The re-registration, with no release in between.
        try await machine.holdWithoutCommanding(fan: 0)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 3_000)

        await machine.watchdog.cycle()

        #expect(
            await machine.commandedRPMs == [3_000],
            "the divergence was invisible, so § 5 never re-asserted the commanded target")
        #expect(await machine.ledger.reclaimedFans == [0])
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }
}
