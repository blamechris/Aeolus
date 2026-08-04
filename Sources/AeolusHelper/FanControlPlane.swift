import SMCCore

/// The E5/hardware seam: everything E5 needs of the firmware, and nothing else.
///
/// `FanAuthority` is the seam between the privilege boundary and the safety subsystem.
/// This is the seam on the *other* side of the safety subsystem, between it and the SMC.
/// The supervisor, the lease enforcer and startup reconciliation all talk to this; none of
/// them talks to `SMCConnection` or to `SensorProvider` directly.
///
/// ## Internal, like `ConnectionID`
///
/// Declared in `AeolusHelper` rather than in `AeolusXPC` or `SMCCore`, for the same reason
/// `ConnectionID` is: a type a client cannot name is a type a client cannot reach. E2 froze
/// the boundary at seven messages behind `FanAuthority`, and nothing here widens that — the
/// operations below are how E5 speaks to the hardware, not a new thing anyone can ask for.
///
/// ## Why not `SensorProvider`
///
/// `SensorProvider` is a general sensor abstraction whose defining operation is
/// `readAll()`. On this project's development machine `readAll()` costs 2.2 s warm and
/// enumerates 2929 keys, and [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) puts the
/// helper's snapshot on the same single SMC connection. The supervisor reads a handful of
/// curated keys on a tight cycle and must never queue behind a client's snapshot, so its
/// needs are stated here as a handful of named operations — **there is no `readAll()` on
/// this protocol and there must never be one.** Making the scheduling explicit is the point
/// of a separate seam; making every failure mode injectable without hardware is the other
/// half.
///
/// ## The keystone
///
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md) rests every safety mechanism on
/// one principle:
///
/// > Restore-to-automatic is a mode write, and must never depend on trusted data.
///
/// `restoreToAutomatic(_:)` is therefore its own operation, taking nothing but a scope. It
/// consumes no bounds, no clamp, no sensor reading, no lease and no prior call of any kind,
/// because a terminal action that needs a successful read is not available in the one case
/// it exists for — the helper that cannot read. That property is structural here: no
/// trusted value crosses the signature, so none can be depended on.
///
/// ## What conforms
///
/// `SMCFanControlPlane` is the production conformer. Its reads are real; **its writes throw
/// and will keep throwing until E3 and E4 build a write path.** E5 is what gates those
/// epics, so modelling the write side here — while implementing none of it — is the whole
/// shape of this seam. `ScriptedControlPlane`, in the test target, is the scriptable mock
/// every other E5 mechanism is tested through.
protocol FanControlPlane: Sendable {

    // MARK: - Reads

    /// Reads the curated critical temperature keys, as one subset read.
    ///
    /// The set is the caller's — #102 curates it in code, per family, never from
    /// configuration — so it crosses as a parameter rather than being fixed here.
    ///
    /// - Throws: `FanControlPlaneError.criticalTelemetryUnavailable` when **no** requested
    ///   key produced a usable reading, including when the requested set is empty. A
    ///   supervisor that cannot see any temperature is blind, and blindness must not arrive
    ///   as a successful report of nothing — see `CriticalTemperatureReport`.
    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport

    /// Reads one fan's firmware-declared envelope, `F<n>Mn` and `F<n>Mx`.
    ///
    /// Reported exactly as declared. Whether an envelope is *plausible* is
    /// `FanControlEnvelope.validating(...)`'s judgement, not this seam's, and this seam must
    /// not pre-empt it by rounding, flooring or omitting a declaration it dislikes.
    ///
    /// - Important: **A declared minimum of zero is accepted, not refused.** Some firmware
    ///   really does say it — `docs/RECOVERY.md` records that fans stopping at idle is
    ///   normal on many Macs — so refusing to lease such a fan would deny manual control on
    ///   legitimate hardware. What keeps `CLAUDE.md` rule 3 true there is the *floor*:
    ///   targets clamp to `[max(F0Mn, minimumManualRPM), F0Mx]`, so zero is uncommandable
    ///   whatever the firmware declares. The plausibility gate binds the **maximum**
    ///   instead. This paragraph exists because an earlier draft of this comment said the
    ///   opposite, and an implementer honouring it would have added a `> 0` refusal and
    ///   regressed every Mac whose fans idle at rest.
    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope

    /// Reads one fan's control state: `F<n>Md` and the `F<n>Tg` read-back.
    ///
    /// Both halves in one subset read, because both consumers want them together: startup
    /// reconciliation asks "is this fan in manual with nobody holding it", and the
    /// reclamation watchdog compares this read-back against the target it last commanded.
    func readControlState(ofFan index: Int) async throws -> FanControlState

    // MARK: - The keystone

    /// Returns fans to the system's own thermal management.
    ///
    /// The terminal action of every safety mechanism, and the only operation on this
    /// protocol that takes no reading, no bound and no lease. It must stay that way: see
    /// this protocol's documentation.
    ///
    /// `.everyFan` additionally clears the Apple Silicon force key. It resolves the fan set
    /// from knowledge the conformer already holds — never from a read issued here, because
    /// a restore that must first read cannot run while reading is what has failed.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws

    // MARK: - Manual control

    /// Takes one fan off the system's thermal management: `F<n>Md`, plus whatever unlock
    /// the platform needs. The opposite direction to `restoreToAutomatic(_:)`, and
    /// deliberately not the same operation — this one is allowed to fail and be refused,
    /// where the restore verb is the one that has to work.
    func engageManualControl(ofFan index: Int) async throws

    /// Commands a target speed, `F<n>Tg`.
    ///
    /// `rpm` must already be clamped into the fan's envelope and above the manual floor —
    /// the seam writes what it is given. Clamping lives in #101, above this, so that one
    /// place owns it and this one cannot silently disagree with it.
    @discardableResult
    func commandTarget(_ rpm: Double, ofFan index: Int) async throws -> CommandedTarget
}

// MARK: - Scope

/// Which fans a restore covers.
enum FanRestoreScope: Sendable, Hashable {
    /// One fan.
    case fan(Int)
    /// Every fan the conformer can address, plus the Apple Silicon force key. `SAFETY.md`
    /// §7's panic verb.
    case everyFan
}

// MARK: - Values

/// Whether the firmware says a fan is on Apple's thermal management or on ours.
///
/// Deliberately not `FanKit.FanControlMode`, which distinguishes `manualFixed` from
/// `manualCurve`. That distinction is Aeolus's own intent and the firmware has never heard
/// of it; `F<n>Md` is one bit. A type that carried the richer vocabulary down here would
/// invite somebody to read a curve out of a flag.
enum FirmwareFanMode: Sendable, Hashable {
    /// The system owns the fan. The safe state, and the destination of every restore.
    case automatic
    /// The fan is off automatic control.
    case manual
}

/// One fan's firmware-declared envelope, as read.
struct FanEnvelope: Sendable, Hashable {
    let index: Int
    /// `F<n>Mn`, exactly as declared. Not a floor the observed speed is known to respect —
    /// `F0Ac` was measured at 1343.07 against a declared minimum of 1350 on this project's
    /// development machine.
    let minimumRPM: Double
    /// `F<n>Mx`, exactly as declared.
    let maximumRPM: Double
}

/// One fan's control state at one instant.
struct FanControlState: Sendable, Hashable {
    let index: Int
    /// `F<n>Md`. Never optional: a mode that could not be read is a read failure, because
    /// there is no safe default to stand in for it — "assume automatic" would let a fan
    /// sit pinned with nobody noticing, and that is the failure this whole epic exists to
    /// prevent.
    let mode: FirmwareFanMode
    /// `F<n>Tg`, or the reason it could not be obtained.
    let target: FanTargetReadback
}

/// What `F<n>Tg` said, or why it said nothing.
///
/// An enum rather than `Double?` because `nil` would mean two different things — "this fan
/// has no target set" and "this target could not be read" — and only the second one blinds
/// the reclamation watchdog. A watchdog that cannot tell them apart reports "no divergence"
/// for a fan it can no longer see.
enum FanTargetReadback: Sendable, Hashable {
    case rpm(Double)
    case unreadable(reason: String)
}

/// The target actually put on the wire.
///
/// Returned rather than left to the caller to remember, because a caller mid-ramp is
/// holding two different numbers: the goal it is heading for and the step it wrote this
/// cycle. `F<n>Ac` legitimately lags the goal during a ramp — `docs/SMC-RESEARCH.md`
/// records the fan slewing toward `F<n>Tg` rather than stepping — so a watchdog comparing a
/// read-back against the *goal* would read its own ramp as reclamation. This is the other
/// number.
struct CommandedTarget: Sendable, Hashable {
    let fanIndex: Int
    let rpm: Double
}

/// One critical temperature key's reading.
struct CriticalTemperature: Sendable, Hashable {
    let key: SMCKey
    let celsius: Double
}

/// What one critical-temperature cycle saw.
///
/// **This type cannot be empty.** Its initialiser refuses, which is the single place the
/// supervisor-blindness rule lives so that every conformer — production and mock alike —
/// gets it without restating it. The alternative shape, an array that happens to have no
/// elements, is the defect this repository keeps producing: a successful read of nothing
/// looks exactly like "no sensor is above its ceiling", so the thermal override quietly
/// stops firing and every test still passes.
struct CriticalTemperatureReport: Sendable, Hashable {
    /// Never empty.
    let readings: [CriticalTemperature]
    /// Keys that were asked for and did not answer this cycle. Partial loss is visible
    /// rather than silent: five of six critical sensors is a degraded cycle worth logging,
    /// even though it is not blindness.
    let unreadableKeys: [SMCKey]

    /// - Throws: `FanControlPlaneError.criticalTelemetryUnavailable` when `readings` is
    ///   empty.
    init(readings: [CriticalTemperature], unreadableKeys: [SMCKey]) throws {
        guard !readings.isEmpty else {
            throw FanControlPlaneError.criticalTelemetryUnavailable(
                requestedKeys: unreadableKeys.count)
        }
        self.readings = readings
        self.unreadableKeys = unreadableKeys
    }
}

// MARK: - Failures

/// Why an operation on the seam did not produce what was asked of it.
enum FanControlPlaneError: Error, Sendable, Hashable {
    /// This machine has no well-formed key for that fan index. `F10Md` is five characters
    /// and is not a valid SMC key, so a tenth fan is refused rather than silently answered
    /// — see `SMCFanEnumeration.actualKey(forFan:)`.
    case fanNotAddressable(index: Int)

    /// A read the caller needs did not produce a usable value. `detail` is diagnostic and
    /// is never parsed.
    case readFailed(detail: String)

    /// No requested critical temperature key produced a usable reading.
    ///
    /// Its own case, not a `readFailed`, because it is a distinct condition with a distinct
    /// response: `SAFETY.md` covers divergence of values and does not cover the inability
    /// to obtain them at all. #102 treats this as divergence — restore, report, and refuse
    /// to grant new leases — rather than as a read that can be retried indefinitely while
    /// fans stay pinned.
    case criticalTelemetryUnavailable(requestedKeys: Int)

    /// The firmware refused the control write. On Apple Silicon this is the expected answer
    /// while the thermal manager is holding the fans; see `SMCError.isCommandRejection` for
    /// why the response code alone does not identify that condition.
    case firmwareRefusedControl(detail: String)

    /// This build has no SMC write path at all.
    ///
    /// Not a stub and not a placeholder: `SMCConnection.write(_:to:)` is `package`-scoped
    /// and throws, no write selector exists anywhere in `Sources`, and E5 is the epic that
    /// gates E3 and E4 rather than the one that pre-empts them. Every write verb on
    /// `SMCFanControlPlane` answers with this until those epics land.
    case controlPathNotBuilt
}

// MARK: - The one finiteness rule

/// The single guard every number crossing this seam passes through.
///
/// `SMCValue.scalar()` applies no finiteness check, so a byte-swapped `flt` or `ioft`
/// decodes to `±.infinity` or `.nan` on an otherwise-successful read. `Double.infinity`
/// compares equal to its own `rounded()` and survives arithmetic without ever looking
/// wrong, so a non-finite bound would reach a clamp, a non-finite temperature would reach a
/// ceiling comparison, and neither would fire. `SMCFanEnumeration.checked` already refuses
/// these for the three fan keys it reads; this is the same rule for the keys E5 reads.
///
/// It lives here, on the seam, rather than inside the production conformer, so the mock
/// applies exactly the same rule. A test double that answers a NaN where the real thing
/// would report a fault is a double that hides the bug it was written to catch.
enum FanControlPlaneValue {

    /// A number the seam will hand on, or the failure it refused it with.
    typealias Checked = Result<Double, FanControlPlaneError>

    static func finite(_ value: Double, describing what: String) -> Checked {
        guard value.isFinite else {
            return .failure(
                .readFailed(
                    detail: "\(what) decoded to \(describe(value)) — likely a byte-order "
                        + "fault; see docs/SMC-RESEARCH.md"))
        }
        return .success(value)
    }

    private static func describe(_ value: Double) -> String {
        guard !value.isFinite else { return String(value) }
        return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
    }
}
