# ADR 0014 — The Apple Silicon unlock: the plane owns the force key, any restore supersedes an engagement, and the first write runs in the shipping daemon

- **Status:** Proposed
- **Date:** 2026-10-09
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s keystone to the force key's
  lifetime; applies [ADR 0009](0009-precedence-at-the-write.md) D1 and D2 to an engagement of many
  writes; amends [ADR 0011](0011-reconciliation-and-foreign-manual-control.md) D3 to issue the
  machine-wide restore at every start on a plane that can write; amends
  [ADR 0004](0004-float-byte-order.md)'s write-time key-info sentence to forward writes (D7);
  supplies the procedure for [ADR 0012](0012-a-round-trip-that-does-not-return-ends-the-helper.md)
  H3 and H6. [ADR 0008](0008-write-authorisation.md)'s engage signature is **not** changed (D2).)

## Context

E4 ([#9](https://github.com/blamechris/Aeolus/issues/9)) is the first epic that takes a fan off
Apple's thermal management. Most of what sits beneath it is built and running in the installed
Developer ID helper on `Mac16,5` since [#82](https://github.com/blamechris/Aeolus/issues/82)
(2026-10-09): the lease, the clamp and the permit (ADR 0008), § 3, § 5, § 4, § 6's reconciliation
and signal teardown, and ADR 0012's watchdog. Three pieces are not: ADR 0009 D2's lease check at the
write ([#180](https://github.com/blamechris/Aeolus/issues/180)), § 5's re-assert registering with
§ 3 ([#181](https://github.com/blamechris/Aeolus/issues/181)), and the end of
[#104](https://github.com/blamechris/Aeolus/issues/104) — so E5
([#7](https://github.com/blamechris/Aeolus/issues/7)) is open. The production plane answers
`writeCapability == .notBuilt`, `SMCConnection.write(_:to:)` throws, and no write selector exists
under `Sources/`.

What is known about the write path here is almost nothing, and the gap between known and reported
decides most of this ADR:

| Observed on `Mac16,5`, read selectors only | Reported by community sources, unverified here |
|---|---|
| `F0Md`, `F1Md`, `Ftst` exist as `ui8` and read raw `00` in every raw read on record — the 26.5.2 dump, and the 27.0.1 dump and 30 ticks of [#323](https://github.com/blamechris/Aeolus/issues/323) — every one at idle. One byte and attributes `0xD0` were recorded on 27.0.1 only | A naive `F<n>Md = 1` is refused with `0x82` while the thermal manager actively asserts control, and succeeds when it does not |
| `F<n>Md` **decoded non-zero** on both fans while a third-party tool held them, and zero again with it still running (26.6.2, 2026-09-05). That reading is `FirmwareFanMode`'s fold — `0` is automatic, anything else manual — and not the byte ([#208](https://github.com/blamechris/Aeolus/issues/208)). Manual mode of *some* value is reachable on this hardware, by a route this project has not seen and will not inspect | `Ftst = 1` makes the thermal manager yield in about 3 s; retry budgets of about 300 × 100 ms |
| `F<n>Tg` is `flt`, attributes `0xD4`: bit `0x04` set, little-endian under ADR 0004. Apple's controller moves it with load (`F0Tg` 1350 → 2195 under sustained load) | The thermal manager "holds the fans in mode 3" — **unverified here**: no raw `F<n>Md` other than `0` has been recorded, and none under load or while a fan was held (#208), so whether Apple's management or a held fan reads `3` is unknown |
| Worst read round trip 11.45 ms over 912,000 reads (27.0.1) | Release must restore the mode **and** clear `Ftst`; sleep resets `Ftst` |
| A competing fan-control tool was running in most recorded captures — its app and privileged helper throughout the [#296](https://github.com/blamechris/Aeolus/issues/296) latency runs, present for #323 — and was quit for the 2026-09-05 20:13 reading; the 2026-07-25 and 2026-08-20 sessions do not record it | — |

Nothing has ever been written. The unlock is a hypothesis and the first write is an experiment —
but it is also the first time the safety subsystem acts on real firmware. Two choices have to be
made before any of it is coded, and both are expensive to reverse: **what code path the experiment
runs through**, which decides whether its findings describe the code that ships and whether a
failure mid-run is covered by restart and reconciliation; and **who owns the force key**, which
decides the keystone's shape on M3+, where `Ftst` is machine-wide and every lease, permit and
restore is per fan.

Five facts about the tree constrain both:

1. `SupervisedFanAuthority.apply` refuses unconditionally, and actor level 6 does not exist:
   `GovernedFanWriter` has no caller and no engage verb, and `engageManualControl(of:)` has one
   caller, § 5's re-assert (`ReclamationWatchdog` through `SafetyActorWriter`).
2. `renewLease` and `releaseLease` are dispatched on arrival
   ([#229](https://github.com/blamechris/Aeolus/issues/229)), so a release can arrive while a
   multi-second `apply` is still unlocking, and ADR 0009 D2 is unbuilt (#180).
3. `HelperClientDeadlines.gatedVerb` — 5 s, unmeasured
   ([#325](https://github.com/blamechris/Aeolus/issues/325)) — bounds every message behind the
   handshake gate, `apply` and the heartbeats alike; the reported yield is about 3 s.
4. The installed helper cannot write. A process that dies holding a fan is covered by restart and
   a reconciliation that can write **only if that process is the launchd-managed daemon**.
5. Every mode read in E5 — reconciliation, the grant path, § 3's and the lease core's read-backs,
   the snapshot — goes through `FirmwareFanMode`'s fold, so every one of them rests on "Apple's
   own management reads raw `0`", which has been observed at idle and nowhere else.

The slices that implement this ADR, and their order, are tracked on #9
([comment](https://github.com/blamechris/Aeolus/issues/9#issuecomment-6077938964)); D8 lists the
ones run 1 depends on, so this document does not need the plan to be read.

## Decision

### D1 — The experiment is the production path, in the installed daemon, built from an unmerged branch. There is no bring-up mode

The first write and every hardware row after it run through the code that will ship —
`SMCConnection.write`'s body, the plane's write verbs, the engagement driver (D2), the level-6
`apply` path, the lease, § 3, § 5, § 4, ADR 0009's checks and ADR 0012's watchdog — inside the
launchd-managed helper, built `Full Release` by the maintainer from the head of `e4/bring-up`,
installed over the current one, and driven by the signed `fanctl` embedded in that build through
the ordinary `acquireLease` and `apply` (`fanctl set`,
[#324](https://github.com/blamechris/Aeolus/issues/324), carried on the branch).

- **No mode, no flag, no environment variable.** What an experiment varies — fan, target,
  duration, machine load — is a `fanctl set` argument or the operator's. What it measures is
  permanent instrumentation: every write round trip logs its key, selector, SMC result byte and
  duration (ADR 0012's stamp already brackets the call), and every engagement step logs what D3
  lists. There is nothing for a client to enable, so rule 5 is met by absence rather than by a
  guard.
- **What stops it shipping is the merge, and the merge is visible.** On `main`,
  `WritePathAbsenceTests` keeps the selector allowlist at `{5, 8, 9}` and the production plane
  answers `.notBuilt`. Rule 1's line is therefore exactly: `SMCConnection.write`'s body, any write
  selector under `Sources/`, and a production plane answering `.built`. Code above that line may
  merge once E5 closes; nothing at or below it merges before the E4 gate.
- **Reviewed before hardware, merged after it.** The branch gets its full review, panel and Codex
  pass, before run 1; the merge waits for the checklist.
- **One permitted build-time variation.** Checklist row 8 runs on a throwaway commit that lowers
  § 3's ceiling through `ThermalEmergency`'s existing `requestedCeilingCelsius`, clamped downward
  only by `ThermalCeiling.effective`, so the emergency fires a few degrees above idle rather than at
  95 °C. It can only make § 3 fire earlier and no client reaches it. **A source tripwire, added to
  `main` before run 2, holds that `HelperComposition.init` — where `ThermalEmergency` is
  constructed — passes no `requestedCeilingCelsius`;** that commit therefore turns it red by
  construction, which is what makes "dropped before the merge" enforced rather than remembered.

### D2 — The unlock's sequence is the plane's, its cadence is a driver's, and the engage verb still takes a permit and nothing else

- **The sequence — which keys, which values, what a refusal code means, whether the force key is
  needed — is inside `SMCFanControlPlane`**, as `readControlState`'s documentation anticipates.
  Above the seam nothing writes, reads or names `Ftst`. The platform split is keyed on what the SMC
  declares and how it answers, never on the chip (rule 9): the force key is used only if `Ftst` is
  in the key table read at bring-up, and only after the firmware refused a naive mode write. A
  machine whose firmware accepts the naive write runs the same code and never touches `Ftst` —
  M1/M2, untested, shipped `untested`.
- **The plane verb performs one step and reports progress:**
  `engageManualControl(of: CommandableFan) async throws -> EngagementStep`, where `EngagementStep`
  is `.engaged` or `.awaitingYield`. The parameter list is ADR 0008's unchanged — one permit, and
  nothing beside it — so `WriteAuthorisationTests.everyEngageVerbTakesAPermit` and
  `WriteVerbAllowlistTests.aPermitTravelsBesideNothingThatNamesAFan` stand as they are.
- **The cadence — interval, budget, the entitlement before and after each step, the undo — is an
  `EngagementDriver`**, one helper-internal type that both writers' engage verbs go through:
  `SafetyActorWriter`'s, for § 5, and a new one on `GovernedFanWriter`, for level 6. Its sources —
  the lease core's per-fan liveness query (#180), § 3's latch, its writer's level, and § 3's
  registration role — are **stored properties set at composition, never arguments**, so its verb
  is `engageManualControl(of: CommandableFan)` as well, and it always asks about the permit's own
  index: the fan whose lease is checked cannot differ from the fan being written.
  `WriteVerbAllowlistTests` acknowledges it in `permitBearingVerbs`, which is what that list exists
  for.

### D3 — The engagement sequence, which is the hypothesis under test

**Every mode value in this sequence, and in D5 and D8, is the raw `F<n>Md` value — the declared
`ui8` decoded to its integer — never `FirmwareFanMode`'s fold**, which reads anything non-zero as
manual (#208). Every step logs the key, the value written, the result byte, the raw value read
back, the round-trip duration and the attempt number. The budgets are `UnlockLimits`, the driver's
constants, beside `RestoreLimits`.

**Which yield signal the poll uses is decided before run 1, by D8's read-only pre-flight**: raw
`F0Md`, `F1Md` and `Ftst` at 10 Hz, idle, then through a sustained twelve-way load while Apple's
controller ramps `F<n>Tg`, then through the heat soak after it.

- **Raw `F<n>Md` reads only `0` throughout** → Apple's management is invisible in the mode key,
  and the poll **retries the mode write** (Y-write) — on a measured basis.
- **It reads any third value *V*** (the reported `3`, or another) → two things return to the
  architect before run 1: `FirmwareFanMode`'s fold, which every E5 confirmation read relies on and
  which would then call Apple's own management manual; and the poll, which becomes **read until raw
  `F<n>Md` leaves *V*, then write** (Y-read), so the firmware is asked once rather than up to 35
  times.

For one fan *n*:

1. The driver asks the entitlement (D4). **Plane step, one turn:** check the restore epoch (D4);
   read raw `F<n>Md`, recorded as the pre-state; resolve `F<n>Md`'s type and order from a fresh
   `READ_KEYINFO` (ADR 0004); write `F<n>Md = 1`.
2. **`0x00`** → read raw `F<n>Md` in the same turn. **Exactly `1`** → `.engaged`, the force key
   untouched; at idle this is the reported first step, under load it disagrees with the report,
   and it is recorded either way. `0` → accepted is not applied
   ([#291](https://github.com/blamechris/Aeolus/issues/291)): throw. Any other value → throw, and
   back to the architect.
3. **`0x82`, `Ftst` in the key table, and the force key not already set by this plane** → in the
   same turn, re-check the epoch, take a fresh `READ_KEYINFO` and write `Ftst = 1`. `0x00` →
   `.awaitingYield`; anything else → throw. `0x82` with no `Ftst` in the key table → throw: this
   firmware offers no route this ADR knows. **Any first result other than `0x00` or `0x82`** —
   including the other codes this machine has returned to reads, `0x89`, `0xc7`, `0xcb` and `0xd8`
   — → throw, with no force key and no retry.
4. **While `.awaitingYield`**, every `UnlockLimits.pollInterval` (100 ms) the driver asks the
   entitlement and takes another step.
   - **Y-write:** check the epoch and write `F<n>Md = 1`. `0x00` → read back as in step 2.
     `0x82` → `.awaitingYield`. Anything else → throw.
   - **Y-read:** read raw `F<n>Md`. Still *V* → `.awaitingYield`, nothing written. Otherwise, as
     Y-write.

   When `UnlockLimits.yieldBudget` elapses — 3.5 s for run 1, so at most 35 steps — the driver
   undoes and refuses. **No turn is held between steps.** The step records the time from `Ftst`'s
   acceptance to `.engaged`, and the step count.
5. **On `.engaged`** the driver registers the fan with § 3, runs D4's after-check and returns.
   `apply` then registers the fan with § 5, commands its target and reads `F<n>Tg` back.

On any throw the driver undoes (D4, D5) and refuses. The budget is sized to the client rather than
to the report: 3.5 s leaves `gatedVerb`'s 5 s room for the target write and its read-back, and a
budget that proves too short fails safe. New refusals — the firmware refused the unlock; the yield
did not arrive — are additive `ManualControlAvailability.Reason` cases under `AeolusXPCVersion`'s
bump policy.

### D4 — Every write away from the safe state is checked before, inside and after; a restore supersedes an engagement; ADR 0009 D1's residual remains, and is covered

An engagement is seconds of writes away from the safe state, and a release, § 4's handback, a § 3
latch or a § 5 fallback can arrive at any point in it. ADR 0009 applies to every step, for both
callers:

- **Before each step**, the driver asks the entitlement. A live lease must cover fan *n* (#180's
  per-fan query; ADR 0009 D2, which binds § 5's re-assert exactly as it binds level 6), and
  `SafetyArbiter` must permit the driver's level against § 3's latch (ADR 0009 D1's ruling read at
  the write). § 5 keeps its own `currentRuling()` and `held` re-fetch around the call.
- **Inside the step's turn**, the plane checks a restore epoch. Every `restoreToAutomatic` call
  increments the counter **synchronously, when it is called, before it waits for a turn**. An
  engagement records the epoch at its first step, and once the epoch has moved it writes nothing
  more and throws `.superseded`. A turn is one indivisible occupation of the connection, so no
  forward write lands after a restore that was *requested* before that write's turn began.
- **After `.engaged`**, the driver registers the fan with § 3, then asks the entitlement again. If
  it has gone, the driver undoes.

**What this removes and what it leaves**, stated the way ADR 0009 D1 requires — it warns that
calling the window closed "would be the more dangerous spelling":

- **What the epoch removes, structurally:** one race inside the plane — a forward write landing
  after a restore that was requested first. A forward write that lands just ahead of a restore's
  turn is undone by that restore, which runs after it; that order is correct.
- **What remains:** the epoch does **not** make the entitlement check atomic with the write. A
  lease can end, or § 3 can latch, between the driver's check and the step's turn. That residual is
  ADR 0009 D1's. It is discharged the way D1 prescribes, by acting and then checking — the
  after-check and the undo — and the undo is itself a write the firmware can refuse.
- **What covers a refused undo:** the driver registered the fan with § 3 *before* the after-check,
  so the fan stays in § 3's registry until a read confirms it automatic (the
  [#295](https://github.com/blamechris/Aeolus/issues/295)/[#300](https://github.com/blamechris/Aeolus/issues/300)
  rule). The next emergency bridges and restores it.

That registration is #181's acceptance, met in the driver for both callers. It must be on `main`
before run 1, because § 5's re-assert — the only existing caller of `engageManualControl` — runs
the unlock from the first build that has one.

The keystone gains no input: incrementing a counter is not reading trusted data. **No restore waits
for an engagement to finish.** A restore waits at most for the turn in flight and the turns queued
ahead of it at `.supervisor` (D7). The epoch and the engaged set (D5) are lock-guarded, under the
discipline `SMCRoundTripMonitor` already uses, and held by the one production plane.

### D5 — The force key is the plane's, reference-counted by what the plane engaged, cleared last, and cleared at every start

- **An engaged set.** A fan joins when its mode write is accepted *and* raw `F<n>Md` reads back
  exactly `1`, inside the turn that wrote it. It leaves when any restore covering it is **issued**,
  whatever the firmware answers.
- **Restore is the unlock reversed: every `F<n>Md = 0` in scope, then `Ftst = 0`.** Each write is
  issued in the force-key state in which its forward write was accepted. Clearing the key first
  would issue the mode writes in exactly the state the report says refuses them, and a refusal
  there mints a durable `restoreToAutomaticFailed` for a fan with nothing wrong with it.
- **Every write in a restore is attempted regardless of the others.** A refused mode write is
  still followed by the force-key clear, the strongest remaining lever to bring the thermal
  manager back, and the restore throws only after all of them were attempted.
- **`.fan(n)` clears the force key when the set is empty after it; `.everyFan` clears it
  unconditionally** and empties the set. A per-lease teardown clears `Ftst` exactly when it hands
  back the last fan the plane engaged, and never while another engaged fan depends on it.
  `KeystoneRestoreAttempt` still issues `.fan(index)` only; the decision sits with the conformer,
  where the knowledge is.
- **`BoundedFanRestorer`'s retry tests the other order for free.** A first attempt whose mode
  write is refused has already cleared the key, because the set emptied when the restore was
  issued, so the second attempt writes `F<n>Md = 0` with `Ftst = 0`.
- **Startup reconciliation issues `.everyFan` once, on a plane that can write,** after its
  per-fan pass and inside its budget. This amends ADR 0011 D3, which issued it only where the pass
  could not see. Without it, a helper that died holding the key with every fan already back in
  automatic leaves `Ftst = 1` that nothing clears, because the per-fan pass finds nothing in
  manual. The cost is ADR 0011 D1's one-time discourtesy, extended to a force key another tool may
  hold.
- **§ 7's panic verb issues `.everyFan` after `releaseEveryLease()` on a plane whose
  `writeCapability` is `.built`, and does nothing more on one that is `.notBuilt`**, so v1's reply
  is unchanged on today's helper. This is the end of #104 and lands on `main` before run 1:
  - it inverts `PanicPathScopeTripwireTests.theShippedPanicVerbIssuesNoControlPlaneRestore`, with a
    mutation for each capability;
  - it adds `SupervisedFanAuthority.swift` to the file set that
    `everyMachineWideRestoreIsOneOfTheThreeKnownCallSites` holds;
  - it walks that suite's seven `documentationSites`, including `docs/SAFETY.md` § 1's "three call
    sites" sentence and § 7's "belongs with the write path rather than before it".

  Without it, `fanctl reset --all` — D8's first recovery step — clears no stray force key.

**The keystone holds, and its one data-dependent branch is named.** No restore write consumes
bounds, a reading, a lease or a permit (D7). The fan set comes from bring-up enumeration and
`Ftst`'s presence from the bring-up key table, with unknown counting as present; nothing is read at
restore time. The engaged set decides only whether `.fan(n)` *also* clears the key, and it can err
only toward leaving the key set. Every `.everyFan` removes it: § 4 before sleep, § 6's teardown,
reconciliation at the next start, and § 7's panic verb. Whether a key left set with every fan
automatic is harmless is U6; if it is not, the gate goes.

### D6 — Engagement happens at the first `apply`, never at grant, and an `apply` is all or nothing

`LeaseAuthority` stays hardware-free; a grant writes nothing. The first `apply` engages the fans
its settings name through `GovernedFanWriter`'s engage verb and the driver (D2–D4), which registers
each with § 3. `apply` registers each fan with § 5 at the landing, commands its target through
`GovernedFanWriter` and reads it back. If any fan's engagement fails, every fan that `apply`
engaged is restored and the call is refused. A lease that is never applied never takes a fan off
automatic control. A post-wake re-acquire re-runs the unlock with no special case, because § 4's
`.everyFan` emptied the engaged set before the sleep.

The level-6 body is built in E4, though `apply`'s comment attributes it to E3: E3
([#8](https://github.com/blamechris/Aeolus/issues/8)) lists no such item, and E4 is the only write
path this project can verify. E5's own Done-when text — "the unlock is re-run as part of the grant
(ADR 0007)" — is restated to match. ADR 0007 and `docs/SAFETY.md` § 4 leave where the unlock runs
to E4, so this is consistent with both.

### D7 — Each write takes one supervisor turn; forward writes read, restores do not; the unlock holds no turn between steps

- **Forward verbs** — an engagement step, `commandTarget` — take one `.supervisor` turn covering a
  fresh `READ_KEYINFO` (ADR 0004), the write and its read-back.
- **`restoreToAutomatic` takes one `.supervisor` turn per call and issues no read.** It encodes
  `F<n>Md = 0` and `Ftst = 0` from the type and size recorded at bring-up and writes them. Both are
  `ui8`, one byte, with no byte order for ADR 0004 to resolve; where bring-up recorded nothing, it
  writes one zero byte and reports what the firmware said.

  This keeps three things unchanged: `SMCFanControlPlane`'s property that restore issues no read
  (asserted by `SMCFanControlPlaneTests`), `docs/SAFETY.md`'s keystone, and ADR 0007's 2026-09-20
  amendment ("no read is queued ahead of it"). It **amends ADR 0004's sentence** — "writes resolve
  the order from a fresh `keyInfo` at write time and are followed by a mandatory read-back compare
  that aborts to automatic" — to forward writes. Applied to a restore it would put a read ahead of
  the keystone, and a read-back that "aborts to automatic" has nothing to abort to when the write
  *is* the restore. A restore's confirmations stay where E5 put them, beside and after it
  ([#204](https://github.com/blamechris/Aeolus/issues/204), #291, #295).
- **The engagement holds no turn between steps.** One engagement in progress adds one outstanding
  supervisor reader to ADR 0012's N while it waits for a turn, and none while it sleeps. The slice
  that adds write turns re-runs ADR 0012's allowance and `theBoundsAreDerivedAndConstant`, as ADR
  0012 requires. A scripted test holds that § 3 keeps completing cycles while an engagement is
  mid-poll.
- **The write selector is `WRITE_BYTES`, 6**, through the one stamped `IOConnectCallStructMethod`
  site. `docs/SMC-RESEARCH.md` names only selectors 5, 8 and 9 today, so **the source for 6, and
  its licence, is recorded in its Sources table before the change that adds the constant**, as
  `CLAUDE.md` requires.

### D8 — The first supervised write

**Preconditions. Any one failing means no write.**

On `main`:

- #180, ADR 0009 D2's per-fan lease check.
- #181, met by the driver's § 3 registration (D4).
- The end of #104 (D5's § 7 bullet), which closes E5.6 and lets E5 close.
- The seam shape and the driver over `ScriptedControlPlane` (D2, D4, D5, D7).
- Reconciliation's startup `.everyFan` (D5).
- The level-6 `apply` path (D6).
- #208's correction: the 2026-09-05 rows restated as "non-zero", and the hardware print recording
  the raw value.
- The selector-6 citation (D7).

Read-only on `Mac16,5`, the pre-flight session:

- The raw-mode capture D3 relies on: raw `F0Md`, `F1Md` and `Ftst` at 10 Hz — 10 min idle, 10 min
  under a twelve-way load, then the heat soak. If a third value appears, run 1 waits for the
  architect.
- D9's census (U10) and an exclusion dry run.

On the branch:

- The full review, with a recorded mutation for each of: the epoch check, both entitlement
  checks, the LIFO order, both restore writes attempted after a refusal, the clear on an empty set,
  restore issuing no read, the unknown-code abort, the unknown-raw-value abort and the budget
  abort.
- The installed helper reports the branch build, and its reconciliation log for this start shows
  the startup `.everyFan` accepted and read back.

The machine and operator:

- D9's exclusion, census and quiescence passed.
- AC power, lid open, no build or agent session running on the machine (concurrent builds distort
  SMC timing, [#227](https://github.com/blamechris/Aeolus/issues/227)), `pmset -g therm` clean,
  package below 50 °C, the app quit.
- The maintainer at the machine with `fanctl reset --all` and
  `sudo launchctl bootout system/com.blamechris.Aeolus.Helper` ready.
- A recorder running: `smc-sampler` at 10 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac`,
  `F1Ac` and the curated package keys, each recorded as its decoded scalar — for a `ui8`, the
  byte's own value, not `FirmwareFanMode`'s fold. And `log stream` on the helper's subsystem at
  debug.

**The run: three holds, each `fanctl set 0 50% --for 60s --json`.** That is **fan 0 only, at
3,564 RPM, above what Apple's controller ran here at idle (about 1,350–1,580 RPM) and under a
twelve-way load (about 2,200–2,400 RPM).**

The target direction is the safety argument. Every hold asks for *more* cooling than the system
would, so every stuck state it can produce — an unlock that will not undo, a restore the firmware
refuses — is a loud fan, not a hot one. Fan 1 is left automatic on purpose: its behaviour under
`Ftst = 1` is U7.

- **1a, idle**, after 60 s of baseline. This is where the report says the naive write succeeds.
- **1b, under the twelve-way load**, engaged once `F0Tg` has stayed at least 300 RPM above `F0Mn`
  for 30 s, so Apple's controller is actively managing the fan. This is where the report says the
  naive write is refused and the unlock is needed. Its abort baseline is the loaded steady state.
- **1c, idle**, 30 s, ended early from an SSH session with `fanctl reset --all` (row 18).

After each hold's release (D5's restore), run `fanctl auto` (ADR 0013's check). Then observe for
120 s, including a 20 s twelve-way load that must move `F0Tg` and `F0Ac`: the fan following load
is the only proof that Apple's management came back.

**Recorded** in `docs/SMC-RESEARCH.md`'s observed section, with machine state and build:

- every write's key, value, result byte and round-trip duration, the teardown restore's included
  (ADR 0012 H6);
- raw `F0Md` before the first write and after every accepted one;
- whether the naive write was refused, at idle and under load, and with what;
- time-to-yield and the step count;
- the 10 Hz trace of all seven fan keys through engage, hold, restore and load;
- whether `F0Tg` held the written value on every § 5 cycle;
- `F0Ac`'s step response (row 9);
- fan 1 under the force key (U7), and the force key's state at every point;
- `apply`'s and each heartbeat's client round trip (#325);
- that no third-party SMC client was present.

**Abort.** The maintainer runs `fanctl reset --all` at once on any of:

1. A curated temperature 10 °C above the hold's baseline, or above 85 °C. The target is above
   automatic, so a rise means the fan is not doing what was written.
2. `F0Ac` or `F1Ac` more than 20 % below its automatic speed for 10 s.
3. Either of:
   - during a hold — from the first accepted forward write until the restore is issued — any change
     to raw `F0Md` or to `F0Tg` that no helper write explains;
   - at any time, any change to `Ftst` that no helper write explains.

   Fan 1 stays automatic, so `F1Tg` moving is Apple's controller and is recorded, not an abort. A
   change in raw `F1Md` is recorded for U7 and guarded by abort 2.
4. A result or raw value outside D3's cases, or the budget expiring. The helper undoes on its own;
   the maintainer verifies.
5. Any write round trip over 1 s.
6. Thermal pressure above nominal.
7. The helper exiting or restarting during a hold.
8. Five minutes from engage without a verified restore.

**If the restore does not land.** Go in order, each step only if raw `F0Md`, `F1Md` and `Ftst` are
not all `0` on the recorder 10 s after the previous one:

1. `fanctl reset --all`: every lease released, then `.everyFan`, with every mode and then the key,
   each attempted. This rests on D5's § 7 precondition; on a build without it, the step restores
   covered fans by name only and clears no stray force key (`docs/SAFETY.md` row 18), so go
   straight to step 2.
2. `sudo launchctl bootout`: § 6's teardown, two more `.everyFan`. launchd will not restart it.
3. `pmset sleepnow`, and wake. That sleep resets the force key is reported, not observed (U12).
4. Shut down, wait 30 s, power on (U11).

A refused restore after a target *above* automatic is a recoverable nuisance, which is why every
hold in run 1 aims there.

**Decided on the result, before anything else runs.**

- **Write latency.** Every round trip at or under 50 ms (D/100) → D stands for writes. Any
  between 50 ms and 1 s → D is raised to 100× the worst in the merge PR, and ADR 0012's derived
  bounds are re-run. Any over 1 s → stop, and back to the architect.
- **Yield.** If it does not arrive within 3.5 s, raise `yieldBudget` and give `apply` a client
  deadline of its own, then repeat. `gatedVerb` bounds every gated message, so raising it would slow
  loss detection on every heartbeat (#325). A yield beyond about 4 s at all means asynchronous
  engagement before E4 may merge.
- **Hypotheses.** Any contradiction of U0–U7 → `docs/SMC-RESEARCH.md` first, then the architect,
  per `CLAUDE.md`.

### D9 — Another SMC writer is excluded by the operator, gated read-only, and never detected by the helper

**Every run before run 4 refuses to start while another SMC writer could be active, and the
refusal is the maintainer's act.**

- **Exclusion, product-agnostic.** Quit every third-party fan or SMC utility, switch its
  background item off in System Settings → General → Login Items & Extensions, and reboot, so no
  process survives. Re-enable afterwards; under ADR 0011 D1 that tool loses its settings once per
  Aeolus helper start.
- **Census, read-only.** Before the first write, the IORegistry's `AppleSMC` user clients must be
  only the Aeolus helper and the runbook's own sampler. That `ioreg` exposes each with its creating
  process is U10, checked in the pre-flight session before it is relied on. It counts clients,
  names no product, and nothing in the helper reads it.
- **Quiescence, read-only.** 120 s at 2 Hz in which raw `F0Md`, `F1Md` and `Ftst` read `0` on
  every sample. This sees a writer that is holding, not one that is idle — on 2026-09-05 those were
  minutes apart on this machine — so it backs the exclusion rather than replacing it.
- **In-run tripwire:** abort 3.

**The helper detects nothing, and ADR 0011 D1 stands.** What ADR 0011 already gives is protection
for the machine, not for the measurement:

- **What it gives:** reconciliation hands a held fan back once; a grant re-reads the mode and
  refuses `.foreignManualControl`; § 5 never adopts a foreign fan.
- **What it does not cover:** a foreign writer taking a fan Aeolus already holds. § 5 reads that
  as `reclaimedBySystem`, a diagnosis that would be false, and re-asserts up to
  `ReclamationLimits.reassertAttemptBudget` (3) before falling back — a bounded fight, and a trace
  nobody could interpret. A foreign `Ftst` write would read as a yield or a reclamation.

So the tool is tested once, deliberately, last, to settle ADR 0011's unverified re-assert
assumption and #300's revisit condition.

**No raw mode value is captured with the competing tool holding a fan before run 1.** #208 closes
by restating its rows as "non-zero". D3 writes the community-documented `1` and accepts it only on
its own read-back. A value taken from another product's resulting state, captured just before
choosing what to write, is the provenance question the clean room exists to avoid. Run 4 records
raw values as a matter of course, after this project's own path is established.

### D10 — Runs are ordered by thermal risk

1. **Run 1:** above automatic, one fan, idle and under load (D8).
2. **Run 2:** both fans, below automatic (the declared minimum), under a moderate load for 5 min,
   with § 3 armed. It needs the read-only half of rows 2 and 16–17 and ADR 0012 H2 first, and the
   ceiling tripwire (D1) on `main`. It covers:
   - rows 1, 2 and 3: kill `fanctl` with SIGKILL; kill the helper with SIGKILL mid-hold, then
     confirm restart and reconciliation (H3);
   - row 8, on D1's lowered-ceiling commit;
   - row 9, under load and downward.
3. **Run 3:** lifecycle with a hold — rows 5–7, row 10 as restated, row 11, row 17's restore half,
   and #325's sleep-handback heartbeat.
4. **Run 4:** the competing tool re-enabled, holding at helper start, then taking a fan Aeolus
   holds.

Each run's findings are recorded, and the branch revised, before the next.

## Consequences

- Rule 1's line is explicit (D1), and `main` keeps every write tripwire until the merge.
- **ADR 0008 is not amended.** The plane verb and the driver each take one permit. The driver
  joins `WriteVerbAllowlistTests.permitBearingVerbs`; `WriteAuthorisationTests` is untouched.
- **ADR 0004's write-time sentence is amended** to forward writes (D7), and ADR 0011 D3 is
  amended by D5's startup clear.
- **`PanicPathScopeTripwireTests` changes in one place only.** It asserts a set of three files, not
  a count. § 6's teardown already issues `.everyFan` (`SignalTeardown.swift`), and D5's startup
  clear lands in `StartupReconciliation.swift`, which is already in the set. § 7's change adds
  `SupervisedFanAuthority.swift`, inverts `theShippedPanicVerbIssuesNoControlPlaneRestore`, and
  walks its seven `documentationSites`.
- `docs/SAFETY.md` § 1's statement that a per-lease teardown leaves `Ftst` untouched becomes false
  on the branch and is corrected at the merge.
- **If U0 fails**, `FirmwareFanMode` needs a third case, or an explicit classification of *V*, and
  every E5 confirmation read is re-examined before run 1.
- **Three texts are restated:**
  - E4's "post-wake re-assertion" bullet;
  - row 10's "does sleep reset `Ftst`" — the new form: § 4's handback leaves raw `F<n>Md = 0` and
    `Ftst = 0` at wake, and a post-wake acquire re-runs the unlock;
  - E5's "the unlock is re-run as part of the grant" (D6).

  Whether firmware also resets the key no longer bears on correctness. It cannot be observed
  through the helper without disabling § 4, which no message and no build may do, and it matters
  only as a backstop for one residual: a § 4 keystone never issued before the sleep.
- `fanctl set` (#324) is the bring-up client and merges with E4.
- **If U7 fails**, per-fan manual control is not an honest product on such firmware, and the lease
  shape returns to the maintainer.

## Alternatives considered

### A standalone write probe, before any helper code

The strongest alternative, and the one an implementer will reach for first. A few hundred lines —
open the SMC, write `F0Md`, read the code, write `Ftst`, retry, write `F0Tg`, restore in a `defer`
— would answer U1 to U5 in an afternoon. It would need no lease, no signing, no XPC, and no review
of a helper change the answers might overturn. Isolating the firmware from the safety layer is a
real virtue for a measurement.

Rejected on how it fails:

- **A probe that dies holding a fan leaves it to nothing.** A Ctrl-C between the forward writes and
  the `defer`, a crash, or a synchronous IOKit call that never returns (ADR 0012's case, which no
  `defer` survives) leaves `F0Md` and `Ftst` set. Nothing counts a lease, nothing watches, and no
  reconciliation can write — the installed helper answers `.notBuilt`. What is left is sleep (U12,
  reported) and a power cycle (U11, partly asserted and unverified).
- **It needs the write seam outside the helper:** `@_spi(FanWrite) import SMCCore` under `Tools/`.
  `WriteSeamAccessTests` scans `Sources/` only, so nothing there would turn red. Each tool's own
  seam suite is held to forbidden tokens (`ToolsSeamCoverageTests`), and a tool written for this
  would simply not forbid that one. The rejection stands on `CLAUDE.md`'s rule: a new member of
  the `FanWrite` audience is a safety review, and "the helper is the sole writer" would hold only
  for code that is not research.
- **Its findings describe a code path that never ships:** no turns, no epoch, no entitlement, no
  § 3 beside it, no teardown restore through the path ADR 0012 bounds. Run 1 would still be owed,
  and it is the run that matters.
- **Reversal cost:** low in code, high in precedent — the second probe is easier than the first.

Revisit only if the signed helper cannot be built from a branch for an extended period, **and** the
maintainer accepts manual recovery as the only cover.

### The production graph composed inside `swift test`, under `sudo`

A close second, and closer than it looks.
`HelperHardwareTests.theComposedHelperServesRealHardware` already composes the production graph
over the real SMC, with recording signal sources, a recording terminator and manual watchdog ticks.
Those recording seams are exactly why it cannot be the vehicle for a write:

- **A recording terminator ends nothing, and a test runner is not a launchd job.** A watchdog
  verdict or a crash has no restart and no reconciliation behind it.
- **Recording signal sources run no teardown.** Installing the real ones would apply `SIG_IGN` to
  the runner permanently (`docs/SAFETY.md` § 1). Either way, a Ctrl-C during a hold ends the
  process with the fan pinned.
- **It runs as root, as a new kind of writer.** The whole test target runs as root, and a write
  from a test process is a kind of writer the sole-writer rule has never had to consider.

Revisit if a test host can run as a launchd job with the real teardown and terminator — at which
point it is the daemon.

### The entitlement as a closure parameter on the engage verb

`engageManualControl(of:while:)`, with the plane looping internally. Rejected:

- **It contradicts ADR 0008's sole-parameter rule and its two tripwires.**
  `expectPermitIsTheOnlyParameter` requires exactly one parameter, and `SeamScanner`'s
  `\([^)]*\)` cannot span a closure's `()`.
- **A closure that is not handed the index can check a different fan's lease than the permit
  names** — the disagreement ADR 0008 exists to make unrepresentable.

Amending the rule would loosen a safety tripwire for a convenience D2 does not need.

### The unlock above the seam

An `UnlockCoordinator` sequencing raw primitives — `writeMode(_:ofFan:)`, `writeForceKey(_:)`.
Rejected:

- The primitives take an index rather than a permit, reopening what ADR 0008 closed.
- Everything that holds the plane could write the force key.
- Platform differences leak above the seam (rule 9).

D2 keeps the sequence below the seam and puts only the cadence above it, which needs neither.

### Engage at grant

Rejected:

- It puts firmware writes into `LeaseAuthority`, which owns no hardware by design.
- A lease that is never applied pins a fan at whatever target the thermal manager left.
- A multi-second grant meets the same 5 s deadline for nothing.

### Hold the force key for the helper's life, or set it at bring-up

Rejected: it tells the thermal manager to yield with nobody holding a fan, and whether that is
harmless is U6, unknown.

### Clear the force key on every per-fan restore

The near miss, and the fallback if U6 fails. Rejected for now: inside a two-fan teardown sweep,
clearing the key after the first fan puts the second fan's mode write into the state the report
says refuses mode writes.

### Clear the force key first

Rejected for the same reason, applied to every fan rather than the second.
`BoundedFanRestorer`'s second attempt runs this order after a refused first one, so it is observed
without being depended on.

### Poll by reading the raw mode byte

Not rejected — conditional. It is better than polling by writing whenever a read can tell "held by
the system" from "yielded", and D3's pre-flight decides whether this machine offers one.

### Read the raw mode byte with the competing tool holding a fan, to settle #208 first

Rejected for E4 bring-up (D9). #208 closes by restatement, and D3 does not need the value.

### Detect the other writer in the helper

Rejected by ADR 0011 D1 and the clean room. The census is legitimate as an operator's read-only
pre-flight only because it counts clients, names nothing and changes no product behaviour.

### First write with the competing tool present, relying on ADR 0011

Rejected: ADR 0011 bounds what that tool can do to the machine, not to the measurement (D9).

### Asynchronous engagement

`apply` answers at once and the snapshot reports progress. Deferred, not rejected. It is needed
only if U3 fails beyond about 4 s, and it changes what `apply`'s reply means, so it needs a version
bump.

## Assumptions and what would invalidate them

| # | Assumption | Basis | If it fails |
|---|---|---|---|
| U0 | Apple's own management reads raw `F<n>Md = 0` | Observed at idle only (26.5.2, 27.0.1); "mode 3" reported; never read under load (#208) | Before run 1: `FirmwareFanMode`'s fold and every E5 confirmation read are re-decided, and D3 polls by reading (Y-read) |
| U1 | A naive `F<n>Md = 1` succeeds at idle and is refused `0x82` while the thermal manager actively asserts | Reported. `0x82` seen here only on reads of function keys | **Accepted and applied under load:** no force key is needed on this machine; recorded. **Accepted, then taken back within § 5's cycles:** write `Ftst` before the mode write, a conformer-internal change. **Another code:** treated as "held" only after architect review |
| U2 | `Ftst = 1` is accepted, and the mode write after it | Reported | No unlock by this route: E4 stops, the snapshot says manual control is unavailable and why, the matrix says so, and it goes back to the architect. Never coded around |
| U3 | The yield arrives within 3.5 s | Reported about 3 s; budgets of about 30 s suggest a tail | Raise the budget and give `apply` its own client deadline; beyond about 4 s, asynchronous engagement before merge |
| U4 | Accepted `F<n>Md` reads back raw `1`; `F<n>Tg` reads back within `ReclamationLimits.targetToleranceRPM` (1 RPM) of what was written | Unobserved; § 5's primary signal rests on the second | **Mode:** D3 refuses, correctly. **Target:** re-derive the 1 RPM tolerance from the observed quantum — a safety-limit change, made before merge — or every § 5 cycle reports a reclamation |
| U5 | The reverse-order restore is accepted | Unobserved | The retry already runs the other order; if only that one lands, D5's order flips in one place |
| U6 | With `Ftst = 1` and every raw `F<n>Md = 0`, Apple's management drives the fans | Unknown | D5's gate goes: every restore clears the key and every engagement re-sets it; § 4's never-issued keystone becomes a priority residual |
| U7 | `Ftst = 1` does not change a fan Aeolus did not engage | Unknown | A one-fan lease takes the others off Apple's management while the snapshot calls them automatic (rule 6). Engagement becomes all-fans-or-nothing on such firmware; the lease shape is the maintainer's call |
| U8 | Every write round trip, the teardown restore's included, stays under 50 ms (D/100) | Reads 11.45 ms worst; writes unmeasured | D8's decision rule |
| U9 | Manual mode and the key persist after the writer dies (ADR 0012 H3) | Reported | If they revert on close, ADR 0012 and D5's startup clear get cheaper; nothing changes |
| U10 | `ioreg` lists every `AppleSMC` user client with its creating process | Hypothesis | D9's census gate is dropped |
| U11 | A power cycle returns raw `F<n>Md` and `Ftst` to `0` | `RECOVERY.md` step 7 asserts the force key resets; that `F<n>Md` does not persist is `docs/SAFETY.md` row 7's unverified assumption (and ADR 0011's) | D8's ladder ends in a loud fan and `RECOVERY.md` § 8; run 1's target direction is what makes that acceptable |
| U12 | Sleep resets `Ftst` | Reported; not depended on (D5) | Only the never-issued-keystone residual widens |
| — | The restore keys' type and size are known from bring-up | Both `ui8`, one byte, on 27.0.1 | D7 writes one zero byte and reports the firmware's answer |
| — | One lease-table entry, one production plane | True today | Concurrent leases or a second plane: re-check D4's epoch scope and D5's gate |

Every observation above is `Mac16,5`; the write-path rows are hypotheses until D8 runs. Intel and
M1/M2 ship `untested`.

## Revisit when

Any of U0 to U7 is contradicted, by the pre-flight or a run — the expected case, so amend this
ADR and do not code around it. Also revisit when: a write round trip exceeds 50 ms; the yield does
not fit a synchronous `apply`; concurrent leases or self-renewing leases are proposed; a second
production plane exists; or a report arrives from M1/M2 or another M3+ machine.

The ruling is the architect's E4 consult, run on Opus.
