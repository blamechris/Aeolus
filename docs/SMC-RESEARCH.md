# SMC Research

**Status: stub. Nothing here has been verified on hardware by this project.**

This document is the record of what Aeolus has *observed*, as distinct from what the
community reports. Right now it contains only the latter, clearly marked. Epic E1 fills in
the read-path findings and epic E4 the write path, both from measurements taken on real
machines.

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

*Empty. E1 and E4 fill this in.*

Each entry should record: the machine, the macOS build, the exact keys and values seen,
how the observation was made, and whether it agreed with the reported behaviour above.
Disagreements are the most valuable thing this file can contain.

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

**Before adapting code from any of these**, confirm the licence, record it above, and
attribute it in the source file. Reading a project's documentation and reimplementing from
the described behaviour is not adaptation; copying its implementation is, and carries its
licence with it.
