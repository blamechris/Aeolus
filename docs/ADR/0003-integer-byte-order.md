# ADR 0003 — Integer byte order is resolved from firmware-declared metadata, not from the declared type alone

- **Status:** Accepted, amended by [ADR 0004](0004-float-byte-order.md)
- **Date:** 2026-07-25
- **Deciders:** Project maintainer
- **Supersedes:** — (amends the "key on the declared type" principle in ARCHITECTURE.md)
- **Amended by:** [ADR 0004](0004-float-byte-order.md) — extends per-key byte-order
  resolution to `flt` and `ioft` on the modern interface

> **Read ADR 0004 before implementing against this one.** This ADR scopes per-key byte
> order to the plain integers and decodes `flt`/`ioft` little-endian unconditionally by
> type. ADR 0004 found that carve-out unsupported by the evidence and extends the resolver
> to cover them on the modern interface. Everything else here — the generation split, the
> attribute-bit rule, the fail-safe, the `#KEY` cross-check — stands unchanged.

## Context

The project's founding codec principle was: read each key's declared type from the SMC and
decode according to that type; never branch on the architecture. A full enumeration of all
3385 keys on the development machine (`Mac16,5`, M4 Max, macOS 26.5.2) shows the principle
is incomplete: **the declared type does not determine byte order for the plain integer
types** (`ui16`/`ui32`/`si16`/`si32`/`ui64`/`si64`).

Observed on `Mac16,5`:

- Ordinary integer data keys are **little-endian**. `B0AV` (`ui16`, raw bytes `fd2e`) reads 12029 mV
  little-endian — exactly the sum of the three cell voltages `BC1V + BC2V + BC3V`
  (4009 + 4011 + 4009). Big-endian it is 64814, which is nonsense.
- A minority (~19 non-zero keys, 114 total) are **big-endian**: `#KEY` = 3385 (matches the
  walked index count exactly), `RBID` = 6, `RCRV` = 17, `B0RM` = 6238 mAh, `F0Fc` = 7.
  Little-endian these are all garbage.
- The split correlates **perfectly** with bit `0x04` of the key's firmware-declared
  attribute byte: set → little-endian, clear → big-endian. Zero clean counterexamples
  across every decidable multi-byte integer key on the machine.

Independent corroboration, from clean-room sources:

- The [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/)
  (independent hardware reverse-engineering, no macOS tools involved) documents the Apple
  Silicon SMC as natively little-endian with a small set of byte-reversed quirk keys — and
  names `#KEY` and `B0RM` explicitly. Both carry bit `0x04` clear in our dump.
- Asahi also lists `VP3b` as byte-reversed on M1-era hardware. On our M4 Max, `VP3b` is
  declared `flt`, not a plain integer — a type this ADR's resolver never consults, since
  `flt` decodes little-endian unconditionally by type (see Decision below). Its attribute
  bit being set here is therefore not evidence for or against the resolver's rule, one way
  or the other; it says nothing about whether the bit tracks quirk migration for the class
  this ADR actually governs. Whether the same migration Asahi describes for `VP3b`
  recurs among the plain integers this resolver governs is untested on this machine.
  Whether it recurs for `flt` itself — where this project has no fail-safe at all — is
  tracked separately as issue #35.
- [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/kern_vsmcapi.hpp)
  documents bit `0x04` on **Intel** as `ATTR_ATOMIC`, and its Intel key databases show
  data keys with `attr [84]` that are big-endian like everything else on Intel. So the bit
  does not *mean* "little-endian"; on Apple Silicon the correlation is structural (which
  firmware path serves the key), and the rule must never be applied to the legacy
  interface.

Also relevant: on Intel-era SMCs, all integer keys are big-endian (abundantly documented;
untestable here). The fixed-point types `fpe2`/`fp78`/`sp78` are big-endian *by
definition of the type* and exist only on the legacy interface; `flt` and `ioft` are
little-endian and observed only on the modern one. **The only types whose byte order is
genuinely underdetermined by the type are the plain integers — exactly the types that
exist on both interface generations.**

One further fact bounds this ADR's own scope: **no control-path key is a plain integer**,
the only class the resolver below governs. Fan RPM is `flt` (always LE by type) or `fpe2`
(always BE by type); temperatures are `flt`/`ioft`/`sp78`; mode keys (`F0Md`, `Ftst`,
`FNum`) are single-byte `ui8`; Intel's `FS!` bitmask is `ui16` but exists only on the
legacy interface, where big-endian is unconditional. So the resolver, and its fail-safe,
never touch a control-path value, by construction — that much is true by exhaustive
enumeration of the control-path key set, not by measurement.

That is a narrower claim than "no control-path key is ambiguous," and the narrower claim
is the one this ADR can actually support. Whether attribute bit `0x04` also governs byte
order for `flt`/`ioft` themselves — decoded unconditionally little-endian in this decision,
never through the resolver — is a separate question this ADR does not answer and cannot:
on `Mac16,5`, all 2073 readable `flt` keys and 10 of 11 readable `ioft` keys carry bit
`0x04` set, so this machine contains no key that could falsify "the bit only governs plain
integers" (what is implemented) against "the bit governs every type" (untested) — both
hypotheses predict the same little-endian result for every `flt`/`ioft` key this hardware
can read. Tracked as issue #35, `safety-critical` because `flt` is the write-path encoding
target on Apple Silicon and has no fail-safe of its own: unlike a plain integer, a wrong
guess there does not decline and log, it silently returns a wrong number.

## Decision

**The declared type determines the format. Byte order for plain integers is resolved per
key from two pieces of firmware-declared metadata:**

1. **The SMC interface generation**, detected once per connection from the SMC service's
   own IORegistry provenance (never from `uname -m`/`utsname`, which reports the process,
   not the firmware — Rosetta makes it lie):
   - **Legacy** (Intel-era SMC): plain integers are big-endian, unconditionally. The
     attribute byte is never consulted for byte order — bit `0x04` means `ATOMIC` there.
   - **Modern** (Apple Silicon SMC): byte order is per-key.
2. **On the modern interface only**, the key's attribute bit `0x04`: set → little-endian,
   clear → big-endian.

`#KEY` needs no special case under this rule: attribute `0x80` (bit clear) → big-endian
on modern; legacy default → big-endian on Intel. Enumeration nevertheless cross-checks the
decoded `#KEY` count against the actual walked index count and logs loudly on mismatch —
a free runtime tripwire on the entire hypothesis, exercised at every startup on every
machine.

**Fail-safe:** if the interface generation cannot be determined, plain-integer keys
surface raw bytes with no scalar (`scalar()` returns `nil`), and the condition is logged.
Guessing is worse than declining: a wrong reading presented confidently is the failure
mode this project's rules exist to prevent. Every control-path type decodes by type alone,
never through this resolver, so this fail-safe never reaches one — whether attribute bit
`0x04` would matter for those types too, had this resolver been asked to consult it, is
the separate question tracked as issue #35, not a claim this fail-safe depends on.

`#KEY` is the one exception to "surface raw bytes only": without a key count nothing can
be enumerated, control path included, so `SMCConnection.keyCount()` decodes it directly as
big-endian in the enumeration layer — a guess, not a resolved fact, validated on every
connection by the cross-check below. See `decodeKeyCountFallback(value:)` in
`Sources/SMCCore/SMCConnection.swift`.

Mechanically: the read layer resolves a `ByteOrder` per key at read time and stores it on
`SMCValue`; `scalar()` consumes it for plain integers only. The resolution policy lives in
one function, with the citations and the falsification criteria in its doc comment.

## Rationale

- It is the only model that decodes **every** observed key on the only machine this
  project can test correctly. Every alternative leaves known-wrong values on the very
  hardware used for verification.
- It is the project's stated epistemology applied honestly: ask the firmware, honour the
  answer. The firmware declares the attribute byte per key, exactly as it declares the
  type. We widen "declared type" to "declared metadata"; we do not abandon it.
- It would handle quirk migration for free among the plain integers it actually governs,
  the class where a static table would need per-generation entries. The one migration case
  actually on record, `VP3b`, turned out on inspection to be `flt` on this machine — outside
  this resolver's domain, so it is not an instance of this benefit, just a reminder that the
  benefit is scoped to plain integers. See issue #35 for whether the same migration risk
  exists for `flt` itself.
- Its failure mode is bounded: if the attribute hypothesis fails on some other machine,
  the damage is wrong display-grade integers plus a tripwire firing at startup — never a
  wrong fan bound, RPM, or temperature.

## Alternatives considered

### Per-type endianness with `#KEY` special-cased

Keep "type determines everything", flip `ui16`/`ui32` to little-endian, and carve out
`#KEY`. Rejected: the observed byte-reversed population is ~19 non-zero keys, not one.
`B0RM` (battery mAh, a reading a user will actually look at) would display 24088 instead
of 6238 — a confidently wrong number. And the first exception invites the next; within
three hardware reports the "exception" is a quirk table, i.e. the next alternative, but
grown ad hoc.

### A static per-key quirk table

Honest about endianness being per-key, but the table must come from somewhere, and a table
built from any one machine's observations is wrong on the others once firmware quirks
migrate between generations — this is not incompleteness, it is active wrongness that
tracks firmware revisions we cannot enumerate. (Asahi's own M1-era report of `VP3b` as
byte-reversed, compared against this machine, was this ADR's original illustration of that
migration risk — but `VP3b` is `flt` here, outside a plain-integer quirk table's domain
entirely, so it illustrates the general risk of static tables tracking firmware revisions
without actually being an instance of the plain-integer table changing under it. The
argument against a static table stands on the general point regardless.) It is also
exactly the hard-coded key list the architecture rejects for discovery, reintroduced
through the codec.

### Treat `#KEY` as protocol metadata outside the codec

Defensible in itself — `#KEY` is the index-table size, not a sensor, and `keyCount()` is
already a dedicated API — and the enumeration layer keeps that shape. Rejected *as the
answer* because it addresses one key out of ~19 and leaves the actual finding (hundreds of
little-endian integer keys decoded big-endian) untouched.

### Modern-interface = little-endian, no attribute bit (the fallback)

Decode all plain integers little-endian on the modern interface, big-endian on legacy,
`#KEY` handled by the enumeration layer. Simpler, and rests only on facts corroborated by
Asahi. Costs: ~19 keys of visible garbage on the reference machine, including `B0RM`.
**This is the designated fallback if the attribute-bit hypothesis is falsified** — the
code structure (one resolver function) makes the retreat a one-function change, which is
why the riskier-but-correct rule is acceptable now.

### An unscoped attribute-bit rule (both generations)

Rejected outright: VirtualSMC's Intel databases show big-endian data keys with bit `0x04`
set (`ATTR_ATOMIC`). Applying the rule on legacy hardware would corrupt exactly the
platform we cannot test. Scoping to the modern interface is mandatory, which is why the
generation bit exists in the model at all.

## Assumptions and what would invalidate them

| Assumption | Provenance | If it fails |
|---|---|---|
| Modern-interface integers are LE with a BE quirk subset | Observed (3385 keys) + Asahi | Model is wrong at the root; full revisit |
| Bit `0x04` tracks the quirk subset on modern | **Observed on one machine only** | Fall back to modern-LE + enumeration-layer `#KEY`; one-function change |
| Intel integers are all BE; bit `0x04` = `ATOMIC` | Documented (VirtualSMC et al.), untestable here | Intel path ships `untested` regardless; first Intel report validates |
| Generation is detectable from IORegistry provenance | To be implemented and verified in E1 | Fail-safe already specified: raw-only integers, logged |
| M1/M2 behave like the M4 (modern) | Assumed, untested | Tripwire fires at startup; report captures the dump |
| Bit `0x04` governs plain integers *only*, never `flt`/`ioft` | **Unfalsifiable on `Mac16,5`** — every readable `flt`/`ioft` key is bit-set, so this machine cannot distinguish that from "the bit governs every type" | See issue #35; `flt` is the write-path encoding target and has no fail-safe if wrong |

**Revisit this decision when:** the `#KEY` tripwire fires on any machine; any hardware
report shows a bit-`0x04`-set integer key that only decodes sanely big-endian (or
vice versa); Apple documents the attribute byte; an Intel report contradicts the
big-endian default; or issue #35 reaches a decision on whether `flt`/`ioft` should consult
this resolver too.

## Consequences

- `SMCValue` carries a resolved byte order; `scalar()` uses it for plain integers only.
  `flt`/`ioft` stay little-endian and `fpe2`/`fp78`/`sp78` stay big-endian by type,
  unconditionally.
- The enumeration layer must capture the attribute byte (needed anyway for readability
  filtering) and cross-check `#KEY` against the walked count.
- `docs/ARCHITECTURE.md` § "Key on the declared type" is amended: the type determines the
  format; byte order of plain integers is firmware-declared per interface generation and
  per key. The `uname -m` ban stands and gains its real justification.
- `docs/SMC-RESEARCH.md` gains the observations above in the Observed section, and Asahi
  Linux and VirtualSMC in the sources table (documentation consulted; no code adapted).
- Write-path encoding (E3/E4) must use the same resolver in reverse. Round-trip tests are
  mandatory before any write ships.
- `#KEY` is decoded directly, big-endian, in the enumeration layer
  (`SMCConnection.decodeKeyCountFallback(value:)`) when the interface generation cannot be
  determined — a guess, not a resolved fact, and the one exception to "plain integers
  surface raw bytes only." Without it, an undetectable generation would take out
  enumeration entirely, not just the display-grade integers the fail-safe is meant to
  degrade. `verifyKeyCountCrossCheck()` validates the guess on every connection.
- Whether attribute bit `0x04` governs `flt`/`ioft` byte order, in addition to the plain
  integers this ADR resolves, is unestablished and unfalsifiable on `Mac16,5` — tracked as
  issue #35, `safety-critical` because `flt` is the write-path encoding target on Apple
  Silicon.
