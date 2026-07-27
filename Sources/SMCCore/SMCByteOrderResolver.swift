import Foundation
import os

/// The two SMC firmware interface generations, each with its own rule for how a key's
/// byte order is determined. See `resolveByteOrder(generation:attributes:type:)`.
///
/// Detected once per connection from the `AppleSMC` IOService's own IORegistry
/// provenance — never from `uname -m`/`utsname`. Those report the architecture of the
/// running *process*, not the firmware interface, and lie outright under Rosetta. See
/// `SMCConnection.open()` for where detection happens.
public enum SMCInterfaceGeneration: Sendable, Hashable {
    /// The Intel-era SMC, reached as an ACPI embedded-controller device.
    case legacy
    /// The Apple Silicon SMC, reached over the always-on coprocessor's RTKit mailbox.
    case modern
}

/// Byte order for a decoded scalar.
public enum SMCByteOrder: Sendable, Hashable {
    case littleEndian
    case bigEndian
}

/// Resolves the byte order of a numeric SMC key from firmware-declared metadata.
///
/// This is deliberately the only function in the codebase that knows about the bit-`0x04`
/// hypothesis. Every citation and every condition that would falsify the hypothesis is
/// documented here, and nowhere else, so that if the hypothesis is falsified the retreat
/// is a change to this one function.
///
/// [ADR 0003](../../docs/ADR/0003-integer-byte-order.md) established the rule for the six
/// plain-integer types. [ADR 0004](../../docs/ADR/0004-float-byte-order.md) extended it to
/// `flt`/`ioft`, which this function previously decoded unconditionally little-endian by
/// type, bypassing this resolver entirely. Read ADR 0004 before changing anything below.
///
/// ## The rule
///
/// - **The plain integers** (`ui16`, `si16`, `ui32`, `si32`, `ui64`, `si64`) **and,
///   since ADR 0004, `flt`/`ioft`:**
///   - **`.legacy`** (Intel-era SMC): the plain integers are `.bigEndian` unconditionally,
///     by type; `flt`/`ioft` are `.littleEndian` unconditionally, by type. The attribute
///     byte is **not** consulted for byte order on this generation for either group —
///     VirtualSMC documents bit `0x04` there as `ATTR_ATOMIC`, an unrelated meaning, and
///     applying the modern rule on legacy firmware would actively corrupt Intel readings,
///     not merely leave them unresolved.
///   - **`.modern`** (Apple Silicon SMC): bit `0x04` of `attributes` set → `.littleEndian`;
///     clear → `.bigEndian`. The identical formula for both groups — ADR 0004 found no
///     evidentiary basis to treat `flt`/`ioft` differently from the plain integers on this
///     generation, and the asymmetric failure mode (a silently wrong `F0Mx`, with no
///     fail-safe at all under the prior rule) argued for folding them in rather than
///     carving them out.
/// - **`fpe2`/`fp78`/`sp78`:** `.bigEndian`, unconditionally, on both generations, by
///   *definition* of the type — genuinely fixed, never firmware-declared, never consults
///   the attribute byte. These are Intel-only formats; observing one on `.modern` is not
///   predicted by any hypothesis this project holds (zero occurrences across the 3385 keys
///   enumerated on `Mac16,5`), so this function logs it as an anomaly via
///   `logUnexpectedFixedPointOnModern(type:)` rather than silently returning a
///   plausible-looking answer.
/// - **Every other type** (`ui8`, `si8`, `flag`, and the non-numeric types) has no
///   meaningful byte order — a single byte, or no numeric interpretation at all — and
///   falls through to the plain-integer formula above harmlessly: `SMCValue.scalar()`
///   never consults the result for those types.
///
/// ## Evidence (`Mac16,5`, macOS 26.5.2 — see `docs/SMC-RESEARCH.md`, ADR 0003, ADR 0004)
///
/// **The plain-integer half** — 97 supporting cases, zero clean counterexamples. Two
/// results carry the conclusion beyond a magnitude heuristic:
///
/// - `B0AV` (pack voltage, `ui16`, attrs `132`, bit set) decodes little-endian to
///   **12029 mV** — exactly `BC1V + BC2V + BC3V` (4009 + 4011 + 4009). Big-endian it is
///   64814, which equals nothing. A pack voltage summing to its own cells can only be
///   right by construction.
/// - `#KEY` (`ui32`, attrs `128`, bit clear) decodes big-endian to **3385**, matching the
///   walked index count exactly, with no special case — see
///   `SMCConnection.verifyKeyCountCrossCheck()`, the runtime tripwire on this rule.
///
/// **The `flt`/`ioft` half is a provable no-op on this machine, not new evidence.** All
/// 2073 readable `flt` keys and 10 of 11 readable `ioft` keys carry bit `0x04` **set**, so
/// every one of them resolves little-endian under this rule — exactly the answer the prior,
/// unconditional-by-type rule already gave, verified key by key rather than in aggregate.
/// Every control-path fan key is individually bit-set: `F0Ac`/`F1Ac` (132), `F0Mn`/`F1Mn`
/// (132), `F0Mx`/`F1Mx` (133), `F0Tg`/`F1Tg` (212). The machine contains **no** readable
/// bit-clear `flt`/`ioft` key, so it cannot distinguish "byte order is a property of the
/// type" from "byte order is a property of the bit" for these two types — see ADR 0004's
/// "No cheap local experiment exists" section.
///
/// Independent corroboration, from clean-room sources (documentation consulted, no code
/// adapted — see `docs/SMC-RESEARCH.md` sources table):
///
/// - The [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/)
///   (independent hardware reverse-engineering) documents the Apple Silicon SMC as
///   natively little-endian with a small byte-reversed quirk subset, and names `#KEY` and
///   `B0RM` explicitly — both bit-clear on this machine, both plain integers. It also
///   names `VP3b` as byte-reversed on M1-era hardware. On this M4 Max, `VP3b` is `flt`,
///   attrs `133` (bit set), raw `8020e73f`, decoding little-endian to **1.8057** — bit-set,
///   so it cannot discriminate the two `flt` hypotheses here either, and ADR 0004 does not
///   treat it as corroboration. It is, however, the concrete reminder that a byte-reversed
///   float is a documented phenomenon on other firmware, which is why `flt`/`ioft` are no
///   longer carved out as immune to it. The designated discriminator is an M1/M2 report of
///   `VP3b`'s type, attributes, and raw bytes.
/// - [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/kern_vsmcapi.hpp)
///   documents bit `0x04` on Intel as `ATTR_ATOMIC` and shows Intel data keys with that
///   bit set decoding big-endian like everything else on that generation — confirmation
///   that the bit does not *mean* "little-endian" in general, and that the rule above must
///   never be applied outside `.modern`.
///
/// ## What would falsify this
///
/// - `SMCConnection.verifyKeyCountCrossCheck()` disagreeing, on any machine.
/// - Any bit-set key on `.modern` (integer, `flt`, or `ioft`) that only decodes sanely
///   big-endian, or a bit-clear key that only decodes sanely little-endian.
/// - An Intel report contradicting the unconditional big-endian default for plain integers
///   on `.legacy`, or the unconditional little-endian default for `flt`/`ioft` there.
/// - Apple documenting the attribute byte with a different meaning.
/// - Any hardware report of a readable bit-clear `flt`/`ioft` key — whichever way it
///   decodes, it is the first direct evidence either hypothesis has ever had for these two
///   types. Byte-reversed and bit-clear confirms this rule for floats; byte-reversed and
///   bit-**set** falsifies it (fall back to unconditional little-endian for `flt`/`ioft` on
///   `.modern`, still a one-function change here).
///
/// The `.modern` half of this rule is, as of this writing, a **single-machine
/// observation** and stays a hypothesis until a second machine reports.
public func resolveByteOrder(
    generation: SMCInterfaceGeneration,
    attributes: UInt8,
    type: SMCKeyType
) -> SMCByteOrder {
    switch type {
    case .flt, .ioft:
        switch generation {
        case .legacy:
            return .littleEndian
        case .modern:
            return attributes & 0x04 != 0 ? .littleEndian : .bigEndian
        }
    case .fpe2, .fp78, .sp78:
        if generation == .modern {
            logUnexpectedFixedPointOnModern(type: type)
        }
        return .bigEndian
    default:
        switch generation {
        case .legacy:
            return .bigEndian
        case .modern:
            return attributes & 0x04 != 0 ? .littleEndian : .bigEndian
        }
    }
}

private let byteOrderResolverLogger = Logger(subsystem: "dev.aeolus.SMCCore", category: "ByteOrder")

/// The anomaly log ADR 0004 asks for: `fpe2`/`fp78`/`sp78` are Intel-only formats with a
/// byte order fixed by the type, never firmware-declared. Zero occurrences across the 3385
/// keys enumerated on `Mac16,5` — seeing one on `.modern` would be the first evidence
/// either way about whether these three types can appear there at all, so it is worth a
/// loud log rather than a silent decode.
private func logUnexpectedFixedPointOnModern(type: SMCKeyType) {
    byteOrderResolverLogger.error(
        """
        \(type.fourCharString, privacy: .public) observed on the modern (Apple Silicon) \
        SMC interface — an Intel-only encoding this project has never seen there (zero \
        occurrences on Mac16,5). Decoding big-endian, per its fixed type-defined order, but \
        this is an anomaly worth investigating: see docs/ADR/0004-float-byte-order.md.
        """
    )
}

/// The result of `SMCConnection.verifyKeyCountCrossCheck()`: `#KEY`'s own decoded value
/// against the number of indices a walk of the key table could actually retrieve. See
/// that method's documentation for what this is a tripwire on.
public struct KeyCountCrossCheck: Sendable, Hashable {
    /// `#KEY`'s own decoded value.
    public let declaredCount: Int
    /// The number of indices `0..<declaredCount` for which `key(at:)` succeeded.
    public let walkedCount: Int
    /// Whether a key exists at index `declaredCount` — one past the declared bound.
    ///
    /// The walk that produces `walkedCount` is bounded by `declaredCount`, so on its own
    /// it can only ever detect a declared count that is too *large* (some indices in
    /// `0..<declaredCount` fail). A declared count that is too *small* walks exactly that
    /// many indices, every one succeeds, `walkedCount == declaredCount`, and the walk alone
    /// reports a spurious match while a real key sits one past where the walk stopped
    /// looking and enumeration silently truncates it. This field closes that half of the
    /// blind spot: `true` means the table has at least one more entry than `#KEY` claimed.
    /// Defaults to `false` — "no evidence of undercounting" — for call sites that have not
    /// probed this index; see `matches`.
    public let keyExistsPastDeclaredCount: Bool

    public init(
        declaredCount: Int, walkedCount: Int, keyExistsPastDeclaredCount: Bool = false
    ) {
        self.declaredCount = declaredCount
        self.walkedCount = walkedCount
        self.keyExistsPastDeclaredCount = keyExistsPastDeclaredCount
    }

    /// `true` only when the walk found exactly `declaredCount` keys **and** nothing exists
    /// past that bound — the two-sided check. A one-sided caller that never probed
    /// `declaredCount` itself leaves `keyExistsPastDeclaredCount` at its `false` default,
    /// so `matches` there still reduces to the original `declaredCount == walkedCount`.
    public var matches: Bool { declaredCount == walkedCount && !keyExistsPastDeclaredCount }
}
