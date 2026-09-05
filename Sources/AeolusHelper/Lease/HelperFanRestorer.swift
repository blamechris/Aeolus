/// One attempt at the keystone write, through the safety-actor writer.
///
/// The bridge `BoundedFanRestorer` was shipped without: #110 gave the bound a home in code
/// the lease core's tests can drive, and named the missing half plainly — *"#102 still owns
/// the wiring — which `FanRestoreScope` a production adapter uses per attempt."* This is
/// that decision, and it is `.fan(index)`.
///
/// **Per fan, never `.everyFan`.** `FanRestoring` reports *which* fans could not be handed
/// back, and `LeaseAuthority.restoreAbandoned` turns that set into a per-fan refusal a
/// client is told about. A conformer that restored `.everyFan` once could not produce that
/// set: one throw would have to be reported as every fan abandoned (refusing leases over
/// fans that are demonstrably fine) or as none (the inversion `FanRestoring` calls out —
/// *"it converts 'the write was refused' into 'the teardown completed'"*). `.everyFan` also
/// clears the Apple Silicon force key, which is a machine-wide act and not this path's to
/// perform: § 7's panic verb owns it, and E5.4d wires it to the signal handlers.
///
/// **Through `SafetyActorWriter`, never through the plane directly.** [ADR
/// 0008](../../../docs/ADR/0008-write-authorisation.md) makes every write to a *fan* carry a
/// permit stamped by the read that established its bounds; the keystone verb is the one
/// exception, and it is an exception because it needs no bounds at all — see ADR 0007. The
/// writer is what makes that exception legible: it is the type that carries a
/// `SafetyActorLevel.Ungoverned`, so a restore issued here is attributable to a level rather
/// than being an anonymous call into the firmware, and § 8's ramp governor cannot reach it
/// (`SafetyActorWriter` holds no `RampGovernor` and has no property one could be assigned
/// to). No new write verb is introduced anywhere: this composes `restoreToAutomatic(_:)`,
/// which both the writer and the plane already declare.
struct KeystoneRestoreAttempt<Plane: FanControlPlane>: FanRestoreAttempting {

    private let writer: SafetyActorWriter<Plane>

    init(writer: SafetyActorWriter<Plane>) {
        self.writer = writer
    }

    func restoreOnce(fanAt index: Int) async throws {
        try await writer.restoreToAutomatic(.fan(index))
    }
}

/// The production `FanRestoring`: `BoundedFanRestorer` over the firmware, with the two
/// safety registries told about every fan it hands back.
///
/// ## What was missing, and why it was missing
///
/// #103's adjudication found it: *"there is no `FanRestoring` conformer anywhere in
/// `Sources/` (only `RecordingFanRestorer` in tests), and
/// `ReclamationWatchdog.manualControlReleased(fanAt:)` and
/// `ThermalEmergency.manualControlEngaged(_:)` have zero callers in `Sources/`."* The lease
/// core, the bound from #110 and both safety registries all shipped; the wire between them
/// did not. This is that wire, and it is the reason the
/// bridge is worth a type of its own rather than a closure at the composition root: the
/// **order** of the two deregistrations relative to the write is a safety decision, and a
/// decision needs somewhere to be written down and tested.
///
/// ## The order, and why the two registries do not share one
///
/// § 5 is told **before** the write; § 3 is told **after** it, and only about the fans the
/// firmware actually took. They differ because the two registries are read by mechanisms
/// that draw opposite conclusions from the same entry.
///
/// - **`ReclamationWatchdog` — before.** Its cycle asks, of every fan in its registry,
///   "is this fan still where Aeolus put it?" A fan that has just gone back to automatic
///   reads `mode == .automatic`; with a commanded target on record that is
///   `.modeReclaimed`, the strongest primary signal there is, and it lands on
///   `finaliseRelease(fanAt:because:)` with `.systemReclaimed` — **every lease on the
///   machine revoked** and a `.fault` line blaming the operating system for a handback
///   Aeolus asked for. The window between a landed write and a later deregistration is
///   exactly one actor hop wide and § 5 runs at 1 Hz, so it is small and it is reachable;
///   the harm is not small. Telling § 5 first closes it, and costs only that § 5 stops
///   watching a fan whose restore is already in flight — a fan no client holds, because
///   every teardown path removes its lease entry synchronously before awaiting the restore.
///   § 5 already settles the same question the same way for itself:
///   `finaliseRelease(fanAt:because:)` "drops the fan from its registry **regardless**" of
///   whether the restore threw.
///
/// - **`ThermalEmergency` — after, and only for fans that came back.** Its registry is read
///   by `fire(_:from:)`, which bridges each entry to maximum RPM and then restores it. A
///   stale entry there is harmless in a way a stale § 5 entry is not, and that type says so
///   itself: *"the emergency would bridge a fan that is already on Apple's management, which
///   is a redundant write and then a redundant restore, not an unsafe state."* A **missing**
///   entry is not harmless: a fan whose restore the firmware refused three times is still
///   off automatic control, possibly pinned low, and if § 3 has forgotten it then a machine
///   going over its ceiling will not bridge it to maximum. So the fans in the abandoned set
///   stay registered, deliberately, and only the ones that went back are dropped. The
///   asymmetry is the point: for § 5 the failure direction is a false alarm, for § 3 it is a
///   missed one.
///
/// `HelperRestorerTests` has one test per registry, each named for the call whose deletion
/// turns it red.
///
/// ## Why the registries are bound after construction
///
/// The graph is circular and cannot be built in one pass: `LeaseAuthority` requires a
/// `FanRestoring`, and both `ThermalEmergency` and `ReclamationWatchdog` require the
/// `LeaseAuthority`. Something has to be late, and this edge is the cheapest one to make
/// late — the registrations are notifications, while the lease core's reference to the
/// restorer and the registries' references to the lease core are both on paths that act.
///
/// **The window in which this is unbound is closed by the composition root's ordering, not
/// by hope.** `HelperComposition.bringUp()` binds as its first statement, before either
/// supervisor is started and before `listener.resume()` advertises the Mach service — so no
/// client can acquire a lease, no supervisor can revoke one, and no TTL can lapse until
/// after the bind. `HelperCompositionTests` asserts both the ordering at the source and that
/// a composed helper is bound once brought up. A restore that somehow arrived first would
/// still restore — the keystone is never gated on bookkeeping — and would say so at
/// `.fault`.
actor HelperFanRestorer<Plane: FanControlPlane>: FanRestoring {

    private let bounded: BoundedFanRestorer<KeystoneRestoreAttempt<Plane>>
    private let log: LeaseLog

    /// `docs/SAFETY.md` § 3's registry of fans off automatic control. `nil` until `bind`.
    private var thermalEmergency: ThermalEmergency<Plane>?

    /// § 5's registry of the same fans, read by a mechanism that judges them. `nil` until
    /// `bind`.
    private var reclamationWatchdog: ReclamationWatchdog<Plane>?

    init(writer: SafetyActorWriter<Plane>, log: LeaseLog = LeaseLog()) {
        bounded = BoundedFanRestorer(
            attempting: KeystoneRestoreAttempt(writer: writer), log: log)
        self.log = log
    }

    /// Hands this restorer the two registries it must keep in step with the firmware.
    ///
    /// Called once, by `HelperComposition.bringUp()`, before anything can restore. Not
    /// idempotent-by-guard and deliberately so: a second bind replaces, because the only
    /// caller is a composition root that builds each registry exactly once, and a guard here
    /// would be a branch no test could reach.
    func bind(
        thermalEmergency: ThermalEmergency<Plane>,
        reclamationWatchdog: ReclamationWatchdog<Plane>
    ) {
        self.thermalEmergency = thermalEmergency
        self.reclamationWatchdog = reclamationWatchdog
    }

    /// Whether both registries have been bound, for the composition tests and diagnostics.
    var isBound: Bool { thermalEmergency != nil && reclamationWatchdog != nil }

    /// Returns `fans` to Apple's thermal management, telling § 5 before the write and § 3
    /// after it. See this type's documentation for why those are different sides.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async -> Set<Int> {
        if reclamationWatchdog == nil || thermalEmergency == nil {
            log.restoredWithoutSafetyRegistries(fans: fans, because: cause)
        }

        // Sorted for `BoundedFanRestorer`'s reason: set iteration order is not a contract,
        // and a log line a test can read has to be in the same order every run.
        //
        // Re-fetched from the actor's own state on each hop rather than hoisted into a local
        // before the loop — `ReclamationWatchdog.cycle()`'s rule, applied here: this actor is
        // reentrant across every `await` below.
        for fan in fans.sorted() {
            await reclamationWatchdog?.manualControlReleased(fanAt: fan)
        }

        let abandoned = await bounded.restoreToAutomatic(fans: fans, because: cause)

        // Only the fans the firmware took. One it refused is still off automatic control, so
        // § 3 must keep it: an abandoned fan is precisely the one a thermal emergency would
        // need to bridge to maximum.
        for fan in fans.subtracting(abandoned).sorted() {
            await thermalEmergency?.manualControlReleased(fanAt: fan)
        }

        return abandoned
    }
}
