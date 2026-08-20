/// The one bit that says `docs/SAFETY.md` § 3 is holding, shared by the mechanism that
/// sets it and the mechanisms that must honour it.
///
/// ## Why the latch is its own type
///
/// Three things need it and they must not need each other. `ThermalEmergency` engages and
/// releases it; `LeaseAuthority` refuses to grant a lease while it is engaged; the snapshot
/// reports it to the user as `isThermalEmergencyActive`. Giving the lease core a reference
/// to the emergency — or the emergency a reference to the snapshot assembler — would make
/// a cycle out of what is one boolean, and would put the emergency's whole cycle behind
/// every `acquireLease`.
///
/// It is an actor and not an `nonisolated(unsafe) var` because a root daemon driving
/// cooling hardware does not get to have a data race on the bit that says the machine is
/// too hot. `CLAUDE.md` rule 10 and this repository's `no_unchecked_sendable_in_helper`
/// rule would both treat the cheaper spelling as a claim requiring review.
///
/// ## Why engage and release report whether they changed anything
///
/// The supervisor polls on a cycle. A latch that is already engaged is engaged again on
/// every tick above the ceiling, and one that is already clear is cleared again on every
/// tick below the release threshold — so a caller that logged unconditionally would emit at
/// its polling rate. #125's forward constraint from #124 says exactly this about
/// `SafetyLog.degradedCycle`: *"an unchanged degraded set logged every tick at 1 Hz is not
/// a log, it is a denial of service against the reader"*. The same is true of the latch,
/// and the answer is the same — **log the transition, not the state** — so these return
/// whether a transition happened rather than leaving each caller to remember the previous
/// value.
actor ThermalEmergencyLatch {

    /// The reading that engaged the current latch, or `nil` when it is clear.
    ///
    /// Kept for the log and for whoever diagnoses it afterwards. Never consulted to decide
    /// anything: the release test compares a *fresh* reading against the threshold, because
    /// a latch that released itself against the temperature that engaged it would never
    /// release at all.
    private(set) var engagedBy: CriticalTemperature?

    /// Whether § 3 is currently holding.
    var isActive: Bool { engagedBy != nil }

    /// Engages the latch.
    ///
    /// - Returns: `true` when this call engaged a latch that was clear — the transition
    ///   worth logging. `false` when it was already engaged.
    @discardableResult
    func engage(by reading: CriticalTemperature) -> Bool {
        let wasClear = engagedBy == nil
        // Overwritten on every cycle above the ceiling, deliberately: the most recent
        // reading is the useful one for a reader watching a machine that is still climbing.
        engagedBy = reading
        return wasClear
    }

    /// Releases the latch.
    ///
    /// - Returns: `true` when this call released a latch that was engaged. `false` when it
    ///   was already clear.
    @discardableResult
    func release() -> Bool {
        guard engagedBy != nil else { return false }
        engagedBy = nil
        return true
    }
}
