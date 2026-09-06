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
  `ioft` keys, 10 are bit-set; the sole bit-clear key (`pcHS`, attrs `0xF0`) declares itself
  **readable** (bit `0x80` is set) but has never yielded bytes across 965 probes under varied
  machine state — see issue #52 and the "No cheap local experiment exists" section below for
  the full accounting, which corrects an earlier characterisation of this key as simply
  "unreadable." **The machine contains no readable key that can distinguish "the type is
  little-endian" from "the bit is set."** Every local observation supports both hypotheses
  equally.
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
`package` — **corrected: it is `@_spi(FanWrite) public` as of the 2026-09-06 amendment in
[ADR 0008](0008-write-authorisation.md); `package` never reached the Xcode helper target**),
throwing on `nil` for multi-byte numeric types — **changed now, while it has zero
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

**Revisit when:** any hardware report shows a readable bit-clear `flt`/`ioft` **data** key —
whichever way it decodes, it is the first direct evidence either hypothesis has ever had; when
E4's `F0Tg` round trip runs; and above all when any M1/M2 report shows `VP3b`'s type,
attributes, and raw bytes. Byte-reversed and bit-clear confirms this rule; byte-reversed and bit-**set** falsifies it
for floats (fall back to unconditional LE); not reversed at all dates Asahi's observation to a
particular firmware. That single observation is the designated discriminator, and the E10a
`fanctl` dump subcommand exists partly to collect it.

## No cheap local experiment exists — this is measured, not assumed

An earlier revision of this ADR stated flatly that the discriminating population on `Mac16,5`
— readable, bit-clear, `flt`/`ioft` — was **empty**, and named `pcHS` as an "unreadable"
bit-clear `ioft` candidate. **That was wrong.** It rested on a characterisation carried over
from the original enumeration spike, which logged `pcHS` as `READ_FAILED` without inspecting
its attribute byte. `pcHS` declares itself readable (bit `0x80` set); it is *gated*, not
unreadable, and the two are different claims. Issue #52 tracked down what the gate is.

**The investigation.** `pcHS` was probed 965 times on `Mac16,5` across five conditions:
battery idle, battery under sustained 12-way CPU load, a 300-read 50 ms hammer, a 10-minute
1 Hz watch, and two full-table walks. **965 rejections, zero bytes.** `READ_KEYINFO` was
stable throughout every probe: `ioft`, 8 bytes, attributes `0xF0`. Combined with the
2026-07-25 AC-idle enumeration that first surfaced this key, `pcHS` has never returned bytes
under AC idle, battery idle, battery under load, rapid retry, or a sustained watch. **Not
tried:** sleep/wake, the first minutes after boot (uptime at the time of this investigation
was 5 days), an AC re-test in the same session as the battery runs, and Low Power Mode. Anyone
extending this investigation should start with those, not repeat the five above.

**The structural explanation**, verified independently against the full enumeration: attribute
bit `0x10` is `SMC_KEY_ATTRIBUTE_FUNCTION` (VirtualSMC's `AppleSmc.h`; also documented by
Intel). **All 52 firmware-rejected keys on this machine carry it — zero exceptions.** The
converse does not hold: **308 bit-`0x10` keys read fine**, including all nine `ioft`
temperature sensors (`TG*`/`TR*`, attrs `0x94`). The bit means "served by a firmware function
handler," and only some handlers reject a plain read. The four observed rejection codes map to
documented Intel result names — `0x82` `SmcBadCommand`, `0x89` `SmcBadArgumentError`, `0xc7`
`SmcDeviceAccessError`, `0xcb` `SmcUnsupportedFeature` — which supports the namespace carrying
over to Apple Silicon, but that is **an assumption, not an observation**, since none of the
four has been independently verified against Apple Silicon firmware source. Asahi's quirks
section documents this exact cluster from the other side: "`rLD0` etc. cannot be read
normally, but can be read with a `0x00000001` or `0x00ffffff` payload. Maybe that's related to
the 'flags' byte being `0xf0`." **The gate is the request shape, not machine state** — a plain,
payload-less `READ_BYTES` is not a valid command for a function key, and no machine-state
variable this investigation varied was ever going to change that.

**The verdict: this ADR's decision is unchanged, and stays undetermined on the
attribute-bit-for-floats question exactly as before.** It always rested on failure-mode
asymmetry, never on local evidence — see the Rationale above. What was wrong was purely this
section's *evidence accounting*: calling `pcHS` "unreadable" when its attribute byte says
readable-but-function-gated overstated how empty the discriminating population was, and
understated what kind of empty it is.

`pcHS` was also always a weaker lead than hoped, independent of whether it ever yields bytes.
A function key's payload comes from a firmware function handler, not the data path that serves
an ordinary `flt` control key like `F0Mx`; even a successful `pcHS` read would have been weak
evidence about how ordinary `flt`/`ioft` **data** keys decode. And within the function-key
population, attribute bit `0x04` visibly tracks nothing checkable from here: `pcHS` (`0xF0`,
bit `0x04` clear) and `aDCR` (`ioft`, `0xF4`, bit `0x04` set) both never return data, so the
bit's presence or absence predicts nothing observable in this population either way.

**The M1/M2 `VP3b` report stays the designated discriminator, and is now strictly stronger**
than it was: `VP3b` is an ordinary, non-function `flt` **data** key (attrs 133, bit `0x10`
clear), so unlike `pcHS` it bears directly on the same data path that serves `F0Mn`/`F0Mx`. No
change is needed to the `fanctl dump --key VP3b` request this ADR already designates for
collecting it.
