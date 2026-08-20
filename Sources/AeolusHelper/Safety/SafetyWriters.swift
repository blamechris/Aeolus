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
// control loop uses it. Because neither conforms to a shared writing protocol, no code can
// be generic over "a writer" and hand a safety actor the governed one by accident — the
// substitution is not expressible, rather than merely discouraged.
//
// The mutation that proves this is not decorative: point `ThermalEmergency.writer` at a
// `GovernedFanWriter` and its single maximum write becomes a staircase of 200 RPM steps,
// which turns `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite` red. The
// arithmetic behind that number is in `RampGovernor`.

/// The writer for actor levels 1 to 5: panic, thermal emergency, reclamation, sleep/wake,
/// lease expiry.
///
/// Every write goes straight to the firmware. There is no rate limit, no dwell, no budget
/// and nothing between this and `FanControlPlane` — which is the point, and is why the
/// level it carries is a `SafetyActorLevel.Ungoverned` rather than a `SafetyActorLevel`:
/// the control loop cannot be given one of these at all.
///
/// ## What it still cannot do
///
/// It does not widen anything. `commandMaximum(of:)` takes a `CommandableFan`, so a fan
/// whose declared bounds failed the plausibility gate cannot be commanded through here
/// either — § 2's closing rule, that the only action such a fan is subject to is the
/// bounds-free restore verb, holds for safety actors exactly as it holds for the control
/// loop. Bypassing § 8 is not bypassing § 2, and conflating those two would be ADR 0007's
/// conflict 4 with the classes swapped.
struct SafetyActorWriter<Plane: FanControlPlane>: Sendable {

    private let plane: Plane

    /// Which safety actor is writing. Provenance for a log line and for the arbiter; never
    /// an input to the arithmetic, because there is no arithmetic here to vary.
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
        try await plane.commandTarget(fan.target(for: fan.envelope.highestCommandableRPM))
    }

    /// The keystone verb. Needs no bounds, no reading, and no lease — see
    /// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) and `FanControlPlane`.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await plane.restoreToAutomatic(scope)
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
/// ## Not built on: there is no control loop yet
///
/// Nothing in `Sources/` calls this. Actor level 6 arrives with the write path in E3/E4,
/// and hysteresis — § 8's other half — arrives with the curve evaluator in
/// [#17](https://github.com/blamechris/Aeolus/issues/17). What exists here is the governor
/// and the boundary it sits behind, built in #125 because ADR 0007's ruling that § 8 never
/// delays a safety-actor write was, until now, a rule about a mechanism that did not exist
/// to break it — see [#121](https://github.com/blamechris/Aeolus/issues/121) and
/// `RampGovernor`.
actor GovernedFanWriter<Plane: FanControlPlane> {

    private let plane: Plane
    private let governor: RampGovernor

    /// The last target written per fan. Cleared when a fan goes back to automatic, because
    /// a remembered target would then ramp from a speed nothing is holding.
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

    /// Forgets a fan's ramp state, because it went back to Apple's thermal management.
    func fanReturnedToAutomatic(index: Int) {
        lastCommandedRPM[index] = nil
    }

    /// What this writer would ramp from, for tests and diagnostics.
    func lastCommanded(ofFan index: Int) -> Double? { lastCommandedRPM[index] }
}
