import Foundation

/// The two SMC firmware interface generations, each with its own rule for how a plain
/// integer key's byte order is determined. See `resolveByteOrder(generation:attributes:)`.
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

/// Resolves the byte order of a **plain integer** key (`ui16`, `si16`, `ui32`, `si32`,
/// `ui64`, `si64`) from firmware-declared metadata.
///
/// This is deliberately the only function in the codebase that knows about the bit-`0x04`
/// hypothesis. Every citation and every condition that would falsify the hypothesis is
/// documented here, and nowhere else, so that if the hypothesis is falsified the retreat
/// is a change to this one function — see ADR 0003's designated fallback.
///
/// Does **not** apply to `flt`/`ioft` (little-endian by construction) or
/// `fpe2`/`fp78`/`sp78` (big-endian by definition of the type). Those five types decode
/// unconditionally in `SMCValue.scalar()` and never call this function.
///
/// ## The rule
///
/// - **`.legacy`** (Intel-era SMC): always `.bigEndian`. The attribute byte is **not**
///   consulted for byte order on this generation — VirtualSMC documents bit `0x04` there
///   as `ATTR_ATOMIC`, an unrelated meaning. Applying the modern rule on legacy firmware
///   would actively corrupt Intel readings, not merely leave them unresolved.
/// - **`.modern`** (Apple Silicon SMC): bit `0x04` of `attributes` set → `.littleEndian`;
///   clear → `.bigEndian`.
///
/// ## Evidence (`Mac16,5`, macOS 26.5.2 — see `docs/SMC-RESEARCH.md` and ADR 0003)
///
/// 97 supporting cases, zero clean counterexamples. Two results carry the conclusion
/// beyond a magnitude heuristic:
///
/// - `B0AV` (pack voltage, `ui16`, attrs `132`, bit set) decodes little-endian to
///   **12029 mV** — exactly `BC1V + BC2V + BC3V` (4009 + 4011 + 4009). Big-endian it is
///   64814, which equals nothing. A pack voltage summing to its own cells can only be
///   right by construction.
/// - `#KEY` (`ui32`, attrs `128`, bit clear) decodes big-endian to **3385**, matching the
///   walked index count exactly, with no special case — see
///   `SMCConnection.verifyKeyCountCrossCheck()`, the runtime tripwire on this rule.
///
/// Independent corroboration, from clean-room sources (documentation consulted, no code
/// adapted — see `docs/SMC-RESEARCH.md` sources table):
///
/// - The [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/)
///   (independent hardware reverse-engineering) documents the Apple Silicon SMC as
///   natively little-endian with a small byte-reversed quirk subset, and names `#KEY` and
///   `B0RM` explicitly — both bit-clear on this machine, both plain integers, both
///   squarely within this resolver's own domain. (Asahi separately lists `VP3b` as a
///   byte-reversed quirk key on M1-era hardware; on this M4 Max `VP3b` is declared `flt`,
///   a type this resolver never consults — see the "Does not apply to" note above — so its
///   attribute bit is not evidence for or against the rule below, one way or the other.
///   Whether bit `0x04` matters for `flt` too is a separate, untested question: see
///   issue #35.)
/// - [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/kern_vsmcapi.hpp)
///   documents bit `0x04` on Intel as `ATTR_ATOMIC` and shows Intel data keys with that
///   bit set decoding big-endian like everything else on that generation — confirmation
///   that the bit does not *mean* "little-endian" in general, and that the rule above must
///   never be applied outside `.modern`.
///
/// ## What would falsify this
///
/// - `SMCConnection.verifyKeyCountCrossCheck()` disagreeing, on any machine.
/// - Any bit-set integer key on `.modern` that only decodes sanely big-endian, or a
///   bit-clear key that only decodes sanely little-endian.
/// - An Intel report contradicting the unconditional big-endian default on `.legacy`.
/// - Apple documenting the attribute byte with a different meaning.
///
/// Not addressed here at all: whether this rule's premise — that byte order is a property
/// of *type*, not of *key*, for `flt`/`ioft` — holds. `Mac16,5` cannot falsify it either
/// way (every readable `flt`/`ioft` key on this machine carries bit `0x04` set, so it
/// offers no counterexample regardless of which hypothesis is true), which is exactly why
/// that question is open and tracked separately rather than folded into "what would
/// falsify this" above. See issue #35.
///
/// The `.modern` half of this rule is, as of this writing, a **single-machine
/// observation** and stays a hypothesis until a second machine reports. If it is
/// falsified, the designated fallback (ADR 0003) is: all plain integers little-endian on
/// `.modern`, with `#KEY` handled by the enumeration layer instead of this rule — still a
/// one-function change here.
public func resolveByteOrder(
    generation: SMCInterfaceGeneration,
    attributes: UInt8
) -> SMCByteOrder {
    switch generation {
    case .legacy:
        return .bigEndian
    case .modern:
        return attributes & 0x04 != 0 ? .littleEndian : .bigEndian
    }
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
