/// Which fans § 5 has given up on and why, shared by the mechanism that decides it and the
/// snapshot that reports it.
///
/// ## Why it is its own type
///
/// `ThermalEmergencyLatch`'s reasoning, one cardinality up. Two things need this fact and
/// they must not need each other: `ReclamationWatchdog` sets it, and the authority
/// assembling a `SystemSnapshot` reports it to the user as `FanState.isReclaimedBySystem`.
/// Giving the snapshot assembler a reference to the watchdog would put a safety mechanism's
/// whole cycle behind every 1 Hz snapshot, and would make a cycle out of what is one fact
/// per fan.
///
/// It is an actor for the latch's reason, and `CLAUDE.md` rule 10's: a root daemon driving
/// cooling hardware does not get to have a data race on the bit that says a fan is no
/// longer ours.
///
/// ## Per fan, and with a cause — not a `Bool`
///
/// § 3's latch is machine-wide because a package temperature is not attributable to a fan.
/// Reclamation is the opposite: the OS takes back *a fan*, and `FanState` already carries
/// the flag per fan, so collapsing this to one boolean would report a two-fan machine's
/// reclaimed fan 1 as a reclaimed fan 0 as well. That is `CLAUDE.md` rule 6 in the
/// direction people forget — claiming to have *lost* control that is in fact still held is
/// still a false report, and it is the one that makes a user stop trusting the display.
///
/// A bare `Set<Int>` was one collapse short of that same rule, in the other axis: § 5 gives
/// a fan up either because the system took it or because the helper went blind on it, and
/// membership alone could not tell a reader which. See `Cause`.
///
/// ## Why the mutators report whether they changed anything
///
/// The watchdog polls on a cycle, so a fan that is reclaimed is reclaimed again on every
/// tick, and one that is not is cleared again on every tick. A caller that logged
/// unconditionally would emit at its polling rate — #124's forward constraint, which
/// `ThermalEmergencyLatch` states in full: *log the transition, not the state*. These
/// return whether a transition happened rather than leaving each caller to remember the
/// previous value.
actor ReclamationLedger {

    /// Why a fan is no longer Aeolus's to command.
    ///
    /// **The two are not one bit**, which is #140: § 5 reaches its terminal action down two
    /// paths that are diagnosed completely differently, and both used to set the same
    /// `Set<Int>` membership. `FanRestoreCause` already keeps them apart on the lease side
    /// — *"a reclamation is a working helper losing a contest with the OS; this is a helper
    /// that has gone blind"* — and then the one field the user actually reads,
    /// `FanState.isReclaimedBySystem`, collapsed them again.
    ///
    /// That collapse is `CLAUDE.md` rule 6 in the direction this type's own documentation
    /// calls out. A blind cycle has learned nothing about who holds the fan; it has learned
    /// that the helper cannot read. Reporting it as a system reclamation sends a user to
    /// look at macOS's thermal behaviour instead of at Aeolus's dead SMC connection — which
    /// [#68](https://github.com/blamechris/Aeolus/issues/68), the stale `io_connect_t` after
    /// wake, is precisely the case for.
    enum Cause: Sendable, Hashable {

        /// The system took this fan back: § 5's primary signal fired, the helper could read
        /// throughout, and what it read was a fan the firmware is no longer holding for us.
        /// This is the cause `FanState.isReclaimedBySystem` reports, and the only one.
        case systemReclaimed

        /// The helper could not read this fan for
        /// `ReclamationLimits.blindCyclesBeforeDivergence` consecutive cycles, a reconnect
        /// was attempted, and the fan went back to automatic control anyway. ADR 0007's
        /// hole 2. Nothing here is a statement about the operating system.
        case supervisorBlind
    }

    /// Every fan § 5 has given up on, and why.
    ///
    /// Empty is the ordinary state, and it is also the state of every build that cannot
    /// write: no fan is ever taken off automatic control, so none can be taken back and
    /// none can be watched blindly.
    private(set) var causes: [Int: Cause] = [:]

    /// The fans currently believed to be back under the system's own thermal management
    /// despite Aeolus having asked otherwise.
    ///
    /// **Blind fans are deliberately absent.** This is what becomes
    /// `FanState.isReclaimedBySystem`, so a fan in here is a fan the user is told the
    /// system took.
    var reclaimedFans: Set<Int> { fans(causedBy: .systemReclaimed) }

    /// The fans § 5 released because it had gone blind on them.
    var supervisorBlindFans: Set<Int> { fans(causedBy: .supervisorBlind) }

    /// Whether the system has taken this fan back. Blindness is not this.
    func isReclaimed(fanAt index: Int) -> Bool { causes[index] == .systemReclaimed }

    /// Whether this fan was released because the helper could not see it.
    func isSupervisorBlind(fanAt index: Int) -> Bool { causes[index] == .supervisorBlind }

    /// Records that the system has taken this fan back.
    ///
    /// - Returns: `true` when this call recorded a fan that was not already reclaimed — the
    ///   transition worth logging. `false` when it was already recorded.
    @discardableResult
    func markReclaimed(fanAt index: Int) -> Bool {
        record(.systemReclaimed, fanAt: index)
    }

    /// Records that the helper has gone blind on this fan and given it up.
    ///
    /// - Returns: `true` when this call changed what the ledger says about the fan.
    @discardableResult
    func markSupervisorBlind(fanAt index: Int) -> Bool {
        record(.supervisorBlind, fanAt: index)
    }

    /// **Last diagnosis wins**, including over an entry recorded with the other cause.
    ///
    /// A fan can be marked reclaimed, re-asserted successfully, and then go unreadable, so
    /// blindness genuinely can arrive on top of a reclamation. The entry describes what the
    /// mechanism most recently concluded, and the terminal action taken in the same breath
    /// revokes the lease under that same cause — a ledger disagreeing with the revocation
    /// the user was just shown would be two reports of one event.
    ///
    /// Not a way around `clearReclaimed(fanAt:)`'s rule: nothing here clears anything, and
    /// a cycle that merely failed to read still records nothing until the blindness
    /// threshold is crossed.
    private func record(_ cause: Cause, fanAt index: Int) -> Bool {
        let previous = causes.updateValue(cause, forKey: index)
        return previous != cause
    }

    private func fans(causedBy cause: Cause) -> Set<Int> {
        Set(causes.filter { $0.value == cause }.keys)
    }

    /// Records that this fan is no longer § 5's problem — Aeolus has it back, or has
    /// stopped asking for it. Clears whichever cause was recorded, because a fan in either
    /// of those states is neither reclaimed nor one this mechanism is blind on.
    ///
    /// Called when a re-assert lands and when a fan is released to automatic control on
    /// purpose. **Not** called by a cycle that merely failed to read: a fan whose state
    /// cannot be seen is not a fan known to be fine, and clearing on an unreadable cycle
    /// would flip the user's display back to "in control" on exactly the machine that has
    /// stopped answering. That is `ThermalEmergency`'s failure asymmetry — a mechanism that
    /// cannot see never releases — applied to the reporting bit.
    ///
    /// - Returns: `true` when this call cleared a fan that was recorded.
    @discardableResult
    func clearReclaimed(fanAt index: Int) -> Bool {
        causes.removeValue(forKey: index) != nil
    }
}
