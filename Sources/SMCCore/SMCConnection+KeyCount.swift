import Foundation
import os

// `#KEY`'s decode, apart from the read that feeds it: `SMCConnection`'s own statics, pure and
// synchronous, touching none of a connection's state. `keyCount()` reads `#KEY` in
// `SMCConnection.swift` and hands the value here. They moved here unchanged in the sync of `main`
// into `e4/bring-up`, which took `SMCConnection.swift` past SwiftLint's 1000-line `file_length`
// error; neither side's file exceeded it alone. Nothing here reads, writes or opens the SMC.

extension SMCConnection {
    /// The largest `#KEY` decode this project will trust as a genuine firmware value,
    /// rather than a byte-order decode fault.
    ///
    /// `Mac16,5` reports 3385. No hardware report this project has seen — its own dump or
    /// any community source cited in `docs/SMC-RESEARCH.md` — describes an SMC key table
    /// within even one order of magnitude of six figures; the most densely instrumented
    /// Macs documented anywhere are in the low thousands. 100,000 is roughly 30x
    /// `Mac16,5`'s own count: generous headroom for a Mac with meaningfully more sensors
    /// than any observed so far, while sitting almost four orders of magnitude below the
    /// one byte-swap artefact this project has actually measured — `#KEY`'s own raw bytes
    /// (`00000d39`) decode to 957,153,280 read little-endian instead of the correct
    /// big-endian 3385 (see ADR 0003). This ceiling only has to separate "any plausible
    /// key table" from "a byte order got flipped"; it does not need to be tight, and
    /// picking it wide keeps a legitimately larger future Mac from tripping it.
    static let maxPlausibleKeyCount = 100_000

    /// Sanity-bounds a decoded `#KEY` value before it is trusted to size an allocation or
    /// bound a loop — the fix for the scenario `SMCError.implausibleKeyCount` documents.
    ///
    /// Pure and synchronous, deliberately not private, so the exact failure value ADR 0003
    /// records (957,153,280, `#KEY` misdecoded little-endian on `Mac16,5`) is directly
    /// unit-testable via `@testable import SMCCore` without hardware — see
    /// `SMCConnectionKeyCountPlausibilityTests`.
    static func validatePlausibleKeyCount(_ count: Int) throws -> Int {
        guard count >= 0, count <= maxPlausibleKeyCount else {
            logger.fault(
                """
                #KEY decoded to \(count, privacy: .public), outside the plausible range \
                0...\(maxPlausibleKeyCount, privacy: .public). Refusing to use it to size \
                an allocation or bound an enumeration — this is ADR 0003's byte-order \
                tripwire firing on a decode fault, not a real key count. See \
                docs/ADR/0003-integer-byte-order.md.
                """
            )
            throw SMCError.implausibleKeyCount(declared: count)
        }
        return count
    }

    /// Everything `keyCount()` does after its one `READ_BYTES`: decode `#KEY`, convert it to an
    /// `Int`, and sanity-bound it.
    ///
    /// A `#KEY` that declares a non-numeric type is refused first, as
    /// `SMCError.nonNumericKeyCount`. No byte order would turn that type into a count, so
    /// whether the generation is known does not matter to it.
    ///
    /// The firmware declares `#KEY`'s type, and `scalar()` decodes whatever it declares. A
    /// `flt` can decode to NaN, ±infinity or a fraction, and a fixed-point type (`fpe2`,
    /// `fp78`, `sp78`, `ioft`) to a fraction. A `ui64` or `si64` of 2^63 − 512 or more decodes
    /// to 2^63 or above, because `Double` rounds it up. `Int(_: Double)` traps on
    /// all of those except the fraction, which it silently truncates. A trap here would end
    /// the root helper (through `ReadOnlyFanAuthority` and `readAll()`) and `fanctl` on a
    /// firmware value they should refuse, before `validatePlausibleKeyCount(_:)` could see
    /// it. `Int(exactly:)` returns `nil` for every one of them, and the value is refused as
    /// `SMCError.unrepresentableKeyCount`.
    ///
    /// **A fractional count is refused, never rounded.** No key count is fractional, and
    /// rounding or truncating one would make up a count nothing declared. `SMCFanEnumeration`
    /// refuses a fractional `FNum` by the same rule; until #531 it rounded one.
    ///
    /// `scalar()` declines a numeric type only when the value's byte order was never resolved,
    /// which `read(_:)` leaves `nil` exactly when the generation is unknown. Then
    /// `decodeKeyCountFallback(value:)` gets its one chance, at a `ui32`, and anything it
    /// refuses is `SMCError.integerByteOrderUndetectable`.
    ///
    /// Pure and synchronous, and deliberately not private, for the same reason as
    /// `validatePlausibleKeyCount(_:)`. `SMCConnection` has no scripted transport, so this is
    /// the seam through which a test can hand `#KEY` a value no real Mac has produced. See
    /// `SMCConnectionKeyCountDecodeTests`.
    static func decodeKeyCount(value: SMCValue) throws -> Int {
        guard value.type.isNumeric else {
            logger.fault(
                """
                #KEY declares \(value.type.fourCharString, privacy: .public), which is not a \
                numeric type, so it has no key count to decode. See SMCError.nonNumericKeyCount.
                """
            )
            throw SMCError.nonNumericKeyCount(type: value.type, bytes: value.bytes)
        }

        let decoded: Int
        if let scalar = try value.scalar() {
            guard let whole = Int(exactly: scalar) else {
                logger.fault(
                    """
                    #KEY (\(value.type.fourCharString, privacy: .public)) decoded to \
                    \(scalar, privacy: .public), which is not a whole number within Int's \
                    range. Refusing it rather than converting it, since the conversion would \
                    trap or truncate. See SMCError.unrepresentableKeyCount.
                    """
                )
                throw SMCError.unrepresentableKeyCount(type: value.type, bytes: value.bytes)
            }
            decoded = whole
        } else if let fallback = decodeKeyCountFallback(value: value) {
            decoded = fallback
        } else {
            throw SMCError.integerByteOrderUndetectable(key: SMCKey.keyCount)
        }

        return try validatePlausibleKeyCount(decoded)
    }

    /// Decodes `#KEY` directly as big-endian, bypassing
    /// `resolveByteOrder(generation:attributes:type:)` and `SMCValue.scalar()` entirely,
    /// for the one case both of those correctly refuse:
    /// the SMC interface generation could not be determined for this connection.
    ///
    /// This is ADR 0003's own designated fallback shape for exactly this situation —
    /// "`#KEY` handled by the enumeration layer instead of this rule" — because without a
    /// key count `SMCSensorProvider.readAll()` cannot enumerate a single reading, control
    /// path included, which is a stronger failure than the fail-safe is meant to cause.
    ///
    /// Justification for guessing big-endian specifically here, when every other plain
    /// integer correctly declines rather than guess:
    /// - Unconditionally correct on `.legacy` (Intel), where all plain integers are
    ///   big-endian regardless of the attribute byte — so this guess is right by
    ///   construction on one of the two generations this project models.
    /// - Correct on the only `.modern` case this project has observed: `#KEY` on
    ///   `Mac16,5` carries attribute bit `0x04` clear (128), which
    ///   `resolveByteOrder(generation:attributes:type:)` already resolves to big-endian
    ///   when the generation *is* known — see `SMCByteOrderCapturedBytesTests`.
    /// - The Asahi Linux SMC documentation names `#KEY` explicitly as one of the
    ///   byte-reversed quirk keys on Apple Silicon, independent of and prior to this
    ///   project's own attribute-bit hypothesis.
    ///
    /// This is a guess, not a resolved fact, and is not treated as one:
    /// `verifyKeyCountCrossCheck()` independently validates whatever `keyCount()` returns —
    /// resolved or guessed — against an actual walk of the key table. If `#KEY` were ever
    /// little-endian on some future machine with an undetectable generation, the walk would
    /// not reach the guessed count and the tripwire fires loudly, exactly as it would for a
    /// wrong resolver decode. See issue #35 for the open question of whether attribute bit
    /// `0x04` governs byte order beyond the plain integers this resolver actually covers.
    ///
    /// Scoped to `#KEY` only — `value.key` and `value.type` are checked so a caller cannot
    /// accidentally widen this into a general "guess big-endian" escape hatch for other
    /// plain integers, which must keep declining per the fail-safe. Returns `nil` if either
    /// check fails, or if `bytes` is not the 4 bytes a `ui32` should be (defensive; not
    /// expected, since `SMCValue.scalar()` already validates width before this is reached).
    ///
    /// Also returns `nil` when `value.byteOrder` is set: the generation was known, so there
    /// is nothing to guess, and a guess must never stand in for a resolved order. Inside
    /// `decodeKeyCount(value:)` this is a second line, since `scalar()` decodes every `ui32`
    /// whose order was resolved and this function is reached only when it was not. It is
    /// here so this function keeps its own promise whoever calls it.
    /// `SMCConnectionKeyCountFallbackTests` pins it directly.
    static func decodeKeyCountFallback(value: SMCValue) -> Int? {
        guard
            value.key == SMCKey.keyCount, value.type == .ui32, value.bytes.count == 4,
            value.byteOrder == nil
        else {
            return nil
        }
        let bytes = value.bytes
        let bits =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        return Int(bits)
    }

    /// A second file-private logger on `SMCConnection`, with the same subsystem and category as the
    /// one in `SMCConnection.swift`, so a fault from the decode files where it always did. The
    /// other is `private`, and `private` is file-scoped, so this file cannot reach it.
    private static let logger = Logger(subsystem: "dev.aeolus.SMCCore", category: "SMCConnection")
}
