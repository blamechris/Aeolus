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
/// of it; `F<n>Md` answers one question, whose fan it is. A type that carried the richer
/// vocabulary down here would invite somebody to read a curve out of a mode byte.
///
/// **Two cases, though Apple's management reads two bytes.** Every consumer decides a fan Apple
/// has stopped exactly as it decides one Apple is spinning, so a third case would be a third arm
/// with the same body everywhere ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s P1′
/// amendment). Code that needs the byte reads it raw, as D3 does.
enum FirmwareFanMode: Sendable, Hashable {
    /// The system owns the fan. The safe state, and the destination of every restore.
    case automatic
    /// The fan is off automatic control.
    case manual

    /// The raw `F<n>Md` values Apple's own thermal management leaves: `0` while it spins the fan
    /// and `3` while it has the fan stopped. Defined once, here, with ADR 0014's P1′ amendment as
    /// its provenance: P1 recorded these two values and no other in 41,931 samples on `Mac16,5`
    /// under macOS 27.2, idle and through two loads, with `3` only ever beside a target of 0.
    ///
    /// A value joins the set only on evidence of that grade (the amendment's U0). It never holds
    /// `EngagementRules.engagedRawMode`: D3 can attribute a read-back of that value to the plane's
    /// own write only because Apple's management never produces it.
    static let systemManagedRawModes: Set<UInt8> = [0, 3]

    /// The fold of one raw `F<n>Md` byte: `.automatic` exactly for a byte in
    /// `systemManagedRawModes`, and `.manual` for every other. D3's pre-state
    /// (`EngagementRules.requireAutomatic`) and `init(declaredByFirmware:)` both answer through
    /// this, so the grant's read and the engagement's cannot disagree about one byte.
    init(rawByte: UInt8) {
        self = Self.systemManagedRawModes.contains(rawByte) ? .automatic : .manual
    }
}

/// What one step of an engagement achieved ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)
/// D2): the plane's step verb performs one step and reports progress, and `EngagementDriver`
/// owns the cadence between steps. A refusal is a throw, never a third case.
enum EngagementStep: Sendable, Hashable {
    /// The mode write was accepted and read back raw `1` in the same turn (D3 step 2).
    case engaged
    /// The firmware is still holding the fan; the driver asks again after its poll interval.
    case awaitingYield
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
    ///
    /// Also what an engagement step throws for a write the firmware did not answer at all
    /// (`FirmwareWriteAnswer.unanswered`). Either way the write was issued and may have taken
    /// effect (ADR 0014's #410 refused-hand-back amendment, "issued, not landed"), so it is never
    /// retried, and the driver undoes it: the fan's mode at once, and a force key it may have set
    /// once no engaged fan depends on the key (D5's gate; ADR 0014's B1 amendment).
    case firmwareRefusedControl(detail: String)

    /// A target command's in-turn read-back of `F<n>Tg` fell outside
    /// `ReclamationLimits.targetToleranceRPM` of the target it wrote
    /// ([ADR 0004](../../docs/ADR/0004-float-byte-order.md); ADR 0014 D7 and U4): the firmware did
    /// not hold the target, so nothing is returned to report it as commanded. Thrown after the
    /// write, which was issued and may have taken effect, so every caller routes it as it routes a
    /// refused command. Its answer at the boundary is `notConfirmed`'s `helperFailed`, which v1
    /// clients already render.
    case targetNotConfirmed(index: Int, commandedRPM: Double, readBackRPM: Double)

    /// This build has no SMC write path at all.
    ///
    /// Not a stub and not a placeholder: `SMCConnection.write(_:to:)` is SPI-gated
    /// and throws, no write selector exists anywhere in `Sources`, and E5 is the epic that
    /// gates E3 and E4 rather than the one that pre-empts them. Every write verb on
    /// `SMCFanControlPlane` answers with this until those epics land.
    case controlPathNotBuilt

    /// A restore was requested after this engagement's first step, so it writes nothing more (ADR
    /// 0014 D4's restore epoch) — a restore of any fan, this one's and a machine-wide one included
    /// — or its ticket predates a restore, or the plane is sealed for exit (ADR 0014's #410
    /// ticket-and-seal amendment). Thrown only at an admission, before anything is read or written:
    /// a step's, or, once sealed, a target command's (`PlaneWriteLedger.admitCommand()`). The same
    /// discovery after a write is `.supersededAfterWrite`.
    case superseded

    /// A restore was requested during this step's turn, **after its mode write was issued** —
    /// D3 step 3's re-check before `Ftst = 1` — so the force key is not written. The mode write
    /// may have landed: unlike `.superseded`, this is never retried and always undone.
    case supersededAfterWrite

    /// The fan's raw `F<n>Md` was not one the fold calls automatic — `0` or `3`, Apple's set (ADR
    /// 0014's P1′ amendment) — before the first write, so the plane does not take it (D3 step 1).
    /// Nothing was written. Thrown only by a first step. The plane does not say whose the
    /// fan is: level 6 reads the raw value against its own account (ADR 0014's #410
    /// refused-hand-back amendment), and with none it is `foreignManualControl`.
    case notAutomatic(index: Int, rawMode: UInt8)

    /// An engagement's first step was admitted, then failed before it issued any write: its
    /// pre-state read of `F<n>Md`, or a read the mode write needs, did not answer (ADR 0014's #410
    /// refused-hand-back amendment). Nothing was written, so nothing is undone. Thrown only by a
    /// first step: once a step has been answered the engagement has written, and a later step's
    /// failure is thrown as it is. A write that was issued and refused is
    /// `.firmwareRefusedControl`, never this.
    case failedBeforeFirstWrite(index: Int, detail: String)

    /// The mode write was accepted and raw `F<n>Md` did not read back `1` (D3 step 2): `0` is
    /// accepted-not-applied ([#291](https://github.com/blamechris/Aeolus/issues/291)); any
    /// other value is outside the hypothesis and goes back to the architect.
    case engagementNotConfirmed(index: Int, rawMode: UInt8)

    /// A machine-wide restore wrote what it knew and could not know the rest (ADR 0014 D5).
    ///
    /// The bring-up enumeration failed, so `.everyFan` wrote the fans this process touched and
    /// the force key — every write attempted — and fans this process never touched were not
    /// written. `refusedWrite` describes the first of those writes the firmware refused, if
    /// any did. Every caller treats it as a keystone that did not land.
    case fanSetUnknown(refusedWrite: String?)
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

    /// `value` as whole RPM for a log line, total over every `Double`. `Int(_:)` traps on a value
    /// that is not a number or does not fit, which in a root daemon is the helper dying on a log
    /// line; this names such a value instead, and never as zero.
    static func wholeRPM(_ value: Double) -> String {
        Int(exactly: value.rounded()).map(String.init) ?? describe(value)
    }

    private static func describe(_ value: Double) -> String {
        guard !value.isFinite else { return String(value) }
        return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
    }
}
