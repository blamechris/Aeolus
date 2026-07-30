import Foundation
import SMCCore

/// One SMC reading, or the reason it could not be produced right now — never a bare `0`
/// standing in for either.
///
/// ## An unavailable reading is not zero, and a low reading is not an error
///
/// `F0Ac` was measured at **1343.07 against a declared `F0Mn` of 1350** on this project's
/// development hardware — a reading below the declared minimum is a legitimate
/// observation, not a fault, and it is carried through as `.value(1343.07)` exactly like
/// any other successful read. Nothing in this type clamps a reading into `[minimum,
/// maximum]`; only `FanKit.Fan.clamp(_:)`, on the write path this epic does not touch,
/// is allowed to do that. A read that fails, is refused, or does not decode is
/// `.unavailable`, never `.value(0)` — the fabricated-zero failure mode that reads to a
/// user as "this fan has stopped."
///
/// Mirrors the shape `fanctl` settled on for the same problem (`ListCommand.KeyedValue`,
/// `SensorsCommand.Entry`: a raw key always present, a value and a failure reason mutually
/// exclusive), reimplemented here as an enum rather than imported: `AeolusUI` and `fanctl`
/// are separate unprivileged clients of `SensorProvider`, neither depending on the other,
/// so each carries its own copy of "how do I represent a subset read" rather than coupling
/// the CLI's executable target to the app's library target. The enum (rather than
/// `fanctl`'s two-optional-fields struct) makes "value and reason are mutually exclusive"
/// a fact the type system enforces instead of a convention call sites have to trust.
public struct KeyedReading: Sendable, Hashable {
    /// The raw four-character SMC key that produced (or failed to produce) this reading.
    /// Always present, even when `availability` is `.unavailable` — see `CLAUDE.md`'s
    /// rule that the raw SMC key is always shown alongside any friendly label or rendered
    /// value.
    public let key: String
    public let availability: Availability

    public enum Availability: Sendable, Hashable {
        /// A value was read and it decoded to a finite `Double`. Never clamped, floored,
        /// or otherwise adjusted from what `SensorProvider` reported.
        case value(Double)
        /// The read failed, the key is not present on this machine, or it decoded to
        /// something unusable — including a non-finite `Double`; see
        /// `init(key:outcome:)` for why a *successful* read is still checked before being
        /// trusted. `reason` is human-readable and diagnostic only, never parsed.
        case unavailable(reason: String)
    }

    public init(key: String, availability: Availability) {
        self.key = key
        self.availability = availability
    }

    /// The finite `Double`, or `nil` when unavailable.
    ///
    /// A convenience accessor for call sites (sorting, sparkline history) that only need
    /// "is there a number here" and would otherwise have to re-derive it from
    /// `availability` on every use. Rendering code should still switch on `availability`
    /// directly rather than branch on this being `nil` — that keeps "why is it missing"
    /// available at the point that needs to say so, per `CLAUDE.md`'s labelling rule.
    public var value: Double? {
        if case .value(let value) = availability { return value }
        return nil
    }

    public var isAvailable: Bool { value != nil }
}

extension KeyedReading {
    public static func value(key: String, _ value: Double) -> KeyedReading {
        KeyedReading(key: key, availability: .value(value))
    }

    public static func unavailable(key: String, reason: String) -> KeyedReading {
        KeyedReading(key: key, availability: .unavailable(reason: reason))
    }

    /// Builds a `KeyedReading` from one `SensorProvider.read(keys:)` outcome — the single
    /// seam every fan and sensor value in `AeolusUI` passes through on its way from
    /// `SMCCore` into the view layer.
    ///
    /// Two rules are enforced here, not left to call sites to remember:
    ///
    /// 1. A failed read never decodes to a fabricated `0` — every `SensorReadFailure`
    ///    case below maps to `.unavailable`, never to `.value(0)`.
    /// 2. A *successful* read is still checked for finiteness before being trusted.
    ///    `SMCValue.scalar()` applies no finiteness or magnitude guard on the way out of
    ///    `SMCCore`: a byte-swapped `flt` can decode to `±.infinity`/`.nan`, and
    ///    `Double.infinity == Double.infinity.rounded()` is `true` — a genuine property,
    ///    not a bug — so any code downstream that assumes a plausible RPM or temperature
    ///    must never see a non-finite value reach it. Same defence as `fanctl`'s
    ///    `Formatting.number`/`ListCommand.sanitized`.
    public init(key: String, outcome: Result<SensorReading, SensorReadFailure>) {
        switch outcome {
        case .success(let reading):
            guard reading.value.isFinite else {
                self = .unavailable(
                    key: key,
                    reason:
                        "decoded to a non-finite value (\(Self.describeNonFinite(reading.value))) "
                        + "— likely a byte-order fault; see docs/SMC-RESEARCH.md")
                return
            }
            self = .value(key: key, reading.value)
        case .failure(let failure):
            self = .unavailable(key: key, reason: failure.readableDescription)
        }
    }

    private static func describeNonFinite(_ value: Double) -> String {
        guard !value.isFinite else { return String(value) }
        return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
    }
}
