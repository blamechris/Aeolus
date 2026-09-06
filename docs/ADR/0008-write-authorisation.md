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
- Both permit types are `AeolusHelper`-internal, and that gate is the only mint inside
  `Sources` because of **two** access-level facts, neither redundant:
  **(a)** every initialiser is `fileprivate` — without it the mint is `internal` and any file
  in the module can issue a permit for an arbitrary index; `private` would be wrong in the
  other direction, since `FanEnvelope.commandable` is an extension on a different type.
  **(b)** every stored property is `private` behind a computed accessor — without it (a) is
  bypassable, because Swift's "an initialiser in an extension must delegate" rule is
  cross-*module*, not cross-*file*, so another file could declare an extension initialiser
  and assign the stored properties directly. A stored `var` would be worse than a `let`: it
  would let another file re-point an already-minted permit at a different fan.
  Successive drafts of this ADR asserted each half alone; both were wrong, and the tests
  assert both plus the expected property count. `FanTargetRPM` in `FanKit` gets the same
  treatment for a sharper reason — its `rpm` was `public let`, so a forged initialiser there
  would have been *public API*. A test that wants to command a fan builds a `FanEnvelope`,
  which is the honest shape: faking a firmware reading looks like faking one.
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

## Amendment (2026-09-06, [#160](https://github.com/blamechris/Aeolus/issues/160)) — the write seam's access level

**Decision.** `SMCConnection.write(_:to:)`
([`Sources/SMCCore/SMCConnection.swift`](../../Sources/SMCCore/SMCConnection.swift)) and
`SMCKeyType.encode(scalar:byteOrder:)`
([`Sources/SMCCore/SMCValue.swift`](../../Sources/SMCCore/SMCValue.swift)) become
`@_spi(FanWrite) public`. `Sources/AeolusHelper` reaches them with
`@_spi(FanWrite) import SMCCore`; a plain `import SMCCore` — which is what `fanctl`, the
app target and everything else writes — cannot name either declaration. Both are in scope,
not just the first: E4 encodes bytes before it writes them, so gating only the write would
have left half the seam open.

**Why the change was forced.** `package` visibility is computed against the SwiftPM
package, and the Xcode `AeolusHelper` target consumes `SMCCore` as a *product*
([`project.yml`](../../project.yml), the `AeolusHelper` target's `dependencies`), so it is
outside that package. The same defect was found and fixed once already, for
`ClientAuthorisation`, where the failure appeared only in the Xcode build — the only build
that produces a signed helper; its file comment records the measurement. The
`Monitor app build` CI job ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml))
compiles the helper target, so it is where this would have failed the moment E3/E4 made the
plane write.

**What the `@_spi` gate proves, and does not.** It is a compile-time gate of the same
strength as `package`: the symbol is public in the binary, and any module can opt in by
declaring the group. It does not stop a determined caller and does not claim to. What it
converts is the accident — an app-side call that compiles and looks correct — into a
deliberate, one-line, greppable act. That is this ADR's own standard for the permit types,
applied to their supplier.

One reach is *wider* than `package` was, and the controls below do not narrow it.
`SMCCore` is a published `.library` product ([`Package.swift`](../../Package.swift)), so a
**downstream package** that depends on Aeolus can write `@_spi(FanWrite) import SMCCore`
and name the seam. `package` did prevent that; `@_spi` does not. Every control below scans
this repository's `Sources/`, which a downstream consumer is not in, so nothing here fires.
The exposure is bounded by what the members do — both throw today, and E3/E4 put them
behind the safety subsystem — and by the fact that no such consumer exists; it is recorded
so the next reader does not have to rediscover it.

**Rejected: plain `public`.** Simplest, and the fallback had `@_spi` proved unusable in the
Xcode build. Rejected because after E3/E4 the write body no longer throws, and `fanctl` and
`Aeolus.app` would then link a callable root SMC write; `sudo fanctl` is a realistic
invocation, and "the helper is the sole writer" would rest on review discipline alone.

**Rejected: a capability token in `SMCCore`.** The mint must be reachable by the helper and
unreachable by clients, inside a module every client links, which degrades to a runtime
`geteuid() == 0` check that `sudo` passes. It also puts authorisation vocabulary into a
client-linked module, which this ADR already rejected for `FanKit`, and it is the most
expensive option to reverse: public `SMCCore` API against three consuming targets.

**Rejected: compiling `SMCCore`'s sources into the Xcode helper target.** `import SMCCore`
stops resolving in every helper file; keeping the product dependency alongside produces two
definitions of every type.

**Rejected: building the helper only with SwiftPM and embedding the binary.** It deletes the
build that compiles the helper as it ships — hardened runtime, entitlements, universal — and
moves helper signing into a hand-maintained script.

**Rejected: pinning `SWIFT_PACKAGE_NAME`.** Already measured: SwiftPM derives it from the
checkout directory basename, so it works in a clone and fails in a worktree. See
[`ClientAuthorisation.swift`](../../Sources/AeolusXPC/ClientAuthorisation/ClientAuthorisation.swift),
which carries the observation.

**Controls.** Nine, replacing the one that `package` supplied. Three of them were added by
#226's review, which defeated the first four, and two more by the delta re-review of that
round, which defeated the probe's own claim one indirection later — the seam is bound to a
local inside the probe, and applying *that* name is a write no scan looking for `write(`
can see:

| Control | Where |
|---|---|
| The only SPI group imported under `Sources/` is `FanWrite`, and only by the helper | `WriteSeamAccessTests.spiImportAppearsOnlyInTheHelper` |
| `Sources/SMCCore/` declares exactly two SPI members, both named, both in `FanWrite` | `WriteSeamAccessTests.smcCoreDeclaresExactlyTwoSPIMembers` |
| `write(` — with or without a receiver — appears in exactly one named, never-called probe file, and only as a reference | `WritePathAbsenceTests.helperNeverCallsWrite` |
| No helper file declares a populated `extension SMCConnection`, so the actor's isolation is never open to helper code | `WritePathAbsenceTests.noHelperFileOpensSMCConnectionsIsolation` |
| No declaration under `Sources/` carries the `package` access level | `WriteSeamAccessTests.noSourceFileDeclaresPackageAccess` |
| No file under `Sources/` describes the write seam as `package`-scoped | `WriteSeamAccessTests.noSourceFileCallsTheWriteSeamPackageScoped` |
| The probe applies none of the locals it binds the seam to, and contains no `try` and no `await` | `WritePathAbsenceTests.theWriteSeamProbeIsInert` |
| Nothing under `Sources/` references the probe, so anything smuggled into it stays dead code | `WritePathAbsenceTests.nothingOutsideTheProbeNamesIt` |
| The `Monitor app build` job compiles the probe and asserts its demangled symbols are in the helper | `.github/workflows/ci.yml` |

The probe is
[`Sources/AeolusHelper/WriteSeamReachability.swift`](../../Sources/AeolusHelper/WriteSeamReachability.swift).
It names both members and calls neither.

**The probe's shape is itself a control, and the first shape was wrong.** `SMCConnection`
is an `actor`, and the reference must sit inside its isolation, so the `write` half was
first written as an `extension SMCConnection`. That opened a hole in the control above it:
inside such an extension `self` *is* the connection, so an unqualified
`write(bytes, to: key)` is a live SMC write, and the scan — which matched the literal
`.write(` — could not see it. #226's reviewer inserted exactly that call; it compiled and
left all four controls green.

The probe is a free `enum` whose `write` half takes an `isolated SMCConnection` parameter.
That puts the *body* inside the actor's isolation, which is what the access check needs,
while putting no instance in unqualified scope: the same mutation now fails to compile with
`cannot find 'write' in scope`. Referencing `SMCConnection.write(_:to:)` as an unbound
function value instead — the obvious alternative — is not available: Swift rejects it from a
`nonisolated` context as `call to actor-isolated instance method 'write(_:to:)' in a
synchronous nonisolated context`, with or without an explicit
`@Sendable (isolated SMCConnection) -> …` annotation. The scan was widened to a bare
`write(` as well, and the extension shape is now forbidden outright, so neither half rests
on the other.

**Assumption.** `@_spi` resolves correctly when Xcode consumes a SwiftPM product. Verified
on `Mac16,5` / macOS 26.6.2 before this amendment was accepted:

```
xcodegen generate
xcodebuild -project Aeolus.xcodeproj -scheme "Aeolus (Monitor)" \
  -configuration "Monitor Debug" -destination "platform=macOS" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

`** BUILD SUCCEEDED **`, with the log line
`SwiftCompile normal arm64 … WriteSeamReachability.swift (in target 'AeolusHelper' …)` and
`nm | xcrun swift-demangle` on
`DerivedData/Build/Products/Monitor Debug/AeolusHelper` reporting
`static AeolusHelper.WriteSeamReachability.namesTheWriteSeam(on: isolated SMCCore.SMCConnection) -> Swift.Bool`.
The symbols are compared **demangled** because Swift's mangler substitutes repeated words:
`WriteSeamReachability.namesTheWriteSeam` mangles to `…WriteSeamReachabilityO08namesThecD02on…`
and the source spelling never appears in raw `nm` output, so grepping the raw table for it
is a check that can only pass by accident. Two negative controls
were run against the same tree and both failed to compile, which is what makes the gate a
gate rather than a convention:

- the probe with a plain `import SMCCore` → `error: 'write' is inaccessible due to '@_spi'
  protection level`;
- the same references from a scratch file under `Sources/fanctl` → the same error for both
  members.

Had the Xcode build failed instead, the decision was plain `public` with the same controls
minus the import tripwire.

**Revisit when:** Swift changes or removes `@_spi`; `package` becomes usable from an Xcode
target consuming a package product; or the helper stops being built by Xcode at all.
