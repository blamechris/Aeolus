# ADR 0003 — Integer byte order is resolved from firmware-declared metadata, not from the declared type alone

- **Status:** Proposed
- **Date:** 2026-07-25
- **Deciders:** Project maintainer
- **Supersedes:** — (amends the "key on the declared type" principle in ARCHITECTURE.md)

## Context

The project's founding codec principle was: read each key's declared type from the SMC and
decode according to that type; never branch on the architecture. A full enumeration of all
3385 keys on the development machine (`Mac16,5`, M4 Max, macOS 26.5.2) shows the principle
is incomplete: **the declared type does not determine byte order for the plain integer
types** (`ui16`/`ui32`/`si16`/`si32`/`ui64`/`si64`).

Observed on `Mac16,5`:

- Ordinary integer data keys are **little-endian**. `B0AV` (`ui16`, `fd2e`) reads 12029 mV
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
- Asahi also lists `VP3b` as byte-reversed on M1-era hardware. On our M4 Max, `VP3b` has
  bit `0x04` **set** and decodes little-endian to 1.8057 — a sane 1.8 V rail reading. The
  quirk population migrates between firmware generations, **and the attribute bit tracks
  the migration**. Any static quirk list is therefore wrong across generations, not merely
  incomplete.
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

One further fact shapes the risk: **no control-path key is in the ambiguous class.** Fan
RPM is `flt` (always LE) or `fpe2` (always BE); temperatures are `flt`/`ioft`/`sp78`;
mode keys (`F0Md`, `Ftst`, `FNum`) are single-byte `ui8`; Intel's `FS!` bitmask is
`ui16` but exists only on the legacy interface, where big-endian is unconditional. The
ambiguity affects display-grade readings (battery telemetry, IDs, counters), never a
value that drives or bounds a fan.

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
mode this project's rules exist to prevent. All control-path types decode by type alone
and are unaffected.

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
- It handles quirk migration (`VP3b`) for free, which no static table can.
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

Honest about endianness being per-key, but the table must come from somewhere, and the
evidence says it cannot be right: Asahi's M1-era list marks `VP3b` byte-reversed, while on
the M4 it is native little-endian. A table keyed to any one machine's observations is
wrong on the others — this is not incompleteness, it is active wrongness that tracks
firmware revisions we cannot enumerate. It is also exactly the hard-coded key list the
architecture rejects for discovery, reintroduced through the codec.

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

**Revisit this decision when:** the `#KEY` tripwire fires on any machine; any hardware
report shows a bit-`0x04`-set integer key that only decodes sanely big-endian (or
vice-versa); Apple documents the attribute byte; or an Intel report contradicts the
big-endian default.

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
