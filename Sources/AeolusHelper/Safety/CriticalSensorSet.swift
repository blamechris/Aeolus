import FanKit
import SMCCore

/// The temperature keys `docs/SAFETY.md` § 3 compares against its ceiling, per hardware
/// family.
///
/// ## Why this is in code, and why configuration may never supply it
///
/// `CLAUDE.md` rule 5 says a configuration may tune a thermal ceiling downward and never
/// upward, because a safety limit the user can defeat is not a safety limit. The sensor
/// *set* is the same rule one step earlier: a configuration that could name the keys could
/// name a set that never gets hot, which disables § 3 completely while leaving every
/// ceiling constant untouched and every test green. There is no file, no payload and no
/// XPC message that reaches this type. It is compiled in.
///
/// ## Why the set is curated rather than derived
///
/// The obvious implementation — every key beginning with `T`, take the maximum — is
/// actively wrong on this project's development machine, and `docs/SMC-RESEARCH.md`
/// records the measurement that says so in two independent ways.
///
/// 1. **Frozen constants.** `Tf06` reads 98.484375 °C on an idle machine with both fans
///    stopped, and reads *exactly* the same value under a twelve-way load that moves the
///    die cluster 12 °C and spins the fans to 3400 RPM. It is not a measurement of
///    anything thermal. A max-over-all-`T*` set would therefore sit at 98.48 °C
///    permanently — above the 95 °C CPU ceiling — and latch the emergency forever on a
///    machine doing nothing.
/// 2. **Per-core sensors legitimately exceed the ceiling.** Filtering to keys that *do*
///    respond to load is still not enough: the `Tp0*` cluster runs 95.69–111.14 °C during
///    an ordinary `swift build`, while the system's own thermal management sits at
///    2372 RPM against a 5777 RPM maximum — i.e. entirely relaxed. Apple Silicon cores are
///    designed to run there. A set built from them would revoke the user's lease and slam
///    the fans to maximum every time somebody compiled something.
///
/// The die/package cluster is the population a 95 °C ceiling is actually about: it
/// moved 41.48–44.80 °C idle → 53.17–56.07 °C loaded → 55.85–62.40 °C at peak heat
/// soak. Thirty-three degrees of headroom under the ceiling, and it tracks load without
/// ever pretending the machine is in distress.
///
/// ## Adding a family
///
/// A row here is a claim that somebody has *measured* that machine, and `CLAUDE.md`
/// rule 11 forbids claiming hardware support that has not been verified. The bar for a new
/// row is the same evidence `docs/SMC-RESEARCH.md` carries for `Mac16,5`: a
/// `fanctl sensors --json --raw-keys` dump at idle and under load, showing the proposed
/// keys move with load and stay clear of the ceiling when the machine is not in distress.
/// A key list copied from another Mac, or inferred from a naming convention, is exactly
/// the fabrication that rule prohibits — the `TPD`/`TRD` spelling looks generic to Apple
/// Silicon and this project has seen it on precisely one machine.
///
/// **An unrecognised machine resolves to the empty set**, which is blindness, which is no
/// lease. That is deliberate and it is the safe direction: refusing manual control on a
/// machine whose thermal sensors nobody has identified is a product limitation, whereas
/// granting it is a fan controller running with its eyes shut.
struct CriticalSensorSet: Sendable, Hashable {

    /// The curated keys, in no significant order. May be empty — see this type's
    /// documentation for why that is a state rather than a bug.
    let keys: [SMCKey]

    /// What this set is and where it came from, for the log. Diagnostic only; never
    /// parsed, never compared.
    let provenance: String

    var isEmpty: Bool { keys.isEmpty }

    /// This machine's critical set, or the empty set if nobody has measured this machine.
    ///
    /// Keyed on `modelIdentifier`, which `HardwareIdentity` reads from `hw.model` — never
    /// on `uname -m`, and deliberately not on `chipFamily` either. `CLAUDE.md` rule 9 puts
    /// the general principle as "key on the SMC's declared type, never on `uname -m`"; the
    /// same reasoning applies to *which machine this is*, and `chipFamily` is the wrong
    /// granularity for it. "M4 Max" spans laptop and desktop enclosures with different
    /// sensor populations, and this project has enumerated the keys on exactly one of
    /// them.
    static func resolve(for identity: HardwareIdentity) -> CriticalSensorSet {
        guard let model = identity.modelIdentifier else { return .unidentifiedHardware }
        switch model {
        case "Mac16,5": return .mac16x5
        default: return .unidentifiedHardware
        }
    }

    /// `Mac16,5` (M4 Max, 12P/4E): the `TPD*`/`TRD*` die/package cluster.
    ///
    /// Spelled `mac16x5` rather than `mac16_5` only because the underscore trips
    /// SwiftLint's `identifier_name`; the machine is `Mac16,5`.
    ///
    /// Thirty-four keys, enumerated live on 2026-08-20 and recorded in
    /// `docs/SMC-RESEARCH.md`. The suffixes are hexadecimal digits plus `X`, and they are
    /// spelled out rather than generated from a range so that this list is a transcript of
    /// what enumeration returned rather than a guess at a pattern.
    ///
    /// Asking for a key this firmware does not expose is not a failure: the seam reports
    /// it in `CriticalTemperatureReport.unreadableKeys`, and partial loss is a degraded
    /// logged cycle rather than blindness. That is what makes a fixed list safe here.
    static let mac16x5 = CriticalSensorSet(
        keys: dieClusterKeys(prefixes: ["TPD", "TRD"]),
        provenance: "Mac16,5 die cluster (TPD*/TRD*), measured 2026-08-20"
    )

    /// The empty set: a machine nobody has measured.
    ///
    /// Not a fallback in the "sensible default" sense. It carries no keys precisely so
    /// that every consumer treats this machine as blind, which is what
    /// `docs/SAFETY.md` § 3 being a precondition of § 1 requires.
    static let unidentifiedHardware = CriticalSensorSet(
        keys: [],
        provenance: "no measured critical-sensor set for this machine"
    )

    private static func dieClusterKeys(prefixes: [String]) -> [SMCKey] {
        let suffixes = [
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "a", "b", "c", "d", "e", "f", "X",
        ]
        return prefixes.flatMap { prefix in suffixes.map { known(prefix + $0) } }
    }

    /// A key known at authoring time to be four ASCII characters.
    ///
    /// Traps rather than returning an optional, for the same reason `SMCKey.known(_:)`
    /// does: the only failure it can have is a typo in this file, which the test suite
    /// catches rather than a user.
    private static func known(_ raw: String) -> SMCKey {
        guard let key = SMCKey(raw) else {
            preconditionFailure("'\(raw)' is not a valid four-character SMC key")
        }
        return key
    }
}

// MARK: - The plausibility gate

/// The value-level check a curated reading passes before anything compares it to a
/// ceiling.
///
/// Curation, above, is the primary defence and this is the second one. It exists because
/// `docs/SMC-RESEARCH.md` records that **a non-reading on this hardware presents as a
/// clean constant, not as an error**: `Tpx0`–`Tpx5` read exactly 0.00 °C while their
/// cluster is powered down and 81–111 °C under load, and `Tp0*` sits at exactly 40.00 °C
/// at idle. Both decode as well-formed `flt` values that the read path has no reason to
/// complain about, so a gate that only rejects non-finite values believes both.
enum CriticalTemperaturePlausibility {

    /// A reading must be **strictly above** this to be believed.
    ///
    /// Zero rather than a physically-argued figure like -40 °C, because zero is what the
    /// hardware actually produces for "this sensor is not reporting". A powered Mac's
    /// silicon does not sit at or below 0 °C, and a machine cold enough to genuinely read
    /// there warms past it within seconds of doing any work at all.
    static let minimumPlausibleCelsius = 0.0

    // There is deliberately NO upper bound, and this comment is what stops somebody
    // adding one for symmetry.
    //
    // docs/SAFETY.md § 3's failure asymmetry decides it: over-firing returns fans to
    // automatic — safe and noisy, acceptable — while under-firing is the dangerous
    // direction. An upper bound discards exactly the readings the override exists to act
    // on, so a garbage-decoded 200 °C and a genuine 200 °C would both be silently
    // dropped, and the mechanism would fail closed in the one direction it must not.
    //
    // The permanent-latch worry an upper bound seems to answer is real, and curation is
    // what answers it: Tf06's frozen 98.48 °C never enters the set in the first place.

    /// Excludes readings that cannot be temperatures, folding them into the report's
    /// unreadable keys.
    ///
    /// A rejected reading becomes *unreadable*, not *absent*. The difference matters: if
    /// every curated key is rejected, `CriticalTemperatureReport`'s initialiser refuses to
    /// construct and this throws `criticalTelemetryUnavailable`, which is blindness. A
    /// gate that quietly returned a shorter list would report "nothing is above its
    /// ceiling" for a machine it can no longer see.
    ///
    /// - Note: the comparison is `>`, which is false for `NaN`, so a NaN reading is
    ///   excluded rather than believed. `docs/SAFETY.md` § 3 spells out the inverse trap —
    ///   a NaN *ceiling* disables the override, because every comparison against NaN is
    ///   false — and this is the same hazard on the other operand.
    static func gate(_ report: CriticalTemperatureReport) throws -> CriticalTemperatureReport {
        var believed: [CriticalTemperature] = []
        var rejected: [SMCKey] = []
        for reading in report.readings {
            if reading.celsius > minimumPlausibleCelsius {
                believed.append(reading)
            } else {
                rejected.append(reading.key)
            }
        }
        return try CriticalTemperatureReport(
            readings: believed,
            unreadableKeys: report.unreadableKeys + rejected
        )
    }
}
