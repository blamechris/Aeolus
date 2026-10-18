/// `docs/SAFETY.md` § 3's handback: the one restorer in § 3's lane, held by § 3 and lent for one
/// call.
///
/// ## The lane, by construction
///
/// [ADR 0012](../../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment counts § 3's revocation's restores in D_cycle's allowance, so they take
/// § 3's lane. Its #440 amendment settles how they reach it: by holding a restorer whose writer is
/// admitted there, never by a value a restore carries. This is that restorer. Its initialiser
/// takes the writer at the admission it was built at and admits it in the lane itself, so a
/// handback cannot be built at `.supervisor` and the lane is minted in this file and the
/// composition alone (`ThermalCycleLaneTripwireTests`).
///
/// ## Who holds it, and how it is lent
///
/// The composition builds one, over § 3's writer and the one `HelperFanRestorer`, and gives it to
/// `ThermalEmergency` alone, as a required stored property with no default. § 3 passes it to
/// `LeaseAuthority.revokeEveryLease(handingBackThrough:)`, which borrows it — a `borrowing`
/// parameter of a generic that suppresses `Copyable` — and hands back through it inside the
/// bracket every teardown uses. The lease core can call it and cannot keep it: the compiler
/// refuses a store, a copy, a cast, an existential box and a capture by an escaping closure or a
/// `Task`. The positive stored-plane census in `ThermalCycleLaneWriterTests` holds that § 3 is the
/// one holder, at rest and after a firing.
///
/// ## Copyable, deliberately
///
/// A noncopyable handback would be refused more places still, and it would blind the census:
/// `Mirror` reflects a noncopyable stored field as `()`, so the walk could not see what § 3
/// holds. The guarantee lives in the borrowing signatures instead, which take a copyable argument
/// and lend it on the same terms.
///
/// ## The notices, written once
///
/// It restores through `HelperFanRestorer.handBack(_:because:through:)`, lending its own bound,
/// so § 5 is told before the write and § 3's entries are marked after it exactly as on every other
/// route. It is not a second `HelperFanRestorer`: that would need a second `bind`, and a missed
/// bind skips both notices with nothing to say so.
struct ThermalCycleHandback<Plane: FanControlPlane>: FanRestoring {

    /// The one restorer whose notices every handback goes through.
    private let notices: HelperFanRestorer<Plane>

    /// `BoundedFanRestorer` over the keystone attempt, through the writer's lane view: the same
    /// budget and order as the restorer's own, with each attempt admitted in § 3's lane.
    private let bounded: BoundedFanRestorer<KeystoneRestoreAttempt<Plane>>

    /// - Parameters:
    ///   - notices: the composition's one `HelperFanRestorer`, bound to both registries.
    ///   - writer: § 3's writer, at the admission it was built at; admitted in the lane here.
    init(notifying notices: HelperFanRestorer<Plane>, writer: SafetyActorWriter<Plane>) {
        self.notices = notices
        bounded = BoundedFanRestorer(
            attempting: KeystoneRestoreAttempt(writer: writer.admitted(at: .thermalCycle)),
            log: notices.log)
    }

    /// Returns `fans` to Apple's thermal management in § 3's lane, with both registries told.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        await notices.handBack(fans, because: cause, through: bounded)
    }
}
