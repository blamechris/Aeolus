# ADR 0004 — `flt` and `ioft` resolve byte order per key on the modern interface, like the plain integers

- **Status:** Accepted
- **Date:** 2026-07-26
- **Deciders:** Project maintainer
- **Supersedes:** — (amends ADR 0003, which scoped per-key resolution to plain integers)

## Context

[ADR 0003](0003-integer-byte-order.md) established that byte order on the modern interface is
firmware-declared per key via attribute bit `0x04`, but scoped the rule to the six plain-integer
types, holding that `flt`/`ioft` are "little-endian by construction." Adversarial review of the
implementing PR found that claim to be (a) unfalsifiable on the only test machine, (b) supported
by a circular citation, and (c) contradicted by the project's own clean-room source.

Verified by full read-only enumeration on `Mac16,5` (M4 Max, macOS 26.5.2), re-run independently
during this decision rather than taken from the original dump:

- All **2073** `flt` keys carry bit `0x04` **set** — including the 9 unreadable ones. Of 11
  `ioft` keys, 10 are bit-set; the sole bit-clear key (`pcHS`, attrs `0xF0`) is unreadable, and
  Asahi independently notes that `0xF0`-flagged keys do not return values reliably. **The machine
  contains no readable key that can distinguish "the type is little-endian" from "the bit is
  set."** Every local observation supports both hypotheses equally.
- Every control-path fan key is individually bit-set: `F0Ac`/`F1Ac` (132), `F0Mn`/`F1Mn` (132),
  `F0Mx`/`F1Mx` (133), `F0Tg`/`F1Tg` (212). Routing them through the resolver is a decode no-op
  on this machine, verified key by key rather than in aggregate.
- `VP3b` — cited by the resolver's own doc comment as evidence for the attribute-bit rule — is
  `flt` (attrs 133) and therefore **bypassed the resolver entirely** under ADR 0003's scoping.
  The citation was circular.
- The Asahi Linux SMC documentation says of float keys: "In at least one case, the byte order is
  actually reversed," naming `VP3b` on M1-era firmware. Byte-reversed floats are documented to
  exist; "little-endian by construction" is not a safe assumption.

The stakes are not symmetric with the integer case: **`flt` is the control path.** `F0Mx` and
`F0Mn` bound the E5 clamp. Under ADR 0003's scoping, a byte-reversed fan key on any machine
would decode to garbage silently — no `nil`, no log, no tripwire — and a byte-swapped `flt`
misdecode is typically a denormal (≈ 0) or ~1e14. A silently wrong `F0Mx` defeats hard rule 4 at
its root.

## Decision

**On `.modern`, `flt`, `ioft`, and the plain integers all resolve byte order per key from
attribute bit `0x04`, through the single resolver function, which gains the declared type as an
input. On `.legacy`, byte order is fixed per type — integers and fixed-point big-endian,
`flt`/`ioft` little-endian — and the attribute byte is never consulted (`ATTR_ATOMIC` there).
`fpe2`/`fp78`/`sp78` remain big-endian by type on both generations; their appearance on
`.modern` (zero observed) is logged as an anomaly.**

Mechanically: `SMCValue.integerByteOrder` becomes `byteOrder`; its initializer default is removed
so every construction site states the order or states that it is unresolved; `scalar()` for
`flt`/`ioft` consumes it exactly as the integers do, returning `nil` and logging when the
generation is undetectable. The write-path encode API becomes `encode(scalar:byteOrder:)` (still
`package`), throwing on `nil` for multi-byte numeric types — **changed now, while it has zero
callers**, because changing it after E3/E4 means changing the write encoding of a shipped root
helper. Writes resolve the order from a fresh `keyInfo` at write time and are followed by a
mandatory read-back compare that aborts to automatic on mismatch. E5 plausibility-gates decoded
bounds (`0 < F0Mn < F0Mx`, sanity envelope) before manual control is offered.

## Rationale

The two rules are **observationally identical** on the only machine this project can test —
proved by enumeration, not assumed. The choice therefore rests on failure modes on machines we
cannot test, and there the per-key rule weakly dominates: its rival fails silently on a
documented phenomenon (Asahi's byte-reversed floats), while the per-key rule's only novel failure
requires the attribute hypothesis to fail specifically for floats — undocumented anywhere — and
degrades into the same designated fallback ADR 0003 already carries.

It is also the project's epistemology applied consistently: the quirk population Asahi documents
is per-key, not per-type, and includes a float. A type-based carve-out for floats was an
unfalsifiable assertion, not an observation.

Reversal cost is maximally asymmetric. Adopting this now is hours, with provably identical output
on this machine. Adopting it after E3/E4 is a change to the write encoding of a shipped root
helper — re-verification of the unlock and write path on hardware, with a hazard window. Backing
out later, if falsified, stays a one-function change precisely because this keeps the policy
centralized and makes byte order an explicit input everywhere.

## Alternatives considered

### Keep `flt`/`ioft` little-endian by type, unconditionally (ADR 0003's scoping)

The status quo, and not unreasonable: every readable `flt`/`ioft` key on the reference machine is
little-endian, the write path only touches bit-set keys here, and the rule is simpler.

Rejected because its correctness claim cannot be tested on available hardware while the contrary
phenomenon is documented; because it leaves the control path as the only multi-byte class with no
fail-safe, no log, and no tripwire; because it makes the resolver's own supporting citation
(`VP3b`) circular; and because adopting per-key resolution later means changing the write
encoding after E4 — a migration on a root component with hardware risk, versus hours now.

### Extend the bit rule to the fixed-point types as well

A fully uniform "on modern, the bit decides everything." Rejected: `fpe2`/`fp78`/`sp78` have zero
occurrences on modern hardware here and no source describes their behaviour there; extending the
rule would fabricate semantics with no evidence. By-type plus an anomaly log is the honest scope.

## Assumptions and what would invalidate them

| Assumption | Provenance | If it fails |
|---|---|---|
| Bit `0x04` tracks byte order for `flt`/`ioft` on `.modern` | Inferred: consistent with all local observations (which cannot discriminate) + Asahi's type-agnostic quirk model | Fall back to unconditional LE for the float class on `.modern` — one-function change |
| `flt` on `.legacy` is little-endian | Documented (VirtualSMC SDK host-order decode); untestable here | Legacy ships `untested`; first Intel report validates |
| Key attributes are stable between enumeration and write time | Unverified | Writes already re-resolve from fresh `keyInfo`; verify stability across sleep/boot in E4 |

**Revisit when:** any hardware report shows a readable bit-clear `flt`/`ioft` key — whichever way
it decodes, it is the first direct evidence either hypothesis has ever had; when E4's `F0Tg`
round trip runs; and above all when any M1/M2 report shows `VP3b`'s type, attributes, and raw
bytes. Byte-reversed and bit-clear confirms this rule; byte-reversed and bit-**set** falsifies it
for floats (fall back to unconditional LE); not reversed at all dates Asahi's observation to a
particular firmware. That single observation is the designated discriminator, and the E10a
`fanctl` dump subcommand exists partly to collect it.

## No cheap local experiment exists — this is measured, not assumed

The discriminating population on `Mac16,5` — readable, bit-clear, `flt`/`ioft` — is **empty**.
Every avenue was checked: the only bit-clear `ioft` candidate (`pcHS`, `0xF0`) never returns
bytes; the 9 unreadable `flt` keys are bit-*set*; every independently cross-checkable key
(`B0AV` against its cell sum, `TR0Z` against IOHID's `PMU tcal`, `TG0B` against `TB0T`) is
bit-set and so confirms both hypotheses equally; and round trips are prohibited before E5 and
would, on this machine, only ever exercise the bit-set direction anyway.

That negative result is itself worth recording: it is why this ADR rests on failure-mode
asymmetry rather than on local evidence, and why the M1/M2 `VP3b` report is the designated
discriminator.
