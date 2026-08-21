/// Which fans the system has taken back, shared by the mechanism that decides it and the
/// snapshot that reports it.
///
/// ## Why it is its own type
///
/// `ThermalEmergencyLatch`'s reasoning, one cardinality up. Two things need this fact and
/// they must not need each other: `ReclamationWatchdog` sets it, and the authority
/// assembling a `SystemSnapshot` reports it to the user as `FanState.isReclaimedBySystem`.
/// Giving the snapshot assembler a reference to the watchdog would put a safety mechanism's
/// whole cycle behind every 1 Hz snapshot, and would make a cycle out of what is one bit
/// per fan.
///
/// It is an actor for the latch's reason, and `CLAUDE.md` rule 10's: a root daemon driving
/// cooling hardware does not get to have a data race on the bit that says a fan is no
/// longer ours.
///
/// ## A set of indices, not a `Bool`
///
/// § 3's latch is machine-wide because a package temperature is not attributable to a fan.
/// Reclamation is the opposite: the OS takes back *a fan*, and `FanState` already carries
/// the flag per fan, so collapsing this to one boolean would report a two-fan machine's
/// reclaimed fan 1 as a reclaimed fan 0 as well. That is `CLAUDE.md` rule 6 in the
/// direction people forget — claiming to have *lost* control that is in fact still held is
/// still a false report, and it is the one that makes a user stop trusting the display.
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

    /// The fans currently believed to be back under the system's own thermal management
    /// despite Aeolus having asked otherwise.
    ///
    /// Empty is the ordinary state, and it is also the state of every build that cannot
    /// write: no fan is ever taken off automatic control, so none can be taken back.
    private(set) var reclaimedFans: Set<Int> = []

    /// Whether this fan has been taken back.
    func isReclaimed(fanAt index: Int) -> Bool { reclaimedFans.contains(index) }

    /// Records that the system has taken this fan back.
    ///
    /// - Returns: `true` when this call recorded a fan that was not already reclaimed — the
    ///   transition worth logging. `false` when it was already recorded.
    @discardableResult
    func markReclaimed(fanAt index: Int) -> Bool {
        reclaimedFans.insert(index).inserted
    }

    /// Records that this fan is no longer reclaimed — Aeolus has it back, or has stopped
    /// asking for it.
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
        reclaimedFans.remove(index) != nil
    }
}
