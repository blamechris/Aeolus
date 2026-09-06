import SMCCore

// The vocabulary `FanControlPlane` speaks, lifted out of `FanControlPlane.swift` by
// [#128](https://github.com/blamechris/Aeolus/issues/128) — a mechanical move, with every
// type, every case and every doc comment unchanged.
//
// The cut is at the seam's own boundary. `FanControlPlane.swift` keeps the three protocols —
// `FanStateSensing`, `SMCConnectionRecovering`, `FanControlPlane` — and `FanRestoreScope`,
// which is the keystone verb's only parameter and is pinned to that file by
// `WriteAuthorisationTests.theRestoreScopeCarriesNoAuthorisation`. This file keeps what the
// seam reads, returns and throws.
//
// #128's second comment records the +7 lines that put the file over: the
// `FanWriteCapabilityReporting` refinement and the note explaining why the capability is a
// role of its own. Those stay on the protocol declaration, because a conformance list is
// part of the declaration — moving it would put the seam's shape in a different file from
// the seam. What moves is the vocabulary, which has no such tie.

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
    /// `F<n>Tg`, or the reason it could not be obtained. `docs/SAFETY.md` § 5's **primary**
    /// signal, compared against `CommandedTarget`.
    let target: FanRPMReadback
    /// `F<n>Ac`, or the reason it could not be obtained. § 5's **secondary** signal, and
    /// only ever consulted behind a dwell — see `ReclamationLimits.actualDwellCycles` for
    /// why a bare comparison here would read every ramp as a reclamation.
    let actualRPM: FanRPMReadback
}

/// What one RPM key said, or why it said nothing.
///
/// An enum rather than `Double?` because `nil` would mean two different things — "this fan
/// has no target set" and "this target could not be read" — and only the second one blinds
/// the reclamation watchdog. A watchdog that cannot tell them apart reports "no divergence"
/// for a fan it can no longer see.
///
/// **Named for its shape rather than for one of its two uses.** It was `FanTargetReadback`
/// while `F<n>Tg` was the only key that needed it; `FanControlState.actualRPM` is the same
/// question about `F<n>Ac` and wants the same answer, and a second identical enum would be
/// two places for one rule about what an unreadable RPM means. The rename is
/// [#126](https://github.com/blamechris/Aeolus/issues/126)'s, and that issue's text names
/// the old spelling.
enum FanRPMReadback: Sendable, Hashable {
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
///
/// `rpm` is a plain `Double` while `commandTarget(_:)` takes an `AuthorisedFanTarget`, and
/// the asymmetry is deliberate. This is a *record of what happened*, compared numerically
/// against a `FanRPMReadback` that is also a plain number, and it lands in logs and test
/// fixtures. Embedding the permit would make any past command mint future writes without
/// ever touching the read side again — provenance decaying to "an envelope was read once,
/// ever", inside the one type whose job is to be a passive observation.
///
/// The rejected argument for embedding it is that #102's bounded re-assert after
/// reclamation would then be total. [ADR 0007](../../docs/ADR/0007-safety-composition.md)
/// already settles that: the action required to be total is *restore*, which needs no
/// bounds and no read at all. The re-assert branch is explicitly fallible, bounded by an
/// attempt budget, floored by "restore and report", and never runs while any temperature is
/// above ceiling. A re-assert that cannot obtain an envelope should restore, not command.
///
/// - Important: this withholds a free re-assert from the *observation record*; it does not
///   prevent the commanding actor from retaining its own `AuthorisedFanTarget`, since
///   permits do not expire. Freshness before a re-assert is therefore policy held by
///   review, not by the type. Saying otherwise is what an earlier draft of this comment did.
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
    /// Not a stub and not a placeholder: `SMCConnection.write(_:to:)` is SPI-gated
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
