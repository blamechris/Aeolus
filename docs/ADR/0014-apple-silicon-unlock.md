# ADR 0014 — The Apple Silicon unlock: the plane owns the force key, any restore supersedes an engagement, and the first write runs in the shipping daemon

- **Status:** Proposed
- **Date:** 2026-10-09
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s keystone to the force key's
  lifetime; applies [ADR 0009](0009-precedence-at-the-write.md) D1 and D2 to an engagement of many
  writes; amends [ADR 0004](0004-float-byte-order.md)'s write-time key-info sentence and its
  assumption row to forward writes (D7); adds a write-path preparation step to bring-up (D5),
  extending [ADR 0011](0011-reconciliation-and-foreign-manual-control.md) D1's one-time discourtesy
  to the force key without amending ADR 0011; supplies the procedure for
  [ADR 0012](0012-a-round-trip-that-does-not-return-ends-the-helper.md) H3 and H6.
  [ADR 0008](0008-write-authorisation.md)'s engage signature is **not** changed (D2).)

## Context

E4 ([#9](https://github.com/blamechris/Aeolus/issues/9)) is the first epic that takes a fan off
Apple's thermal management. Most of what sits beneath it is built and running in the installed
Developer ID helper on `Mac16,5` since [#82](https://github.com/blamechris/Aeolus/issues/82)
(2026-10-09): the lease, the clamp and the permit (ADR 0008), § 3, § 5, § 4, § 6's reconciliation
and signal teardown, and ADR 0012's watchdog. Three pieces are not built: ADR 0009 D2's lease check
at the write ([#180](https://github.com/blamechris/Aeolus/issues/180)), § 5's re-assert registering
with § 3 ([#181](https://github.com/blamechris/Aeolus/issues/181)), and the rest of
[#104](https://github.com/blamechris/Aeolus/issues/104). So E5
([#7](https://github.com/blamechris/Aeolus/issues/7)) is open. The production plane answers
`writeCapability == .notBuilt`, `SMCConnection.write(_:to:)` throws, and no write selector exists
under `Sources/`.

What is known about the write path here is almost nothing, and the gap between known and reported
decides most of this ADR:

| Observed on `Mac16,5`, read selectors only | Reported by community sources, unverified here |
|---|---|
| `F0Md`, `F1Md`, `Ftst` exist as `ui8`. Every raw read on record is `00`, and every one was taken with no load and nothing holding a fan. **`F<n>Md`:** the 26.5.2 dump; the 27.0.1 dump and 30 ticks of [#323](https://github.com/blamechris/Aeolus/issues/323). **`Ftst`:** those reads, plus 26.6.2 on 2026-09-05 at 20:13 and before and after that night's lid close. One byte and attributes `0xD0` were recorded on 27.0.1 only | A naive `F<n>Md = 1` succeeds "when the system is not actively asserting control" and is refused with `0x82` when it is |
| `F<n>Md` **decoded non-zero** on both fans while a third-party tool held them, and zero again with it still running (26.6.2, 2026-09-05). That reading is `FirmwareFanMode`'s fold — `0` automatic, anything else manual — and not the byte ([#208](https://github.com/blamechris/Aeolus/issues/208)). Manual mode of *some* value is reachable on this hardware, by a route this project has not seen and will not inspect | `Ftst = 1` makes the thermal manager yield in about 3 s; retry budgets of about 300 × 100 ms |
| `F<n>Tg` is `flt`, attributes `0xD4`: bit `0x04` set, little-endian under ADR 0004. **What Apple's controller commands** (26.6.2, 2026-08-20, with idle readings from 2026-07-25 and 2026-10-08): at rest, fans stopped or about 1,350–1,580 RPM; under a 40 s twelve-way load, 2372/2551 RPM; **45 s after that load stopped, 3433/3683 RPM** — demand peaks in the heat soak, after the load | The thermal manager "holds the fans in mode 3" — **unverified here**: no raw `F<n>Md` other than `0` has been recorded, and none under load or while a fan was held (#208), so whether Apple's management or a held fan reads `3` is unknown |
| Worst read round trip 11.45 ms over 912,000 reads (27.0.1) | Release must restore the mode **and** clear `Ftst`; sleep resets `Ftst` |
| A competing fan-control tool was running in most recorded captures. Its app and privileged helper ran throughout the [#296](https://github.com/blamechris/Aeolus/issues/296) latency runs, and it was present for #323. It was quit for the 2026-09-05 20:13 reading, and the 2026-07-25 and 2026-08-20 sessions do not record it | — |

Nothing has ever been written. The unlock is a hypothesis and the first write is an experiment —
but it is also the first time the safety subsystem acts on real firmware. Two choices have to be
made before any of it is coded, and both are expensive to reverse:

- **What code path the experiment runs through.** That decides whether its findings describe the
  code that ships, and whether a failure mid-run is covered by restart and reconciliation.
- **Who owns the force key.** That decides the keystone's shape on M3+, where `Ftst` is
  machine-wide and every lease, permit and restore is per fan.

Five facts about the tree constrain both:

1. `SupervisedFanAuthority.apply` refuses unconditionally, and actor level 6 does not exist:
   `GovernedFanWriter` has no caller and no engage verb. `engageManualControl(of:)` has one caller,
   § 5's re-assert (`ReclamationWatchdog` through `SafetyActorWriter`).
2. `renewLease` and `releaseLease` are dispatched on arrival
   ([#229](https://github.com/blamechris/Aeolus/issues/229)). A release can therefore arrive while
   a multi-second `apply` is still unlocking, and ADR 0009 D2 is unbuilt (#180).
3. `HelperClientDeadlines.gatedVerb` bounds every message behind the handshake gate, `apply` and
   the heartbeats alike. It is 5 s and unmeasured
   ([#325](https://github.com/blamechris/Aeolus/issues/325)); the reported yield is about 3 s.
4. The installed helper cannot write. A process that dies holding a fan is covered by restart and
   a reconciliation that can write **only if that process is the launchd-managed daemon**.
5. Every mode read in E5 goes through `FirmwareFanMode`'s fold: reconciliation, the grant path,
   § 3's and the lease core's read-backs, § 5's cycle, and the snapshot (and so `fanctl auto`). All
   of them therefore rest on "Apple's own management reads raw `0`", which has been observed only
   with no load and nothing holding a fan. Bring-up reads no key table, and the plane never reads
   `Ftst`.

The slices that implement this ADR, and their order, are tracked in the slice plan on #9. D8 lists
the ones run 1 depends on, so this document can be read without the plan.

## Decision

### D1 — The experiment is the production path, in the installed daemon, built from an unmerged branch. There is no bring-up mode

The first write, and every hardware row after it, runs through the code that will ship:
`SMCConnection.write`'s body, the plane's write verbs and its bring-up preparation step (D5), the
engagement driver (D2), the level-6 `apply` path, the lease, § 3, § 5, § 4, ADR 0009's checks and
ADR 0012's watchdog. All of it runs inside the launchd-managed helper:

- built `Full Release` by the maintainer from the head of `e4/bring-up`;
- installed over the current one;
- driven by the signed `fanctl` embedded in that build, through the ordinary `acquireLease` and
  `apply` (`fanctl set`, [#324](https://github.com/blamechris/Aeolus/issues/324), carried on the
  branch).

- **No mode, no flag, no environment variable.** What an experiment varies — fan, target,
  duration, machine load — is a `fanctl set` argument or the operator's choice. What it measures
  is permanent instrumentation:
  - every write round trip logs its key, selector, SMC result byte and duration (ADR 0012's stamp
    already brackets the call);
  - every engagement step logs what D3 lists.

  There is nothing for a client to enable, so rule 5 is met by absence rather than by a guard.
- **The branch build identifies itself.** It changes `AeolusHelperMain.build` from `"0.0.0 (E2)"`
  to `"0.0.0 (E4 bring-up)"`, which `fanctl status` shows as the helper's build. When the
  maintainer builds it, they record the branch head and the helper's code-directory hash
  (`codesign -dvvv`). Before each run, the installed helper's hash is checked against that record.
- **What stops it shipping is the merge, and the merge is visible.** On `main`,
  `WritePathAbsenceTests` keeps the selector allowlist at `{5, 8, 9}`, and the production plane
  answers `.notBuilt`. Rule 1's line is therefore exactly three things:
  - `SMCConnection.write`'s body;
  - any write selector under `Sources/`;
  - a production plane answering `.built`, together with the bodies that make it true.

  Code above that line may merge once E5 **exists and is tested**, in `CLAUDE.md`'s words, read as
  ADR 0007's Consequences read it. That means every E5 mechanism built and tested against the
  scripted plane, with the hardware checklist written. This ADR takes that point as #180, #181 and
  #104's code (D4, D5, D8) being on `main`. Nothing at or below the line merges before the E4 gate.
- **Reviewed before hardware, merged after it.** The branch gets its full review, panel and Codex
  pass, before run 1. The merge waits for the checklist.
- **One permitted build-time variation.** Checklist row 8 runs on a throwaway commit that lowers
  § 3's ceiling through `ThermalEmergency`'s existing `requestedCeilingCelsius`. That parameter is
  clamped downward only by `ThermalCeiling.effective`, so the emergency fires a few degrees above
  idle rather than at 95 °C. It can only make § 3 fire earlier, and no client reaches it.
  **A source tripwire, added to `main` before run 2, holds that `HelperComposition.init` passes no
  `requestedCeilingCelsius`.** `HelperComposition.init` is where `ThermalEmergency` is constructed,
  so the throwaway commit turns that tripwire red by construction. That is what makes "dropped
  before the merge" enforced rather than remembered.

### D2 — The unlock's sequence is the plane's, its cadence is a driver's, and the engage verb still takes a permit and nothing else

- **The sequence is inside `SMCFanControlPlane`.** That covers which keys, which values, what a
  refusal code means, and whether the force key is needed, as `readControlState`'s documentation
  anticipates. Above the seam, nothing writes, reads or names `Ftst`.

  The platform split is keyed on what the SMC declares and how it answers, never on the chip
  (rule 9). The force key is used only if `Ftst` was found by the preparation step (D5), and only
  after the firmware refused a naive mode write. A machine whose firmware accepts the naive write
  runs the same code and never touches `Ftst`. That is M1/M2: untested, and shipped `untested`.
- **The plane verb performs one step and reports progress.** Its signature is
  `engageManualControl(of: CommandableFan) async throws -> EngagementStep`, where `EngagementStep`
  is `.engaged` or `.awaitingYield`. The parameter list is ADR 0008's, unchanged: one permit and
  nothing beside it. `WriteAuthorisationTests.everyEngageVerbTakesAPermit` and
  `WriteVerbAllowlistTests.aPermitTravelsBesideNothingThatNamesAFan` therefore stand as they are.
- **The cadence is an `EngagementDriver`.** It owns the interval, the budget, the entitlement
  before and after each step, and the undo. It is one helper-internal type that both writers'
  engage verbs go through: `SafetyActorWriter`'s, for § 5, and a new one on `GovernedFanWriter`,
  for level 6.

  Its sources are stored properties set at composition, never arguments:
  - the lease core's per-fan liveness query (#180);
  - § 3's latch;
  - its writer's level;
  - § 3's registration role.

  So its verb is `engageManualControl(of: CommandableFan)` too, and it always asks about the
  permit's own index: the fan whose lease is checked cannot differ from the fan being written.
  `WriteVerbAllowlistTests` acknowledges it in `permitBearingVerbs`, which is what that list
  exists for.

### D3 — The engagement sequence, which is the hypothesis under test

**Raw values, and where the fold remains.** The plane's own mode reads, and D8's recorder, use the
raw `F<n>Md` value: the declared `ui8` decoded to its integer, never `FirmwareFanMode`'s fold
(#208). The fold remains where E5 already uses it: reconciliation, the grant path, § 3's and the
lease core's read-backs, § 5's cycle, and the snapshot, and so `fanctl auto`'s verdict, where
[#178](https://github.com/blamechris/Aeolus/issues/178) also reports an unreadable mode as
automatic. U0 is what makes keeping the fold safe. If U0 fails, those uses are re-decided before
run 1.

**Logging and budgets.** Every step logs the key, the value written, the result byte, the raw
values read before and after, the round-trip duration and the attempt number. The budgets are
`UnlockLimits`, the driver's constants, beside `RestoreLimits`.

**Which yield signal the poll uses is decided before run 1, by D8's read-only pre-flight.** The
pre-flight records raw `F0Md`, `F1Md` and `Ftst` at 10 Hz: idle, then through a sustained
twelve-way load while Apple's controller ramps `F<n>Tg`, then through the heat soak after it.

- **Raw `F<n>Md` reads `0` on every sample** → Apple's management is invisible in the mode key.
  The poll **retries the mode write** (Y-write), on a measured basis.
- **It reads any value other than `0`, `1` included** → two things return to the architect before
  run 1:
  - `FirmwareFanMode`'s fold, which every E5 confirmation read relies on, and which would then call
    Apple's own management manual;
  - the poll, which becomes **read until raw `F<n>Md` leaves that value, then write** (Y-read), so
    the firmware is asked once rather than up to 35 times.

**For one fan *n*:**

1. **First step.** The driver asks the entitlement (D4). Then the plane takes one turn:
   - check the restore epoch (D4);
   - read raw `F<n>Md` as the pre-state. If it is not `0`, throw `.notAutomatic` and write nothing:
     a fan that is not automatic is not Aeolus's to take;
   - resolve `F<n>Md`'s type and order from a fresh `READ_KEYINFO` (ADR 0004);
   - write `F<n>Md = 1`.
2. **`0x00`** → read raw `F<n>Md` in the same turn.
   - **`1`** → `.engaged`, the force key untouched. This counts as evidence of engagement only
     because the same turn read `0` immediately before the write. At rest this is the reported
     first step; under load it disagrees with the report, and it is recorded either way.
   - **`0`** → accepted is not applied ([#291](https://github.com/blamechris/Aeolus/issues/291)):
     throw.
   - **Any other value** → throw, and back to the architect.
3. **`0x82`** → the case depends on the force key:
   - **`Ftst` was found, and the plane's force-key flag (D5) is clear** → in the same turn,
     re-check the epoch, take a fresh `READ_KEYINFO` and write `Ftst = 1`. `0x00` sets the flag and
     returns `.awaitingYield`; anything else throws.
   - **The flag is already set**, as when a second fan engages while the first holds the key → no
     key write; return `.awaitingYield`. This fan waits for its own yield under the key already set.
   - **`Ftst` was not found** → throw: this firmware offers no route this ADR knows.

   **Any first result other than `0x00` or `0x82`** throws, with no force key and no retry. That
   includes the other codes this machine has returned to reads: `0x89`, `0xc7`, `0xcb` and `0xd8`.
4. **While `.awaitingYield`**, every `UnlockLimits.pollInterval` (100 ms), the driver asks the
   entitlement and takes another step.
   - **Y-write:** check the epoch, then write `F<n>Md = 1`. `0x00` → read back as in step 2.
     `0x82` → `.awaitingYield`. Anything else → throw.
   - **Y-read:** read raw `F<n>Md`. Still the non-zero value → `.awaitingYield`, with nothing
     written. Otherwise, continue as Y-write.

   When `UnlockLimits.yieldBudget` elapses — 3.5 s for run 1, so at most 35 steps — the driver
   undoes and refuses. **No turn is held between steps.** The engagement records the time from
   `Ftst`'s acceptance to `.engaged`, and the step count.
5. **On `.engaged`**, the driver registers the fan with § 3, runs D4's after-check, and returns.
   `apply` then registers the fan with § 5, commands its target, and reads `F<n>Tg` back.

On any throw, the driver undoes (D4, D5) and refuses.

The budget is sized to the client rather than to the report. 3.5 s leaves `gatedVerb`'s 5 s room
for the target write and its read-back. A budget that proves too short fails safe.

New refusals are additive `ManualControlAvailability.Reason` cases under `AeolusXPCVersion`'s bump
policy: the firmware refused the unlock; the yield did not arrive; the fan was not automatic.

### D4 — Every write away from the safe state is checked before, inside and after; a restore supersedes an engagement; ADR 0009 D1's residual remains, and is covered

An engagement is seconds of writes away from the safe state. A release, § 4's handback, a § 3
latch or a § 5 fallback can arrive at any point in it. ADR 0009 applies to every step, for both
callers:

- **Before each step**, the driver asks the entitlement. Two conditions must hold:
  - **A live lease covers fan *n*.** This is #180's per-fan query, and ADR 0009 D2, which binds
    § 5's re-assert exactly as it binds level 6.
  - **`SafetyArbiter` permits the driver's level against § 3's latch.** This is ADR 0009 D1's
    ruling, read at the write.

  For § 5, this before-step check is the pre-engage `currentRuling()` guard that #181's 2026-09-05
  comment asks for. § 5 keeps its own `held` re-fetch around the call.
- **Inside the step's turn**, the plane checks a restore epoch. Every `restoreToAutomatic` call
  increments the counter **synchronously, when it is called, before it waits for a turn**. An
  engagement records the epoch at its first step; once the epoch has moved, the engagement writes
  nothing more and throws `.superseded`.

  A turn is one indivisible occupation of the connection. So no forward write lands after a
  restore that was *requested* before that write's turn began.
- **After `.engaged`**, the driver registers the fan with § 3, then asks the entitlement again. If
  the entitlement has gone, the driver undoes.

The plane's own state is three items, lock-guarded under the discipline `SMCRoundTripMonitor`
already uses, and held by the one production plane:

- the restore epoch;
- the engaged set (D5);
- the force-key flag (D5).

**What this removes and what it leaves**, stated the way ADR 0009 D1 requires. ADR 0009 D1 warns
that calling the window closed "would be the more dangerous spelling".

- **What the epoch removes, structurally:** one race inside the plane, in which a forward write
  lands after a restore that was requested first. A forward write that lands just ahead of a
  restore's turn is undone by that restore, which runs after it. That order is correct.
- **What remains:** the epoch does **not** make the entitlement check atomic with the write. A
  lease can end, or § 3 can latch, between the driver's check and the step's turn.

  That residual is ADR 0009 D1's. It is discharged the way D1 prescribes, by acting and then
  checking: the after-check, and the undo. The undo is itself a write the firmware can refuse.
- **What covers a refused undo:** the driver registered the fan with § 3 *before* the after-check.
  So the fan stays in § 3's registry until a read confirms it automatic
  ([#295](https://github.com/blamechris/Aeolus/issues/295) and
  [#300](https://github.com/blamechris/Aeolus/issues/300)), and the next emergency bridges and
  restores it.

**#181 is delivered with the driver, in full, and must be on `main` before run 1.** § 5's
re-assert is the only existing caller of `engageManualControl`, and it runs the unlock from the
first build that has one. Delivering #181 in full means:

- the § 3 registration on engage, in the driver, for both callers;
- deregistration in `finaliseRelease` and `releaseToThermalEmergency`;
- a test in which the emergency latches mid-write and the undo is refused, ending with the fan in
  § 3's registry and bridged by § 3's next latched cycle;
- the pre-engage ruling, and the rewrite of
  `ReclamationWatchdogStalenessTests.itUndoesAReassertWhenTheEmergencyLatchesMidWrite`. The
  driver's before-step latch check turns that test red by design. It is rewritten to assert
  refusal before the write for the `.envelopeRead` moment, with a separate case kept for a latch
  after the ruling, so the post-write undo stays covered;
- a mutation for each of the above;
- ADR 0009's "As built" section updated.

**The keystone gains no input:** incrementing a counter is not reading trusted data. **No restore
waits for an engagement to finish.** A restore waits at most for the turn in flight and the turns
queued ahead of it at `.supervisor` (D7).

### D5 — The force key is the plane's, reference-counted by what the plane engaged, cleared last, and checked at every start

- **An engaged set.** A fan joins when its mode write is accepted *and* raw `F<n>Md` reads back
  `1`, after a pre-state of `0` read in the same turn (D3). It leaves when any restore covering it
  is **issued**, whatever the firmware answers.
- **A force-key flag.** It is set when this plane's `Ftst = 1` is accepted. It is cleared when a
  restore **issues** `Ftst = 0`. Between the key's acceptance and the first fan joining, the
  engaged set is empty while the flag is set. A `.fan(n)` restore in that window — the undo of an
  engagement that never joined — therefore clears the key, which is correct.
- **Restore is the unlock reversed: every `F<n>Md = 0` in scope, then `Ftst = 0`.** Each write is
  issued in the force-key state in which its forward write was accepted. Clearing the key first
  would issue the mode writes in exactly the state the report says refuses them. A refusal there
  mints a durable `restoreToAutomaticFailed` for a fan with nothing wrong with it.
- **Every write in a restore is attempted, regardless of the others.** A refused mode write is
  still followed by the force-key clear, the strongest remaining lever to bring the thermal
  manager back. The restore throws only after all of them were attempted.
- **`.fan(n)` clears the force key when the engaged set is empty after it. `.everyFan` clears it
  unconditionally**, and empties the set.
  - A per-lease teardown clears `Ftst` exactly when it hands back the last fan the plane engaged,
    and never while another engaged fan depends on it.
  - `KeystoneRestoreAttempt` still issues `.fan(index)` only. The decision sits with the
    conformer, where the knowledge is.
- **`BoundedFanRestorer`'s retry tests the other order for free.** A first attempt whose mode write
  is refused has already cleared the key, because the set emptied when the restore was issued. So
  the second attempt writes `F<n>Md = 0` with `Ftst = 0`.
- **The write-path preparation step, new in bring-up.** It runs after the watchdog arms and
  `bindSafetyRegistries()`, and before `reconcileFans()`'s first restore. Over the fans the
  bring-up enumeration names, it does the following:
  - It records, by `READ_KEYINFO`, the declared type and size of every `F<n>Md`, and whether
    `Ftst` exists. That is the knowledge D7's restore encodes from.
  - It reads raw `Ftst`. If the key reads anything other than `0`, or cannot be read, it writes
    `Ftst = 0` once. That is the only write this step can make, and it is toward automatic.

  The step's design rules:
  - **Reads happen at bring-up, never at restore time.** A key whose read failed is recorded as
    unknown, treated as present, and encoded as one byte (D7).
  - **It stays within D_bringUp, and its failure never blocks serving.** It runs inside
    D_bringUp; its round trips are stamped like any other, and its failure is logged.
  - **On a plane that is `.notBuilt` it does nothing.**
  - **What it covers:** a helper that died holding the key, with every fan already back in
    automatic. Without the step, that helper leaves `Ftst = 1` that nothing clears, because
    reconciliation's per-fan pass finds nothing in manual.

  On a quiescent machine, the step writes nothing. It extends ADR 0011 D1's one-time discourtesy
  to a force key another tool may hold, and it amends nothing in ADR 0011.
- **§ 7's panic verb issues `.everyFan` after `releaseEveryLease()` on a plane whose
  `writeCapability` is `.built`, and does nothing more on one that is `.notBuilt`.** v1's reply is
  therefore unchanged on today's helper. This lands on `main` before run 1, as #104's last code
  piece (D8), and it carries five changes:
  - It inverts `PanicPathScopeTripwireTests.theShippedPanicVerbIssuesNoControlPlaneRestore`, with
    a mutation for each capability.
  - It adds `SupervisedFanAuthority.swift` to the file set that
    `everyMachineWideRestoreIsOneOfTheThreeKnownCallSites` holds.
  - It walks that suite's seven `documentationSites`. These include `docs/SAFETY.md` § 1's "three
    call sites" sentence, and § 7's "belongs with the write path rather than before it".
  - It corrects the entry that calls the § 1 list "§ 5's".
  - On the branch, `SMCFanControlPlane.swift` joins the set too. Its restore branches on scope,
    and the scan, `code.contains(".everyFan")`, cannot tell that from a call site. The test's
    message says so.

  Without this change, `fanctl reset --all` — D8's first recovery step — clears no stray force
  key.

**The keystone holds, and its one data-dependent branch is named.**

- **No restore write consumes trusted data.** Not bounds, a reading, a lease or a permit (D7).
  The fan set comes from bring-up enumeration, and the key types and `Ftst`'s presence come from
  the preparation step. Nothing is read at restore time.
- **The one branch is whether `.fan(n)` also clears the key.** The engaged set decides only that,
  and it can err only toward leaving the key set. Every `.everyFan` removes the key: § 4 before
  sleep, § 6's teardown, and § 7's panic verb. The preparation step removes it at the next start.
- **Whether that error is acceptable is U6.** U6 asks whether a key left set with every fan
  automatic is harmless. If it is not, the gate goes.

### D6 — Engagement happens at the first `apply`, never at grant, and an `apply` is all or nothing

`LeaseAuthority` stays hardware-free; a grant writes nothing. The first `apply` does four things:

- engages the fans its settings name, through `GovernedFanWriter`'s engage verb and the driver
  (D2–D4), which registers each with § 3;
- registers each fan with § 5 at the landing;
- commands its target through `GovernedFanWriter`;
- reads the target back.

If any fan's engagement fails, every fan that `apply` engaged is restored and the call is refused.

- **A lease that is never applied never takes a fan off automatic control.**
- **A post-wake re-acquire re-runs the unlock with no special case**, because § 4's `.everyFan`
  emptied the engaged set and cleared the force-key flag before the sleep.
- **#307 becomes reachable once `apply` registers with § 5.**
  [#307](https://github.com/blamechris/Aeolus/issues/307) is § 5's release erasing a re-engagement
  that lands during its restore. That is why it is decided before run 2 (D8).

The level-6 body is built in E4, though `apply`'s comment attributes it to E3. E3
([#8](https://github.com/blamechris/Aeolus/issues/8)) lists no such item, and E4 is the only write
path this project can verify.

`docs/SAFETY.md` § 4 leaves "exactly where the unlock re-runs" to E4. ADR 0007 does not address the
question. E5's own Done-when text — "the unlock is re-run as part of the grant (ADR 0007)" — has no
source in ADR 0007, and it is restated to match this decision.

### D7 — Each write takes one supervisor turn; forward writes read, restores do not; the unlock holds no turn between steps

- **Forward verbs** — an engagement step, and `commandTarget` — take one `.supervisor` turn. The
  turn covers a fresh `READ_KEYINFO` (ADR 0004), the write and its read-back.
- **`restoreToAutomatic` takes one `.supervisor` turn per call and issues no read.** It encodes
  `F<n>Md = 0` and `Ftst = 0` from the types and sizes the preparation step recorded (D5), and
  writes them. Both keys are `ui8`, one byte, so there is no byte order for ADR 0004 to resolve.
  Where nothing was recorded, the restore writes one zero byte and reports what the firmware said.

  This keeps three things unchanged:
  - `SMCFanControlPlane`'s property that restore issues no read, asserted by
    `SMCFanControlPlaneTests`;
  - `docs/SAFETY.md`'s keystone;
  - ADR 0007's 2026-09-20 amendment: "no read is queued ahead of it".

  **This amends ADR 0004 in two places, scoping both to forward writes.** The first is its
  sentence "writes resolve the order from a fresh `keyInfo` at write time and are followed by a
  mandatory read-back compare that aborts to automatic on mismatch". The second is its assumption
  row "Writes already re-resolve from fresh `keyInfo`". Applied to a restore, either would put a
  read ahead of the keystone. And a read-back that "aborts to automatic" has nothing to abort to
  when the write *is* the restore.

  A restore's confirmations stay where E5 put them: beside the restore and after it
  ([#204](https://github.com/blamechris/Aeolus/issues/204), #291, #295).
- **The engagement holds no turn between steps.** One engagement in progress adds one outstanding
  supervisor reader to ADR 0012's N while it waits for a turn, and none while it sleeps. The slice
  that adds write turns re-runs ADR 0012's allowance and `theBoundsAreDerivedAndConstant`, as ADR
  0012 requires. It also re-checks D_bringUp against the preparation step's reads.

  A scripted test holds that § 3 keeps completing cycles while an engagement is mid-poll.
- **The write selector is `WRITE_BYTES`, 6.** It goes through the one stamped
  `IOConnectCallStructMethod` site. `docs/SMC-RESEARCH.md` names only selectors 5, 8 and 9 today.
  **The source for 6, and its licence, is recorded in the Sources table there before the change
  that adds the constant**, as `CLAUDE.md` requires.

### D8 — The first supervised write

**Preconditions. Any one failing means no forward write.** Toward-automatic writes are discussed
after this list.

On `main`:

- #180, ADR 0009 D2's per-fan lease check.
- #181 in full (D4).
- #104's two remaining code pieces:
  - **D5's § 7 bullet.**
  - **The corrupted-state integration test.** This is `fanctl reset --all` invoked against
    deliberately corrupted helper state, through the real client and listener over
    `ScriptedControlPlane` answering `.built`. `docs/SAFETY.md` § 7 lists it as "integration tests
    invoked against a deliberately corrupted helper state". It covers at least:
    - a lease whose connection is gone;
    - a fan in manual under no lease;
    - a stale `restoreAbandoned` entry;
    - a latched § 3;
    - a force key set with nothing engaged.

  § 7's other line, "a manual hardware check", is carried by row 18, as `docs/SAFETY.md` already
  says, and it executes in run 1. With both pieces merged, #104 closes. #7 closes when its
  Done-when is restated per ADR 0007's Consequences (Q3).
- The seam shape and the driver, over `ScriptedControlPlane` (D2, D4, D5, D7), including the
  preparation step's protocol requirement and its place in `bringUp()`.
- The level-6 `apply` path (D6).
- #208's correction:
  - the 2026-09-05 rows restated as "non-zero";
  - the hardware print recording the raw value.
- The selector-6 citation (D7).

**Read-only on `Mac16,5`: the pre-flight session.** This runs with the `main`-build helper, which
cannot write.

- **The raw-mode capture that D3 relies on.** It records raw `F0Md`, `F1Md` and `Ftst` at 10 Hz,
  together with `F0Tg` and `F1Tg`, in three phases: 10 min idle; 10 min under a twelve-way load;
  then the heat soak until `F0Tg` falls back. **If any non-zero raw mode appears, run 1 waits for
  the architect.**
- **D9's census (U10) and an exclusion dry run.**

**On the branch:**

- The full review, with a recorded mutation for each of these:
  - the epoch check;
  - both entitlement checks;
  - the not-automatic pre-state refusal;
  - the force-key flag;
  - the LIFO order;
  - both restore writes being attempted after a refusal;
  - the clear on an empty set;
  - restore issuing no read;
  - the preparation step's conditional clear;
  - the unknown-code, unknown-raw-value and budget aborts.
- The branch build identified as D1 says.

**The machine and operator:**

- D9's exclusion, census and quiescence have passed.
- AC power and lid open.
- No build or agent session running on the machine. Concurrent builds distort SMC timing
  ([#227](https://github.com/blamechris/Aeolus/issues/227)).
- `pmset -g therm` clean, the package below 50 °C, and the app quit.
- The maintainer at the machine, with `fanctl reset --all` and
  `sudo launchctl bootout system/com.blamechris.Aeolus.Helper` ready.
- A recorder running:
  - `smc-sampler` at 10 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac`, `F1Ac` and the
    curated package keys. Each key is recorded as its decoded scalar, which for a `ui8` is the
    byte's own value, not the fold.
  - `log stream` on the helper's subsystem, at debug.

**Toward-automatic writes at start: start 0.** The branch helper's first start runs the
preparation step and reconciliation, and either can write toward automatic.

- **In run 1's session, the branch build is installed only after D9's exclusion, census and
  quiescence have passed, with the recorder already running.** That first start is recorded as
  start 0. On the quiescent machine D9 requires, it should read `Ftst` and every `F<n>Md` as `0`
  and write nothing. **A write at start 0 means the quiescence check was wrong: stop.**
- **In later sessions**, D9's reboot starts the installed branch helper before any recorder can
  run. Any toward-automatic write it makes is recorded in the helper's own log, and the gates apply
  to forward writes.

**The run: start 0, then four steps, all on fan 0.**

The target choice is the safety argument. Every hold asks for more cooling than Apple's controller
would ask *at that moment*, so every stuck state the hold can produce — an unlock that will not
undo, or a restore the firmware refuses — is a loud fan, not a hot one.

- **At rest, 50 % (3,564 RPM) is far above Apple's demand.** That demand is stopped, or about
  1,350–1,580 RPM.
- **Under load, 50 % is not.** Demand reached 3433/3683 RPM in the 45 s after a 40 s twelve-way
  load. So the loaded hold runs at the fan's declared maximum, the one target no automatic demand
  can exceed (U13).
- **Fan 1 is left automatic on purpose.** Its behaviour under `Ftst = 1` is U7, and its `F1Tg`
  is a live proxy for what Apple would ask of fan 0 (abort 9).

The four steps:

- **1a — at rest:** `fanctl set 0 50% --for 60s --json`, after 60 s of baseline. This is where the
  report says the naive write succeeds, because the system is not actively asserting control.
- **1b — under a twelve-way load:** `fanctl set 0 100% --for 60s --json`, which commands
  `F0Mx`, 5,777 RPM. It is engaged once `F0Tg` has stayed at least 300 RPM above `F0Mn` for 30 s,
  so that Apple's controller is actively managing the fan. This is where the report says the naive
  write is refused and the unlock is needed. Its abort baseline is the loaded steady state.
- **1b′ — still under load, with no lease held:** `fanctl reset --all`, once. That sends
  `.everyFan` to two fans already in automatic while the thermal manager asserts control (U5b).
  Then stop the load, and wait until the package is within 3 °C of its pre-run baseline and
  `F0Tg` is back at rest.
- **1c — at rest, 30 s at 50 %:** ended early from an SSH session with `fanctl reset --all`
  (row 18).

After each hold's release (D5's restore), run `fanctl auto`, which is ADR 0013's check. Its
verdict reads the fold (D3). Then observe for 120 s, including a 20 s twelve-way load that must
move `F0Tg` and `F0Ac`. The fan following load is the only proof that Apple's management came
back.

**Recorded** in `docs/SMC-RESEARCH.md`'s observed section, with machine state and build:

- start 0's reads and writes;
- every write's key, value, result byte and round-trip duration, the teardown restore's and
  1b′'s included (ADR 0012 H6);
- raw `F0Md` before every forward write and after every accepted one;
- whether the naive write was refused, at rest and under load, and with what;
- time-to-yield and the step count;
- the 10 Hz trace of all seven fan keys through every hold, restore and load;
- whether `F0Tg` held the written value on every § 5 cycle;
- `F0Ac`'s step response, up from about 2,400 and up from rest (row 9);
- fan 1 under the force key (U7), and the force key's state at every point;
- `apply`'s and each heartbeat's client round trip (#325);
- that no third-party SMC client was present.

**Abort.** The maintainer runs `fanctl reset --all` at once on any of these:

1. A curated temperature 10 °C above the hold's baseline, or above 85 °C. The target is above
   Apple's demand, so a rise means the fan is not doing what was written.
2. `F0Ac` or `F1Ac` more than 20 % below its automatic speed for 10 s.
3. An unexplained change, meaning one that no helper write explains:
   - during a hold, from the first accepted forward write until the restore is issued, any change
     to raw `F0Md` or to `F0Tg`;
   - at any time, any change to `Ftst`.

   Fan 1 stays automatic, so `F1Tg` moving is Apple's controller; it is recorded, not an abort. A
   change in raw `F1Md` is recorded for U7, and guarded by abort 2.
4. A result or raw value outside D3's cases, or the budget expiring. The helper undoes on its own;
   the maintainer verifies.
5. Any write round trip over 1 s.
6. Thermal pressure above nominal.
7. The helper exiting or restarting during a hold.
8. Five minutes from engage without a verified restore.
9. Apple's demand overtaking the held target during a 50 % hold: automatic fan 1's `F1Tg` rising
   above 90 % of fan 0's commanded target. Fan 1's demand ran slightly above fan 0's on
   2026-08-20, so this proxy errs early.

**If the restore does not land**, go through the steps below in order. Take each step only if raw
`F0Md`, `F1Md` and `Ftst` are not all `0` on the recorder 10 s after the previous step.

1. **`fanctl reset --all`.** Every lease is released, then `.everyFan` writes every mode, then the
   key, each attempted. This rests on D5's § 7 precondition. On a build without it, this step
   restores covered fans by name only and clears no stray force key (`docs/SAFETY.md` row 18), so
   go straight to step 2.
2. **`sudo launchctl bootout`.** This runs § 6's teardown, which issues two more `.everyFan`.
   launchd will not restart the helper.
3. **`pmset sleepnow`, and wake.** That sleep resets the force key is reported, not observed
   (U12).
4. **Shut down, wait 30 s, power on.** Whether this resets both keys is U11.

A refused restore after a target at or above Apple's demand is a recoverable nuisance. That is
why every hold in run 1 aims there.

**Decided on the result, before anything else runs.**

- **Write latency:**
  - Every round trip at or under 50 ms (D/100) → D stands for writes.
  - Any between 50 ms and 1 s → D is raised to 100× the worst in the merge PR, and ADR 0012's
    derived bounds are re-run.
  - Any over 1 s → stop, and back to the architect.
- **Yield:**
  - If the yield does not arrive in 3.5 s, raise `yieldBudget`, give `apply` a client deadline of
    its own, and repeat. `gatedVerb` bounds every gated message, so raising it would slow loss
    detection on every heartbeat (#325).
  - A yield beyond about 4 s at all → asynchronous engagement before E4 may merge.
- **1b′:** if 1b′ refused a mode write on a fan already in automatic (U5b), the restore path's
  refusal accounting is re-decided before run 2.
- **Hypotheses:** any contradiction of U0–U7, U5b or U13 → `docs/SMC-RESEARCH.md` first, then the
  architect, per `CLAUDE.md`.

**Before run 2,** these must also be in place:

- the ceiling tripwire (D1), on `main`;
- #307 decided, by a fix or a documented exemption;
- the route for [#201](https://github.com/blamechris/Aeolus/issues/201) decided and built over the
  scripted plane. #201 is a reconciliation restore the firmware refuses, which leaves a fan watched
  by nothing; it becomes live once reconciliation can write, and run 2 kills the helper mid-hold;
- ADR 0012 H2, with the read-only halves of rows 2, 16 and 17, run on the `main`-build helper.

**Before the merge**, these must be in place:

- [#332](https://github.com/blamechris/Aeolus/issues/332);
- [#270](https://github.com/blamechris/Aeolus/issues/270), the missing bounds gate on
  `acquireLease`. It is unreachable on `Mac16,5`, whose bounds are plausible, and its issue names
  E3/E4 as its gate.

### D9 — Another SMC writer is excluded by the operator, gated read-only, and never detected by the helper

**Every run before run 4 refuses to start while another SMC writer could be active. The refusal is
the maintainer's act, and it binds forward writes.**

- **Exclusion, product-agnostic.** Quit every third-party fan or SMC utility. Switch its
  background item off in System Settings → General → Login Items & Extensions. Then reboot, so no
  process survives. Re-enable afterwards. Under ADR 0011 D1, that tool loses its settings once per
  Aeolus helper start.
- **Census, read-only.** In run 1's session, the census runs before the branch build is installed.
  In later sessions it runs before the first forward write. The IORegistry's `AppleSMC` user
  clients must be only the Aeolus helper and the runbook's own sampler.
  - That `ioreg` exposes each client with its creating process is U10. It is checked in the
    pre-flight session before it is relied on.
  - The census counts clients and names no product, and nothing in the helper reads it.
- **Quiescence, read-only.** 120 s at 2 Hz in which raw `F0Md`, `F1Md` and `Ftst` read `0` on
  every sample. This sees a writer that is holding, not one that is idle. On 2026-09-05 those two
  states were minutes apart on this machine, so quiescence backs the exclusion rather than
  replacing it.
- **In-run tripwire:** abort 3.

**The helper detects nothing, and ADR 0011 D1 stands.** What ADR 0011 already gives is protection
for the machine, not for the measurement:

- **What it gives:** reconciliation hands a held fan back once; a grant re-reads the mode and
  refuses `.foreignManualControl`; § 5 never adopts a foreign fan.
- **What it does not cover:** a foreign writer taking a fan Aeolus already holds. § 5 reads that
  as `reclaimedBySystem`, a diagnosis that would be false, and re-asserts up to
  `ReclamationLimits.reassertAttemptBudget` (3) before falling back. That is a bounded fight, and
  it produces a trace nobody could interpret. A foreign `Ftst` write would read as a yield or a
  reclamation.

So the tool is tested once, deliberately, last. That run settles ADR 0011's unverified re-assert
assumption and #300's revisit condition.

**No raw mode value is captured with the competing tool holding a fan before run 1.**

- #208 closes by restating its rows as "non-zero".
- D3 writes the community-documented `1`, and accepts it only on its own read-back.
- A value taken from another product's resulting state, captured just before choosing what to
  write, is the provenance question the clean room exists to avoid.

Run 4 records raw values as a matter of course, after this project's own path is established.

### D10 — Runs are ordered by thermal risk

1. **Run 1:** fan 0 only, at or above Apple's demand: at rest, and under load at maximum (D8).
2. **Run 2:** both fans, below automatic (the declared minimum), under a moderate load for 5 min,
   with § 3 armed. It needs D8's before-run-2 list. It covers:
   - rows 1 and 4, with the client Q2 settles;
   - rows 2 and 3: kill the helper with SIGKILL mid-hold, then confirm restart and reconciliation
     (H3);
   - row 8, on D1's lowered-ceiling commit;
   - row 9, under load and downward;
   - the second-fan path of D3 step 3.
3. **Run 3:** lifecycle with a hold. It covers rows 5–7, row 10 ("`Ftst` semantics", as restated),
   row 11, row 17's restore half, and #325's sleep-handback heartbeat.
4. **Run 4:** the competing tool re-enabled, first holding at helper start, then taking a fan
   Aeolus holds.

Each run's findings are recorded, and the branch revised, before the next run.

## Consequences

- Rule 1's line is explicit (D1), and `main` keeps every write tripwire until the merge.
- **ADR 0008 is not amended.** The plane verb and the driver each take one permit. The driver
  joins `WriteVerbAllowlistTests.permitBearingVerbs`, and `WriteAuthorisationTests` is untouched.
- **ADR 0004's write-time sentence and assumption row are amended** to cover forward writes only
  (D7). **ADR 0011 is not amended.** The preparation step extends its D1 discourtesy to the force
  key.
- **`PanicPathScopeTripwireTests`' file set grows from three to five:**
  - `SupervisedFanAuthority.swift`, from § 7, on `main`;
  - `SMCFanControlPlane.swift`, from the plane's own scope switch, on the branch.

  `SignalTeardown.swift`, `SystemPowerResponder.swift` and `StartupReconciliation.swift` are
  unchanged. `theShippedPanicVerbIssuesNoControlPlaneRestore` is inverted, and its seven
  `documentationSites` are walked.
- `docs/SAFETY.md` § 1's statement that a per-lease teardown leaves `Ftst` untouched becomes false
  on the branch, and is corrected at the merge.
- **If U0 fails,** `FirmwareFanMode` needs a new case, or an explicit classification of the value.
  Every E5 confirmation read is then re-examined before run 1.
- **If U5b fails,** a refused `F<n>Md = 0` on a fan already in automatic must not count as a
  failed restore. Otherwise `BoundedFanRestorer` mints durable refusals, and § 6's exit code reads
  a healthy teardown as failed. The remedy is a read after the refusal, which decides only whether
  the refusal is recorded (ADR 0007's 2026-09-20 rule). It is decided before run 2.
- **Five texts are restated, subject to Q3:**
  - E4's "post-wake re-assertion" bullet.
  - Row 10, "`Ftst` semantics: whether sleep resets the Apple Silicon force key, and where the
    unlock must re-run". The new form says that § 4's handback leaves raw `F<n>Md = 0` and
    `Ftst = 0` at wake, and that a post-wake acquire re-runs the unlock.
  - E5's "the unlock is re-run as part of the grant (ADR 0007)" (D6).
  - E5's "Manual hardware test checklist written and executed on Mac16,5". The new form says the
    checklist is written, and executed as E3/E4's gate, per ADR 0007's Consequences.
  - #104's manual hardware check, which becomes row 18.

  Whether firmware also resets the force key across sleep no longer bears on correctness. It
  cannot be observed through the helper without disabling § 4, which no message and no build may
  do. It matters only as a backstop for one residual: a § 4 keystone that was never issued before
  the sleep.
- `fanctl set` (#324) is the bring-up client, and it merges with E4.
- **If U7 fails,** per-fan manual control is not an honest product on such firmware, and the
  lease shape returns to the maintainer.

## Alternatives considered

### A standalone write probe, before any helper code

This is the strongest alternative, and the one an implementer will reach for first. A few hundred
lines would answer U1 to U5 in an afternoon: open the SMC, write `F0Md`, read the code, write
`Ftst`, retry, write `F0Tg`, and restore in a `defer`. It would need no lease, no signing, no XPC,
and no review of a helper change the answers might overturn. Isolating the firmware from the safety
layer is a real virtue for a measurement.

It is rejected on how it fails:

- **A probe that dies holding a fan leaves it to nothing.** Three things can end it mid-hold: a
  Ctrl-C between the forward writes and the `defer`; a crash; or a synchronous IOKit call that
  never returns, which is ADR 0012's case and which no `defer` survives. Any of them leaves `F0Md`
  and `Ftst` set. Nothing counts a lease, nothing watches, and no reconciliation can write, because
  the installed helper answers `.notBuilt`. What is left is sleep (U12, reported) and a power cycle
  (U11, unverified).
- **It needs the write seam outside the helper.** That means `@_spi(FanWrite) import SMCCore`
  under `Tools/`.
  - `WriteSeamAccessTests` scans `Sources/` only, so nothing there would turn red.
  - Each tool's own seam suite is held to forbidden tokens (`ToolsSeamCoverageTests`), and a tool
    written for this would simply not forbid that one.

  The rejection stands on `CLAUDE.md`'s rule instead. A new member of the `FanWrite` audience is a
  safety review, and "the helper is the sole writer" would hold only for code that is not research.
- **Its findings describe a code path that never ships.** There would be no turns, no epoch, no
  entitlement, no § 3 beside it, and no teardown restore through the path ADR 0012 bounds. Run 1
  would still be owed, and it is the run that matters.
- **Reversal cost:** low in code, high in precedent. The second probe is easier than the first.

Revisit this only if the signed helper cannot be built from a branch for an extended period, **and**
the maintainer accepts manual recovery as the only cover.

### The production graph composed inside `swift test`, under `sudo`

This is a close second, and closer than it looks.
`HelperHardwareTests.theComposedHelperServesRealHardware` already composes the production graph
over the real SMC. It uses recording signal sources, a recording terminator and manual watchdog
ticks, and those recording seams are exactly why it cannot be the vehicle for a write:

- **A recording terminator ends nothing, and a test runner is not a launchd job.** A watchdog
  verdict or a crash has no restart and no reconciliation behind it.
- **Recording signal sources run no teardown.** Installing the real ones would apply `SIG_IGN` to
  the runner permanently (`docs/SAFETY.md` § 1). Either way, a Ctrl-C during a hold ends the
  process with the fan pinned.
- **It runs as root, as a new kind of writer.** The whole test target runs as root. A write from a
  test process is a kind of writer the sole-writer rule has never had to consider.

Revisit this if a test host can run as a launchd job with the real teardown and terminator. At that
point it is the daemon.

### The entitlement as a closure parameter on the engage verb

This is `engageManualControl(of:while:)`, with the plane looping internally. It is rejected:

- **It contradicts ADR 0008's sole-parameter rule and its two tripwires.**
  `expectPermitIsTheOnlyParameter` requires exactly one parameter. `SeamScanner`'s `\([^)]*\)`
  cannot span a closure's `()`.
- **A closure that is not handed the index can check a different fan's lease than the one the
  permit names.** That is the disagreement ADR 0008 exists to make unrepresentable.

Amending the rule would loosen a safety tripwire for a convenience D2 does not need.

### The unlock above the seam

This is an `UnlockCoordinator` sequencing raw primitives, `writeMode(_:ofFan:)` and
`writeForceKey(_:)`. It is rejected:

- The primitives take an index rather than a permit, which reopens what ADR 0008 closed.
- Everything that holds the plane could write the force key.
- Platform differences leak above the seam (rule 9).

D2 keeps the sequence below the seam and puts only the cadence above it, which needs none of this.

### Engage at grant

It is rejected:

- It puts firmware writes into `LeaseAuthority`, which owns no hardware by design.
- A lease that is never applied pins a fan at whatever target the thermal manager left.
- A multi-second grant meets the same 5 s deadline for nothing.

### Hold the force key for the helper's life, or set it at bring-up

Rejected. It tells the thermal manager to yield with nobody holding a fan, and whether that is
harmless is U6, which is unknown.

### Clear the force key on every per-fan restore

This is the near miss, and the fallback if U6 fails. It is rejected for now. Inside a two-fan
teardown sweep, clearing the key after the first fan puts the second fan's mode write into the
state the report says refuses mode writes.

### Clear the force key first

Rejected for the same reason, applied to every fan rather than only the second.
`BoundedFanRestorer`'s second attempt runs this order after a refused first one, so this order is
observed without the design depending on it.

### Issue `.everyFan` from reconciliation at every start

This was this ADR's earlier choice, for the force key a dead helper left behind. It is rejected for
three reasons:

- It writes every mode key at every boot, on every machine.
- If U5b fails, it refuses on a healthy machine at every start under load.
- It cannot be recorded before D9's gates, because it runs at the reboot those gates require.

The preparation step (D5) clears only a key that reads set, and on a quiescent machine it writes
nothing.

### Run the loaded hold at 50 %, conditional on the pre-flight's peak demand

This is rejected. The record already shows a heat-soak demand above 3,564 RPM, after a load
shorter than the hold. The condition would very likely fail. If it passed, it would rest the safety
argument on a measurement taken on another day than the hold.

### Run 1 with no load

This is rejected. On the report, the unlock is needed only while the thermal manager is asserting
control. An unloaded run 1 might never exercise it, and run 2 — below automatic — would then be the
first run that did.

### Poll by reading the raw mode byte

Not rejected; conditional. Polling by reading is better than polling by writing whenever a read can
tell "held by the system" from "yielded". D3's pre-flight decides whether this machine offers such
a read.

### Read the raw mode byte with the competing tool holding a fan, to settle #208 first

Rejected for E4 bring-up (D9). #208 closes by restatement, and D3 does not need the value.

### Detect the other writer in the helper

Rejected by ADR 0011 D1 and the clean room. The census is legitimate as an operator's read-only
pre-flight only because it counts clients, names nothing, and changes no product behaviour.

### First write with the competing tool present, relying on ADR 0011

Rejected. ADR 0011 bounds what that tool can do to the machine, not what it does to the measurement
(D9).

### Asynchronous engagement

`apply` would answer at once, and the snapshot would report progress. This is deferred, not
rejected. It is needed only if U3 fails beyond about 4 s. It changes what `apply`'s reply means,
so it needs a version bump.

## Assumptions and what would invalidate them

| # | Assumption | Basis | If it fails |
|---|---|---|---|
| U0 | Apple's own management reads raw `F<n>Md = 0` | Observed only with no load and nothing holding a fan (26.5.2, 27.0.1); "mode 3" is reported; never read under load (#208) | **Any non-zero raw value, `1` included:** before run 1, `FirmwareFanMode`'s fold and every E5 confirmation read are re-decided, and D3 polls by reading (Y-read) |
| U1 | A naive `F<n>Md = 1` succeeds when the system is not actively asserting control, and is refused with `0x82` when it is | Reported. `0x82` has been seen here only on reads of function keys | **Accepted and applied under load:** no force key is needed on this machine; recorded. **Accepted, then taken back within § 5's cycles:** write `Ftst` before the mode write, a conformer-internal change. **Another code:** treated as "held" only after architect review |
| U2 | `Ftst = 1` is accepted, and so is the mode write after it | Reported | No unlock by this route: E4 stops, the snapshot says manual control is unavailable and why, the matrix says so, and it goes back to the architect. Never coded around |
| U3 | The yield arrives within 3.5 s | Reported at about 3 s; budgets of about 30 s suggest a tail | Raise the budget and give `apply` its own client deadline. Beyond about 4 s, asynchronous engagement before merge |
| U4 | An accepted `F<n>Md` reads back raw `1`, and `F<n>Tg` reads back within `ReclamationLimits.targetToleranceRPM` (1 RPM) of what was written | Unobserved; § 5's primary signal rests on the second | **Mode:** D3 refuses, which is correct. **Target:** re-derive the 1 RPM tolerance from the observed quantum before merge (a safety-limit change), or every § 5 cycle reports a reclamation |
| U5 | The reverse-order restore is accepted for a fan the plane engaged | Unobserved | The retry already runs the other order. If only that one lands, D5's order flips, in one place |
| U5b | `F<n>Md = 0` written to a fan already in automatic is accepted, with or without the force key, whatever the thermal manager is doing | Unobserved; tested by 1b′ and by every `.everyFan` | Refusal accounting changes before run 2 (Consequences) |
| U6 | With `Ftst = 1` and every raw `F<n>Md = 0`, Apple's management drives the fans | Unknown | D5's gate goes: every restore clears the key, and every engagement re-sets it. § 4's never-issued keystone becomes a priority residual |
| U7 | `Ftst = 1` does not change the behaviour of a fan Aeolus did not engage | Unknown | A one-fan lease takes the other fans off Apple's management, while the snapshot calls them automatic (rule 6). Engagement becomes all-fans-or-nothing on such firmware, and the lease shape is the maintainer's call |
| U8 | Every write round trip stays under 50 ms (D/100), the teardown restore's and 1b′'s included | Reads: 11.45 ms worst. Writes: unmeasured | D8's decision rule |
| U9 | Manual mode and the force key persist after the writer dies (ADR 0012 H3) | Reported | If they revert on close, ADR 0012 and the preparation step get cheaper; nothing changes |
| U10 | `ioreg` lists every `AppleSMC` user client with its creating process | Hypothesis | D9's census gate is dropped |
| U11 | A power cycle returns raw `F<n>Md` and `Ftst` to `0` | `RECOVERY.md` step 7 asserts that the force key resets. That `F<n>Md` does not persist is `docs/SAFETY.md` row 7's unverified assumption, and ADR 0011's | D8's recovery steps end in a loud fan and `RECOVERY.md` § 8. Run 1's choice of target is what makes that acceptable |
| U12 | Sleep resets `Ftst` | Reported; not depended on (D5) | Only the never-issued-keystone residual widens |
| U13 | Apple's controller never commands above the declared `F<n>Mx` | Observed peak 3,683 RPM against 5,777 declared (2026-08-20) | 1b's "at or above demand" fails by the excess. Abort 9's proxy and abort 1 catch it |
| — | The preparation step can record both restore keys' type and size | Both are `ui8`, one byte, on 27.0.1 | D7 writes one zero byte and reports the firmware's answer |
| — | One lease-table entry, one production plane | True today | Concurrent leases or a second plane: re-check D4's epoch scope and D5's gate |

Every observation above is from `Mac16,5`. The write-path rows are hypotheses until D8 runs. Intel
and M1/M2 ship `untested`.

## Revisit when

Revisit this ADR when any of U0–U7, U5b or U13 is contradicted, by the pre-flight or by a run. That
is the expected case: amend this ADR, and do not code around it.

Also revisit it when any of these happens:

- a write round trip exceeds 50 ms;
- the yield does not fit a synchronous `apply`;
- concurrent leases or self-renewing leases are proposed;
- a second production plane exists;
- a report arrives from M1/M2 or another M3+ machine.

The ruling is the architect's E4 consult, run on Opus.
