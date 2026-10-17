import FanKit

// The two write paths, one per precedence class, and they are deliberately **different
// types with no protocol in common**.
//
// That is the whole of `docs/SAFETY.md` § 8's exclusion, made structural:
//
//   > Ramp limiting shapes the control loop's output only, and never delays a safety-actor
//   > write.
//
// `SafetyActorWriter` holds no `RampGovernor` and has no property one could be assigned
// to. `GovernedFanWriter` is the only type in `AeolusHelper` that holds one, and only the
// control loop uses it. They share no *writing* protocol, so no code can be generic over
// "a writer" and hand a safety actor the governed one by accident. (They do both satisfy
// `Sendable`, so a `<W: Sendable>` parameter accepts either; the exclusion is about the
// verbs, not about every protocol in the language. An earlier draft of this paragraph said
// "no protocol in common", which is false.)
//
// **How the exclusion is enforced, exactly — because an adversarial review found this
// paragraph overstating it.** Two halves, and only the first is what "by construction"
// means here:
//
//  1. **Compile time.** `GovernedFanWriter` declares neither `commandMaximum(of:)` nor
//     `restoreToAutomatic(_:)`. Pointing `ThermalEmergency.writer` at one therefore does
//     not compile at all until somebody deliberately adds both verbs. That is the strong
//     half, and it is stronger than any runtime check.
//  2. **Behaviour.** The mutation that turns a test red is injecting a governor into
//     `SafetyActorWriter.commandMaximum(of:)` below: the bridge then writes one 200 RPM/s
//     step instead of the fan's maximum, and
//     `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite` fails **on the RPM
//     value**.
//
// This comment previously claimed the *type swap* produced "a staircase of 200 RPM steps"
// and turned that test red "on the count". Both are wrong, and were checked: with the two
// verbs added, the swap leaves all 866 tests green, because `GovernedFanWriter` sends the
// first write to a fan straight to the goal and the fixture had never commanded that fan.
// There is also no staircase to be had — `fire(_:)` is latch-gated and bridges each fan
// exactly once, so on real hardware the mutant would issue **one truncated step and then
// restore**, never reaching maximum at all. That is worse than the 22 seconds ADR 0007
// refuses, not better, and it is the reason the claim was worth correcting rather than
// deleting.

/// The writer for actor levels 1 to 5: panic, thermal emergency, reclamation, sleep/wake,
/// lease expiry.
///
/// Every write goes straight to the firmware. There is no rate limit, no dwell, no budget
/// and nothing between this and `FanControlPlane` — which is the point, and is why the
/// level it carries is a `SafetyActorLevel.Ungoverned` rather than a `SafetyActorLevel`:
/// none of these carries the control loop's level.
///
/// ## Level 6's engagement driver holds one, and commands no target through it
///
/// Level 6 engages through an `EngagementDriver` of its own, and a driver steps through one of
/// these (ADR 0014's A6 amendments). That driver uses it for `engageManualControl(of:)` and
/// `restoreToAutomatic(_:)` and nothing else, is asked about `.controlLoop` whatever this
/// writer's level says, and exposes no target verb; the file that holds level 6's driver never
/// names this type. So the control loop holds no writer it can command a target through but
/// `GovernedFanWriter`, and § 8's exclusion below is about target writes, which is where it
/// was always about.
///
/// ## What it still cannot do
///
/// It does not widen anything. `commandMaximum(of:)` takes a `CommandableFan`, so a fan
/// whose declared bounds failed the plausibility gate cannot be commanded through here
/// either — § 2's closing rule, that the only action such a fan is subject to is the
/// bounds-free restore verb, holds for safety actors exactly as it holds for the control
/// loop. Bypassing § 8 is not bypassing § 2, and conflating those two would be ADR 0007's
/// conflict 4 with the classes swapped.
///
/// ## It is also a `KeystoneRestoring`
///
/// The conformance is its existing restore verb. § 7's panic verb is handed one of these at
/// `.panicRestore`, **typed as the role** (`SupervisedFanAuthority`, ADR 0014 D5): only that
/// role is restore-only. This type still has `commandMaximum(of:)`, `command(_:of:)` and
/// `engageManualControl(of:)`, and anything holding it by its own type can call them. The
/// level is provenance only; nothing reads it. It is not a writing protocol shared with
/// `GovernedFanWriter`, which still declares no restore verb, so the exclusion above stands.
struct SafetyActorWriter<Plane: FanControlPlane>: KeystoneRestoring {

    private let plane: Plane

    /// Which safety actor is writing: provenance only. Nothing reads it today — no log line
    /// prints it, and the one caller of `SafetyArbiter.ruling(for:incumbent:)`,
    /// `ReclamationWatchdog`, names its own level rather than asking a writer — so it is kept
    /// for whoever makes the arbiter govern these writes. It is never an input to the
    /// arithmetic, because there is no arithmetic here to vary.
    let level: SafetyActorLevel.Ungoverned

    init(plane: Plane, level: SafetyActorLevel.Ungoverned) {
        self.plane = plane
        self.level = level
    }

    /// Commands this fan's highest commandable speed, as **one** write.
    ///
    /// `docs/SAFETY.md` § 3's emergency is the caller this exists for. It needs no read to
    /// do it: `CommandableFan` already carries the gated envelope from the read that minted
    /// it, and `FanWriteAuthorisation.swift` documents that permits deliberately do not
    /// expire precisely so this call is available while the machine is above ceiling and
    /// reading may be the thing that has failed.
    ///
    /// - Returns: what was put on the wire, for the reclamation watchdog to compare a later
    ///   read-back against ([#126](https://github.com/blamechris/Aeolus/issues/126)).
    @discardableResult
    func commandMaximum(of fan: CommandableFan) async throws -> CommandedTarget {
        try await command(fan.envelope.highestCommandableRPM, of: fan)
    }

    /// Commands a particular speed, as **one** write.
    ///
    /// `docs/SAFETY.md` § 5's bounded re-assert is the caller this exists for:
    /// `commandMaximum(of:)` is the wrong verb there, because a watchdog re-asserting a
    /// user's 2,400 RPM by writing 5,777 would take a reclamation and answer it with a
    /// noise complaint. Level 3 needs the number it last commanded, not the loudest one.
    ///
    /// Still ungoverned, and still clamped: `requestedRPM` goes through
    /// `CommandableFan.target(for:)`, so §2's bounds and the 0-RPM floor bind this exactly
    /// as they bind every other write in the project. There is one clamp and this is not a
    /// second one.
    ///
    /// `commandMaximum(of:)` is now written in terms of this rather than beside it, so the
    /// two cannot come to disagree about what a safety-actor write does to a permit.
    @discardableResult
    func command(_ requestedRPM: Double, of fan: CommandableFan) async throws -> CommandedTarget {
        try await plane.commandTarget(fan.target(for: requestedRPM))
    }

    /// The keystone verb. Needs no bounds, no reading, and no lease — see
    /// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) and `FanControlPlane`.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await plane.restoreToAutomatic(scope)
    }

    /// One step of taking a fan back off the system's thermal management.
    ///
    /// The one verb here that moves a fan *away* from the safe state, and it exists for one
    /// caller: an `EngagementDriver`, which asks the entitlement around every step and owns the
    /// cadence between them ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md) D2). § 5's
    /// bounded re-assert engages through one, because a fan the system has reclaimed is on
    /// automatic control and re-commanding its target without this first writes a number nothing
    /// honours; level 6's `apply` engages through its own (ADR 0014's A6 amendments).
    ///
    /// It is on this writer rather than reached through the plane directly because neither the
    /// driver nor `ReclamationWatchdog` holds a plane — see `FanStateSensing`. Like every verb
    /// here it takes a `CommandableFan`, so § 2's plausibility gate binds it: a fan whose
    /// declared bounds were refused cannot be taken off automatic control by a safety actor
    /// either.
    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        try await plane.engageManualControl(of: fan)
    }
}

/// The writer for actor level 6, the control loop under a lease — and the **only** holder
/// of a `RampGovernor` in this target.
///
/// ## Why it remembers what it commanded
///
/// A ramp is computed from the target last *written*, never from the fan's measured speed:
/// `F<n>Ac` legitimately slews toward `F<n>Tg` rather than stepping, so governing against a
/// measurement would re-govern movement already asked for. `CommandedTarget` exists to
/// carry that number, and this actor keeps it per fan rather than taking it as a parameter
/// — a caller-supplied "last target" is a caller-supplied *index* too, and it can disagree
/// with the fan being written. That is the same cross-fan defect `commandTarget(_:)`
/// removed its `ofFan:` parameter to make unrepresentable.
///
/// ## Held by level 6's `apply`, and with no control loop yet
///
/// `LeaseApplier` holds one and writes each fixed setting through `hold(_:of:)`; the composition
/// builds one, behind the authority's `apply`. `command(towards:of:since:)` has no caller at all
/// until E8a's loop steps on its own, and hysteresis — § 8's other half — arrives with the curve
/// evaluator in
/// [#17](https://github.com/blamechris/Aeolus/issues/17). What exists here is the governor
/// and the boundary it sits behind, built in #125 because ADR 0007's ruling that § 8 never
/// delays a safety-actor write was, until now, a rule about a mechanism that did not exist
/// to break it — see [#121](https://github.com/blamechris/Aeolus/issues/121) and
/// `RampGovernor`.
actor GovernedFanWriter<Plane: FanControlPlane> {

    private let plane: Plane
    private let governor: RampGovernor

    /// The last target written per fan. Cleared at every engagement and every hand-back, because
    /// a remembered target would then ramp from a speed nothing is holding: see
    /// `fanReturnedToAutomatic(index:)`.
    private var lastCommandedRPM: [Int: Double] = [:]

    init(plane: Plane, governor: RampGovernor = RampGovernor()) {
        self.plane = plane
        self.governor = governor
    }

    /// Moves this fan's target toward `goal`, by no more than § 8's cap allows in
    /// `elapsed`.
    ///
    /// - Parameters:
    ///   - goal: Where the curve or the user asked the fan to be. Clamped into the fan's
    ///     envelope before anything is written, so § 2 binds this exactly as it binds a
    ///     safety actor's write.
    ///   - fan: The permit, carrying the index and the gated envelope from one read.
    ///   - elapsed: Time since this fan's last commanded target. Ignored on the first write
    ///     to a fan, which goes straight to the clamped goal: there is no previous target
    ///     to ramp from, and a fan coming off automatic control is not mid-movement.
    /// - Returns: the step actually put on the wire, which is what the next call ramps from.
    /// - Throws: whatever the plane's `commandTarget(_:)` throws. A refused write leaves the
    ///   remembered target where it was, so the next cycle ramps from the last step that
    ///   really landed rather than from one the firmware discarded.
    @discardableResult
    func command(
        towards goal: Double, of fan: CommandableFan, since elapsed: Duration
    ) async throws -> CommandedTarget {
        let stepped: Double
        if let previous = lastCommandedRPM[fan.index] {
            stepped = governor.step(from: previous, toward: goal, over: elapsed)
        } else {
            stepped = goal
        }

        let commanded = try await plane.commandTarget(fan.target(for: stepped))
        lastCommandedRPM[fan.index] = commanded.rpm
        return commanded
    }

    /// Writes this fan's target as `goal`, whole: **one** write of the clamped goal, with no ramp.
    ///
    /// How level 6 writes a `.fixed(rpm:)` setting (ADR 0014's A6 amendments). A fixed setting is
    /// a speed the client asked for, and a single governed step towards it is not that speed: from
    /// a remembered 3,564 RPM, a one-second step towards a fan's 5,777 maximum writes 3,764 and the
    /// reply still says applied, which is `CLAUDE.md` rule 6. § 8 shapes the steps a control loop
    /// takes (E8a's loop, which will call `command(towards:of:since:)`), not a client's setpoint.
    ///
    /// Still clamped: `goal` goes through `CommandableFan.target(for:)`, so § 2's bounds and the
    /// 0 RPM floor bind it exactly as they bind every other write.
    ///
    /// - Returns: the target the plane put on the wire, which is what the caller reports and what
    ///   the next `command(towards:of:since:)` ramps from.
    /// - Throws: whatever the plane's `commandTarget(_:)` throws, leaving the remembered target
    ///   where it was, as `command(towards:of:since:)` does.
    @discardableResult
    func hold(_ goal: Double, of fan: CommandableFan) async throws -> CommandedTarget {
        let commanded = try await plane.commandTarget(fan.target(for: goal))
        lastCommandedRPM[fan.index] = commanded.rpm
        return commanded
    }

    /// Forgets a fan's ramp state: the fan was on Apple's thermal management until an engagement
    /// took it off, or has just been handed back to it.
    ///
    /// Level 6 calls this at every engagement it makes and every fan its undo hands back (ADR
    /// 0014's A6 amendments), so a target remembered from before a fan went back to automatic is
    /// never the origin of a later ramp. A hand-back the lease core makes is covered by the next
    /// engagement, which comes before any write under a newer lease.
    func fanReturnedToAutomatic(index: Int) {
        lastCommandedRPM[index] = nil
    }

    /// What this writer would ramp from, for tests and diagnostics.
    func lastCommanded(ofFan index: Int) -> Double? { lastCommandedRPM[index] }
}
