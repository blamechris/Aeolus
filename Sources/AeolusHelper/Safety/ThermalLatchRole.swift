/// What § 5 may ask of § 3's latch, and nothing else: whether it is holding
/// ([#380](https://github.com/blamechris/Aeolus/issues/380)).
///
/// A role rather than the actor, for `HeldLeaseRole`'s two reasons. It narrows what
/// `ReclamationWatchdog` can do to the latch to the one read `currentRuling()` makes, so § 5
/// cannot engage or release an emergency and `ThermalEmergency` stays the only thing in
/// `Sources/` that clears the latch. And it is a seam: a test can hold the answer open on a
/// continuation, which is the only way to land a registration between the latch answering and
/// § 5 resuming at `diverged`'s precedence check without racing one in (#109) or blocking a
/// cooperative-pool thread (#344).
///
/// `ThermalEmergencyLatch` is the one conformer in `Sources/`, and `HelperComposition` hands § 5
/// the instance § 3 sets, so the bit § 5 reads is the bit § 3 holds.
protocol ThermalLatchRole: Sendable {

    /// `ThermalEmergencyLatch.isActive`.
    var isActive: Bool { get async }
}
