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

### `flt` decodes little-endian on this machine — agrees, but not decisively about *why*

| Key | Raw | As LE Float32 | As BE Float32 |
|---|---|---|---|
| `F0Mn` | `00c0a844` | **1350.00** | 1.769e-38 |
| `F0Mx` | `0088b445` | **5777.00** | 1.255e-38 |
| `F0Ac` | `57e2a744` | **1343.07** | 4.984e+14 |
| `TB0T` | `9899f541` | **30.70** | -3.980e-24 |

Little-endian yields round RPM figures and plausible Celsius temperatures. Big-endian
yields denormals and nonsense. This matches the reported table above.

**What this table does not establish, and an earlier version of this section overstated:**
every `flt` key on `Mac16,5` — all 2073 of them, these four included — carries
firmware-declared attribute bit `0x04` **set**. The machine contains no readable
bit-clear `flt` key, and of 11 `ioft` keys the single bit-clear one (`pcHS`, attrs
`0xF0`) is not itself unreadable — bit `0x80` is set, so it declares itself readable —
it simply never yields bytes: firmware rejects `READ_BYTES` with result `0x82`. That
means this data can only ever show "bit-set keys decode sanely little-endian" — it
cannot show whether little-endian is a property of the *type* `flt`,
independent of the bit, or a property of the *bit*, coincidentally set on every `flt` key
this hardware happens to expose. Those two hypotheses predict the identical result for
every row above. A negative result, not a decisive one: see
[ADR 0004](ADR/0004-float-byte-order.md), which found this carve-out unsupported for
exactly this reason and folded `flt`/`ioft` into the same per-key attribute-bit resolution
as the plain integers below, rather than leaving them decoded unconditionally by type.

The Asahi Linux SMC documentation, cited in the sources table below, independently reports
that `VP3b` is byte-reversed on M1-era hardware. On `Mac16,5`, `VP3b` is `flt`, attrs 133
(bit set), raw `8020e73f`, decoding little-endian to 1.8057 — bit-set, so, like every
other `flt` key here, it cannot discriminate the two hypotheses above either. **The
standing discriminating request this document records:** an M1/M2 report of `VP3b`'s
declared type, attribute byte, and raw bytes. Byte-reversed and bit-clear would confirm
the attribute-bit hypothesis for floats directly; byte-reversed and bit-**set** would
falsify it; not reversed at all would date Asahi's observation to a particular firmware
rather than to the M1/M2 generation broadly. Running `fanctl dump --key VP3b` and pasting
its output is exactly that report — one command from a source build (`fanctl` is not
distributed as a signed build yet, so this needs `git clone` + `swift build`, not a
download) — and is the field the
[hardware report template](../.github/ISSUE_TEMPLATE/hardware-report.yml) asks for from
every machine, M1/M2 highest priority.

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

**The `TG0B`/`TB0T` match above is evidence for the `ioft` format, not for a battery
meaning.** Neither `TG0B` nor `TB0T` had an established meaning going into that comparison,
so two anonymous keys agreeing with each other confirms only that they read the same
physical sensor — not what that sensor *is*. See "TB0T/TB1T/TB2T versus the real gas gauge
(`AppleSmartBattery`)" below, where an earlier version of this document over-read this
match as battery corroboration that was never actually run.

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

**Confirmed responding under load, not just idle.** The idle snapshot above already showed
`F0Ac` (1343.07) tracking below `F0Tg`'s eventual target. Watched over a session as the
machine warmed under sustained load, `F0Tg` rose from 1350 to 2195 RPM and `F0Ac` tracked
it, rising from 1343 to 2166 RPM — target and actual moving together rather than
independently. That is the "watched that sensor respond" bar `docs/CATALOG.md` sets for
`verified`; the RPM-valued fan keys' basis is no longer a single idle read.

**`F0Md`/`F1Md` remain the weakest of the ten.** Reading `0x00` while `thermalmonitord`
holds both fans in automatic control is consistent with the reported "mode key, 0 =
automatic" convention above (see "The M3+ manual-control rejection"), but nothing has
forced either key to a different value and watched the fans respond to it — that write
belongs to E4, not yet attempted. The catalog reflects this honestly:
`confidence: community`, not `verified`, until a write actually exercises the mode key.

### The attribute byte — bit `0x80` is "readable", necessary but not sufficient

Perfect correlation across all 3385 rows: every key that read successfully has bit 7 set,
and no key with bit 7 clear ever read successfully. 52 keys correctly declare themselves
unreadable this way.

But the bit is **necessary, not sufficient**. A further 52 keys set bit 7 and still return
an SMC error on `READ_BYTES`, spanning **four distinct rejection codes** — `rBK0`–`rBK9`
and `rBKa`, `rLD0`–`rLD5`, `bVUP`, `bVDN`, `aP70`–`aP80` among them. (`rBKa` belongs to this
52-key population but not to the narrower `0x82` group in the table below — it rejects with
`0x89`; see that table for which key belongs to which code.) An earlier draft of this
section called these "action/trigger keys," a characterisation made by feel rather than by
inspecting anything structural. Issue #52 found what actually identifies the population:
all 52 carry attribute bit `0x10` set. See "Bit `0x10` structurally identifies the 52-key
rejection cluster" below for the full breakdown — the bit, not a guess about a key's role,
is what distinguishes this cluster.

Implication for enumeration: filter on the attribute bit as a cheap first pass, then let
the read fail gracefully anyway. A failed read of one key must never abort enumeration of
the rest.

### Bit `0x10` structurally identifies the 52-key rejection cluster (issue #52)

`0x10` is `SMC_KEY_ATTRIBUTE_FUNCTION` in VirtualSMC's `AppleSmc.h`, also documented by
Intel: the bit means "served by a firmware function handler" rather than "a plain data
value." **All 52 keys on `Mac16,5` that set bit 7 (readable) and still reject
`READ_BYTES` carry bit `0x10` — zero exceptions.** The rejection codes returned, by count,
each itemised so that a key's membership in one code and not another is never a matter of
inference:

| Code | Documented Intel name | Count | Keys |
|---|---|---|---|
| `0x82` | `SmcBadCommand` | 21 | `pcBK`, `pcBS`, `pcHS`, `pcLD`, `rBK0`–`rBK9`, `rBSW`, `rLD0`–`rLD5` |
| `0x89` | `SmcBadArgumentError` | 20 | `aDC!`, `aDC?`, `aDCR`, `bRIN`, `bVDN`, `bVUP`, `pcAD`, `rARA`, `rARa`, `rASO`, `rASo`, `rBKa`, `rCPU`, `rLOW`, `rRAM`, `rSOC`, `rVDA`, `rVDB`, `rVDF`, `rWRM` |
| `0xc7` | `SmcDeviceAccessError` | 10 | `CLKo`, `aP00`, `aP70`–`aP74`, `aP7e`, `aP7f`, `aP80` |
| `0xcb` | `SmcUnsupportedFeature` | 1 | `BMFL` |

Note in particular that `rBKa` — which reads as though it should extend the `rBK0`–`rBK9`
range above it — is not a `0x82` key at all. It rejects with `0x89`, alongside `aDCR`, the
`ioft` key referenced a few paragraphs below. Each key belongs to exactly one code; the
four lists above partition the 52, they do not overlap.

All four codes land on documented Intel result names, which supports the result-code
namespace carrying over to Apple Silicon — **that carry-over is an assumption, not an
observation**; none of the four has been independently verified against Apple Silicon
firmware source, only against the community `AppleSmc.h` reference.

**The converse does not hold.** Bit `0x10` is not itself a predictor of rejection: **308
bit-`0x10` keys read fine**, including all nine `ioft` temperature sensors this document
already relies on (`TG0B`, `TG0C`, `TG0H`, `TG0V`, `TG1B`, `TG2B`, `TR0Z`, `TR1d`, `TR2d` —
attrs `0x94`). So "function key" means "served by a firmware handler that *may* reject a
plain read," not "will reject a plain read." Within the rejecting population, bit `0x04`
(the byte-order bit ADR 0003/0004 depend on for data keys) tracks nothing checkable: `pcHS`
(`0xF0`, bit `0x04` clear) and `aDCR` (`ioft`, `0xF4`, bit `0x04` set) both never return
data, so its state predicts nothing observable about function-key behaviour either way.

The [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) independently
documents this exact cluster from the write side: "`rLD0` etc. cannot be read normally, but
can be read with a `0x00000001` or `0x00ffffff` payload. Maybe that's related to the
'flags' byte being `0xf0`." Read together with the local observation, **the gate looks like
the request shape — a plain, payload-less `READ_BYTES` is not a valid command for a
function key — not machine state.**

**The `pcHS` negative result.** `pcHS` (`ioft`, attrs `0xF0`, bit `0x10` set, bit `0x04`
clear — the sole bit-`0x04`-clear `ioft` key, and ADR 0004's discussion of its population)
was probed 965 times: battery idle, battery under sustained 12-way CPU load, a 300-read
50 ms hammer, a 10-minute 1 Hz watch, and two full-table walks. **965 rejections with
`0x82`, zero bytes returned.** `READ_KEYINFO` was stable throughout — `ioft`, 8 bytes,
attrs `0xF0` — so the key's declared metadata is not itself in flux. Combined with the
2026-07-25 AC-idle enumeration that first surfaced it, `pcHS` has never returned bytes
under AC idle, battery idle, battery under load, rapid retry, or a sustained watch.
**Conditions not tried:** sleep/wake, the first minutes after boot (system uptime during
this investigation was 5 days), an AC re-test within the same session as the battery runs,
and Low Power Mode. See [ADR 0004](ADR/0004-float-byte-order.md) for what this does and
does not settle about float byte order.

**To verify (E4):**

- Whether `0x82` returned from an actual `F0Md`/`F0Tg` **write** — not a read of an
  unrelated function key — really is the "thermal manager is holding the fans" rejection
  the community reports, and what would observationally distinguish it from an unrelated
  `0x82` if one happened to coincide.
- Whether a payload-carrying read (Asahi's `0x00000001` / `0x00ffffff` pattern) opens this
  cluster on the macOS user-client path used here, rather than the kernel-level path Asahi
  reverse-engineered. This is **gated like a write despite using a read selector** — an
  undocumented command shape this project has not attempted and does not attempt as part
  of this issue. Asahi separately records reads with side effects on `gP??` keys, which is
  its own reason for caution: a "read" is not guaranteed side-effect-free in this firmware.
- Whether attribute bit `0x20` discriminates anything within the function-key population —
  unexamined by this investigation.

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
surfaced building the production `SMCConnection` for E1.2 (issue #25, shipped in PR #29),
which initially sized the returned payload from the `READ_BYTES` reply's `dataSize` field.
Every call reported success and returned zero bytes: a silent, total failure
indistinguishable from working code until the values were inspected. The fix sizes the
payload from the `dataSize` the caller already obtained from a prior `READ_KEYINFO` call,
rather than trusting the `READ_BYTES` reply's own field — the same approach the enumeration
spike used from the start, which is why the spike's dumps were never affected. Both now
agree, and `SMCConnection.read(_:)` documents the reasoning inline at
`call(key:selector:data32:dataSize:)`.

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
`resolveByteOrder(generation:attributes:type:)` in
`Sources/SMCCore/SMCByteOrderResolver.swift`. The attribute-bit half of the rule is a
single-machine observation and stays that way until a second machine reports.
[ADR 0004](ADR/0004-float-byte-order.md) later widened the same resolver to `flt`/`ioft` —
see the `flt` section above for why that widening rests on failure-mode reasoning, not on
new local evidence.

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

### TB0T/TB1T/TB2T versus the real gas gauge (`AppleSmartBattery`) — not confirmed as battery temperature

The seed catalog (#44) originally cited this document for `TB0T`/`TB1T`/`TB2T` as
"battery-adjacent, corroborated against IOHID's `gas gauge battery`." **That corroboration
was never actually run, and does not appear anywhere above.** `gas gauge battery` is named
only once, in the list of 21 distinct IOHID sensors two paragraphs up; the three
value-level correspondences this document actually itemises are `PMU tcal` = `TR0Z`, `PMU
tdev7` vs. `TS0P`, and `PMU tdev5` vs. `TaRT` — none of them a `TB*T` key. Neither `TB1T`
nor `TB2T` is named anywhere else in this document. The only recorded `TB0T` fact (in the
`flt` table near the top) is that it matched `TG0B` — evidence for the `ioft` format, not
for a battery meaning (see the note there).

This section runs the comparison that citation implied but never happened: `TB0T`/`TB1T`/
`TB2T` against `AppleSmartBattery`, the IOKit service backed by the battery's own gas
gauge IC — a measurement path independent of both the SMC and `IOHIDEventSystemClient`.

| Key | Source | Value |
|---|---|---|
| `TB0T` | SMC, `flt` | 33.9000 °C |
| `TB2T` | SMC, `flt` | 33.9000 °C |
| `TG0B` | SMC, `ioft` (unlabelled) | 34.0000 °C |
| `TB1T` | SMC, `flt` | 31.3000 °C |
| `TG1B` | SMC, `ioft` (unlabelled) | 31.3000 °C |
| `AppleSmartBattery` `Temperature` | IOKit, the gas gauge IC's own reading | 30.70 °C |
| `AppleSmartBattery` `VirtualTemperature` | IOKit, a distinct, apparently derived quantity | 33.79 °C |

All read on the same machine, the same session:

- **`TB0T` and `TB2T` read identically** (33.9000 °C). Whether this is one physical sensor
  exposed under two keys or two sensors that happen to agree is not established.
- `TB0T`/`TB2T` sit 0.1 °C from the unlabelled `ioft` key `TG0B`; `TB1T` reads **identical
  to four decimal places** with the unlabelled `ioft` key `TG1B`. That is real internal
  consistency between two SMC encodings of what looks like the same underlying reading —
  but `TG0B`/`TG1B`'s own meaning is itself unestablished (see the `ioft` finding above),
  so agreeing with an anonymous key does not, by itself, confirm a battery meaning for
  either side.
- **`AppleSmartBattery`'s `Temperature`** — the property backed by the gas gauge IC itself
  — is 30.70 °C: **3.2 °C from `TB0T`/`TB2T`**, and 0.6 °C from `TB1T`. Both gaps are well
  outside the 0.15 °C bar this document uses elsewhere (the IOHID cross-check above) before
  calling two readings the same physical sensor. There is only one `AppleSmartBattery`
  temperature reading on a machine with one battery, so it cannot be "the" gas gauge value
  behind three keys that disagree with each other and with it.
- `VirtualTemperature` (33.79 °C) happens to land within 0.11 °C of `TB0T`/`TB2T`, but sits
  2.49 °C from `TB1T`, and `VirtualTemperature` is itself a distinct, apparently computed
  quantity — nothing here establishes what it is derived from. A near-miss against an
  uncharacterised value is not evidence for a battery meaning either, and it does not
  explain `TB1T`.

**Conclusion: `TB0T`/`TB1T`/`TB2T` remain battery-adjacent by key name only.** They track
each other and the unlabelled `TG0B`/`TG1B` `ioft` keys closely — a real, reproducible
observation about this machine's SMC — but the one comparison against an actual, named gas
gauge misses by an order of magnitude more than this document's own corroboration bar, and
no single `AppleSmartBattery` quantity accounts for all three keys at once. The catalog
reflects this: `confidence: guess`, not `verified`, for all three.

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

### Sleep/wake and the read connection — open question, not exercised (issue #68)

> **Tracked as [#68](https://github.com/blamechris/Aeolus/issues/68)**, which is open and carries
> `needs-hardware`. It also collects two other unknowns that the same single lid-close would retire:
> "Sleep resets the force key" above (marked *To verify (E4)*), and `SMCConnection.close()`'s own note
> that staleness after a wake is "unverified either way". If you are reading this because something
> broke after a wake, start there.

`SMCSensorProvider` opens exactly one `SMCConnection` and holds it for the lifetime of the
process. `SMCConnection.open()` is idempotent purely on whether `connection != 0` — once it
has succeeded, every later call is a guaranteed no-op, regardless of whether the underlying
`io_connect_t` the kernel handed back is still valid. There is no reconnect path anywhere in
this project, and nothing observes sleep or wake at all (`AeolusHelperMain.swift` names
`IORegisterForSystemPower` as future E5 scaffolding, not something implemented yet). Whether
an `io_connect_t` obtained from `IOServiceOpen` against the `AppleSMC` service survives a
sleep/wake cycle is exactly the fact this session was asked to establish, and it was **not**
established here.

**Why not:** the only way to observe this honestly is to start `fanctl watch`, physically
close the lid, wake the machine, and read what happened — a lid-close is a physical action
this session has no way to perform. The one available proxy, forcing a whole-machine sleep
with `pmset sleepnow`, was deliberately not attempted instead of being used as a stand-in:
this development machine may be running other work concurrently in sibling worktrees at the
time of any given session, and a forced system-wide suspend would interrupt all of it to
produce a result that is not even confidently the same code path a lid-close exercises
(`pmset sleepnow` and the lid switch both trigger system sleep, but this project has no
observation confirming they are indistinguishable to `AppleSMC`'s IOKit connection
specifically). Guessing the answer and coding to it would be worse than leaving it open:
CLAUDE.md's rule against fabricating an observation applies exactly as much to a plausible
substitute as to an invented one.

**What to actually do:** run `fanctl watch` in a terminal, close the lid, wait, wake it, and
record which of these happens, verbatim:

- Reads continue normally with no interruption — the connection (or at least its
  behaviour) survives sleep/wake on this machine, this macOS build.
- A read fails outright with a specific `kern_return_t` — record it. If that failure
  reaches `readFanCount` (an `FNum` read), `WatchCommand` exits with
  `FanctlError.connectionFailed`, a clear message, non-zero status — an honest failure, not
  a silent one. If it only ever hits a per-fan key (`F0Ac`/`Mn`/`Mx`), every tick renders
  that fan `unavailable (...)` forever, because nothing currently re-opens or invalidates
  the connection on its own — this is the "silently unavailable forever" outcome the issue
  calls out as the one wrong answer, and it would already be happening today, just not
  proven to.
- Reads hang rather than failing — a third outcome worth recording explicitly, since it
  changes the fix: a bounded timeout would be needed before a reconnect attempt could even
  be tried.

Once one of those is confirmed, the actual decision — reconnect transparently inside
`SMCSensorProvider`/`SMCConnection`, or fail loudly with a message that tells the user to
restart `fanctl watch` — can be made from evidence instead of a guess. No such change is
made in this PR.

**This bears far more on `AeolusHelper` than on `fanctl`.** A `watch` session is one process
a user restarts if it exits; the helper holds its own `SMCConnection` indefinitely, across
every sleep/wake cycle a laptop goes through for as long as it is running, and serves every
client (the app, `fanctl`, the control loop, the safety supervisor) from that one connection.
If it does not survive sleep/wake, the helper needs its own answer to this question — most
likely a reconnect, given how central continuous operation is to what it does — before E5's
safety supervisor can be trusted to keep reading actual fan state correctly across a laptop's
entire uptime. That is out of this issue's and this document's scope (`AeolusHelper` is not
touched here), but it is the reason this question is worth closing rather than leaving
indefinitely open once real hardware access to actually close a lid is available.

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
| [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) | Independent, clean-room hardware reverse-engineering corroborating the little-endian-with-quirks model behind ADR 0003, naming `#KEY`/`B0RM`/`VP3b` specifically, documenting `VP3b` as byte-reversed on M1-era hardware (the reason `flt`/`ioft` are no longer assumed unconditionally little-endian), and (for issue #52) noting that `rLD0`-class keys accept a `0x00000001`/`0x00ffffff` read payload where a plain read is rejected | Documentation consulted, no code adapted |
| [VirtualSMC](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/kern_vsmcapi.hpp) | Documents attribute bit `0x04` as `ATTR_ATOMIC` on Intel, which is why ADR 0003's byte-order rule is scoped to the modern interface only | Documentation consulted, no code adapted |
| [VirtualSMC — `VirtualSMCSDK/AppleSmc.h`](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/AppleSmc.h) | Names attribute bit `0x10` as `SMC_KEY_ATTRIBUTE_FUNCTION`, and result codes `0x82`/`0x89`/`0xc7`/`0xcb` as `SmcBadCommand`/`SmcBadArgumentError`/`SmcDeviceAccessError`/`SmcUnsupportedFeature` — the reference for issue #52's function-key finding | Documentation consulted, no code adapted |

**Before adapting code from any of these**, confirm the licence, record it above, and
attribute it in the source file. Reading a project's documentation and reimplementing from
the described behaviour is not adaptation; copying its implementation is, and carries its
licence with it.
