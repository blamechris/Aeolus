import SMCCore

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
///
/// ## Why the qualifying key set lives here too
///
/// Because the bit and the fact that decides whether the bit may be cleared have to move
/// together. `ThermalEmergency` used to hold the engaging cycle's key set in a field of its
/// own and clear it *after* `await latch.release()` returned — a fact in one actor
/// qualifying a bit in another, across a suspension point on a reentrant actor. A concurrent
/// cycle engaging a fresh episode in that gap had its key set emptied by the releasing
/// cycle's continuation, and `Set().isSubset(of:)` is vacuously `true`, so the degraded-view
/// guard was switched off for the whole remainder of that episode
/// ([#150](https://github.com/blamechris/Aeolus/issues/150)).
///
/// Holding the reading and the keys inside one optional `Episode` makes "holding with no
/// qualifying keys" unrepresentable rather than merely avoided: one assignment publishes
/// both and one assignment clears both, inside the actor, with nothing in between for a
/// second cycle to slip through.
actor ThermalEmergencyLatch {

    /// One episode of § 3 holding: what engaged it, and what the machine could see when it
    /// did.
    struct Episode: Sendable, Hashable {

        /// The reading that engaged this episode.
        ///
        /// Kept for the log and for whoever diagnoses it afterwards. Never consulted to
        /// decide anything: the release test compares a *fresh* reading against the
        /// threshold, because a latch that released itself against the temperature that
        /// engaged it would never release at all.
        var engagedBy: CriticalTemperature

        /// The curated keys that answered on the cycle that engaged the latch.
        ///
        /// **The latch does not let go on a view that has shrunk since it fired.**
        /// `ThermalEmergency.cycle()` releases on `max(...)` over whatever answered, and it
        /// used to ask nothing about what did *not* — so losing the hot keys and keeping the
        /// cool ones read as "the machine cooled down". That is not hypothetical on this
        /// hardware: `CriticalSensorSet` records the curated cluster spanning 55.85–62.40 °C
        /// at peak heat soak, a ~6.5 °C spread, against a 5 °C `releaseHysteresisCelsius`.
        /// So a cluster whose spread exceeds the margin is the **measured** case, and the
        /// failure is concrete — hottest die key at 95.5 °C, coolest at 89 °C, hot half
        /// silent, latch releases, `acquireLease` stops refusing, and the client that was
        /// revoked retries into the same overheating workload. Exactly the loop the refusal
        /// exists to prevent.
        ///
        /// Comparing against the engaging cycle's key set rather than requiring a *complete*
        /// read is deliberate. `CriticalSensorSet`'s whole justification for a compiled-in
        /// key list is that a key this firmware never exposes is not a failure, so demanding
        /// `unreadableKeys.isEmpty` would strand the latch forever on any machine that
        /// permanently lacks one of the 34 — permanent refusal of manual control, which is
        /// `CLAUDE.md` rule 6 reached from the safe-looking direction. A key absent at
        /// engage time is absent from this set and cannot block the release; a key that
        /// *was* answering and has since gone quiet can, and should.
        let keysAnsweringAtEngage: Set<SMCKey>
    }

    /// The episode currently holding, or `nil` when the latch is clear.
    ///
    /// Read as one isolated step by the cycle that has to decide whether to let go, so that
    /// the bit and the keys qualifying it cannot come from two different moments.
    private(set) var holding: Episode?

    /// The reading that engaged the current latch, or `nil` when it is clear.
    var engagedBy: CriticalTemperature? { holding?.engagedBy }

    /// Whether § 3 is currently holding.
    var isActive: Bool { holding != nil }

    /// What the machine could see when the holding episode engaged. Empty when clear.
    var keysAnsweringAtEngage: Set<SMCKey> { holding?.keysAnsweringAtEngage ?? [] }

    /// Engages the latch.
    ///
    /// - Parameters:
    ///   - reading: the curated reading that crossed the ceiling.
    ///   - keys: every curated key that answered on this cycle. Published atomically with
    ///     the bit, and never widened or narrowed by a later engage — see below.
    /// - Returns: `true` when this call engaged a latch that was clear — the transition
    ///   worth logging. `false` when it was already engaged.
    @discardableResult
    func engage(by reading: CriticalTemperature, answering keys: Set<SMCKey>) -> Bool {
        guard var episode = holding else {
            holding = Episode(engagedBy: reading, keysAnsweringAtEngage: keys)
            return true
        }
        // The reading is overwritten on every cycle above the ceiling, deliberately: the
        // most recent one is the useful one for a reader watching a machine that is still
        // climbing. **The key set is not.** A redundant engage arriving from a degraded
        // cycle would narrow the set this episode is qualified by, weakening the release
        // guard from the direction that looks harmless.
        episode.engagedBy = reading
        holding = episode
        return false
    }

    /// Releases the latch, and with it the key set that qualified the episode.
    ///
    /// - Returns: `true` when this call released a latch that was engaged. `false` when it
    ///   was already clear.
    @discardableResult
    func release() -> Bool {
        guard holding != nil else { return false }
        holding = nil
        return true
    }
}
