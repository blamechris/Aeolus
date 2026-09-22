import FanKit

/// Everything the lease core knows about the machine's fans, answered in **one hop**.
///
/// ## Why it is a type rather than a tuple
///
/// It was `(lease: Lease?, accountableFans: Set<Int>)` until
/// [#187](https://github.com/blamechris/Aeolus/issues/187), which needs three more sets to
/// state a fan's availability honestly. A five-element tuple is the same information with no
/// name to hang the invariant on, and the invariant is the interesting part: these fields are
/// **one view of one actor at one instant**. Reading them in separate hops could report a fan
/// as mid-handback and simultaneously absent from `accountableFans`, and
/// `LeaseAuthority.activeLeaseView()` exists precisely so that cannot happen — *"one hop
/// cannot disagree with itself."*
///
/// ## Why `accountableFans` is carried rather than derived here
///
/// It is the union of the three registers with the fans under lease, and
/// `LeaseAuthority.fansAeolusIsAccountableFor` is the one definition of it. Recomputing the
/// union in this type would be a second definition of the set the **grant path** judges
/// against, which is the disagreement that union's own documentation records: the snapshot
/// once named a fan Aeolus could not hand back as another program's doing while the gate
/// refused it correctly. The fans under lease are deliberately not a field of their own, so
/// nothing here can be tempted to re-derive it.
///
/// ## What is missing, and why
///
/// `sleepSeal` and "is the table non-empty" are lease-core facts with no per-fan expression
/// in a snapshot. `ManualControlAvailability.Reason.leaseHeldByAnotherClient` cannot be stated
/// at all from here: `FanAuthority.snapshot()` takes no `ConnectionID`, so the helper does not
/// know whether the reader is the holder, and *"another client"* would be a false claim to the
/// one client it is false for — `CLAUDE.md` rule 6 through the door it is easiest to walk
/// through while fixing rule 6. `SystemSnapshot.activeLease` is how a client learns that, and
/// it is already in the same snapshot.
struct LeaseAccountability: Sendable {

    /// The lease a client is shown, lapsed ones already swept.
    let lease: Lease?

    /// Every fan whose manual state is Aeolus's own doing — `fansAeolusIsAccountableFor`,
    /// verbatim. A fan in here is never reported as foreign manual control.
    let accountableFans: Set<Int>

    /// Fans a restorer gave up on: the firmware refused every attempt. The durable half.
    let abandonedHandbacks: Set<Int>

    /// Fans whose restore was issued, stopped being waited for, and has not come back.
    ///
    /// A subset of `handbacksInFlight` by the lease core's own invariant — see
    /// `LeaseAuthority.handbackUnconfirmed` — which is why the two are reported together
    /// rather than one being inferred from the other.
    let unconfirmedHandbacks: Set<Int>

    /// Fans with a restore-to-automatic on the wire right now: `releasing`'s keys.
    let handbacksInFlight: Set<Int>

    /// Fans § 3 is keeping because the firmware accepted their restore and no read has shown
    /// them automatic — `EmergencyRestoreConfirming`, read from § 3 (#303).
    ///
    /// **Deliberately not part of `accountableFans`.** That set exempts a fan from the foreign
    /// control step, and nothing else then refuses it, so a union would grant the lease. This
    /// one reclassifies that step's refusal instead. See `EmergencyRestoreConfirming`.
    ///
    /// **The one field that is not the lease core's, and so not of the same instant.** It is
    /// § 3's view, read in the hop *before* the four fields above. The order is the argument:
    /// a fan leaves § 3's set only by reading automatic, which is correctly not refused, or by
    /// being engaged again — and then the later lease-core read holds it. Read second, a fan
    /// could fall between the two views. No test forces that interleaving; it would need a
    /// gate inside § 3's accessor, which is production code instrumented for a test.
    let restoresAwaitingConfirmation: Set<Int>
}
