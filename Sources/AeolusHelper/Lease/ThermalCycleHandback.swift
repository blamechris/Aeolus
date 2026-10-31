/// `docs/SAFETY.md` § 3's handback: the one restorer in § 3's lane, held by § 3 and lent for one
/// call.
///
/// ## The lane, by construction
///
/// [ADR 0012](../../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment counts § 3's revocation's restores in D_cycle's allowance, so they take
/// § 3's lane. Its #440 amendment settles how they reach it: by holding a restorer whose writer is
/// admitted there, never by a value a restore carries. This is that restorer. Its initialiser
/// takes a writer at whatever admission it was built at and admits it in the lane itself, so a
/// handback cannot be built at `.supervisor` — and building one is minting a lane writer. So the
/// lane is named only here and in the composition (`ThermalCycleLaneTripwireTests`), and this
/// file holds this one declaration with its one mint inside its own `init`, with no nested type, no
/// static member and no `Self(…)` call or `.init` reference outside that `init`; the type is named
/// only by the composition, which builds it, and by § 3, which holds it, and nothing aliases it
/// (`ThermalCycleHandbackShapeTripwireTests`). Those scans catch accidents. What a deliberate
/// second holder would do — write in the lane from another mechanism — is held by behaviour on the
/// paths `SupervisorWriterAdmissionTests` and K6 drive: level 6, § 5's re-assert, give-up and lapse
/// hand-back, § 7, § 6's machine-wide restore, the signal teardown and the power observer
/// `bringUp()` installs, and K6's other teardowns after a firing. A path neither drives is held by
/// the scans alone.
///
/// ## Who holds it, and how it is lent
///
/// The composition builds one, over a writer at § 3's level on the plane, which this type admits
/// in the lane, and the one `HelperFanRestorer`, and gives it to `ThermalEmergency` alone, as a
/// required stored property with no default. § 3 passes it to
/// `LeaseAuthority.revokeEveryLease(handingBackThrough:)`, which borrows it — a `borrowing`
/// parameter of a generic that suppresses `Copyable` — and hands back through it inside the
/// bracket every teardown uses. The lease core can call it and, in safe Swift, cannot keep it
/// through the parameter: the compiler refuses a store, a copy, a cast, an existential box and a
/// capture by an escaping closure or a `Task` (`FanRestoring`'s "`~Copyable`" note has the
/// exclusions, and which part of the compiler refuses what). The positive stored-plane census in
/// `ThermalCycleLaneWriterTests` holds that § 3 is the one holder, at rest and after a firing.
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
/// route. It is not a second `HelperFanRestorer`: that would need a second `bind`, and a restore
/// through one that missed it skips both notices — said at `.fault`, and lost all the same.
struct ThermalCycleHandback<Plane: FanControlPlane>: FanRestoring {

    /// The one restorer whose notices every handback goes through.
    private let notices: HelperFanRestorer<Plane>

    /// `BoundedFanRestorer` over the keystone attempt, through the writer's lane view: the same
    /// budget and order as the restorer's own, with each attempt admitted in § 3's lane.
    private let bounded: BoundedFanRestorer<KeystoneRestoreAttempt<Plane>>

    /// - Parameters:
    ///   - notices: the composition's one `HelperFanRestorer`, bound to both registries.
    ///   - writer: a writer at § 3's level, at the admission it was built at; admitted in the lane
    ///     here, and only here.
    ///   - log: the lease log the composition was given, so a lane restore's abandonment is written
    ///     where every other lease line is. Required rather than defaulted: in the daemon a default
    ///     `LeaseLog()` would be the same log, but in a composed test it would not be the one the
    ///     test passed, and nothing would say the two had parted.
    init(
        notifying notices: HelperFanRestorer<Plane>, writer: SafetyActorWriter<Plane>,
        log: LeaseLog
    ) {
        self.notices = notices
        bounded = BoundedFanRestorer(
            attempting: KeystoneRestoreAttempt(writer: writer.admitted(at: .thermalCycle)),
            log: log)
    }

    /// Returns `fans` to Apple's thermal management in § 3's lane, with both registries told.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        await notices.handBack(fans, because: cause, through: bounded)
    }
}
