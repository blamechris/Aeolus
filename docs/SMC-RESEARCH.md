# SMC Research

This document is the record of what Aeolus has *observed*, as distinct from what the
community reports. The read path has now been measured once, on one machine — see
"Observed behaviour" below, filled in by epic E1. The write path (epic E4) has not been
attempted here: every observation in this document comes from read selectors only, and
nothing below should be read as evidence about the write path.

Two rules govern this file:

1. **Separate observed from reported.** Every claim carries its provenance. A community
   write-up describing an M2 Air is not evidence about an M4 Max.
2. **Cite every source and honour its licence.** SMC key semantics come from published
   open-source projects and public research. Where code is adapted rather than
   reimplemented, it is attributed here and its licence is carried with it. Nothing in
   this project comes from decompiling a commercial tool — see
   [CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Test hardware

The machine available to this project:

| Model identifier | Chip | macOS | Notes |
|---|---|---|---|
| `Mac16,5` | Apple M4 Max (12P/4E, 64 GB) | 26.5.2 (25F84) | Sole development machine |

That is one Mac, from the M3-and-newer generation. It means:

- The hardest write path — the M3+ `Ftst` unlock — **can** be tested here.
- The M1/M2 path, on which the naive mode write reportedly just works, **cannot**.
- The Intel path (`FS!` bitmask, `fpe2` encoding) **cannot** be tested at all.
- Desktop thermal behaviour — iMac, Mac mini, Mac Studio, Mac Pro — is unavailable.

Everything outside that single row ships marked "untested" until somebody reports
otherwise. See [HARDWARE-MATRIX.md](HARDWARE-MATRIX.md).

---

## Reported behaviour, not yet verified here

Everything in this section is summarised from community sources listed at the bottom. It
is the starting hypothesis for E1 and E4, and it should be treated as something to test
rather than something to implement against.

### Encoding by declared type

| | Apple Silicon | Intel |
|---|---|---|
| Fan RPM | little-endian IEEE-754 float (`flt`) | big-endian 14.2 fixed point (`fpe2`, value = RPM << 2) |
| Force manual | `F0Md` per-fan mode key (plus `Ftst` on M3+) | `FS!` bitmask, bit *n* = fan *n* |

Aeolus reads each key's declared type from the SMC and encodes accordingly rather than
branching on architecture. See [ARCHITECTURE.md](ARCHITECTURE.md#key-on-the-declared-type-never-on-the-architecture).

**To verify (E1):** that the declared types on `Mac16,5` match the table; that `flt` really
is little-endian here; whether any key declares a type not in our registry.

### The M3+ manual-control rejection

Reported: `thermalmonitord` holds the fans in mode 3, and a naive `F0Md = 1` write is
rejected with SMC error `0x82`. The sequence that reportedly works:

1. Write `F0Md = 1` directly. Succeeds on M1/M2, and on M3+ when the system is not
   actively asserting control.
2. On rejection, write `Ftst = 1`.
3. Wait for the thermal manager to yield — reported at roughly 3 seconds. **Poll for the
   condition; do not sleep a fixed interval.**
4. Retry the mode write within a bounded budget. Community implementations use figures
   around 300 attempts at 100 ms.
5. Write the target RPM to `F0Tg`.
6. On release, restore automatic mode **and** write `Ftst = 0`.

**To verify (E4):** every step, on `Mac16,5`. In particular the actual yield latency, the
retry budget genuinely required, and whether the reported ~3 s figure holds under load.

### Sleep resets the force key

Reported: sleep/wake resets `Ftst` in firmware and the system reclaims the fans, so manual
control silently stops working after the lid closes unless the unlock sequence is re-run.

**To verify (E4):** whether reclamation is detectable promptly by comparing actual against
target RPM, and how quickly re-assertion can happen after wake without racing the system.

### Sensors outside the SMC

Reported: some Apple Silicon thermal sensors are exposed through `IOHIDEventSystemClient`
rather than the SMC — this is what `powermetrics` reads.

**To answer (E1):** whether Aeolus needs both providers or the SMC alone is sufficient on
Apple Silicon. `SensorProvider` exists so either answer is absorbable, but the answer
should be recorded here with the enumeration that produced it.

---

## Observed behaviour

**Machine:** `Mac16,5`, Apple M4 Max (12P/4E, 64 GB), macOS 26.5.2 (25F84), on AC power,
lid open, idle at the start of the session. One machine, one snapshot, 2026-07-25. None of
this generalises to Intel, M1, or M2 Macs, or to any other machine — see
[HARDWARE-MATRIX.md](HARDWARE-MATRIX.md), which keeps saying `untested` for all of them.

**Method:** a throwaway enumeration tool (`smcdump.swift`, not repo code), calling
`IOConnectCallStructMethod` selector 2 with read selectors only — `READ_INDEX` (8),
`READ_KEYINFO` (9), `READ_BYTES` (5). **No write selector was issued at any point in this
session.** A second, separate throwaway spike (`iohid_spike.swift`) exercised
`IOHIDEventSystemClient` for the sensor-overlap question in the last subsection below.
Both are ad hoc research tools, not something this project ships or maintains.

### Enumeration and index integrity — agrees

`#KEY` reports **3385** (`ui32`, raw `00000d39`, big-endian → 0x0D39 = 3385). Enumerating
index 0..3384 yields exactly that many keys — no hard-coded key list is needed on this
machine, which satisfies the E1 acceptance criterion directly.

Three keys fail `READ_KEYINFO` outright and carry no type at all: `BDFU`, `CH0J`, `CHLS`.
Enumeration has to tolerate this — a key can appear in the index and still have no
retrievable metadata.

### `flt` is little-endian — agrees, decisively

| Key | Raw | As LE Float32 | As BE Float32 |
|---|---|---|---|
| `F0Mn` | `00c0a844` | **1350.00** | 1.769e-38 |
| `F0Mx` | `0088b445` | **5777.00** | 1.255e-38 |
| `F0Ac` | `57e2a744` | **1343.07** | 4.984e+14 |
| `TB0T` | `9899f541` | **30.70** | -3.980e-24 |

Little-endian yields round RPM figures and plausible Celsius temperatures. Big-endian
yields denormals and nonsense. This matches the reported table above.

### Disagreement 1 — temperatures here are `flt`, not `sp78`

368 keys begin with `T`, and they are **not** all one type:

| Declared type | Count |
|---|---|
| `flt ` | 356 |
| `ioft` | 9 |
| `si32` | 3 |

**`sp78`, `fp78`, `fpe2`, and `{fds` appear exactly zero times on this machine.** Those are
the Intel encodings; our registry carries all four, and none of them can be exercised here.

The reported table earlier in this document presents `sp78` as "the classic Intel
temperature encoding" — accurate, but easy to misread as *the* temperature encoding. On
this Apple Silicon machine, `sp78` is not used at all: the dominant temperature encoding is
`flt`, the same one used for fan RPM.

**Do not read that as "every `T` key is `flt`."** Twelve are not, and the nine `ioft` keys
(`TG0B`, `TG0C`, `TG0H`, `TG0V`, `TG1B`, `TG2B`, `TR0Z`, `TR1d`, `TR2d`) are real
temperature sensors carrying a completely different encoding — see the `ioft` finding
below. Code that keys off the `T` prefix to infer a type will silently mishandle them. The
prefix is a naming convention; the declared type is the only thing that decides the decode.

### Disagreement 2 — six declared types are missing from the registry

Full type distribution across all 3385 keys:

| Type | Count | In `SMCKeyType`? |
|---|---|---|
| `flt ` | 2073 | yes |
| `hex_` | 318 | yes |
| `ui8 ` | 245 | yes |
| `ui16` | 236 | yes |
| `ui32` | 223 | yes |
| `si32` | 84 | **no** |
| `ch8*` | 53 | yes |
| `flag` | 50 | **no** |
| `si16` | 49 | yes |
| `ui64` | 23 | **no** |
| `ioft` | 11 | **no** |
| `si8 ` | 8 | yes |
| `si64` | 5 | **no** |
| `{jst` | 4 | **no** |
| (keyinfo failed) | 3 | — |

**177 keys — 5.2% of the machine — fall through to `.unknown`**, which `isNumeric` reports
as `false`. They are displayable as raw bytes but never usable as readings. Four of the six
missing types are trivially numeric: `flag` is 1 byte and only ever `00` or `01` across all
50 keys observed (a boolean); `si32` is 4 bytes little-endian signed; `ui64` and `si64` are
8 bytes little-endian. `{jst` is left as structured/opaque; see the `ioft` finding below for
the sixth.

### Disagreement 3 — `F0Ac` reads below `F0Mn`

`F0Ac` (1343.07 RPM, actual) reads **below** `F0Mn` (1350 RPM, the declared minimum) on
this idle machine. Actual fan speed is not bounded by the declared minimum. Any code that
assumes `actual >= min` — a gauge, a health check, a "fan stopped" heuristic — is wrong on
this hardware. Clamping applies to *targets* written by Aeolus, never to values *read* from
the SMC; observed reality does not have to respect the bound the firmware itself declares.

### `ioft` decodes as little-endian 48.16 fixed point — derived by this project, not sourced

**This finding did not come from any community source consulted for the reported-behaviour
section above.** No source described the `ioft` type at all. The decode below was worked
out by this project from the raw bytes, and it needs to be read as such — distinguishable
from a format taken from documentation.

All 11 `ioft` keys are 8 bytes. Read as a little-endian `UInt64` and divided by 65536, they
produce coherent temperatures:

| Key | Raw | LE u64 / 65536 |
|---|---|---|
| `TG0B` | `33b31e0000000000` | 30.70 °C |
| `TG0C` | `00001e0000000000` | 30.00 °C |
| `TG1B` | `00801e0000000000` | 30.50 °C |
| `TR0Z` | `9ad9330000000000` | 51.85 °C |
| `TR1d` | `43b6290000000000` | 41.71 °C |
| `TR2d` | `707a2b0000000000` | 43.48 °C |

`TG0B` reads 30.70, exactly matching `TB0T` (`flt`, 30.70) on the same idle machine — one
piece of corroboration. A second, independent one: `TR0Z` decodes to **51.850**, and
`IOHIDEventSystemClient`, an entirely separate measurement path (see below), independently
reports the same physical sensor — `PMU tcal` — as **51.850**. Two unrelated reads agreeing
to three decimals is strong confirmation. Confidence: high on the format, upgraded from
"plausible" to "confirmed" by the IOHID cross-check; medium on the sensor *name* — worth one
confirming pass under thermal load, where the values should move together.

### Fan topology and the `Ftst` key

Two fans, `F0` and `F1`. Every fan key present on this machine:

| Key | Type | Raw | Meaning |
|---|---|---|---|
| `F0Mn` / `F1Mn` | `flt` | `00c0a844` | **1350 RPM** minimum, both fans |
| `F0Mx` / `F1Mx` | `flt` | `0088b445` | **5777 RPM** maximum, both fans |
| `F0Ac` | `flt` | `57e2a744` | 1343.07 RPM actual |
| `F1Ac` | `flt` | `383eb644` | 1457.94 RPM actual |
| `F0Tg` / `F1Tg` | `flt` | — | 1350.00 / 1458.00 target |
| `F0Md` / `F1Md` | `ui8` | `00` | mode — 0 = automatic |
| `Ftst` | `ui8` | `00` | **present on `Mac16,5`** |

**`Ftst` exists and is `ui8`.** The M3+ unlock key the community describes is really
present on this machine. This does **not** prove the unlock sequence works — that requires
a write and belongs to E4 — it only confirms the precondition holds.

`{fds` is absent, so there is **no fan descriptor struct to read names from** on this
machine. Fan naming on Apple Silicon needs another source; this is direct input into E6
(sensor catalog).

### The attribute byte — bit `0x80` is "readable", necessary but not sufficient

Perfect correlation across all 3385 rows: every key that read successfully has bit 7 set,
and no key with bit 7 clear ever read successfully. 52 keys correctly declare themselves
unreadable this way.

But the bit is **necessary, not sufficient**. A further 52 keys set bit 7 and still return
an SMC error on `READ_BYTES`. They cluster obviously — `rBK0`–`rBKa`, `rLD0`–`rLD5`,
`bVUP`, `bVDN`, `aP70`–`aP80` — and read as action/trigger keys rather than data.

Implication for enumeration: filter on the attribute bit as a cheap first pass, then let
the read fail gracefully anyway. A failed read of one key must never abort enumeration of
the rest.

### `dataSize` reaches 120 bytes — the 32-byte struct payload is not enough

`SMCKeyData_t` carries a 32-byte `bytes[]` field, and every community implementation
consulted for this document reads through it. On this machine, 30 keys declare sizes above
32 bytes:

    33, 37, 40, 42, 44, 48, 53, 56, 64, 96, 100, 112, 120

Examples: `ATP0` (96 bytes), `ATC0` (53), `AP1A` (44). None of the 30 is a fan or
temperature key — all are `hex_`/`ch8*` configuration blobs — so this does not block the
monitoring path. It does need a decision in E1: either chunked reads, or these keys are
surfaced with metadata but no value. Silently truncating to 32 bytes is the one option that
is wrong, because it fabricates data.

### `READ_BYTES`'s own `dataSize` reads back as 0 — only `READ_KEYINFO` populates it reliably

Every community implementation consulted for this document reads the payload size from the
`keyInfo.dataSize` field of the *same* reply that carries the bytes — offset 28 of
`SMCKeyData_t`, on a `READ_BYTES` (selector 5) response. On `Mac16,5`, that field reads back
as **0 on every observed `READ_BYTES` reply, including successful ones.** The payload bytes
themselves are present and correct; only the reply's own account of how many are valid is
wrong. A `READ_KEYINFO` (selector 9) reply against the same key populates `dataSize`
reliably, matching the table in "Enumeration and index integrity" above.

This was not caught by the `smcdump.swift` spike described in the Method paragraph — it
surfaced building the production `SMCConnection` for E1.2 (issue #29), which initially sized
the returned payload from the `READ_BYTES` reply's `dataSize` field. Every call reported
success and returned zero bytes: a silent, total failure indistinguishable from working code
until the values were inspected. The fix sizes the payload from the `dataSize` the caller
already obtained from a prior `READ_KEYINFO` call, rather than trusting the `READ_BYTES`
reply's own field — the same approach the enumeration spike used from the start, which is
why the spike's dumps were never affected. Both now agree, and `SMCConnection.read(_:)`
documents the reasoning inline at `call(key:selector:data32:dataSize:)`.

The failure mode is what makes this worth recording here rather than letting it stay in a
PR body: it does not throw, does not log, and does not fail a health check. It produces
empty reads while reporting success, on a struct the eventual E4 write path shares. Anyone
implementing against `SMCKeyData_t` from a community reference that reads `dataSize` off the
`READ_BYTES` reply will hit exactly this on this machine.

### Byte order is **not** uniform — it is firmware-declared per key

This is the most consequential finding in this document, and an earlier draft of this
section got it wrong. Byte order is **not** a property of the declared type.

`si32`, `ui64`, and `si64` all produce sane magnitudes little-endian and absurd ones
big-endian (e.g. `BACC`: 110,928 LE versus 5.8e18 BE), consistent with `flt`. But `ui16`
and `ui32` — 459 keys between them — are **mixed**, and the split tracks bit `0x04` of the
firmware-declared attribute byte: set → little-endian, clear → big-endian.

Measured across every decidable multi-byte integer key on this machine: **87 bit-set keys
decode sanely little-endian, 10 bit-clear keys decode sanely big-endian, and there are no
clean counterexamples.** Two results carry the conclusion beyond a magnitude heuristic:

- `B0AV` (pack voltage, `ui16`, attrs 132, bit set) reads **12029 mV** little-endian —
  exactly `BC1V + BC2V + BC3V` = 4009 + 4011 + 4009. Big-endian it is 64814, which equals
  nothing. A pack voltage summing to its own cells can only be right by construction.
- `#KEY` (attrs 128, bit **clear**) decodes **big-endian** to 3385, matching the walked
  index count exactly — see the enumeration section above, which bootstraps on precisely
  this decode.

Other observed big-endian keys: `B0RM` = 6238 mAh (attrs 144), `F0Fc` = 7 (128),
`RBID` = 6 (128), `RCRV` = 17 (128). Little-endian reads of these give 24088, 1792,
100663296 and 285212672 respectively.

**The big-endian decode path is therefore exercised on this machine, not untested** — the
entire key enumeration depends on it. What remains untested here is the Intel *type* set
(`fpe2`, `fp78`, `sp78`, `{fds`), which no key on `Mac16,5` declares.

The decision this drove is recorded in [ADR 0003](ADR/0003-integer-byte-order.md) (now
**Accepted**); the fix to `SMCValue.scalar()` shipped in issue #30, via
`resolveByteOrder(generation:attributes:)` in `Sources/SMCCore/SMCByteOrderResolver.swift`.
The attribute-bit half of the rule is a single-machine observation and stays that way
until a second machine reports.

#### Interface generation, detected from IORegistry provenance

ADR 0003 requires the SMC interface generation to come from the `AppleSMC` IOService's own
IORegistry provenance, never from `uname -m`. Observed on `Mac16,5`: the service matched by
`IOServiceMatching("AppleSMC")` declares `IOProviderClass` as `"RTBuddyEndpointService"` —
the modern SMC is reached over the always-on coprocessor's RTKit mailbox, not a direct ACPI
device, consistent with Asahi's description of the SMC as an RTKit endpoint service.
`SMCConnection.smcGeneration(for:)` resolves this to `.modern`, unconditionally scoping the
attribute-bit rule to the modern interface as ADR 0003 requires.

Two runtime checks pass live on this machine as a result: `SMCConnection.verifyKeyCountCrossCheck()`
— the `#KEY`-versus-walked-index-count tripwire — reports a match, and `B0AV`, read live,
equals `BC1V + BC2V + BC3V` read live (both exercised in `Tests/SMCCoreTests/SMCConnectionTests.swift`,
gated on `isDevelopmentMachine()`). The legacy (Intel) branch — `IOProviderClass` containing
`"ACPI"` — is not observed on any hardware available to this project; it follows documented
community sources (VirtualSMC and others) and ships `untested` like the rest of the Intel
path.

### The `IOHIDEventSystemClient` question — answered: the SMC alone is sufficient

`IOHIDEventSystemClient` (usage page `0xff00`, usage `0x0005`) enumerates **46 temperature
service instances, 21 distinct named sensors** on this machine: `PMU tdie1`–`tdie10`, `PMU
tdev1`–`tdev8`, `PMU tcal`, `NAND CH0 temp`, `gas gauge battery`. No entitlement or elevated
privilege was required to read this page.

Both providers were dumped back to back and compared **by value, not by name**:

- **19 of the 21 distinct IOHID sensors have an SMC key reading within 0.15 °C.** Several
  agree closely or exactly: `PMU tcal` = `TR0Z` = 51.850 (see the `ioft` corroboration
  above), `PMU tdev7` 62.709 vs. `TS0P` 62.71, `PMU tdev5` 31.931 vs. `TaRT` 31.93.
- The 2 that missed — `PMU tdie6` 60.895, `PMU tdie10` 60.787 — fall 0.32 °C outside the
  SMC `TPD*`/`TRD*` die cluster (57.68–60.47 °C) in this snapshot. The two dumps are not
  atomic, and the machine warmed over the course of the session; this reads as drift
  between two non-simultaneous reads, not a sensor location the SMC lacks.
- Coverage is not close: **365 numeric SMC `T*` keys spanning 0–113.83 °C**, against 21
  IOHID sensors topping out at 62.71 °C. The SMC is a strict superset of what IOHID exposed
  here.

**Decision: the SMC alone is sufficient. Do not add a second `SensorProvider` backed by
`IOHIDEventSystemClient`.** Doing so would mean `dlopen`ing undocumented, private IOKit
symbols for no thermal information the SMC does not already carry on this hardware.
`SensorProvider` remains the seam that would absorb the opposite answer if another machine
ever contradicts this.

This answer is scoped to `Mac16,5`, one snapshot, macOS 26.5.2. It is not generalised to
Intel or M1/M2 hardware, or to any other machine.

### Untestable on this hardware

`fpe2`, `fp78`, `sp78`, and `{fds` were not exercised by any observation in this document,
because no key on `Mac16,5` declares them. Codec tests for those types have to be written
against synthetic byte patterns derived from documented behaviour, not from a measurement,
and [HARDWARE-MATRIX.md](HARDWARE-MATRIX.md) keeps marking Intel and M1/M2 support
`untested` until someone reports from that hardware.

Note that the **big-endian decode path itself is not** in that category — it is exercised
here by `#KEY` and roughly a hundred other keys, as recorded above. What is untested is
the Intel type set, not big-endian decoding as such. Conflating the two is what an earlier
draft of this document did, and it would have led an implementer to make `ui16`/`ui32`
unconditionally little-endian — which decodes `#KEY` as 957,153,280 instead of 3385 and
breaks key enumeration outright.

---

## Sources

To be expanded as they are consulted. Each entry records what was taken from it and under
what licence.

| Source | Used for | Licence |
|---|---|---|
| `agoodkind/macos-smc-fan` | Research write-up on the M3+ unlock sequence | To be confirmed before any adaptation |
| `exelban/stats` issue #2928 | Community discussion of the `0x82` rejection | Discussion only, no code |
| `raminsharifi/MacFanControl` | Prior art on the Apple Silicon path | To be confirmed before any adaptation |
| `tw93/Mole` issue #1119 | Community discussion of fan control on recent silicon | Discussion only, no code |
| `smcFanControl` (hholtmann) | Prior art on the Intel path | GPL — compatible with this project |
| [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) | Independent, clean-room hardware reverse-engineering corroborating the little-endian-with-quirks model behind ADR 0003, and naming `#KEY`/`B0RM`/`VP3b` specifically | Documentation consulted, no code adapted |
| [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/kern_vsmcapi.hpp) | Documents attribute bit `0x04` as `ATTR_ATOMIC` on Intel, which is why ADR 0003's byte-order rule is scoped to the modern interface only | Documentation consulted, no code adapted |

**Before adapting code from any of these**, confirm the licence, record it above, and
attribute it in the source file. Reading a project's documentation and reimplementing from
the described behaviour is not adaptation; copying its implementation is, and carries its
licence with it.
