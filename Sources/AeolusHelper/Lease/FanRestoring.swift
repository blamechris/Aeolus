import Foundation

/// The keystone verb, as a seam.
///
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) rests every precedence ruling
/// on one principle:
///
/// > **Restore-to-automatic is a mode write, and must never depend on trusted data.** It
/// > needs no bounds, no clamp, no sensor reading, no lease lookup and no ramp budget —
/// > `F0Md = 0` (plus `Ftst = 0`) on Apple Silicon, clearing the `FS!` bit on Intel.
///
/// That is why this protocol takes fan indices and a provenance label and nothing else. If
/// an implementation of it ever needs to read a bound, consult a sensor, or look up a
/// lease before it can act, the design has gone wrong — the whole point is that this stays
/// available when every input the other mechanisms depend on has become untrustworthy.
///
/// ## Deliberately unimplemented in this target
///
/// E5.1 ships the lease core and **writes nothing to the SMC**: `SMCConnection.write` is
/// still `package`-scoped and still throws, and no write selector exists anywhere in
/// `Sources/`. The conforming type is the helper's control plane, which arrives with the
/// write path. Declaring the seam here rather than there keeps the lease core testable in
/// full today — every teardown path below is exercised against a recording double — and
/// means the control plane inherits a contract it cannot widen by accident.
///
/// ## Why it cannot fail, and why it must still come back
///
/// No `throws`, for the same reason `FanAuthority.connectionDidInvalidate(_:)` has none:
/// the callers are teardown paths with nobody to report to. A lease that expired has no
/// live client, and a connection that died has no port. Throwing at them would be a failure
/// dressed as a decision.
///
/// **It must nevertheless return, and returning is a hard contract rather than a courtesy**
/// ([#110](https://github.com/blamechris/Aeolus/issues/110)). An implementation that cannot
/// complete the write makes **bounded** attempts — `RestoreLimits.attemptBudget`, spent per
/// fan — and then gives up and says which fans it gave up on. It must never keep trying
/// forever. This contract used to say the opposite, and what that costs was the whole of
/// #110: `LeaseAuthority` awaits this from every teardown path, and since
/// [#136](https://github.com/blamechris/Aeolus/issues/136) one of those paths is
/// `ReclamationWatchdog.cycle()` by way of `revokeEveryLease(because:)`. A conformer parked
/// inside a retry loop therefore parks `ReclamationSupervisor`'s loop for the life of the
/// process — silently, and for every other fan, not only the one that would not go back.
/// A guarantee of return is what makes awaiting this from a safety actor's cycle legal at
/// all.
///
/// `docs/SAFETY.md` § 5 already settled the same question the same way for the mechanism
/// next door: `ReclamationWatchdog.finaliseRelease(fanAt:because:)` attempts the restore,
/// logs a fault if it throws, and drops the fan from its registry **regardless** — bounded,
/// then report, never "keep trying". Two mechanisms in one subsystem must not disagree
/// about what a failed restore means.
///
/// ## Giving up is reported, never swallowed
///
/// The returned set is the fans whose mode write **threw** on every attempt. `LeaseAuthority`
/// keeps them, and refuses a later lease over one with
/// `ManualControlAvailability.Reason.restoreToAutomaticFailed` — durable, and deliberately
/// distinct from the transient `.releaseInProgress`, so a client can tell *retrying* from
/// *gave up*. Returning an empty set from a restore that threw is the inversion this whole
/// subsystem exists to prevent: it converts "the write was refused" into "the teardown
/// completed", and the next client is then handed a lease over a fan in a mode nothing has
/// confirmed. `BoundedFanRestorer` is the shipped implementation of all of this.
///
/// **The throwing half is the whole of it, and the scope is worth stating precisely.** A
/// firmware that accepts the write and then discards it is not detectable here and is not
/// claimed to be: this seam sees a return, not a read-back. An empty set therefore means
/// "nothing was refused", never "every fan is confirmed automatic". Silent reversion is
/// `docs/SAFETY.md` § 5's job — written-versus-read-back on the watchdog's own cycle — and a
/// read-back inside the restore itself would need the write path E3/E4 have not shipped.
/// Widening this contract to promise confirmation before that exists would be a guarantee
/// nothing in the build can keep.
///
/// ## Its relationship to `FanControlPlane`
///
/// These two protocols name the same verb and landed in the same wave from different
/// sub-issues (#99 and #100), so the relationship is written down here rather than left to
/// be inferred: **`FanControlPlane` is the provider, `FanRestoring` is the role the lease
/// core depends on.** The lease core needs one operation, not a control plane, and asking
/// for only what it uses is what keeps it testable against a recording double.
///
/// They differ in one deliberate way. `FanControlPlane.restoreToAutomatic(_:)` **throws**,
/// because a firmware write genuinely can fail and a control plane that hid that would be
/// lying. This one does not, for the reason above. Bridging them is therefore not a
/// signature adjustment — it is the decision about **who owns a restore that failed**, and
/// the answer cannot be "nobody", because ADR 0007's keystone makes restore the terminal
/// action every other mechanism falls back to.
///
/// `BoundedFanRestorer` is that answer, and it ships here rather than with #102 because
/// #110 is a liveness property of the *lease core*, not of whichever plane ends up behind
/// it: the bound has to exist in code the lease core's tests can drive, or "the caller
/// cannot be parked" is an assertion about a comment. **#102 still owns the wiring** — which
/// `FanRestoreScope` a production adapter uses per attempt, and whether the Apple Silicon
/// force key is cleared on the way — and conforms its plane to `FanRestoreAttempting` to
/// get the bound.
protocol FanRestoring: Sendable {

    /// Returns `fans` to the system's own thermal management.
    ///
    /// Must be idempotent: every teardown path may run for fans that are already automatic,
    /// and two paths may name the same fan in the same instant.
    ///
    /// Must also **terminate**: bounded attempts, then report. See "Why it cannot fail, and
    /// why it must still come back" above; a conformer that retries forever is a defect
    /// whatever its tests say, because its caller is a teardown path with no timeout of its
    /// own.
    ///
    /// - Returns: the subset of `fans` whose mode write was refused on every attempt — empty
    ///   when no write threw. Never the fans it restored, and never a claim that a fan is
    ///   confirmed automatic: see "Giving up is reported, never swallowed" for why a write
    ///   the firmware accepts and discards is § 5's to catch rather than this seam's.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int>
}

/// Which mechanism asked for the restore.
///
/// Provenance for a log line, never an input to the decision — the restore is unconditional
/// and identical whatever this says. It is carried because
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md) requires the lease's two teardown
/// paths to be independent, and "independent" is only checkable if an observer can tell
/// which one acted. A restore whose cause cannot be named is a restore whose mechanism
/// cannot be audited.
enum FanRestoreCause: Sendable, Hashable {

    /// `docs/SAFETY.md` § 3 fired: a curated critical temperature went above its ceiling
    /// while this lease held the fans. Actor level 2.
    ///
    /// Like `.allLeasesDropped` — § 7's panic verb, and the one cause that outranks this one
    /// — it is a lease being **taken** from a client that had done nothing wrong, rather
    /// than a lease ending, which is what the three below are. An earlier version of this
    /// comment called it "the highest-precedence cause here", which contradicts the
    /// precedence order shipped in the same change: `SafetyActorLevel.panicRestore` is 1 and
    /// this is 2.
    ///
    /// `ThermalEmergency` performs its own restore before this revocation reaches the lease
    /// core, per ADR 0007's keystone; the restore this cause labels is the idempotent second
    /// one.
    case thermalEmergency

    /// `docs/SAFETY.md` § 5 confirmed divergence: the system took a fan back, and either
    /// the bounded re-assert was refused, its budget was spent, or § 3 was holding and
    /// level 3 must not fight level 2 for the fans. Actor level 3.
    ///
    /// Like `.thermalEmergency`, this is a lease being **taken** rather than a lease ending
    /// — but for the opposite reason. § 3 takes fans because the machine is too hot; this
    /// one records that the fans were *already* gone and Aeolus has stopped pretending
    /// otherwise. `CLAUDE.md` rule 6 is the whole of it: a lease left alive over a fan the
    /// firmware is no longer honouring is a client told it has control it does not have.
    case systemReclaimed

    /// § 5's other half: the helper could not read a leased fan's state for
    /// `ReclamationLimits.blindCyclesBeforeDivergence` consecutive cycles, a reconnect was
    /// attempted, and the fan went back to automatic control anyway. Also actor level 3.
    ///
    /// **Its own case rather than `.systemReclaimed`**, because the two are diagnosed
    /// completely differently and this enum exists to keep such things apart — the same
    /// argument `revokeEveryLease(because:)` makes for not sharing a predicate remover with
    /// the panic path. A reclamation is a working helper losing a contest with the OS; this
    /// is a helper that has gone blind, which ADR 0007 calls hole 2 and
    /// [#68](https://github.com/blamechris/Aeolus/issues/68) is the motivating case for.
    case supervisorBlind

    /// The TTL lapsed. The backstop path, driven by `LeaseExpirySupervisor` against the
    /// monotonic clock, and reachable with no connection event of any kind.
    case leaseExpired

    /// The connection holding the lease died — crash, `SIGKILL`, logout, orderly
    /// disconnect. Reachable with the monotonic clock frozen.
    case connectionInvalidated

    /// The client asked, on a connection that held the lease.
    case leaseReleased

    /// The panic path: every lease dropped at once.
    case allLeasesDropped

    /// Startup reconciliation found the fan in manual before this process served anything.
    ///
    /// **The one cause that names no lease**, and the only one that can be true of a fan
    /// *this* helper never touched. Every case above is a lease ending or being taken; this
    /// one is `docs/SAFETY.md` § 6's crash coverage, clearing what a dead predecessor — or
    /// another program — left behind. See
    /// [ADR 0011](../../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md).
    ///
    /// It happens exactly once per process, before `listener.resume()`. A fan found in
    /// manual afterwards is foreign control and is refused rather than restored, so nothing
    /// can produce this cause twice for the same fan.
    case startupReconciliation
}

/// Where the lease core gets the set of fans this machine actually has.
///
/// `FanAuthority`'s own documentation puts this check on the authority side rather than the
/// listener: *"the authority owns the enumeration, and shipping the set up to the listener
/// on every message would be both chatty and a time-of-check/time-of-use gap on the one
/// input that decides which fans a lease may cover."*
///
/// The lease core does not own hardware, so it asks. `ReadOnlyFanAuthority` already declares
/// exactly this method and is conformed to it below, which is the cheapest possible proof
/// that the seam is satisfiable by shipped code rather than only by a test double.
///
/// **This is the suspension point that makes
/// [#95](https://github.com/blamechris/Aeolus/issues/95) real.** `LeaseAuthority.acquireLease`
/// awaits it, and an invalidation can land during that await — which is precisely the
/// interleaving the post-suspension liveness re-check exists to close.
protocol FanEnumerating: Sendable {

    /// The fan indices this machine enumerated.
    func enumeratedFanIndices() async throws -> Set<Int>
}

extension ReadOnlyFanAuthority: FanEnumerating {}
