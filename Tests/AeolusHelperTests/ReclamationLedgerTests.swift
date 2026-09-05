import Testing

@testable import AeolusHelper

/// The ledger's own semantics, tested where they are stated rather than only where they are
/// used.
///
/// ## This file exists because it did not
///
/// #140 turned `ReclamationLedger` from a `Set<Int>` into a `[Int: Cause]`, and the two
/// rules that conversion introduced — *last diagnosis wins* and *clearing removes either
/// cause* — were documented on the type and asserted nowhere. Every test that touched them
/// went through `ReclamationWatchdog`, which reaches only one cause per scenario, so
/// collapsing `isSupervisorBlind(fanAt:)` to "any cause is recorded" or narrowing
/// `clearReclaimed(fanAt:)` to the reclaimed entries left the suite green. A rule whose
/// deletion nothing notices is documentation, not a rule.
///
/// The distinction these pin is `CLAUDE.md` rule 6's: `reclaimedFans` becomes
/// `FanState.isReclaimedBySystem`, which the UI renders verbatim as "Reclaimed by system",
/// so a blind fan leaking into it claims a loss of control nothing established.
@Suite("ReclamationLedger's two causes")
struct ReclamationLedgerTests {

    /// A reclaimed fan is reclaimed and nothing else.
    ///
    /// Widen `isSupervisorBlind(fanAt:)` to `causes[index] != nil` and this goes red — the
    /// mutation that survived every watchdog test, because no watchdog scenario asks a
    /// reclaimed fan whether it is blind.
    @Test("A fan the system took is not also reported as blind")
    func aReclaimedFanIsNotBlind() async {
        let ledger = ReclamationLedger()

        await ledger.markReclaimed(fanAt: 0)

        #expect(await ledger.isReclaimed(fanAt: 0))
        #expect(
            await ledger.isSupervisorBlind(fanAt: 0) == false,
            "a fan the system took was reported as one the helper cannot see")
        #expect(await ledger.reclaimedFans == [0])
        #expect(await ledger.supervisorBlindFans.isEmpty)
    }

    /// And the mirror, which is the one the user sees: widen `isReclaimed(fanAt:)` — or
    /// `reclaimedFans` — to any cause and `isReclaimedBySystem` tells a user with a dead SMC
    /// connection that macOS took the fan.
    @Test("A fan the helper went blind on is not reported as reclaimed")
    func aBlindFanIsNotReclaimed() async {
        let ledger = ReclamationLedger()

        await ledger.markSupervisorBlind(fanAt: 0)

        #expect(await ledger.isSupervisorBlind(fanAt: 0))
        #expect(
            await ledger.isReclaimed(fanAt: 0) == false,
            "blindness was recorded as the operating system taking the fan")
        #expect(await ledger.supervisorBlindFans == [0])
        #expect(await ledger.reclaimedFans.isEmpty)
    }

    /// Both sets are per fan, and neither spills onto the other's.
    @Test("The two causes partition the ledger per fan")
    func theCausesPartitionPerFan() async {
        let ledger = ReclamationLedger()

        await ledger.markReclaimed(fanAt: 0)
        await ledger.markSupervisorBlind(fanAt: 1)

        #expect(await ledger.reclaimedFans == [0])
        #expect(await ledger.supervisorBlindFans == [1])
        #expect(await ledger.causes == [0: .systemReclaimed, 1: .supervisorBlind])
    }

    /// **Last diagnosis wins**, and the change is a transition worth logging.
    ///
    /// Reachable in production: a fan is marked reclaimed, a re-assert lands, and later
    /// reads go unreadable. The entry must describe what § 5 most recently concluded,
    /// because the terminal action taken in the same breath revokes the lease under that
    /// same cause — a ledger disagreeing with the revocation the user was just shown would
    /// be two reports of one event.
    ///
    /// Make `record(_:fanAt:)` return `previous == nil` and the transition assertion goes
    /// red; make it refuse to overwrite an existing entry and the cause assertions do.
    @Test("Blindness landing on a reclaimed fan replaces the diagnosis")
    func blindnessOverwritesAReclamation() async {
        let ledger = ReclamationLedger()
        await ledger.markReclaimed(fanAt: 0)

        let changed = await ledger.markSupervisorBlind(fanAt: 0)

        #expect(changed, "the change of diagnosis was not reported as a transition")
        #expect(await ledger.isSupervisorBlind(fanAt: 0))
        #expect(
            await ledger.isReclaimed(fanAt: 0) == false,
            "the superseded reclamation still answers for the fan")
        #expect(await ledger.causes == [0: .supervisorBlind])
    }

    /// The same rule in the other direction: a reconnect that restores sight, followed by a
    /// genuine reclamation, must stop reporting blindness.
    @Test("A reclamation landing on a blind fan replaces the diagnosis")
    func aReclamationOverwritesBlindness() async {
        let ledger = ReclamationLedger()
        await ledger.markSupervisorBlind(fanAt: 0)

        let changed = await ledger.markReclaimed(fanAt: 0)

        #expect(changed, "the change of diagnosis was not reported as a transition")
        #expect(await ledger.isReclaimed(fanAt: 0))
        #expect(await ledger.isSupervisorBlind(fanAt: 0) == false)
        #expect(await ledger.causes == [0: .systemReclaimed])
    }

    /// #124's forward constraint: log the transition, not the state.
    ///
    /// The watchdog polls at 1 Hz and re-records the same conclusion on every tick, so a
    /// mutator that returned `true` unconditionally would put a line per second in front of
    /// the reader. Make `record(_:fanAt:)` return `true` always and both halves go red.
    @Test("Re-recording the same cause is not a transition")
    func repeatingACauseIsNotATransition() async {
        let ledger = ReclamationLedger()

        #expect(await ledger.markReclaimed(fanAt: 0))
        #expect(await ledger.markReclaimed(fanAt: 0) == false)
        #expect(await ledger.markSupervisorBlind(fanAt: 1))
        #expect(await ledger.markSupervisorBlind(fanAt: 1) == false)
    }

    /// **Clearing removes either cause.** A fan Aeolus has back, or has stopped asking for,
    /// is neither reclaimed nor one this mechanism is blind on.
    ///
    /// Narrow `clearReclaimed(fanAt:)` to the `.systemReclaimed` entries — the shape the
    /// pre-#140 `Set<Int>` had — and the blind half goes red, leaving a fan reported as
    /// blind forever after § 5 has re-asserted it or released it on purpose.
    @Test("Clearing removes a blind entry as well as a reclaimed one")
    func clearingRemovesEitherCause() async {
        let ledger = ReclamationLedger()
        await ledger.markReclaimed(fanAt: 0)
        await ledger.markSupervisorBlind(fanAt: 1)

        #expect(await ledger.clearReclaimed(fanAt: 0))
        #expect(
            await ledger.clearReclaimed(fanAt: 1),
            "a fan given up for blindness could not be cleared")

        #expect(await ledger.causes.isEmpty)
        #expect(await ledger.reclaimedFans.isEmpty)
        #expect(await ledger.supervisorBlindFans.isEmpty)
    }

    /// Clearing a fan nothing was recorded about is not a transition either — the watchdog
    /// clears on every successful cycle, and each one would otherwise announce a recovery
    /// from nothing.
    @Test("Clearing a fan the ledger never recorded reports no transition")
    func clearingAnUnrecordedFanIsNotATransition() async {
        let ledger = ReclamationLedger()

        #expect(await ledger.clearReclaimed(fanAt: 0) == false)
    }
}
