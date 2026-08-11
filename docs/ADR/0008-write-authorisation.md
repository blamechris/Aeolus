# ADR 0008 — Write authorisation is stamped by the read, in the helper

- **Status:** Proposed
- **Date:** 2026-08-10
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s ruling on the ungoverned case)

## Context

[#108](https://github.com/blamechris/Aeolus/issues/108) typed the write seam on
`FanTargetRPM` so that a clamp could not be skipped. Adversarial review of that change
([#117](https://github.com/blamechris/Aeolus/pull/117)) found the type proves considerably
less than its documentation claimed.

`FanTargetRPM` and `FanControlEnvelope` carry no fan identity; `commandTarget` carried the
index as an independent parameter; and `FanControlEnvelope.validating(...)` is public over
two bare `Double`s. Three consequences, all reproduced against the code rather than argued:

1. A target clamped through fan 0's envelope could be commanded to fan 1, whose declared
   maximum was lower — 5777 RPM written to a fan declaring 2000.
2. An envelope could be minted from two literals with no firmware read anywhere, so the
   only real bound on a written target was the global `maximumPlausibleRPM` of 20,000.
3. A fan whose bounds the [#37](https://github.com/blamechris/Aeolus/issues/37) gate refused
   could still be written through any other fan's envelope — the invariant
   [SAFETY.md](../SAFETY.md) §2 states absolutely.

`engageManualControl` was worse: it took a bare `Int` and was gated by nothing at all, so a
fan with no trustworthy envelope could be taken off Apple's thermal management and left
holding a speed Aeolus could never lawfully command.

The failure mode is worth naming, because it is this repository's recurring one and the PR
that produced it was closing an issue filed against the same shape one level down: **prose
claiming a property the type does not deliver.** The fix is not more prose.

The choice: bind fan identity into `FanKit`'s types, or bind it in the helper.

## Decision

**The helper binds identity to bounds at the read, and the write verbs accept only the
result.**

- `FanEnvelope` — the plane's read result, already carrying the index and the bounds that
  came back from one subset read — gains the single gate that mints a `CommandableFan`
  (index + `FanControlEnvelope`), by running `FanKit`'s `validating(...)` on the bounds it
  actually read and stamping the index it actually read.
- `CommandableFan.target(for:)` mints an `AuthorisedFanTarget` (index + `FanTargetRPM`).
- Both permit types are `AeolusHelper`-internal with `fileprivate` initialisers, so the only
  mint inside `Sources` is that gate. `@testable` does not widen `fileprivate`, so the test
  target has no second route either: a test that wants to command a fan builds a
  `FanEnvelope`, which is the honest shape — faking a firmware reading looks like faking a
  firmware reading.
- `engageManualControl(of: CommandableFan)` and `commandTarget(_: AuthorisedFanTarget)` drop
  their index parameters entirely. An index passed *beside* a target is an index that can
  disagree with it; removing the parameter is what makes the mismatch unrepresentable rather
  than discouraged.
- `restoreToAutomatic(_: FanRestoreScope)` is untouched and **must never acquire a permit
  parameter.** A permit is trusted data, and ADR 0007's keystone is that the terminal action
  depends on none. This is tripwired alongside the other two signatures, in the same suite —
  every other assertion there pushes toward more gating, and that one says where it stops.
- `CommandedTarget` remains a plain record of `(fanIndex, rpm)`. Embedding a permit would let
  any past command mint future writes without touching the read side again.
- `FanKit`'s API is unchanged. Its documentation is corrected to claim only the arithmetic.

## What a permit proves, and does not

**Proves:** a bounds pair passed #37's plausibility gate; the rpm is clamped into that pair's
commandable range, so it is finite, never zero, and never above the declared firmware
maximum; and the index and those bounds came out of the same `FanEnvelope`, so the fan
written to and the envelope clamped into cannot disagree by accident.

**Does not prove** — named here rather than papered over, because an unnamed residual hole is
how the overclaim happened in the first place:

1. **Firmware provenance.** `FanEnvelope`'s initialiser is internal, so code inside
   `AeolusHelper` can construct one from literals. This design converts "skipped the gate by
   accident, in code that looks correct" into "faked a firmware reading on purpose", which
   review can see. It does not make fabrication impossible, and no in-process design can. Any
   `FanEnvelope(...)` outside `SMCFanControlPlane.readEnvelope(ofFan:)` and the test target
   is a red flag by policy, not by compiler.
2. **Freshness.** Permits do not expire. A `CommandableFan` cached across sleep or
   reclamation is still accepted. That is deliberate — §3's thermal emergency may hold a
   permit taken at grant time so its maximum write needs no read while the machine is above
   ceiling — and it rests on declared bounds being stable within a boot, which is believed
   and unverified.

## Alternatives considered

**Bind the index inside `FanKit`** — a `validating(forFan:declaredMinimumRPM:declaredMaximumRPM:)`
storing the index, carried onto `FanTargetRPM`. Rejected, though it closes the same
accidental-mismatch hole at the write site. The pairing "these bounds belong to fan *n*" is a
fact only a firmware read establishes, and `FanKit` never reads firmware — so the index would
be *caller-asserted*, three parameters wide, at every validation site. That restates the
defect being fixed inside the pure library: documentation implying a provenance the type
cannot deliver. It also puts authorisation vocabulary in a module every unprivileged client
links, one future `Codable` conformance away from the wire, and contradicts
`FanControlPlane`'s own doctrine that a type a client cannot name is a type a client cannot
reach. It is the expensive one to reverse: `FanKit`'s public API against three consuming
targets, versus one helper-internal module.

**Embed the permit in `CommandedTarget`**, so #102's bounded re-assert after reclamation
would be total. Rejected: ADR 0007 already settles which action must be total, and it is
*restore*, which needs no bounds and no read. The re-assert branch is explicitly fallible,
bounded by an attempt budget, floored by "restore and report", and never runs while any
temperature is above ceiling. A re-assert that cannot obtain an envelope should restore, not
command. A permit inside the observation record is a laundering loop: provenance decays to
"an envelope was read once, ever", inside the one type whose job is to be passive and to sit
in logs and fixtures.

**Deferring the `engageManualControl` gate to its own issue.** Rejected: it would re-create,
on the second verb, the exact prose-over-code gap this decision closes on the first. #108's
economics apply verbatim — both verbs are unimplemented throws today, so this is a signature
now and a cross-subsystem refactor after E5.3 wires the lease grant path.

## Consequences

- **PR #117 is revised before merge rather than patched after.** The seam signatures change
  once more while both conformers still throw `controlPathNotBuilt` and #102 has wired
  nothing. That is the cheap window #108 named, and it is still open.
- E5.3's mechanisms thread one value — `readEnvelope → commandable → target(for:) →
  commandTarget` — and no write-side API carries a fan index parameter anywhere.
- Two target-shaped types exist, by composition rather than duplication: `FanKit`'s is clamp
  evidence, the helper's adds identity. Each documents exactly one claim.
- `SAFETY.md` §2's closing paragraph and `FanTargetRPM`'s documentation are corrected in the
  same change. Prose may not outrun the types again.
- Tests fabricate `FanEnvelope`s — visibly faking firmware readings — rather than being handed
  a `Double`-to-`FanTargetRPM` back door.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| `F<n>Mn`/`F<n>Mx` are readable before any unlock | Observed on `Mac16,5`; documentation-only for Intel and M1/M2, which ship `untested` | The read → gate → permit → engage chain deadlocks and the engage gate must be revisited. The `commandTarget` gate survives regardless: you cannot command what you cannot clamp |
| Declared bounds are stable within a boot | Believed, **unverified** | The staleness allowance is withdrawn: permits must be invalidated on wake, which is a helper-internal change this decision localises |
| One production plane instance | True today | Permits carry no plane identity; revisit if that changes |
| `FanTargetRPM.init` stays `fileprivate` and non-`Codable`; `FanEnvelope`'s init stays internal | `FanKit`'s existing guarantee; the second is the named, accepted hole | The first is asserted by test; the second is policy |

Every hardware observation above is `Mac16,5` on macOS 26.5.2. Intel and M1/M2 ship
`untested`.

**Revisit when:** any firmware is found where envelope keys are unreadable before unlock;
declared bounds are observed changing within a boot; a second production plane instance ever
exists; or E3/E4 need a write verb this vocabulary cannot express.
