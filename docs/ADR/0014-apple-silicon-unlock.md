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
  [ADR 0008](0008-write-authorisation.md)'s engage **parameter list** is unchanged; only its return
  type gains a step value (D2).)

## Context

E4 ([#9](https://github.com/blamechris/Aeolus/issues/9)) is the first epic that takes a fan off
Apple's thermal management. Most of what sits beneath it is built and running in the installed
Developer ID helper on `Mac16,5` since [#82](https://github.com/blamechris/Aeolus/issues/82)
(2026-10-09): the lease, the clamp and the permit (ADR 0008), § 3, § 5, § 4, § 6's reconciliation
and signal teardown, and ADR 0012's watchdog.

Two pieces are not built: § 5's re-assert registering with § 3
([#181](https://github.com/blamechris/Aeolus/issues/181)), and the rest of
[#104](https://github.com/blamechris/Aeolus/issues/104). So E5
([#7](https://github.com/blamechris/Aeolus/issues/7)) is open. ADR 0009 D2's lease check
([#180](https://github.com/blamechris/Aeolus/issues/180)) is built, by
[#342](https://github.com/blamechris/Aeolus/pull/342): § 5 asks it once per examination, not
around each write, which D4 below still requires.

The production plane answers `writeCapability == .notBuilt`, `SMCConnection.write(_:to:)` throws,
and no write selector exists under `Sources/`.

What is known about the write path here is almost nothing, and the gap between known and reported
decides most of this ADR:

| Observed on `Mac16,5`, read selectors only | Reported by community sources, unverified here |
|---|---|
| **The keys and their raw values.** `F0Md`, `F1Md` and `Ftst` exist as `ui8`. Every raw read on record is `00`, and every one was taken with no load and nothing holding a fan. `F<n>Md` was read in the 26.5.2 dump, and in the 27.0.1 dump and 30 ticks of [#323](https://github.com/blamechris/Aeolus/issues/323). `Ftst` was read in those, and on 26.6.2 at 2026-09-05 20:13 and before and after that night's lid close. One byte and attributes `0xD0` were recorded on 27.0.1 only | A naive `F<n>Md = 1` succeeds "when the system is not actively asserting control", and is refused with `0x82` when it is |
| **What "held" reads as.** While a third-party tool held both fans, `F<n>Md` **decoded non-zero**; it read zero again with the tool still running (26.6.2, 2026-09-05). That reading is `FirmwareFanMode`'s fold — `0` is automatic, anything else is manual — not the byte ([#208](https://github.com/blamechris/Aeolus/issues/208)). Manual mode of *some* value is reachable on this hardware, by a route this project has not seen and will not inspect | `Ftst = 1` makes the thermal manager yield in about 3 s; retry budgets run to about 300 × 100 ms |
| **The target key and Apple's speeds.** `F<n>Tg` is `flt` with attributes `0xD4`: bit `0x04` is set, so it is little-endian under ADR 0004. Under sustained load, `F0Tg` rose from 1350 to 2195 RPM with `F0Ac` tracking it (26.5.2). Other fan speeds recorded under Apple's control, with the key not recorded except where noted: at rest, fans stopped (26.6.2, 2026-08-20); `F0Ac` 1,343 RPM with `F0Tg`/`F1Tg` at 1350/1458 (26.5.2, 2026-07-25); `F0Ac` 1,529–1,578 RPM (27.0.1, 2026-10-08). Under a 40 s twelve-way load, 2372/2551 RPM; **45 s after that load stopped, 3433/3683 RPM** (2026-08-20). The speeds peak in the heat soak, after the load. D8's pre-flight is the first 10 Hz record of `F<n>Tg` through a load and its heat soak | The thermal manager "holds the fans in mode 3". **Unverified here**: no raw `F<n>Md` other than `0` has been recorded, and none under load or while a fan was held (#208). So whether Apple's management or a held fan reads `3` is unknown |
| **Latency.** The worst read round trip was 11.45 ms over 912,000 reads (27.0.1) | Release must restore the mode **and** clear `Ftst`; sleep resets `Ftst` |
| **The competing tool.** A competing fan-control tool was running in most recorded captures: its app and privileged helper throughout the [#296](https://github.com/blamechris/Aeolus/issues/296) latency runs, and present for #323. It was quit for the 2026-09-05 20:13 reading. The 2026-07-25 and 2026-08-20 sessions do not record it | — |

Nothing has ever been written. The unlock is a hypothesis and the first write is an experiment —
but it is also the first time the safety subsystem acts on real firmware. Two choices have to be
made before any of it is coded, and both are expensive to reverse:

- **What code path the experiment runs through.** That decides whether its findings describe the
  code that ships, and whether a failure mid-run is covered by restart and reconciliation.
- **Who owns the force key.** That decides the keystone's shape on M3+, where `Ftst` is
  machine-wide and every lease, permit and restore is per fan.

Five facts about the tree constrain both:

1. **Level 6 does not exist.** `SupervisedFanAuthority.apply` refuses unconditionally.
   `GovernedFanWriter` has no caller and no engage verb. `engageManualControl(of:)` has one caller:
   § 5's re-assert, through `SafetyActorWriter`.
2. **A release can arrive mid-unlock.** `renewLease` and `releaseLease` are dispatched on arrival
   ([#229](https://github.com/blamechris/Aeolus/issues/229)), so a release can arrive while a
   multi-second `apply` is still unlocking. ADR 0009 D2's check is built (#342) but is asked once
   per § 5 examination, and not by `apply` at all.
3. **One deadline covers every gated message.** `HelperClientDeadlines.gatedVerb` bounds every
   message behind the handshake gate, `apply` and the heartbeats alike. It is 5 s and unmeasured
   ([#325](https://github.com/blamechris/Aeolus/issues/325)). The reported yield is about 3 s.
4. **Only the daemon is covered if it dies.** The installed helper cannot write. A process that
   dies holding a fan is covered by restart and by a reconciliation that can write **only if that
   process is the launchd-managed daemon**.
5. **E5's mode reads all rest on one unconfirmed observation.** Every mode read in E5 goes through
   `FirmwareFanMode`'s fold: reconciliation, the grant path, § 3's and the lease core's read-backs,
   § 5's cycle, and the snapshot (and so `fanctl status` and `fanctl auto`). All of them assume
   Apple's own management reads raw `0`. That has been observed only with no load and nothing
   holding a fan. Bring-up reads no key table. Its only fan enumeration happens inside
   `reconcileFans()`, through the composition's `FanEnumerating`. The plane never reads `Ftst`.

The slices that implement this ADR, their order, and the maintainer's questions are in the slice
plan on #9. D8 lists what run 1 depends on, so this document can be read without the plan.

## Decision

### D1 — The experiment is the production path, in the installed daemon, built from an unmerged branch. There is no bring-up mode

The first write, and every hardware row after it, runs through the code that will ship:

- `SMCConnection.write`'s body;
- the plane's write verbs and its bring-up preparation step (D5);
- the engagement driver (D2);
- the level-6 `apply` path;
- the lease, § 3, § 5 and § 4;
- ADR 0009's checks and ADR 0012's watchdog.

All of it runs inside the launchd-managed helper. The maintainer builds that helper `Full Release`
from the head of `e4/bring-up` and installs it over the current one. It is driven by the signed
`fanctl` embedded in that build, through the ordinary `acquireLease` and `apply` — that is, through
`fanctl set` ([#324](https://github.com/blamechris/Aeolus/issues/324)), which the branch carries.

- **No mode, no flag, no environment variable.** What an experiment varies — fan, target,
  duration, machine load — is a `fanctl set` argument or the operator's choice. What it measures is
  permanent instrumentation:
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

  Code above that line may merge once E5 **exists and is tested**. That is `CLAUDE.md`'s phrase,
  read the way ADR 0007's Consequences read it: every E5 mechanism built and tested against the
  scripted plane, with the hardware checklist written.

  **This ADR takes that point as #180 and #104's two remaining code pieces (D8) being on `main`.
  #181 lands in the same change as the driver that carries it (D4), and every other piece of code
  above the line follows that change.** Nothing at or below the line merges before the E4 gate.
- **Reviewed before hardware, merged after it.** The branch gets its full review — a review panel
  and a Codex pass — before run 1. The merge waits for the checklist.
- **One permitted build-time variation.** Checklist row 8 runs on a throwaway commit that lowers
  § 3's ceiling through `ThermalEmergency`'s existing `requestedCeilingCelsius`.
  `ThermalCeiling.effective` clamps that value downward only, so the emergency fires a few degrees
  above idle rather than at 95 °C. The change can only make § 3 fire earlier, and no client
  reaches it.

  **A source tripwire, added to `main` before run 2, holds that `HelperComposition.init` passes no
  `requestedCeilingCelsius`.** `HelperComposition.init` is where `ThermalEmergency` is
  constructed, so the throwaway commit turns the tripwire red by construction. That makes "dropped
  before the merge" enforced rather than remembered.

### D2 — The unlock's sequence is the plane's, its cadence is a driver's, and the engage verb still takes a permit and nothing else

- **The sequence is inside `SMCFanControlPlane`:** which keys, which values, what a refusal code
  means, and whether the force key is needed, as `readControlState`'s documentation anticipates.
  Above the seam, nothing writes, reads or names `Ftst`.

  The platform split is keyed on what the SMC declares and how it answers, never on the chip
  (rule 9). The force key is set only if the preparation step (D5) recorded `Ftst` as present, and
  only after the firmware refused a naive mode write. A machine whose firmware accepts the naive
  write runs the same code and **never sets `Ftst`**. That covers M1/M2, which are untested and
  ship `untested`.
- **The plane verb performs one step and reports progress:**
  `engageManualControl(of: CommandableFan) async throws -> EngagementStep`, where `EngagementStep`
  is `.engaged` or `.awaitingYield`.
  - The parameter list is ADR 0008's, unchanged: one permit and nothing beside it. So
    `WriteAuthorisationTests.everyEngageVerbTakesAPermit` and
    `WriteVerbAllowlistTests.aPermitTravelsBesideNothingThatNamesAFan` stand as they are.
  - The return type changes from nothing to `EngagementStep` at its three declarations: the
    protocol, the conformer and `SafetyActorWriter`.
- **The cadence is an `EngagementDriver`:** the interval, the budget, the entitlement check before
  and after each step, and the undo. It is one helper-internal type, and both writers' engage verbs
  go through it:
  - `SafetyActorWriter.engageManualControl(of:)`, for § 5;
  - a new `GovernedFanWriter.engageUnderLease(of: CommandableFan)`, for level 6. It is named apart
    from `engageManualControl(of:)` because both writers are declared in `SafetyWriters.swift`.
    `WriteVerbAllowlistTests` keys a verb by file, name and parameters, so a second
    `engageManualControl(of:)` there would land silently under the existing entry. The new name
    still matches `everyEngageVerbTakesAPermit`'s `engage\w*`.

  The driver's sources are stored properties set at composition, never arguments:
  - the lease core's per-fan liveness query (#180);
  - § 3's latch;
  - its writer's level;
  - § 3's registration role.

  So its verb is `engageManualControl(of: CommandableFan)` as well, and it always asks about the
  permit's own index. The fan whose lease is checked cannot differ from the fan being written.

  How `WriteVerbAllowlistTests` classifies the new functions:
  - The driver's engage and `engageUnderLease(of:)` join `permitBearingVerbs`.
  - **The driver's undo takes the fan's index, never the permit.** It joins `permitFreeFunctions`,
    because it reaches a write only through `restoreToAutomatic`.

  **As built on `main` (slice A4 of #9, with #181):**
  - § 5's re-assert calls the driver; `SafetyActorWriter.engageManualControl(of:)` is the
    one-step pass-through the driver steps through, and nothing else in `Sources/` calls it.
    `EngagementDriverTests.onlyTheDriverEngages` holds that.
  - § 5 runs the unlock only for a reclaimed mode. D3's first step refuses a fan whose raw mode is
    not `0`, so a fan still in manual whose target diverged is re-commanded alone, after the
    driver's `requireEntitlement(for:)`.
  - `permitBearingVerbs` gained the driver's `engageManualControl(of:)`, `firstStep(of:)` and
    `requireEntitlement(for:)`, and § 3's role requirement `manualControlEngaged(_:)`.
    `permitFreeFunctions` gained `handBack(fanAt:)` (the undo), `handbackAccepted(fanAt:)`, the
    preparation step's requirement and its conformer, and `HelperComposition.prepareWritePath()`.
  - A restore no longer erases an engagement's epoch record, so a restore of the engaging fan or a
    machine-wide one supersedes it; a fresh engagement that finds an earlier one's record out of
    date retries its first step once, after the entitlement (see `EngagementDriver.firstStep`).
  - The restore's plan is decided when it is issued, inside its turn (`PlaneWriteLedger`).
  - **B1 preconditions this leaves.** `PlaneWriteLedger` records the force key's presence but
    not the declared type and size of each `F<n>Md` and of `Ftst`, which D7's encoding of a
    restore needs; B1 adds them to the preparation record. B1's production step must call
    `recordModeWriteIssued(fanAt:)` for every mode write it issues. And B1's restore must call
    `restoreRequested()` synchronously when it is called, **before** it waits for its scheduler
    turn, and `issueRestore(fanAt:)` / `issueMachineWideRestore()` **inside** that turn: the
    scripted double runs both in one actor turn, so no test on `main` can show the split.

### D3 — The engagement sequence, which is the hypothesis under test

**Raw values, and where the fold remains.** The plane's own mode reads, and D8's recorder, use the
raw `F<n>Md` value: the declared `ui8` decoded to its integer, never `FirmwareFanMode`'s fold
(#208).

The fold remains where E5 already uses it: reconciliation, the grant path, § 3's and the lease
core's read-backs, § 5's cycle, and the snapshot. That includes the `mode` field `fanctl status`
and `fanctl auto` read, where [#178](https://github.com/blamechris/Aeolus/issues/178) also reports
an unreadable mode as automatic.

U0 is what makes keeping the fold safe; if it fails, those uses are re-decided before run 1. U14
bears on the preparation step and on D3 step 3, not on the fold.

**Logging and budgets.** Every step logs the key, the value written, the result byte, the raw
values read before and after, the round-trip duration and the attempt number. The budgets are
`UnlockLimits`, the driver's constants, defined beside `RestoreLimits`.

**Which yield signal the poll uses is decided before run 1, by D8's read-only pre-flight.** The
pre-flight records raw `F0Md`, `F1Md` and `Ftst` at 10 Hz: idle, then through a sustained
twelve-way load while Apple's controller ramps `F<n>Tg`, then through the heat soak after it.

- **Raw `F<n>Md` and raw `Ftst` read `0` on every sample.** Apple's management is invisible in both
  keys, and the poll **retries the mode write** (Y-write), on a measured basis.
- **Any raw `F<n>Md` other than `0` — including `1` — or any raw `Ftst` other than `0`.** These
  return to the architect before run 1:
  - `FirmwareFanMode`'s fold, which every E5 confirmation read relies on, and which would then call
    Apple's own management manual;
  - for a mode key, the poll, which becomes **read until raw `F<n>Md` leaves that value, then
    write** (Y-read), so the firmware is asked once rather than up to 35 times;
  - for `Ftst`, the preparation step's premise that a set key was left by a dead holder (D5), and
    D3 step 3's write over a key Apple itself sets.

**For one fan *n*:**

1. **Pre-state and the first write.** The driver asks the entitlement (D4). Then, in one plane
   turn:
   1. Check the restore epoch (D4).
   2. Read raw `F<n>Md` as the pre-state. If it is not `0`, throw `.notAutomatic` and write
      nothing: a fan that is not automatic is not Aeolus's to take.
   3. Resolve `F<n>Md`'s type and order from a fresh `READ_KEYINFO` (ADR 0004).
   4. Write `F<n>Md = 1`.
2. **On `0x00`**, read raw `F<n>Md` in the same turn:
   - **`1`** → `.engaged`, with the force key untouched. This is evidence of engagement only
     because the same turn read `0` immediately before the write. When the system is not actively
     asserting control, this is the reported first step. Under load it disagrees with the report.
     It is recorded either way.
   - **`0`** → accepted is not applied
     ([#291](https://github.com/blamechris/Aeolus/issues/291)): throw.
   - **Any other value** → throw, and back to the architect.
3. **On `0x82`**, it depends on the force key's state:
   - **`Ftst` recorded present, and the plane's force-key flag (D5) clear:** in the same turn,
     re-check the epoch, take a fresh `READ_KEYINFO`, and write `Ftst = 1`. `0x00` sets the flag
     and returns `.awaitingYield`; anything else throws.
   - **The flag is already set** (for example, a second fan engaging while the first holds the key):
     write no key and return `.awaitingYield`. This fan waits for its own yield under the key
     already set.
   - **`Ftst` recorded absent:** throw. This firmware offers no route this ADR knows.
   - **`Ftst` recorded unknown:** treat it as present.

   **Any first result other than `0x00` or `0x82`** throws, with no force key and no retry. That
   includes the other codes this machine has returned to reads: `0x89`, `0xc7`, `0xcb` and `0xd8`.
4. **While `.awaitingYield`**, every `UnlockLimits.pollInterval` (100 ms), the driver asks the
   entitlement and takes another step:
   - **Y-write:** check the epoch, then write `F<n>Md = 1`. `0x00` → read back as in step 2.
     `0x82` → `.awaitingYield`. Anything else → throw.
   - **Y-read:** read raw `F<n>Md`. If it still reads the non-zero value → `.awaitingYield`, with
     nothing written. Otherwise, proceed as Y-write.

   When `UnlockLimits.yieldBudget` elapses — 3.5 s for run 1, so at most 35 steps — the driver
   undoes and refuses. **No turn is held between steps.** The step records the time from `Ftst`'s
   acceptance to `.engaged`, and the step count.
5. **On `.engaged`**, the driver registers the fan with § 3, runs D4's after-check and returns.
   `apply` then registers the fan with § 5, commands its target, and reads `F<n>Tg` back.

On any throw, the driver undoes (D4, D5) and refuses — with two exemptions, both before anything
of the engagement's was written: a first step refused `.notAutomatic` (undoing it would be ADR
0011's contest), and a first step superseded at its admission, which the driver retries once after
asking the entitlement again (as built, `EngagementDriver.firstStep`). A step superseded after its
mode write, before `Ftst = 1`, is `.supersededAfterWrite`, and is undone.

The budget is sized to the client rather than to the report: 3.5 s leaves `gatedVerb`'s 5 s room
for the target write and its read-back. A budget that proves too short fails safe.

The new refusals — the firmware refused the unlock; the yield did not arrive; the fan was not
automatic — are additive `ManualControlAvailability.Reason` cases under `AeolusXPCVersion`'s bump
policy.

### D4 — Every write away from the safe state is checked before, inside and after; a restore supersedes an engagement; ADR 0009 D1's residual remains, and is covered

An engagement is seconds of writes away from the safe state. A release, § 4's handback, a § 3
latch or a § 5 fallback can arrive at any point in it. ADR 0009 applies to every step, for both
callers.

- **Before each step**, the driver asks the entitlement. Two things must hold:
  - **A live lease covers fan *n*.** This is #180's per-fan query, and ADR 0009 D2, which binds
    § 5's re-assert exactly as it binds level 6.
  - **`SafetyArbiter` permits the driver's level against § 3's latch.** This is ADR 0009 D1's
    ruling, read at the write.

  For § 5, this is the pre-engage `currentRuling()` guard that #181's 2026-09-05 comment asks for.
  § 5 keeps its own `held` re-fetch around the call.
- **Inside the step's turn**, the plane checks a restore epoch. Every `restoreToAutomatic` call
  increments the counter **synchronously, when it is called, before it waits for a turn**. An
  engagement records the epoch at its first step. Once the epoch has moved, the engagement writes
  nothing more and throws `.superseded`.

  A turn is one indivisible occupation of the connection. So no forward write **after an
  engagement's first step** lands after a restore that was *requested* before that write's turn
  began. The first step itself is the exception: it records the epoch, so a restore requested
  before its turn is not seen — ADR 0009 D1's residual, below.
- **After `.engaged`**, the driver registers the fan with § 3, then asks the entitlement again. If
  it has gone, the driver undoes.

The plane's own state is lock-guarded, under the discipline `SMCRoundTripMonitor` already uses, and
held by the one production plane. It consists of the restore epoch, the engaged set (D5), the
force-key flag (D5), and the set of fans it has touched (D5).

**What this removes, and what it leaves.** ADR 0009 D1 requires this to be stated, and warns that
calling the window closed "would be the more dangerous spelling".

- **What the epoch removes, structurally:** one race inside the plane, in which a forward write
  of an engagement already under way lands after a restore that was requested first. A forward write that lands just ahead of a
  restore's turn is undone by that restore, which runs after it. That order is correct.
- **What remains:** the epoch does **not** make the entitlement check atomic with the write. A
  lease can end, or § 3 can latch, between the driver's check and the step's turn — and a restore
  requested before an engagement's first step is not seen by the epoch at all. Every genuine
  restore ends the lease (immediately before or right after the restore) or latches § 3, so the
  driver's next check sees it.

  That residual is ADR 0009 D1's. It is discharged the way D1 prescribes, by acting and then
  checking: the after-check, then the undo. The undo is itself a write the firmware can refuse.
- **What covers a refused undo:** the driver registered the fan with § 3 *before* the after-check.
  So the fan stays in § 3's registry until a read confirms it automatic
  ([#295](https://github.com/blamechris/Aeolus/issues/295),
  [#300](https://github.com/blamechris/Aeolus/issues/300)), and the next emergency bridges and
  restores it.

**#181 lands in the same change as the driver, and in full.** It must be on `main` before run 1,
because § 5's re-assert — the only existing caller of `engageManualControl` — runs the unlock from
the first build that has one. In full means:

- the § 3 registration on engage, in the driver, for both callers;
- deregistration in `finaliseRelease` and `restoreAndForget`. The second was
  `releaseToThermalEmergency` until #342, and has three callers since: § 5 yielding to § 3,
  `.leaseLapsed`, and a release during a re-assert write. Whoever builds #9's slice-plan row
  A4 (the engagement driver and #181) decides whether § 3 deregistration applies to each;
- a test in which the emergency latches mid-write and the undo is refused. It ends with the fan in
  § 3's registry, bridged by § 3's next latched cycle;
- the pre-engage ruling;
- a rewrite of
  `ReclamationWatchdogStalenessTests.itUndoesAReassertWhenTheEmergencyLatchesMidWrite`. The
  driver's before-step latch check turns that test red by design. The rewrite asserts refusal
  before the write at the `.envelopeRead` moment, and keeps a separate case for a latch that
  arrives after the ruling, so the post-write undo stays covered;
- a mutation for each of the above;
- an update to ADR 0009's "As built" section.

**The keystone gains no input:** incrementing a counter is not reading trusted data. **No restore
waits for an engagement to finish.** A restore waits at most for the turn in flight and the turns
queued ahead of it at `.supervisor` (D7).

### D5 — The force key is the plane's, reference-counted by what the plane engaged, cleared last, and checked at every start

- **An engaged set.** A fan joins when its mode write is accepted *and* raw `F<n>Md` reads back
  `1`, after a pre-state of `0` read in the same turn (D3). It leaves when any restore covering it
  is **issued**, whatever the firmware answers.
- **A touched set, which never shrinks.** It holds every fan index this plane has engaged or
  restored by index in this process. It lives in memory beside the engaged set, and is never read
  from the SMC.
- **A force-key flag.** It is set when this plane's `Ftst = 1` is accepted, and cleared when a
  restore **issues** `Ftst = 0`. Between the key's acceptance and the first fan joining, the engaged
  set is empty while the flag is set. So a `.fan(n)` restore in that window — the undo of an
  engagement that never joined — clears the key, which is correct.
- **Restore is the unlock reversed: every `F<n>Md = 0` in scope, then `Ftst = 0`.** Each write is
  issued in the force-key state in which its forward write was accepted. Clearing the key first
  would issue the mode writes in exactly the state the report says refuses them. A refusal there
  mints a durable `restoreToAutomaticFailed` for a fan with nothing wrong with it.
- **Every write in a restore is attempted, regardless of the others.** A refused mode write is
  still followed by the force-key clear, the strongest remaining lever to bring the thermal manager
  back. The restore throws only after all of them were attempted. A key recorded absent is never
  written.
- **`.fan(n)` clears the force key when the engaged set is empty after it.** So a per-lease
  teardown clears `Ftst` exactly when it hands back the last fan the plane engaged, and never while
  another engaged fan depends on it. `KeystoneRestoreAttempt` still issues `.fan(index)` only: the
  decision sits with the conformer, where the knowledge is.
- **`.everyFan` clears the force key unconditionally, and empties the engaged set.** It writes the
  mode of every fan the preparation step enumerated, and of every fan in the touched set.

  If the bring-up enumeration failed, `.everyFan` writes the touched set's fans and the force key,
  then throws `.fanSetUnknown`, a new `FanControlPlaneError` case, after attempting them. **So
  every fan this process engaged or restored is written, whatever its earlier restore answered.**
  The throw says that fans this process never touched were not.

  Every caller treats a throwing keystone as not landed:
  - **§ 4** catches it, logs it at `.fault`, and reports the keystone `.refused`. That state's
    documentation in `SystemPowerResponder.swift` says "the force key was not cleared". That
    becomes false once a restore attempts every write, and for `.fanSetUnknown`. It is corrected in
    the change that sets the seam's restore contract (D8).
  - **§ 6** maps it to a non-zero exit. launchd restarts the helper only after a signal it did not
    send itself; after `bootout` or a shutdown, nothing restarts it.
  - **Reconciliation's enumeration-failure branch** refuses every grant.
  - **§ 7** logs it at `.fault` (below).
  - **The preparation step's own `.everyFan`** logs it (below).
- **`BoundedFanRestorer`'s retry tests the other order for free.** A first attempt whose mode write
  is refused has already cleared the key, because the set emptied when the restore was issued. So
  the second attempt writes `F<n>Md = 0` with `Ftst = 0`.

**The write-path preparation step**, new in bring-up. It runs after the watchdog arms and
`bindSafetyRegistries()`, and before `reconcileFans()`. It does four things:

1. **Enumerates fans** through the composition's `FanEnumerating` (`reading`), the seam
   reconciliation and `acquireLease` already use; the plane holds no provider of its own. It records
   the indices, which become the enumerated part of the fan set `.everyFan` writes (the touched set
   is the other part), and it logs whether the enumeration succeeded, which D8's start-0 check reads.
2. **Records key types.** By `READ_KEYINFO`, it records the declared type and size of every
   `F<n>Md`, and records `Ftst` as one of: **present** with its type; **absent**, because the
   firmware reported no such key; or **unknown**, because the read failed.
3. **Reads raw `Ftst`**, if `Ftst` is present.
4. **Issues `restoreToAutomatic(.everyFan)` once**, if any of these holds:
   - raw `Ftst` reads anything other than `0`;
   - `Ftst` is unknown;
   - its read in step 3 fails.

   An absent key is never read or written again.

How it is classified and bounded:

- **Classification.** The step's requirement and its conformer reach a write only through
  `restoreToAutomatic`, so both join `WriteVerbAllowlistTests.permitFreeFunctions`. That adds no
  new restore verb, no new scope, and no new safety classification.
- **Timing.** Its reads happen at bring-up, never at restore time. It runs inside D_bringUp, and
  its round trips are stamped like any other.
- **Failure.** Its failure is logged and never blocks serving. On a `.notBuilt` plane it does
  nothing.
- **Its own `.everyFan`.** That restore is observed and logged like § 4's, and records no durable
  refusal: reconciliation's per-fan pass, which follows, reads every fan's mode itself.

What it covers: a helper that died holding the key with every fan already back in automatic.
Without the step, nothing clears that `Ftst = 1`, because reconciliation's per-fan pass finds
nothing in manual. On a quiescent machine the step writes nothing. It extends ADR 0011 D1's one-time
discourtesy to a force key another tool may hold, and amends nothing in ADR 0011.

**§ 7's panic verb issues `.everyFan` on a plane whose `writeCapability` is `.built`.** It does so
**between `releaseEveryLease()` and `confirmAcceptedHandbacks()`**, so the read-back follows the
keystone and never precedes it (ADR 0007's 2026-09-20 amendment). On a `.notBuilt` plane it issues
nothing more.

- **Route.** `SupervisedFanAuthority` is handed two narrow roles of the plane, never the plane
  itself:
  - a restore-only role, whose one verb is `restoreToAutomatic(_:)`;
  - `FanWriteCapabilityReporting`.

  It still cannot command a fan.
- **The reply is v1's "accepted" in every case.** `restoreAllToAutomatic` answers *accepted*, never
  *done* (ADR 0013).
  - **A refused `.everyFan` on a `.built` plane** is caught explicitly — never with `try?` — and
    logged at `.fault`. The snapshot's existing reasons report what happened to the fans: a fan
    still manual reads as such, under the reason the availability ladder already gives it.
  - **A refused force-key clear** has no snapshot field, and is reported by the fault line alone.
  - **There is no `AeolusXPCVersion` bump.** The reply now follows one more restore call — three
    key writes on `Mac16,5`. The client's `panicVerb` deadline (10 s, unmeasured) covers it, and
    D8 records the reply's round trip.
- **It is one of #104's two remaining code pieces (D8), and lands on `main` before run 1.** It
  carries these changes:
  - It inverts `PanicPathScopeTripwireTests.theShippedPanicVerbIssuesNoControlPlaneRestore`, with a
    mutation for each capability (renamed in #349 to
    `thePanicVerbIssuesTheMachineWideRestoreOnlyOnABuiltPlane`).
  - It adds `SupervisedFanAuthority.swift` to the file set that
    `everyMachineWideRestoreIsOneOfTheThreeKnownCallSites` holds (renamed in #349 to
    `everyMachineWideRestoreIsOneOfTheKnownCallSites`).
  - It walks that suite's eight `documentationSites` (seven when this was written; #345 added
    `docs/records/handback-ledger.md`), including `docs/SAFETY.md` § 1's "three call
    sites" sentence. It corrects `docs/SAFETY.md` § 7's sentence calling the handler-side restore "a
    v1 contract change" that "belongs with the write path rather than before it": the reply's shape
    and meaning are unchanged — accepted, never done — so it is not a contract change and needs no
    bump.
  - It also walks three sites the list does not yet name:
    - `SupervisedFanAuthority`'s header paragraph, "It holds no plane, no capability reporter, and
      cannot write", with its record of a capability reporter removed as decoration;
    - `restoreAllToAutomatic`'s note on the read-back;
    - `LeaseAuthority.confirmAcceptedHandbacks()`'s "the one caller with no keystone queued behind
      the read".
  - It corrects the suite's three references to the call-site list as "§ 5's": the list is in § 1.

  On the branch, `SMCFanControlPlane.swift` joins the set too. Its restore branches on scope, and
  its preparation step names `.everyFan`; the scan, `code.contains(".everyFan")`, cannot tell
  either from a call site, and the test's message says so.

  Without this change, `fanctl reset --all` — D8's first recovery step — clears no stray force key.

**The keystone holds, and its one data-dependent branch is named.**

- **No restore write consumes trusted data:** no bounds, no reading, no lease, no permit (D7). The
  fan set, the key types and `Ftst`'s presence come from the preparation step. The touched set comes
  from the plane's own memory. Nothing is read at restore time.
- **The one data-dependent branch is the engaged set's.** It decides only whether `.fan(n)` *also*
  clears the key, and it can err only toward leaving the key set.
- **Every `.everyFan` removes the key.** That covers § 4 before sleep, § 6's teardown, § 7's panic
  verb, and reconciliation's fallback wherever its pass cannot see (ADR 0011 D3). The preparation
  step removes it again at the next start.
- **Whether a key left set with every fan automatic is harmless is U6.** If it is not, the gate
  goes.

### D6 — Engagement happens at the first `apply`, never at grant, and an `apply` is all or nothing

`LeaseAuthority` stays hardware-free; a grant writes nothing. The first `apply` does four things:

1. It engages the fans its settings name, through `GovernedFanWriter.engageUnderLease(of:)` and
   the driver (D2–D4). The driver registers each fan with § 3.
2. It registers each fan with § 5 at the landing.
3. It commands each fan's target through `GovernedFanWriter`.
4. It reads each target back.

If any fan's engagement fails, every fan that `apply` engaged is restored, and the call is
refused.

- **A lease that is never applied never takes a fan off automatic control.**
- **A post-wake re-acquire re-runs the unlock with no special case,** because § 4's `.everyFan`
  emptied the engaged set and cleared the force-key flag before the sleep.
- **#307 becomes reachable once `apply` registers with § 5.**
  [#307](https://github.com/blamechris/Aeolus/issues/307) is § 5's release erasing a re-engagement
  that lands during its restore. #342 closed it for `restoreAndForget`, which now forgets before
  it restores, so it remains for `finaliseRelease` only. D8 says why run 1 tolerates it, and
  requires it decided before run 2.

The level-6 body is built in E4, though `apply`'s comment attributes it to E3: E3
([#8](https://github.com/blamechris/Aeolus/issues/8)) lists no such item, and E4 is the only write
path this project can verify.

`docs/SAFETY.md` § 4 leaves "exactly where the unlock re-runs" to E4, and ADR 0007 does not address
the question. E5's own Done-when text — "the unlock is re-run as part of the grant (ADR 0007)" —
has no source in ADR 0007, and is restated to match.

### D7 — Each write takes one supervisor turn; forward writes read, restores do not; the unlock holds no turn between steps

- **Forward verbs** — an engagement step, and `commandTarget` — take one `.supervisor` turn. The
  turn covers a fresh `READ_KEYINFO` (ADR 0004), the write and its read-back.
- **`restoreToAutomatic` takes one `.supervisor` turn per call and issues no read.** It encodes
  `F<n>Md = 0` and `Ftst = 0` from the types and sizes the preparation step recorded (D5), and
  writes them. Both keys are `ui8`, one byte, so there is no byte order for ADR 0004 to resolve. A
  key recorded absent is not written. A key recorded unknown gets one zero byte, and the restore
  reports what the firmware said.

  This keeps three things unchanged:
  - `SMCFanControlPlane`'s property that restore issues no read, asserted by
    `SMCFanControlPlaneTests`;
  - `docs/SAFETY.md`'s keystone;
  - ADR 0007's 2026-09-20 amendment, "no read is queued ahead of it".

  **This amends ADR 0004 in two places, scoping both to forward writes.** The first is its
  sentence "writes resolve the order from a fresh `keyInfo` at write time and are followed by a
  mandatory read-back compare that aborts to automatic on mismatch". The second is its assumption
  row "Writes already re-resolve from fresh `keyInfo`".

  Applied to a restore, either would put a read ahead of the keystone. A read-back that "aborts to
  automatic" has nothing to abort to when the write *is* the restore.

  A restore's confirmations stay where E5 put them, beside it and after it
  ([#204](https://github.com/blamechris/Aeolus/issues/204), #291, #295).
- **The engagement holds no turn between steps.** One engagement in progress adds one outstanding
  supervisor reader to ADR 0012's N while it waits for a turn, and none while it sleeps.
  - The slice that adds write turns re-runs ADR 0012's allowance and
    `theBoundsAreDerivedAndConstant`, as ADR 0012 requires.
  - It also re-checks D_bringUp against the preparation step's reads.
  - A scripted test holds that § 3 keeps completing cycles while an engagement is mid-poll.
- **The write selector is `WRITE_BYTES`, 6,** through the one stamped `IOConnectCallStructMethod`
  site. `docs/SMC-RESEARCH.md` names only selectors 5, 8 and 9 today. **The source for 6, and its
  licence, is recorded in that file's Sources table before the change that adds the constant**, as
  `CLAUDE.md` requires.

### D8 — The first supervised write

**Preconditions.** If any one fails, there is no forward write. Toward-automatic writes at start
are covered under "Start 0" below.

**On `main`**, in this order where they depend on each other. Items 1 to 4 are sequential; items 5
and 6 are independent.

1. **#180**, ADR 0009 D2's per-fan lease check.
2. **#104's two remaining code pieces:**
   - **D5's § 7 bullet.**
   - **The corrupted-state integration test**: `fanctl reset --all` invoked against deliberately
     corrupted helper state, through the real client and listener, over `ScriptedControlPlane`
     answering `.built`. `docs/SAFETY.md` § 7 calls these "integration tests invoked against a
     deliberately corrupted helper state". This slice adds a minimal machine-wide force-key flag to
     the double itself, so it does not wait for the driver's unlock model. It covers at least:
     - a lease whose connection is gone;
     - a fan in manual under no lease;
     - a stale `restoreAbandoned` entry;
     - a latched § 3;
     - a force key set with nothing engaged.

   § 7's other line, "a manual hardware check", is row 18's hardware half, executed by run 1's
   1c. Row 18's last sentence — "This row also carries #104's corrupted-helper-state case" — is
   restated so that the scripted test carries that case (maintainer question 3 on #9). With both
   pieces merged, #104 closes.

   With the restatements, nothing in #7's Done-when waits on the write path. #7 otherwise closes on
   its own rows and its own "Blocked by #6".
3. **The seam shape and the driver, with #181 in full, in one change** (D2, D4, D5, D7), over
   `ScriptedControlPlane`. It includes:
   - the preparation step's protocol requirement and its place in `bringUp()`;
   - the touched set;
   - `.fanSetUnknown`;
   - the correction of § 4's `.refused` documentation.

   It follows items 1 and 2.
4. **The level-6 `apply` path (D6).** It follows item 3.
5. **#208's correction:** the 2026-09-05 rows restated as "non-zero", and the hardware print
   recording the raw value.
6. **The selector-6 citation (D7).**

**Read-only on `Mac16,5`: the pre-flight session**, with the `main`-build helper, which cannot
write.

- **The raw-mode capture D3 relies on.** Raw `F0Md`, `F1Md` and `Ftst` at 10 Hz, together with
  `F0Tg` and `F1Tg`: 10 min idle, then 10 min under a twelve-way load, then the heat soak until
  `F0Tg` falls back. This is the first 10 Hz record of demand through a load and its heat soak.
  - **If any non-zero raw mode or raw `Ftst` appears, run 1 waits for the architect.**
  - If `F1Tg` ever runs more than 10 % below `F0Tg`, abort 9's threshold is lowered by that margin
    before run 1.
- **D9's census (U10) and an exclusion dry run.**

**On the branch:**

- **The full review, with a recorded mutation for each of these:**
  - the epoch check;
  - both entitlement checks;
  - the not-automatic pre-state refusal;
  - the force-key flag;
  - the LIFO order;
  - both restore writes attempted after a refusal;
  - the clear on an empty set;
  - restore issuing no read;
  - an absent key never written;
  - the preparation step's conditional `.everyFan`, including a failed value read;
  - `.everyFan` with a failed enumeration still writing a fan whose earlier restore was refused;
  - `.everyFan`'s unknown-fan-set throw;
  - § 7's placement before the read-back;
  - the unknown-code, unknown-raw-value and budget aborts.
- **The branch build identified as D1 says.**

**The machine and operator:**

- **Gates:** D9's exclusion, census and quiescence have passed.
- **Machine state:**
  - AC power, lid open;
  - no build or agent session running on the machine, since concurrent builds distort SMC timing
    ([#227](https://github.com/blamechris/Aeolus/issues/227));
  - `pmset -g therm` clean, the package below 50 °C, the app quit.
- **The maintainer at the machine,** with `fanctl reset --all` and
  `sudo launchctl bootout system/com.blamechris.Aeolus.Helper` ready.
- **A recorder running:**
  - `smc-sampler` at 10 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac`, `F1Ac` and the
    curated package keys. Each is recorded as its decoded scalar, which for a `ui8` is the byte's
    own value, not the fold;
  - `log stream` on the helper's subsystem, at debug.

**Start 0, and toward-automatic writes at start.** The branch helper's first start runs the
preparation step and then reconciliation, and either can write toward automatic.

- **In run 1's session, the branch build is installed only after D9's exclusion, census and
  quiescence have passed, with the recorder already running.** That first start is recorded as
  start 0. On the quiescent machine D9 requires, it should do three things:
  - read `Ftst` and every `F<n>Md` as `0`;
  - write nothing;
  - log that the preparation step's enumeration succeeded.
- **Stop if start 0 logs no successful enumeration.** In that case `.everyFan` knows only the fans
  this process touches.
- **Stop if start 0 writes anything.** A write means one of two things: the quiescence check was
  wrong, or a read failed (the preparation step's, or the one that sent reconciliation to its
  keystone). Either way, stop and record which.
- **In later sessions**, D9's reboot starts the installed branch helper before any recorder can
  run. Any toward-automatic write it makes is recorded in the helper's own log, and the gates apply
  to forward writes.

**The run: start 0, then four steps, all on fan 0.**

**The safety argument is the choice of target.** Every hold asks for more cooling than Apple's
controller would ask for *at that moment*. So every stuck state it can produce — an unlock that
will not undo, a restore the firmware refuses — is a loud fan, not a hot one.

- **At rest, 50 % (3,564 RPM) is far above** any speed recorded under Apple's control at rest.
- **Under load, 50 % is not.** The fans reached 3433/3683 RPM in the 45 s after a 40 s twelve-way
  load. So the loaded hold runs at the fan's declared maximum, the one target no automatic demand
  can exceed (U13).
- **Fan 1 is left automatic on purpose.** Its behaviour under `Ftst = 1` is U7. Its `F1Tg` is a
  live proxy for what Apple would ask of fan 0 (abort 9).

The four steps:

- **1a — at rest:** `fanctl set 0 50% --for 60s --json`, after 60 s of baseline. This is where the
  report says the naive write succeeds, because the system is not actively asserting control.
- **1b — under a twelve-way load:** `fanctl set 0 100% --for 60s --json`, which commands `F0Mx`,
  5,777 RPM.
  - **Engaged once `F0Tg` has stayed at least 300 RPM above `F0Mn` for 30 s,** so Apple's
    controller is actively managing the fan. This is where the report says the naive write is
    refused and the unlock is needed.
  - **Its abort baseline is the loaded steady state.**
- **1b′ — still under load, with no lease held:** `fanctl reset --all`, once. That sends
  `.everyFan` to two fans already in automatic while the thermal manager asserts control (U5b).
  Then stop the load, and wait until the package is within 3 °C of its pre-run baseline and `F0Tg`
  is back at rest.
- **1c — at rest, 30 s at 50 %:** ended early from an SSH session with `fanctl reset --all`. This
  is row 18's hardware half.

**After each hold's release (D5's restore), check with `fanctl status --json`:** no lease listed,
and fan 0's mode and availability cleared in ADR 0013's sense.

- **Why not `fanctl auto`:** `auto` sends one `restoreAllToAutomatic` — on the branch, an
  `.everyFan` — whenever a fan is not yet cleared. That would be an unlabelled U5b test. 1b′ is that
  test, labelled.
- **Then observe for 120 s,** including a 20 s twelve-way load that must move `F0Tg` and `F0Ac`.
  The fan following load is the only proof that Apple's management came back.

**Recorded** in `docs/SMC-RESEARCH.md`'s observed section, with machine state and build:

- **Start 0:** its reads and any writes, and whether its enumeration succeeded.
- **Writes:**
  - every write's key, value, result byte and round-trip duration, including the teardown restore's
    and 1b′'s (ADR 0012 H6);
  - § 7's reply round trip.
- **The unlock:**
  - raw `F0Md` before every forward write and after every accepted one;
  - whether the naive write was refused, at rest and under load, and with what code;
  - time-to-yield and the step count.
- **The traces:**
  - the 10 Hz trace of all seven fan keys through every hold, restore and load;
  - whether `F0Tg` held the written value on every § 5 cycle;
  - `F0Ac`'s step response, from about 2,400 RPM and from rest (row 9).
- **Fan 1 and the force key:** fan 1 under the force key (U7), and the force key's state at every
  point.
- **The client:** `apply`'s and each heartbeat's client round trip (#325).
- **Exclusion:** that no third-party SMC client was present.

**Abort.** The maintainer runs `fanctl reset --all` at once on any of these:

1. **A curated temperature** 10 °C above the hold's baseline, or above 85 °C. The target is at or
   above Apple's demand, so a rise means the fan is not doing what was written.
2. **`F0Ac` or `F1Ac` more than 20 % below its automatic speed** for 10 s.
3. **An unexplained change**, meaning one that no helper write explains:
   - during a hold, from the first accepted forward write until the restore is issued: any change to
     raw `F0Md` or to `F0Tg`;
   - at any time: any change to `Ftst`.

   Fan 1 stays automatic, so `F1Tg` moving is Apple's controller; that is recorded, not an abort. A
   change in raw `F1Md` is recorded for U7, and guarded by abort 2.
4. **A result or raw value outside D3's cases, or the budget expiring.** The helper undoes on its
   own; the maintainer verifies.
5. **Any write round trip over 1 s.**
6. **Thermal pressure above nominal.**
7. **The helper exiting or restarting during a hold.**
8. **Five minutes from engage without a verified restore.**
9. **During any hold, Apple's demand overtaking the held target:** automatic fan 1's `F1Tg` rising
   above 90 % of fan 0's commanded target. That is 3,208 RPM at 50 %, and 5,199 RPM at 100 %. On
   2026-08-20 fan 1's speed ran slightly above fan 0's, so the proxy errs early. The pre-flight
   checks that against `F<n>Tg` directly.

**If the restore does not land**, take these steps in order. Take each step only if raw `F0Md`,
`F1Md` and `Ftst` are not all `0` on the recorder 10 s after the previous step.

1. **`fanctl reset --all`.** Every lease is released, then `.everyFan` writes the mode of every
   enumerated and every touched fan and then the key, each attempted. This rests on D5's § 7 precondition. On a build without it, this step
   restores covered fans by name only and clears no stray force key (`docs/SAFETY.md` row 18), so
   go straight to step 2.
2. **`sudo launchctl bootout`.** This runs § 6's teardown, which issues two more `.everyFan`
   calls. launchd will not restart the helper.
3. **`pmset sleepnow`, and wake.** That sleep resets the force key is reported, not observed
   (U12).
4. **Shut down, wait 30 s, power on (U11).**

A refused restore after a target at or above Apple's demand is a recoverable nuisance. That is why
every hold in run 1 aims there.

**Why run 1 tolerates #307 and #201, though they are decided only before run 2.**

- **Both are reachable in run 1.** `apply` registers with § 5, and reconciliation can write from
  start 0.
- **#307** needs a re-engagement to land during § 5's release write. Run 1 has one client, and that
  client never re-acquires (ADR 0013 D1). Since #342 the release paths are `finaliseRelease` and
  `restoreAndForget`, whose three callers are § 5 yielding to § 3, `.leaseLapsed`, and a release
  during a re-assert write. `restoreAndForget` forgets before it restores, so a re-engagement
  during its write survives; #342 tests that. #307's own text records that `finaliseRelease` is
  followed by `revokeEveryLease`, which restores the fan.
- **#201's path** needs a fan in manual at a start. Run 1 reaches that only through abort 7 (a
  helper restart mid-hold), or after recovery step 4's power cycle if U11 fails. In both cases the
  fan is at or above demand, and the recovery steps above apply.

**Decided on the result, before anything else runs:**

- **Write latency:**
  - every round trip at or under 50 ms (D/100) → D stands for writes;
  - any between 50 ms and 1 s → D is raised to 100× the worst in the merge PR, and ADR 0012's
    derived bounds are re-run;
  - any over 1 s → stop, and back to the architect.
- **The yield:**
  - not arriving within 3.5 s → raise `yieldBudget`, give `apply` a client deadline of its own, and
    repeat. `gatedVerb` bounds every gated message, so raising it would slow loss detection on every
    heartbeat (#325);
  - beyond about 4 s at all → asynchronous engagement before E4 may merge.
- **U5b:** if 1b′ refused a mode write on a fan already in automatic, the restore path's refusal
  accounting is re-decided before run 2. A refused keystone in any run (U5 or U5b) also goes to the
  architect with #343's decision (ADR 0009, 2026-10-15 amendment) before the next run.
- **Hypotheses:** any contradiction of U0–U7, U5b, U13 or U14 → `docs/SMC-RESEARCH.md` first, then
  the architect, per `CLAUDE.md`.

**Before run 2:**

- the ceiling tripwire (D1) on `main`;
- **#307 decided**, by a fix or a documented exemption;
- **the route for [#201](https://github.com/blamechris/Aeolus/issues/201) decided and built over
  the scripted plane.** #201 is a reconciliation restore the firmware refuses, which leaves a fan
  watched by nothing. Run 2 kills the helper mid-hold, which makes it live;
- ADR 0012 H2, with row 16 and the read-only halves of rows 2 and 17, run on the `main`-build
  helper.

**Before the merge:**

- [#332](https://github.com/blamechris/Aeolus/issues/332);
- [#270](https://github.com/blamechris/Aeolus/issues/270), the missing bounds gate on
  `acquireLease`. It is unreachable on `Mac16,5`, whose bounds are plausible, and its issue names
  E3/E4 as its gate. *(Taken by the #128/#270 amendment below.)*

### D9 — Another SMC writer is excluded by the operator, gated read-only, and never detected by the helper

**Every run before run 4 refuses to start while another SMC writer could be active. The refusal is
the maintainer's act, and it binds forward writes.**

- **Exclusion, product-agnostic.** Quit every third-party fan or SMC utility. Switch its background
  item off in System Settings → General → Login Items & Extensions. Reboot, so no process survives.
  Re-enable the item afterwards. Under ADR 0011 D1, that tool loses its settings once per Aeolus
  helper start.
- **Census, read-only.** In run 1's session it runs before the branch build is installed; in later
  sessions, before the first forward write. The IORegistry's `AppleSMC` user clients must be only
  the Aeolus helper and the runbook's own sampler.
  - That `ioreg` exposes each client with its creating process is U10. It is checked in the
    pre-flight session before anything relies on it.
  - The census counts clients and names no product. Nothing in the helper reads it.
- **Quiescence, read-only.** 120 s at 2 Hz in which raw `F0Md`, `F1Md` and `Ftst` read `0` on every
  sample. This sees a writer that is holding, not one that is idle; on 2026-09-05 those two states
  were minutes apart on this machine. So quiescence backs the exclusion rather than replacing it.
- **In-run tripwire:** abort 3.

**The helper detects nothing, and ADR 0011 D1 stands.** What ADR 0011 already gives is protection
for the machine, not for the measurement:

- **What it gives:** reconciliation hands a held fan back once; a grant re-reads the mode and
  refuses `.foreignManualControl`; § 5 never adopts a foreign fan.
- **What it does not cover:** a foreign writer taking a fan Aeolus already holds.
  - § 5 would read that as `reclaimedBySystem`, a diagnosis that would be false.
  - It would then re-assert up to `ReclamationLimits.reassertAttemptBudget` (3) before falling back.
    That is a bounded fight, and it leaves a trace nobody could interpret.
  - A foreign `Ftst` write would read as a yield or a reclamation.

So the tool is tested once, deliberately, last. That run settles ADR 0011's unverified re-assert
assumption. It addresses #300's revisit condition only if a § 3 episode is run with the tool
holding. D7 keeps `commandTarget` a target-only write, so that condition's second clause is not
triggered.

**No raw mode value is captured with the competing tool holding a fan before run 1.**

- #208 closes by restating its rows as "non-zero".
- D3 writes the community-documented `1`, and accepts it only on its own read-back.
- A value taken from another product's resulting state, captured just before choosing what to
  write, is the provenance question the clean room exists to avoid.

Run 4 records raw values as a matter of course, once this project's own path is established.

### D10 — Runs are ordered by thermal risk

1. **Run 1:** fan 0 only, at or above Apple's demand — at rest, and under load at maximum (D8).
2. **Run 2:** both fans, below automatic (the declared minimum), under a moderate load for 5 min,
   with § 3 armed. It needs D8's before-run-2 list. It covers:
   - rows 1 and 4, with the client the maintainer chooses (maintainer question 2 on #9);
   - rows 2 and 3: kill the helper with SIGKILL mid-hold, then confirm restart and reconciliation
     (H3);
   - row 8, on D1's lowered-ceiling commit;
   - row 9, under load and downward;
   - the second-fan path of D3 step 3.
3. **Run 3:** lifecycle with a hold. It covers:
   - rows 5–7;
   - row 10 ("`Ftst` semantics", as restated);
   - row 11;
   - row 17's restore half;
   - #325's sleep-handback heartbeat.
4. **Run 4:** the competing tool re-enabled. First it holds a fan at helper start, then it takes a
   fan Aeolus holds. It includes a § 3 episode with the tool holding only if #300's revisit is to be
   addressed.

Each run's findings are recorded, and the branch revised, before the next.

## Consequences

- **Rule 1's line is explicit (D1),** and `main` keeps every write tripwire until the merge.
- **ADR 0008's parameter list is not amended.**
  - The plane verb, the driver and `GovernedFanWriter.engageUnderLease(of:)` each take one permit;
    the plane verb gains a return value.
  - In `WriteVerbAllowlistTests`, the driver's engage and `engageUnderLease(of:)` join
    `permitBearingVerbs` — as built, with the driver's `firstStep(of:)` and
    `requireEntitlement(for:)` and § 3's role requirement `manualControlEngaged(_:)` (D2).
  - Joining `permitFreeFunctions`, because each reaches a write only through `restoreToAutomatic`:
    the driver's undo, which takes an index and never the permit, and the preparation step's
    requirement and its conformer — as built, with § 3's `handbackAccepted(fanAt:)` and the
    composition's `prepareWritePath()`.
  - `WriteAuthorisationTests` is untouched.
- **`FanControlPlaneError` gains `.fanSetUnknown`.**
- **ADR 0004's write-time sentence and its assumption row are amended** to cover forward writes
  (D7).
- **ADR 0011 is not amended.** The preparation step extends its D1 discourtesy to the force key.
- **`PanicPathScopeTripwireTests`' file set grows from three to five:** four on `main` since
  #349, and five on the branch.
  - `SupervisedFanAuthority.swift` (§ 7, on `main`);
  - `SMCFanControlPlane.swift` (its scope switch and preparation step, on the branch).

  `SignalTeardown.swift`, `SystemPowerResponder.swift` and `StartupReconciliation.swift` are
  unchanged. `theShippedPanicVerbIssuesNoControlPlaneRestore` is inverted (as
  `thePanicVerbIssuesTheMachineWideRestoreOnlyOnABuiltPlane`, #349). Its eight
  `documentationSites` (seven when this was written) and the three named sites are walked, and its
  three "§ 5" references become "§ 1".
- **`docs/SAFETY.md` § 1's statement that a per-lease teardown leaves `Ftst` untouched** becomes
  false on the branch, and is corrected at the merge.
- **§ 4's `.refused` documentation** is corrected in the change that sets the seam's restore
  contract (D5).
- **If U0 fails,** `FirmwareFanMode` needs an explicit classification of the value, and every E5
  confirmation read is re-examined before run 1.
- **If U14 fails,** the preparation step and D3 step 3 are re-decided before run 1.
- **If U5b fails,** a refused `F<n>Md = 0` on a fan already in automatic must not count as a failed
  restore. Otherwise `BoundedFanRestorer` mints durable refusals, and § 6's exit code reads a
  healthy teardown as failed. The remedy is a read after the refusal, which decides only whether
  the refusal is recorded (ADR 0007's 2026-09-20 rule). It is decided before run 2. A refused
  keystone, from U5 or U5b, also goes to the architect with #343's decision (ADR 0009, 2026-10-15
  amendment) before the next run.
- **Six texts are restated** (maintainer question 3 on #9):
  - E4's "post-wake re-assertion" bullet.
  - Row 10, "`Ftst` semantics: whether sleep resets the Apple Silicon force key, and where the
    unlock must re-run". The restatement: § 4's handback leaves raw `F<n>Md = 0` and `Ftst = 0` at
    wake, and a post-wake acquire re-runs the unlock.
  - Row 18's last sentence. The restatement: the corrupted-helper-state case is carried by D8's
    scripted integration test, and row 18 on hardware is 1c's SSH reset.
  - E5's "the unlock is re-run as part of the grant (ADR 0007)" (D6).
  - E5's "Manual hardware test checklist written and executed on Mac16,5". The restatement: the
    checklist is written, and executed as E3/E4's gate, per ADR 0007's Consequences.
  - #104's "a manual hardware check", which is row 18's hardware half.

  **Whether firmware also resets the force key across sleep** no longer bears on correctness. It
  cannot be observed through the helper without disabling § 4, which no message and no build may
  do. It matters only as a backstop for one residual: a § 4 keystone never issued before the sleep.
- **`fanctl set` (#324)** is the bring-up client, and it merges with E4.
- **If U7 fails,** per-fan manual control is not an honest product on such firmware, and the lease
  shape returns to the maintainer.

## Alternatives considered

### A standalone write probe, before any helper code

The strongest alternative, and the one an implementer will reach for first. A few hundred lines
would answer U1 to U5 in an afternoon: open the SMC, write `F0Md`, read the code, write `Ftst`,
retry, write `F0Tg`, and restore in a `defer`. It would need no lease, no signing, no XPC, and no
review of a helper change the answers might overturn. Isolating the firmware from the safety layer
is a real virtue for a measurement.

It is rejected on how it fails:

- **A probe that dies holding a fan leaves it to nothing.** Any of these leaves `F0Md` and `Ftst`
  set:
  - a Ctrl-C between the forward writes and the `defer`;
  - a crash;
  - a synchronous IOKit call that never returns — ADR 0012's case, which no `defer` survives.

  Then nothing counts a lease, nothing watches, and no reconciliation can write, because the
  installed helper answers `.notBuilt`. What is left is sleep (U12, reported) and a power cycle
  (U11, unverified).
- **It needs the write seam outside the helper**, as `@_spi(FanWrite) import SMCCore` under
  `Tools/`.
  - `WriteSeamAccessTests` scans `Sources/` only, so nothing there would turn red.
  - Each tool's own seam suite is held to forbidden tokens (`ToolsSeamCoverageTests`), and a tool
    written for this would simply not forbid that one.

  The rejection stands on `CLAUDE.md`'s rule: a new member of the `FanWrite` audience is a safety
  review. Otherwise "the helper is the sole writer" would hold only for code that is not research.
- **Its findings describe a code path that never ships.** There would be no turns, no epoch, no
  entitlement, no § 3 beside it, and no teardown restore through the path ADR 0012 bounds. Run 1
  would still be owed, and run 1 is the run that matters.
- **Reversal cost:** low in code, high in precedent. The second probe is easier than the first.

Revisit only if the signed helper cannot be built from a branch for an extended period, **and** the
maintainer accepts manual recovery as the only cover.

### The production graph composed inside `swift test`, under `sudo`

A close second, and closer than it looks.
`HelperHardwareTests.theComposedHelperServesRealHardware` already composes the production graph
over the real SMC, using recording signal sources, a recording terminator and manual watchdog
ticks. Those recording seams are exactly why it cannot be the vehicle for a write:

- **No restart.** A recording terminator ends nothing, and a test runner is not a launchd job. A
  watchdog verdict or a crash has no restart and no reconciliation behind it.
- **No teardown.** Recording signal sources run none. Installing the real ones would apply
  `SIG_IGN` to the runner permanently (`docs/SAFETY.md` § 1). Either way, a Ctrl-C during a hold
  ends the process with the fan pinned.
- **A new kind of writer.** The whole test target runs as root, and a write from a test process is
  a kind of writer the sole-writer rule has never had to consider.

Revisit if a test host can run as a launchd job with the real teardown and terminator — at which
point it is the daemon.

### The entitlement as a closure parameter on the engage verb

That is, `engageManualControl(of:while:)`, with the plane looping internally. It is rejected:

- **It contradicts ADR 0008's sole-parameter rule and its two tripwires.**
  `expectPermitIsTheOnlyParameter` requires exactly one parameter, and `SeamScanner`'s `\([^)]*\)`
  cannot span a closure's `()`.
- **A closure that is not handed the index can check a different fan's lease than the permit
  names.** That is the disagreement ADR 0008 exists to make unrepresentable.

Amending the rule would loosen a safety tripwire for a convenience D2 does not need.

### The unlock above the seam

An `UnlockCoordinator` would sequence raw primitives, `writeMode(_:ofFan:)` and
`writeForceKey(_:)`. It is rejected:

- The primitives take an index rather than a permit, reopening what ADR 0008 closed.
- Everything that holds the plane could write the force key.
- Platform differences leak above the seam (rule 9).

D2 keeps the sequence below the seam and puts only the cadence above it, which needs none of this.

### Engage at grant

Rejected:

- It puts firmware writes into `LeaseAuthority`, which owns no hardware by design.
- A lease that is never applied pins a fan at whatever target the thermal manager left.
- A multi-second grant meets the same 5 s deadline, for nothing.

### Hold the force key for the helper's life, or set it at bring-up

Rejected: it tells the thermal manager to yield with nobody holding a fan. Whether that is harmless
is U6, which is unknown.

### Clear the force key on every per-fan restore

The near miss, and the fallback if U6 fails. Rejected for now: inside a two-fan teardown sweep,
clearing the key after the first fan puts the second fan's mode write into the state the report
says refuses mode writes.

### Clear the force key first

Rejected for the same reason, applied to every fan rather than the second. `BoundedFanRestorer`'s
second attempt runs this order after a refused first one, so the order is observed without being
depended on.

### Issue `.everyFan` from reconciliation at every start

This was this ADR's earlier choice for a force key a dead helper left behind. Rejected:

- It writes every mode key at every boot, on every machine.
- If U5b fails, it refuses on a healthy machine at every start under load.
- It cannot be recorded before D9's gates.

The preparation step (D5) issues `.everyFan` only when `Ftst` reads set or cannot be read.

### Refuse every grant while the preparation step's fan set is unknown

The other answer to an enumeration that fails at bring-up, mirroring reconciliation's
`nothingEstablished`. Rejected:

- A transient `FNum` failure at bring-up would remove manual control for the life of the process.
- It couples the grant path to plane state, where `writeCapability`'s contract makes the plane's
  answer immutable for the process.
- It would still leave `.everyFan` short of fans a previous process touched.

The touched set (D5) covers every fan this process engaged or restored, with no read at restore
time.

### A key-only restore scope for the preparation step

A new `FanRestoreScope` case that clears the force key alone. Rejected:

- It names the force key's concept above the seam.
- It adds a scope every machine-wide tripwire would have to learn.
- It invites a caller to use it in place of `.everyFan`.

When the key reads set, something held machine-wide control. Restoring every fan as well is then the
keystone, not an excess.

### A new restore verb for the preparation step

This would make the step's clear a direct write, classified in `restoreVerbs`. Rejected: that list
is ADR 0007's verbs. Routing the clear through the existing keystone keeps the step in
`permitFreeFunctions`, with nothing new to classify.

### Run the loaded hold at 50 %, conditional on the pre-flight's peak demand

Rejected:

- The record already shows fan speeds above 3,564 RPM in a heat soak after a load shorter than the
  hold.
- So the condition would very likely fail.
- If it passed, it would rest the safety argument on a measurement taken on another day.

### Run 1 with no load

Rejected. On the report, the unlock is needed only while the thermal manager asserts control. So an
unloaded run 1 might never exercise it, and run 2 — below automatic — would then be the first run
that did.

### `fanctl auto` as the post-hold check

Rejected for run 1. `fanctl auto` sends `restoreAllToAutomatic` whenever a fan is not yet cleared
(ADR 0013 D2), and on the branch that is an `.everyFan`. That would mix an unlabelled U5b test into
every hold's record. `fanctl status --json` reads the same snapshot and writes nothing.

### Poll by reading the raw mode byte

Not rejected — conditional. It is better than polling by writing whenever a read can tell "held by
the system" from "yielded". D3's pre-flight decides whether this machine offers such a read.

### Read the raw mode byte with the competing tool holding a fan, to settle #208 first

Rejected for E4 bring-up (D9). #208 closes by restatement, and D3 does not need the value.

### Detect the other writer in the helper

Rejected by ADR 0011 D1 and the clean room. The census is legitimate as an operator's read-only
pre-flight only because it counts clients, names nothing, and changes no product behaviour.

### First write with the competing tool present, relying on ADR 0011

Rejected: ADR 0011 bounds what that tool can do to the machine, not what it does to the measurement
(D9).

### Asynchronous engagement

`apply` answers at once, and the snapshot reports progress. Deferred, not rejected. It is needed
only if U3 fails beyond about 4 s. It changes what `apply`'s reply means, so it needs a version
bump.

## Amendment (2026-10-15, [#350](https://github.com/blamechris/Aeolus/issues/350), [#355](https://github.com/blamechris/Aeolus/issues/355)) — no lease is granted while § 7 runs, and § 5's ledger is history, not a refusal

Two A6 preconditions, found in the reviews of #349 and #354. Both are unreachable on every build
on `main`, where a `.notBuilt` plane grants no lease, and both are decided before A6 gives a lease a
write to make. They rest on one rule, stated here and in `AvailabilityRestatement.swift`: **a grant
refusal, and the snapshot availability that mirrors it, is computed from current evidence the
grant path consults. A diagnosis of something that already happened is a fact, and is reported as
one.**

### #350 — the panic verb seals the grant gate for its whole duration

**The defect.** `restoreAllToAutomatic` runs `releaseEveryLease()`, then
`restoreToAutomatic(.everyFan)`, then `confirmAcceptedHandbacks()`. From the moment the sweep empties
the table, nothing refuses a grant over a fan the sweep does not cover. While `.everyFan` is awaited,
nothing refuses any grant. After A6, a lease granted and applied in that window is undone by
`.everyFan` and survives it, so § 5 reads `.modeReclaimed` under a live lease. It then either
re-asserts, so level 3 undoes level 1, or gives the fan up blaming the operating system. D4's epoch
covers the forward writes of an engagement already under way. It does not cover a lease granted into
a restore that will undo it.

**Decision.** `LeaseAuthority.sealingGrants(during:)` counts the § 7 panic verbs inside it — on
every plane, `.notBuilt` included, and never § 4's or § 6's `.everyFan` (*amended by the
#364/#347 amendment below: it counts § 4's handback too*). It
increments when it begins and decrements in a `defer` in the same frame, so a throw cannot leak it,
and overlapping panic verbs hold it until the last one ends. § 7's three acts run inside it, so it
opens before the sweep empties the table and closes after the read-back. That is § 4's rule: no
instant at which the table is empty and the gate is open.
`acquireLease` checks it once, inside its straight-line region, after § 4's sleep-seal refusal and
before the lease-table refusal: no lease is added while it is open, so a lease the table shows
then is one the sweep is about to drop. It refuses with `.releaseInProgress`, under a log line of its own.
The snapshot states the seal as the last rung before `.available`, read in the same hop as the
registers.

**What it does not change.** The keystone gains no input and waits on nothing. The seal gates grants
only, no restore reads it, and no read is queued ahead of `.everyFan` (ADR 0007, 2026-09-20). The
reply is v1's *accepted*. § 4 keeps `sleepSeal`, § 6 its gate and second keystone, and reconciliation
runs before the listener resumes. So § 7's, bring-up's and, since
[#364](https://github.com/blamechris/Aeolus/issues/364), § 4's machine-wide restores run behind a
grant interlock. § 6's gate refuses
a grant on arrival, not one already in flight; such a grant can land, and `apply` is refused by
the same gate before the process exits.

*Corrected in the review of [#363](https://github.com/blamechris/Aeolus/pull/363):* this
subsection said the seal counted machine-wide restores, put its guard after the lease-table
refusal, and said every machine-wide restore ran behind a grant interlock.

**What remains.** The seal does not tie a § 5 registration to the lease that made it. An `apply`
whose lease ends between the driver's after-check and its § 5 registration leaves an entry that D2
judges under whichever lease covers the fan next. The identity amendment below closes that: the
registration names its lease and is refused when that lease is no longer live, and D2 judges the
record under that lease alone.

### #355 — the snapshot publishes § 5's ledger as a fact, never as an availability

**The defect.** Since #354 the terminal action keeps its ledger entry. The snapshot published it as
an availability (`.supervisorBlind` on any seam, `.reclaimedBySystem` on a `.built` one), while
`acquireLease` never consults the ledger. So after a terminal action the snapshot refused, for the
life of the process, a lease the helper would grant. Only an engagement or a release clears the mark,
and both need that lease: #189's register that seals its own exit.

**Decision.** The grant does not move; the snapshot does.

- **`ReadOnlyFanReport.availability` no longer reads the ledger.**
- **`.systemReclaimed` stays on `FanState.isReclaimedBySystem`.** § 5's blindness is reported by its
  fault lines and by the revocation itself. Its present-tense sentence, "cannot currently read", was
  false whenever the reconnect had worked.
- **Step 5 no longer exempts § 5's fans,** so it answers as `refusalForGrant` does: the durable
  reconciliation refusal, the mode guard (three-way since the #360 amendment below), § 3's kept set
  (#303), then `.foreignManualControl`. Under U0
  the system's hold reads raw `0` and never reaches the foreign answer. If U0 fails, the grant is
  already wrong the same way, and D3 re-decides the fold before run 1.
- **A re-grant re-runs the unlock** with a fresh yield budget (D3, D6). A landed engagement clears the
  mark, and § 5 judges the fan afresh with a fresh re-assert budget. Every re-grant is a client's
  request (ADR 0013 D1), so the contest with the system is bounded per request.

After this change, `.supervisorBlind` has two producers, both of which the grant shares: the fan
reconciliation never established, and a grant-time read that failed. The #360 amendment below makes
the snapshot state the second as well, from its own read. No helper on `main` publishes
`.reclaimedBySystem` as an availability; the case stays for wire stability.

**What remains.** A fan § 5 gave up blind that is *still* unreadable reads `.available` while the
grant's fresh read refuses it. That is the gap every unreadable fan already has, and it is fail-safe
for the grant. It is not for `fanctl auto`: with the mode reported `automatic` (#178) and nothing
beside it, `auto` on a plane that can write would exit 0 without sending its restore, the outcome
ADR 0013 rejects under "Exit 0 on the mode alone" (its "Exit 0 only when the mode was actually read"
accepted that residue only while a reason sat beside the fan). That is
[#360](https://github.com/blamechris/Aeolus/issues/360), an A6 precondition. *(Closed on a seam that
can write by the #360 amendment below.)*
`isReclaimedBySystem` is history after the terminal action and can go stale if another program later
takes the fan; the availability beside it is correct.

### #270 is the same rule, moving the other side

`.boundsImplausible` is current evidence, re-read on demand, and it makes a lease unusable, so the
grant should refuse it. #270's scope and slot (D8, before the merge) are unchanged. *(Taken by the
#128/#270 amendment below.)*

### No `AeolusXPCVersion` bump

No field, case or method changes. The seal refuses with a reason `acquireLease` already throws. The
availability now conforms to its documented meaning, and no shipped helper ever published what is
removed: § 5's ledger is empty on a `.notBuilt` plane.

**Alternatives considered.**

- *Hold every enumerated fan in `releasing`.* Enumeration is a hardware read. Taken before the
  keystone, it is a read queued ahead of it, and if it fails the window reopens. It would also give
  `releasing` and `handbackUnconfirmed` a second writer.
- *Re-sweep after the keystone.* § 5 can cycle in between, and the re-sweep revokes a lease just
  granted.
- *§ 5 discounts a reclamation that follows a machine-wide restore.* It cures the diagnosis and
  leaves a client holding a lease a restore already in flight will undo.
- *The plane refuses a first step while a machine-wide restore is pending.* Partial: an engagement
  completed under a lease granted during the sweep is still undone.
- *An explicit seal/unseal pair.* It leaks on the first throw an edit adds; the scoped form costs
  nothing.
- *Refuse the grant on § 5's ledger.* No read can clear `.systemReclaimed`, so it seals its own exit.
  It also makes a misdiagnosis durable (D9's foreign writer, U4). A cooldown adds an unmeasured
  constant and a second definition of "reclaimed".
- *Clear the ledger at the grant's fresh read.* That is the decision above, plus a mutation on the
  grant path.

**Revisit if** a run shows the system repeatedly reclaiming re-engaged fans, or a client re-acquires
on its own. A ledger-keyed refusal with a measured time limit, and the snapshot rung restored in the
same commit, would then be justified. Revisit too if D8's measured § 7 round trip makes the seal's
"retry in a moment" untrue. The ruling is the architect's #350/#355 consult, run on Opus.
This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under.
**Status stays Proposed.**

## Amendment (2026-10-15, [#353](https://github.com/blamechris/Aeolus/issues/353), [#357](https://github.com/blamechris/Aeolus/issues/357)) — an engagement asks about the lease it runs under

**The defect in D4's residual argument.** D4 discharges the restore the epoch cannot see, one
requested between the driver's check and an engagement's first step, with "every genuine restore
ends the lease … so the driver's next check sees it". That holds only if the check asks about
the engagement's own lease. As built it asks whether *any* live lease covers the fan, and a lease
granted over the same fan once the first lease's restore has returned answers yes. The epoch
cannot help: it is recorded at the first step's admission, after that restore was requested, so
no later step of the engagement sees it; and nothing reads the epoch after `.engaged`. Under a
re-grant the engagement runs on to `.engaged` and returns to a caller whose lease has ended.

Where the epoch does cover a release and re-grant, it covers it fully. Every lease ends by
restoring its fans; the restore moves the epoch when it is requested; and `acquireLease` refuses
a fan in `releasing` until that restore returns. So the increment precedes any re-grant over the
fan, and every later step refuses `.superseded`.

**Decision.** The driver is bound to a lease per engagement. `EngagementDriver.under(lease:)`
returns a copy that stores the identity, and `requireEntitlement(for:)` asks
`hasLiveLease(id:coveringFan:)` about the permit's own fan. The composed driver is unbound and
refuses every step. No engage verb's parameter list changes. § 5 binds it to the lease its record
was registered under; level 6 binds it to the lease `apply` authorised.
`WriteVerbAllowlistTests` gains one keyed companion: `ReclamationWatchdog.manualControlEngaged(_:
CommandableFan, under: UUID)` may carry a `UUID`, because a registration writes nothing and its
lease is judged against the permit's own fan at every examination. No write verb may.

**A6's contract, fixed before A6 is written.**
1. Engage through a driver bound to the ID `heldLease(id:from:)` returned for the calling
   connection. That call is the ownership check: a lease bound to another connection, or
   lapsed, never reaches the driver.
2. Register each fan with `manualControlEngaged(_:under:)` under the same ID. A refusal is an
   engagement failure: every fan this `apply` engaged is handed back, and the call is refused.
   A refusal never leaves a fan off automatic control unwatched even before that hand-back:
   the driver returned after an after-check that found the lease live, so a lease that has since
   ended restores the fan after the engagement's writes, and a fan released or registered while
   § 5 asked is being restored or is watched by the newer record. Register one fan at a time per
   lease: a second registration of the same fan under the same lease, in flight at once, is
   refused, and the hand-back would then contest § 5's record of the first. A registration
   under the lease § 5's terminal action gave the fan up for is refused, while the terminal
   action runs or after: the revocation in the same call undoes that engagement. One accepted
   mid-episode leaves the fan reported as reclaimed until § 5 reads its target held, or gives the
   fan up as reclaimed and keeps the mark; an episode that escalates through blind cycles ends
   `.supervisorBlind` instead (#366). Register each fan before this `apply`'s first command write
   to it, a fan already engaged under the lease included. A registration accepted while § 5 is
   examining the fan leaves that examination's re-assert to this engagement (#381).
3. Report each commanded target with `commandedTarget(_:under:)`, after the write returns and never
   before. § 5 re-asserts the target last reported, and a report that arrives during its own
   command write wins the record (#381).
4. Ask `heldLease(id:from:)` again before replying, so the reply never says *applied* under a
   lease that has ended.
5. Map a superseded step to `.releaseInProgress`, unless the lease itself has gone. Map a
   registration's `.leaseNotLive` by asking `heldLease(id:from:)` again: if it still succeeds,
   the refusal was under a live lease — the fan's generation moved, or § 5 is giving the fan up
   — and it is `.releaseInProgress`; otherwise it is the lease fault that call throws.

**What remains.** A restore owed to an ended lease, whether § 5's hand-back or a bound driver's
undo, can land after a newer lease's engagement and before it registers. The newer record's
first examination reads the fan as reclaimed and re-asserts its own target: one cycle, in the
safe direction, with a reclamation reported that the system did not cause. Two engagements of
one fan under one lease remain an A6 precondition.

**No `AeolusXPCVersion` bump.** Nothing crosses the boundary.

This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under.
**Status stays Proposed.**

## Amendment (2026-10-15, [#360](https://github.com/blamechris/Aeolus/issues/360)) — a fan whose mode did not read answers what the grant's fresh read answers

Found in the review of #359, and an A6 precondition like #350's and #355's. Unreachable on every
build on `main`, for the same reason: a `.notBuilt` seam answers `.writePathNotBuilt` before anything
this changes.

**The defect.** The #355 half above left one gap and called it fail-safe: a fan whose `F<n>Md` does
not read reads `.available`, while the grant's fresh read throws and refuses it `.supervisorBlind`.
It is fail-safe for the grant and not for `fanctl auto`: the fan reads `automatic` by #178's fold
with no reason beside it, so `auto` sends no restore and exits 0, the outcome ADR 0013 rejects under
"Exit 0 on the mode alone". #359's review reached it through § 5's terminal action. § 5 is not
needed: a foreign-held fan whose mode stops reading reads the same.

**Decision.** Step 5 of the availability ladder judges the read path's own `F<n>Md` answer three
ways, as `StartupReconciliation.refusalForGrant` judges its fresh read: no answer is
`.supervisorBlind`, automatic is left to the rungs below, and manual is § 3's kept set or
`.foreignManualControl`. `ReadOnlyFanAuthority` hands the answer to the restatement beside the
snapshot it was read for, from the same read. `FanState.mode` is unchanged.

- **After the `held` exemption and the durable reconciliation refusal**, as in the grant, which
  skips the fans Aeolus is accountable for and asks the baseline before it reads.
- **Not over `.writePathNotBuilt`**, which the grant answers before it reads anything. Answering
  `.supervisorBlind` there would state a reason no grant returns, on every fan of every Mac without
  `F<n>Md`, which by the reported key map is every Intel Mac.
- **For every fan Aeolus is not accountable for, not only § 3's kept set.** The grant refuses any such
  fan it cannot read; a rung keyed
  on § 3's set mirrors a subset of that rule.
- **Above #350's seal**, which re-states only a fan nothing else refused: the grant's fresh read is
  above its straight-line region, and the seal check is inside it.
- **Disjoint from steps 1–3**, by the argument they already rest on: a fan in a handback register
  is in `fansAeolusIsAccountableFor`, and step 5 returns it untouched.

This is current evidence the grant path consults, so it keeps the rule above.

**What it costs.** A read that fails on one snapshot and answers on the next refuses, for that
snapshot, a lease the next grant could get. Every step-5 answer has that staleness: the foreign
answer judges the same read. For `fanctl auto`, a transient failure costs one unneeded restore and a
poll. A lasting one gives exit 8 with the reason's advice, as ADR 0013 D3 says a blind fan gets.

**What remains.** On a `.notBuilt` seam, which is every build on `main`, an unreadable fan still
reads `automatic` with `.writePathNotBuilt` beside it, and `auto` exits 0 about it: #178's, because
the wire cannot yet say a mode is not known. Where the grant refuses before its fresh read — § 3's
latch (`thermalEmergencyActive`) and `.noThermalTelemetry`, the only machine-state refusals ahead of
it besides the build — an
unreadable fan reads `.supervisorBlind`, a refusal the grant makes once those clear; the snapshot
has no `.noThermalTelemetry` rung yet (#269). The sleep seal is checked *after* the fresh read, so
while it holds the grant also answers `.supervisorBlind` for such a fan and the two agree; #269's
`.systemSleeping` rung therefore goes below step 5 and above step 10. #270 places its bounds gate
relative to the fresh read and moves steps 5 and 8 together. *(Taken by the #128/#270/#269
amendment below, which also moves #269's rung below step 8, and states `.noThermalTelemetry` last:
over a fan nothing else refuses, never over this `.supervisorBlind`.)*

**No `AeolusXPCVersion` bump.** No field, case or method changes. `.supervisorBlind` is on the wire
and already published for the reconciliation producer, and "cannot read this fan's control state" is
exactly this producer. No shipped helper publishes anything new: every one is `.notBuilt`.

**Alternatives considered.**

- *Only a fan in § 3's kept set.* Closes #359's scenario and leaves the general gap.
- *Over `.writePathNotBuilt` too, as foreign control is.* `auto` exits 8 for ever on every Intel
  Mac, by a reason no grant returns. #178 decides how such a build says "not known".
- *A wire field or mode case for "not read", read by `SafeState`.* Fixes the CLI and leaves the
  availability offering a lease the grant refuses. #178's design, and it composes with this one.
- *Two consecutive unread snapshots before refusing.* The grant refuses on one failed read; a
  debounce is state in a pure function and a second definition of blind.

**Revisit if** a hardware run shows `F<n>Md` failing at `.snapshot` while it reads at `.supervisor`,
or flickering on `Mac16,5`: fix the read, do not debounce the rung. Revisit before any plane reports
`.built` on a platform whose mode is not `F<n>Md` — Intel's `FS! ` bitmask: the snapshot's
`SnapshotFanModeReads` must take the same branch as the plane's read, or share its decode, in the
same change, or every fan reads `.supervisorBlind` for ever while the grant grants. Revisit too when
#178 lets the
wire say a mode is not known; the rung stays, and ADR 0013's exit 0 can then be strengthened on a
`.notBuilt` seam. The ruling is the architect's #360 consult, run on Opus.

This amendment corrects a clause of a Proposed ADR, not the decision it sits under. **Status stays
Proposed.**

## Amendment (2026-10-15, [#364](https://github.com/blamechris/Aeolus/issues/364), [#347](https://github.com/blamechris/Aeolus/issues/347)) — § 4's handback runs inside the machine-wide restore seal, and a wake opens only a seal older than every sleep that met it

Two more A6 preconditions, both § 4's, found in the reviews of #363 and #345. Both are unreachable on
every build on `main`, where a `.notBuilt` plane grants no lease. The first applies #350's seal to the
runtime caller it left out; the second applies #202's stamping to the one write of `sealGeneration` it
missed.

### #364 — every § 4 teardown runs inside `sealingGrants(during:)`

**The defect.** `sleepSeal` was § 4's only grant interlock, and it lasts an episode: set before the
teardown, cleared by the next newer wake. The teardown lasts a call. The two coincide only if the
teardown starts after the seal is set and ends before the wake clears it, and three routes break that:

- **A declined seal.** When a strictly later wake has been seen, `sealForSleep` declines, and the
  starved body's `releaseEveryLease()` and `.everyFan` run on an awake machine with the gate open.
- **A keystone that outlives its wake.** With no lease, `.everyFan` is issued, the budget acknowledges,
  the machine sleeps and wakes, and `.didWake` lifts the seal with the keystone still pending.
- **A sweep that outlives its wake.** A lease's per-fan restore outlasts the budget; after the wake a
  grant over another fan succeeds, and § 4 issues `.everyFan` once the sweep returns.

Reviewers' probes granted a lease on all three, and `UnconfirmedHandbackTests` and
`SleepCycleSurvivalTests` asserted the third as correct. After A6 each is #350's harm on § 4's path:
§ 5 reads `.modeReclaimed` under a live lease.

**Decision.** `SystemPowerResponder.allowSleepAfterHandback` runs `handBackEveryFan(reportingTo:)`
inside `LeaseAuthority.sealingGrants(during:)` on every `.willSleep`, whatever `sealForSleep` decided
and whatever the wake does. `sealForSleep` still runs first and decides only the episode seal. The
count now covers § 7's panic verbs and § 4's handbacks, and still neither § 6's teardown, whose gate
refuses `apply`, nor bring-up's, which runs before the listener resumes. `acquireLease`'s guard, its
position and its reason are unchanged: a sealed teardown is refused `.systemSleeping` until the wake,
and a declined one, or one still running after the wake, `.releaseInProgress`.

**What the declined teardown is for.** The later wake proves the sleep is over, not what it left. The
starved body is still the only act that ends a lease which crossed the sleep (ADR 0007, Sleep), and
that returns the plane's engaged set and force-key flag to the state D6's post-wake re-acquire assumes
on firmware that may have reset `Ftst` (U12). So it keeps running, and the gate is shut while it does.

**What it does not change.** The keystone gains no input and waits on nothing: the seal is a counter
raised on the lease actor before the sweep, no restore reads it, and no read is queued ahead of
`.everyFan` (ADR 0007, 2026-09-20). `.everyFan` is not made conditional on the seal still standing.
The order — seal, release, keystone, acknowledge — and the budget are unchanged, and § 4 still writes
nothing on wake.

**The snapshot.** Step 10 states `.releaseInProgress` while the count is above zero, over every fan
no higher rung refuses, so after a declined seal or a wake the teardown outlived, the snapshot and
the grant both say `.releaseInProgress`. During a sealed teardown the grant says `.systemSleeping`
about a fan nothing else refuses, and the snapshot said `.releaseInProgress`:
[#269](https://github.com/blamechris/Aeolus/issues/269)'s gap, narrower in availability. The grant
checks the sleep seal after its fresh read and, since #270, its bounds read, and before this seal and
`releasing`, so #269's rung goes below steps 5 and 8 and above step 10 and step 3. *(Built so by the
#128/#270/#269 amendment below.)*

**What it costs.** A teardown that never returns refuses every grant, after the wake as before it —
`.systemSleeping` while the sleep seal stands, `.releaseInProgress` once the wake lifts it — until it
returns or ADR 0012 ends the helper. A lease granted there is one the pending `.everyFan` would undo.
A fan the sweep covered still answers `.handbackUnconfirmed`, checked first. After a wake the
teardown outlived, "retry in a moment" is untrue by construction: the machine slept only once the
budget or the kernel's timeout acknowledged, so the restore has outlived five seconds. Rather than
give D33's register a second producer, `.releaseInProgress`'s advice escalates when it does not
clear within a few seconds.

### #347 — a wake clears only a seal older than every sleep that met it

**The defect.** `sealForSleep` returned at `guard !sleepSeal` without recording its generation, so a
stale wake newer than episode 1's seal but older than episode 3's `.willSleep` reopened the table during
episode 3's sleep.

**Decision.** Every `.willSleep` that is not declined sets `sealGeneration` to the larger of its own
generation and the one standing, whether or not it sets the seal. The larger, because a starved older
`.willSleep` running after a newer one sealed would otherwise lower it below a stale wake. Nothing is
counted or spent, so #202's no-latch argument holds: the wake that follows the newest sleep is newer
than every sleep that met the seal.

**How the two compose.** `sleepSeal` says the machine is going to sleep; the count says a restore that
would undo a grant is in flight. Since #364 a stale wake cannot open the gate during a teardown, so #347
is narrowed to the window after the newer teardown returns and before the machine sleeps. Neither
covers for the other.

### No `AeolusXPCVersion` bump

No field, case or method changes. Both reasons are ones `acquireLease` already throws, and step 10
already exists.

**Alternatives considered.**

- *Seal only the declined teardown.* Leaves both wake-outliving routes open, and ties the interlock to
  the method #347 changes.
- *Skip the teardown on a declined seal.* A lease crosses an unhandled sleep with only the TTL (#210,
  unverified) to end it, the plane's memory crosses a sleep that may have reset the firmware (U12), and
  the never-issued-keystone residual widens. It does nothing for the other two routes.
- *Skip only `.everyFan` on a declined seal.* Loses the one restore that reaches a fan or a force key
  the sweep cannot.
- *Issue `.everyFan` only while the episode's seal stands.* Makes the keystone depend on lease-core
  state, and leaves the machine unrestored on a late wake.
- *Make `.didWake` wait for the teardown before unsealing.* Puts a wait on the wake path, says
  `.systemSleeping` on an awake machine, and misses the declined route.
- *Re-set `sleepSeal` for a declined teardown.* An explicit pair that leaks on a throw, and a false
  `.systemSleeping`.
- *Open the count before `sealForSleep`.* A lease taken in that gap is one the sweep drops; it buys
  nothing.
- *Seal § 6's teardown too.* Its gate refuses `apply`, so nothing granted in flight engages.
- *For #347, assign rather than take the larger generation.* `SleepOrderingTests` holds it.

**Revisit if** a client re-acquires on every wake (#211), or concurrent leases or a second production
plane arrive. "Retry in a moment" is already untrue after a wake a teardown outlived, which the
escalating advice answers; revisit the reason itself if D8's measured § 4 round trip shows an ordinary
teardown taking seconds. The ruling is the architect's #364/#347 consult, run on Opus.

This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under.
**Status stays Proposed.**

## Amendment (2026-10-15, [#343](https://github.com/blamechris/Aeolus/issues/343)) — a lease-end handback the firmware refuses needs no watcher of its own

An A6 precondition decided, with no change to behaviour. [ADR 0009](0009-precedence-at-the-write.md)'s
#343 amendment records it: such a fan is reported by the grant refusal and the snapshot, bridged by
§ 3 above the ceiling, retried by § 7's panic verb, § 4's sleep handback and SIGTERM's teardown, and
reconciled by the next process, and gets no retry of its own until a run shows what a refused keystone
is. For this ADR it adds one consequence to A6's contract (the identity amendment, item 1): engaging
through the driver is also what puts every fan level 6 engages into § 3's registry, the only mechanism
that acts unprompted on such a fan, so level 6 reaches a writer's `engageManualControl(of:)` through
the driver or not at all, and a source tripwire holds that. The driver registers a fan once the
engagement returns, or at its undo, so a lease released during the yield wait leaves § 3 holding
nothing for up to one `UnlockLimits.pollInterval` (100 ms), until the driver's next entitlement check
throws, registers and undoes. U5 and U5b gain a consequence: a refused keystone in any run goes to the
architect with #343's decision before the next run. **No `AeolusXPCVersion` bump. Status stays
Proposed.**

## Amendment (2026-10-15, [#368](https://github.com/blamechris/Aeolus/issues/368)) — a revocation that finds its lease already ended returns only once that ending's handback has

An A6 precondition, found by the delta review of #361 and reproduced under load with the real
`LeaseAuthority`, `HelperFanRestorer` and § 5 — the issue's probe lost 4–6 marks in 1,200 runs, 5–9
in 2,000 and 15 in 1,200, about 2.5–12.5 per 1,000, and none in 1,200 run alone.
Unreachable on every build on `main`, where a `.notBuilt` plane grants no lease. A reporting error,
`CLAUDE.md` rule 6 in the direction that hides a loss: the fan is handed back on every route.

**The defect.** § 5's terminal action keeps a fan's ledger entry by holding `finalising` from before
its hand-back until `revokeLease` returns (#346, #361). A lease-core teardown — the TTL sweep, a
connection death, any of the seven — that takes the lease out of the table first makes `revokeLease`
answer `.gone` at once. That teardown's release notice is still on its way through
`HelperFanRestorer`, an actor hop or two behind; it can reach § 5 after `finalising` has closed, and
clears `.systemReclaimed`. The window is set by the notice's delivery, not by the removal, so no
reordering of § 5's own statements closes it.

**Decision.** `revokeLease(id:forFan:because:)` takes the fan § 5 is giving up, and answers `.gone`
only once `releasing[fan]` is empty. The waiter is a continuation on the lease actor, registered in
the straight-line region that found the lease gone, and resumed in `restore(_:because:)`'s `defer`
at the instant the fan's count reaches zero. It waits once and does not re-check: a handback begun
after the drain is a newer lease's, whose notice must clear the mark. It is not cancellable, because
the restore it outwaits is not.

While the ending's handback is still under way, the drain is that ending's notice, by three facts
the design already rests on:

1. Every lease-core teardown takes its entries out of the table and counts their fans into
   `releasing` with no suspension between (ADR 0009's assumption table).
2. `HelperFanRestorer` awaits each § 5 notice before its write, and `releasing` drops only when it
   returns.
3. While `releasing[fan]` is held, `acquireLease` refuses the fan, and a fan in `restoreAbandoned`
   before that, so neither a newer lease nor a panic sweep of the register can begin a second
   handback of it until the first returns.

So when `releasing[fan]` drains, the notice the defect is about has reached § 5 and found
`finalising` holding the fan. `.revoked` and `.expired` need no wait: by the same three facts their
own restore is the fan's only handback.

**The drain is not always the ending's** ([#377](https://github.com/blamechris/Aeolus/issues/377),
found by #375's review). § 5's hand-back is the driver's write, and `releasing` does not count it,
so the ending teardown's handback can return during the hand-back and leave the fan to a later
lease-core handback by the time the revocation arrives. There are two routes. A newer lease can be
granted over the fan once the hand-back lands, and released. Or the ending's restore is refused for
the fan, which puts it in `restoreAbandoned`, and a `releaseEveryLease()` — § 7's panic verb, § 4's
sleep handback or SIGTERM's teardown — sweeps it before § 5 reaches the revocation. Either window is
the whole hand-back, not one resumption. A revocation arriving while that later handback is in
flight outwaits it instead, and `finalising` absorbs its notice. The cost is bounded and in the safe
direction: one more bounded wait, the whole sweep's on the second route, and a mark kept rather than
lost. The exact fix keys the wait on the lease as well as the fan, and #377 tracks both routes; the
mechanism here is unchanged.

**What it costs.** `.gone` now waits for one bounded restore call: the ending teardown's or, by the
routes above, a later one's. That is `RestoreLimits.attemptBudget` attempts for each fan the call
hands back, each bounded by `FanRestoreAttempting`'s contract (#168) and, failing that, by ADR 0012.
For most teardowns those are the ended lease's fans, as `.revoked`'s are. When the ending is
`releaseEveryLease()` — § 7's panic verb, § 4's sleep handback or SIGTERM's teardown — the call also
sweeps `restoreAbandoned`, so the wait spans every abandoned fan's attempt budget too: longer than
`.revoked`, and still bounded. § 5's cycle is parked for that long, as it already is for its own
revocation, and a handback that never returns parks it no longer than it would park `.revoked`. No
restore waits on anything: the hand-back has been issued, the ending's restore is untouched, and the
keystone gains no input and no read ahead of it.

**What remains.** Two notices can still be absorbed in the one continuation resumption between the
drain and § 5 resuming, the same two shapes as the routes above but begun after the drain rather
than before it. One is a newer lease's, granted over the fan and ended with no engagement between.
The other comes when the ended lease's restore was refused for the fan and a `releaseEveryLease()`
from § 7, § 4 or SIGTERM hands it back again. Here either needs a second lease-core handback to
begin inside that resumption and its notice to cross `HelperFanRestorer` before § 5 resumes: a grant
through its five suspensions and then the lease's ending, or a sweep. The guard has always had a
window of that shape after its last suspension, and this neither widens nor removes it. Absorbed,
either keeps a mark rather than losing one. A notice that reaches § 5 before the terminal action
begins still clears the mark: § 5 learns a lease has ended when its notice arrives, and one that
arrives first is a release that came first.

**What does not change.** § 5's body: one argument at one call site and no new line, which is why
this lands before #128's split. `LeaseRevocation`'s cases. The hand-back's place before the
revocation. § 3. **No `AeolusXPCVersion` bump**: `HeldLeaseRole` and `LeaseRevocation` are internal,
and nothing crosses the boundary.

**Alternatives considered.**

- *A token in § 5 that absorbs the next notice after a `.gone`.* It decides which notice is the
  ended lease's by counting, and miscounts whenever that notice already arrived — inside the
  hand-back, as #346's test lands it — and then swallows a later lease's release: rule 6 the other
  way. Exact only by asking `releasing`, and it spends lines § 5's body does not have.
- *Wait until every handback has drained.* No signature change, but another fan's handback extends
  the wait, and a client granting and releasing elsewhere could hold § 5 parked while it should be
  watching that client's fan.
- *Carry the lease in the release notice.* Exact, and what this ADR's table names for a restore path
  that bypasses `releasing`; it changes `FanRestoring`, the keystone's seam, and every conformer,
  for a fact the lease core already holds.
- *A second `HeldLeaseRole` verb § 5 calls after `.gone`.* A test sees the wait for free, and a
  future caller can forget the call — ADR 0009's "forgettable call" — in a body with four lines left.
- *Re-mark after the revocation returns.* Rejected in #346: a clear and a "resolved" line between,
  and an act after a suspension on a judgement made before it.

**Revisit if** a lease-core restore path bypasses `releasing`, or `HelperFanRestorer` stops awaiting
its § 5 notices before it returns — the wait then ends before the notice it exists for, and the
notice must carry the lease; a `restore(_:because:)` call outside lease teardown makes the
`releasing` overlap reachable, so two handbacks can hold one fan's count and the wait spans both;
leases that can overlap on a fan are proposed; #377 keys the wait on the lease and the fan, which
changes what the wait is for; or D8's measured write round trip makes a teardown's handback long
against § 5's cadence. The ruling is the architect's
#368/#343 consult, run on Opus.

This amendment corrects a clause of a Proposed ADR rather than the decision it sits under.
**Status stays Proposed.**

## Amendment (2026-10-15, [#128](https://github.com/blamechris/Aeolus/issues/128), [#270](https://github.com/blamechris/Aeolus/issues/270), [#269](https://github.com/blamechris/Aeolus/issues/269)) — § 5's registry is a value type, the grant reads the bounds, and the snapshot states the sleep seal and § 3's blindness

Three A6 enablers. The first changes no behaviour; the other two are unreachable on every build on
`main`, where a `.notBuilt` seam answers `.writePathNotBuilt` before either.

### #128 — § 5's registry leaves the actor as a value type it holds privately

**The constraint.** `ReclamationWatchdog`'s body was 346 code lines against `type_body_length`'s
error at 350, its file 977 of 1000, and #365, #366 and #368 each need § 5 code. Every member left
reads or writes `held`, so moving methods to another file widens it (D36).

**Decision.** `held`, `finalising` and `registrations`, with every synchronous decision made over
them, move into `ReclamationWatchdog.Registry`; the per-reading judgement moves into `HeldFan`. The
actor holds `private var registry` and keeps every `await`, every re-fetch and every act, in the same
order. Nothing the actor holds is widened: the new surface is `Registry`, the two enums its answers
are (`Registration`, `Judgement`) and `HeldFan`'s new methods, and an instance outside the actor
governs nothing. The compiler refuses a mutating `async` call on an actor's stored struct; the
registry also has no `async` member and no function-typed parameter — a closure that reaches the
registry while it is being mutated traps at run time — and `ReclamationWatchdogAccessTests` and
`ReclamationRegistryAccessTests` hold both, the actor's state private, its internal members exactly
acknowledged and its views get-only, its use of `registry` member-only, its file set read off the
tree, and no other file reaching the registry by an alias or a dotted extension. Measured under SwiftLint 0.65.1: 301 code lines,
867 lines. New § 5 state lands in `Registry`, tested as a value.

**Not taken.** Extensions in the same file: SwiftLint since 0.57 excludes extensions from
`type_body_length` by default, so they retire the bound rather than meet it, and leave `file_length`
where it was. A helper holding the ledger and driver: every call becomes a hop, so scheduling moves.

**No `AeolusXPCVersion` bump:** nothing on the wire changes. The ruling is the architect's #128
consult, run on Opus. This amendment corrects a clause of a Proposed ADR rather than the decision it
sits under. **Status stays Proposed.**

**The lease core's extraction, named by the same ruling, is taken.** It was set to land before any
change took `LeaseAuthority`'s body past 320 code lines or its file past 960, and #269 would have.
`releasing`, `restoreAbandoned`, `handbackAcceptedUnconfirmed` and `handbackUnconfirmed` move into
`LeaseAuthority.HandbackRegisters`, and `sleepSeal`, `latestWakeGeneration` and `sealGeneration`
into `LeaseAuthority.SleepSealPairing`, with every synchronous decision made over them; the actor
holds `private var registers` and `private var sleep` and keeps every `await`, every re-read and
every act, in the same order. `handbackWaiters` stays on the actor, because a continuation is not a
value. The rules and guards are § 5's: no `async` member, no function-typed parameter, no
whole-value use, the stores `private` and exactly listed, held by
`LeaseAuthorityRegistersAccessTests`. Measured under SwiftLint 0.65.1: body 308 to 287 code lines,
file 956 to 851. No behaviour changes and nothing on the wire moves; **Status stays Proposed.**

### #270 — the grant reads the bounds, after the foreign-control read

**Decision.** `acquireLease` reads `F<n>Mn` and `F<n>Mx` afresh through `FanEnvelopeReading`
(`readEnvelope(ofFan:)`, which `FanStateSensing` now refines) for every requested fan the
foreign-control step did not exempt, after that step and above the straight-line marker. It judges
them with `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)`, the snapshot's derivation; a
failed read is `.notMeasured`, as the snapshot's is. It refuses
`.manualControlUnavailable(reason: .boundsImplausible)`, mints no permit and caches nothing.

- **After the foreign read**, so a fan whose reads fail is told `.supervisorBlind`, and the ladder's
  step 5 already ranks above step 8: the two sides keep one order and no rung moves. Ahead of it, the
  snapshot would state a reason `fanctl auto` reads as silent over one it reads as pending.
- **Over the fans the foreign read did not exempt, never the exempted ones.** A fan in a handback
  register is answered by the register, as the snapshot answers it; `refuseIfExemptionLapsed` covers
  a handback landing during this read as it covers one during the foreign read.
- The seal case, recorded at step 10 as the one divergence left, closes.
- **Above the marker, so above the sleep seal's guard.** #269's `.systemSleeping` rung therefore goes
  below step 8 as well as step 5: while the seal holds, a fan with implausible bounds is refused
  `.boundsImplausible`, as the snapshot states.

**What it costs.** One `.supervisor` turn per requested fan Aeolus is not accountable for, per grant,
bounded by per-connection serialisation, as the foreign read is. `SMCReadPriority`'s "revisit when"
note records it and is not acted on.

**No `AeolusXPCVersion` bump.** No field, case or method changes: `.boundsImplausible` is on the wire
and is thrown through the existing `manualControlUnavailable(reason:)` fault.

**Assumption added.** The snapshot's `F<n>Mn`/`F<n>Mx` read and `readEnvelope` fail together and
reach one plausibility gate (`FanControlEnvelope.validating`); if a platform splits them, fix the read
in the same change. It is a row of the table below.

**Alternatives considered.** *Bounds first, or over every fan*: silent over pending. *Bounds inside
§ 6's role*: widens it to save one turn. *`.boundsImplausible(fanIndex:detail:)` from the grant*:
`apply`'s form, two shapes for one refusal.

**Revisit if** bounds are seen changing at run time: fix the read, do not debounce (the #360
precedent). The ruling is the architect's #128/#270/#269 consult, run on Opus. This amendment
corrects clauses of a Proposed ADR rather than the decisions they sit under. **Status stays
Proposed.**

### #269 — the sleep seal and § 3's blindness, placed by what `fanctl auto` reads them as

**Decision.** The ladder is evaluated in `acquireLease`'s order — 6, 5, 8, 1, 2, 11, 10, 3, then 9 —
with two new rungs, as **one first-match function**, `ReadOnlyFanReport.firstRefusal`, in place of
re-statements layered over one another: a rung keyed on what the one above it left breaks silently
once that one starts producing it. **Step 11, `.systemSleeping`**, from
`LeaseAccountability.sleepSealed`, read in the registers' hop, where the grant checks the seal; step 3
moves below it and below step 10, so a fan mid-handback during a sealed teardown reads what the grant
throws. **Step 12, `.noThermalTelemetry`**, from one `sighting()` per snapshot on a `.built` seam,
re-states `.available` and `.boundsImplausible` and nothing else. Steps 4 and 7 stay retired.

**Step 12 is the exception, and it refines the rule.** The grant asks blindness before every per-fan
step because it suspends. In that order the rung would overwrite `.supervisorBlind`, the registers and
the seals — reasons `SafeState` classes pending or durable — with one it classes silent, and `fanctl
auto` would exit 0 about a fan whose mode did not read, on a machine that cannot read: #360's defect.
So: **the snapshot agrees with the grant on whether a grant is refused, always, and on the reason,
except that a machine-wide refusal `fanctl auto` reads as silent is never stated over a fan's own
durable or pending reason.** Step 5's manual arm over step 6 was the first instance; step 12 is the
second. Where they part, both refuse. Step 11 is pending, so it follows the grant's order exactly; if
ADR 0013 classes it silent, it drops below steps 3 and 10 in the same change.

**Plumbing.** `SupervisedFanAuthority` holds the cache the lease core proves grants against, the same
instance, as a required `private let telemetry: any SightednessProving`. `snapshot()` asks it first,
only when the seam is `.built`; the check rethrows `CancellationError` and logs nothing of its own.
`restatingAvailability(…, blind:)` takes the answer with no default. On every shipped `.notBuilt`
build nothing observable changes: step 6 masks steps 11 and 12, and `sighting()` is never called.

**What it costs.** A `.built` snapshot asks the cache once: an actor hop warm, one coalesced curated
read cold. Measured on `Mac16,5`, macOS 27.0.1 (26A434), by
`HelperHardwareTests.theSnapshotsSightingIsCheapAndCoalesced`, in four runs with no other build or
test on the machine: warm, the check took 0.79–0.96 µs at p50 and at most 1.7 µs, with no curated
read in 160 snapshots; cold, one curated-set read per snapshot, 40 of 40, at 48–115 ms p50; and with
§ 3 stopped, twelve bursts of 16 concurrent snapshots on an expired cache issued one read each and
never held more than one `.supervisor` turn, parked or in flight. A snapshot-path failure is
remembered as a grant-path one is, so the
snapshot can produce the blindness a grant is refused on — the same read. On a `.built` seam, during a
sealed sleep after the teardown returns, `fanctl auto` exits 8 where it exited 0: `systemSleeping` is
pending (ADR 0013). § 3's latch stays machine-wide only.

**No `AeolusXPCVersion` bump.** No field, case or method changes: `.systemSleeping` and
`.noThermalTelemetry` are on the wire and already thrown.

**Assumption added.** The cache keeps the snapshot's sighting to one curated read per period. It is a
row of the table below.

**Alternatives considered.** *A machine-wide field for either rung*: a bump. *Rung 12 in grant
order*: #360's exit 0. *Reclassify `noThermalTelemetry` as pending*: `auto` never exits 0 on a blind
machine whose fans read automatic, and durable 9s become 8s. *A cache peek that does not read*: a
second definition of sighted. *Move the grant's blindness check below the foreign read*: costs reads
when blind, and the registers still part.

**Revisit if** ADR 0013 reclassifies `noThermalTelemetry` or `systemSleeping`; the `Mac16,5`
measurement exceeds one curated read per period; or concurrent grants across connections contend with
§ 3. The ruling is the architect's #128/#270/#269 consult, run on Opus. This amendment corrects
clauses of a Proposed ADR rather than the decisions they sit under. **Status stays Proposed.**

## Amendment (2026-10-15, [#366](https://github.com/blamechris/Aeolus/issues/366)) — § 5's mark follows the primary signal, a re-apply mid-episode leaves it to the episode, and a lease given up stays refused

Three A6 preconditions about one fact, the `.systemReclaimed` mark behind
`FanState.isReclaimedBySystem`. #361's § 5 reviewer found the first and third, and the review of
#365 (#379) found the second. Each was demonstrated by a test. All three are unreachable on every
build on `main`, where a `.notBuilt` plane grants no lease, and all three are reporting errors
(`CLAUDE.md` rule 6): on every route the fan stays bounded and is handed back.

**The defects.**

1. *Cleared by a re-apply during the re-assert.* § 5 marks a fan reclaimed when its primary signal
   diverges, then re-asserts. A registration under the same lease was accepted during the
   re-assert's envelope read, and it cleared the mark. The envelope then failed, and the terminal
   action gave the fan up as `.systemReclaimed` with no mark left.
2. *Cleared by a re-apply after the terminal action.* A same-lease registration can begin during the
   hand-back and resume after the terminal action has returned. It read the generation after the
   entry's bump, and `finalising` had closed, so nothing refused it. It was accepted, recorded the
   fan under the revoked lease and cleared the mark; had it not, the next cycle's `.leaseLapsed`
   hand-back would have. The revocation's own release notice is a hint (ADR 0009 D2), so nothing may
   rely on it.
3. *Held through a ramp.* Only a cycle converged on both signals cleared the mark. A re-asserted fan
   whose target the firmware holds, but which has not yet reached its speed, reads `.short`, and
   `.short` returned before the clear. The mark stood for the whole ramp, and for good on a fan that
   cannot reach its target. The identity amendment's "one cycle" was not true; #361 corrected the
   documents to the real bound.

**Decision.**

- **The mark follows the primary signal.** Every readable cycle whose primary signal converges
  clears the mark, `.short` included, because reaching the secondary signal means the firmware is
  holding Aeolus's target (#119). This makes the identity amendment's "one cycle" true again, as
  the next readable cycle: cycles that cannot read clear nothing. The re-assert budget is unchanged
  and still refills only on a cycle converged on both signals: the budget bounds a contest, and the
  mark says who holds the fan.
- **A re-apply mid-episode leaves the mark to the episode.** `judge(_:)` sets
  `HeldFan.episodeInFlight` on every `.diverged`, before `diverged(_:fanAt:heldUnder:)` reaches the
  ledger, and the next readable cycle whose primary converges clears it. While it is set, a
  registration under the record's own lease is accepted: it keeps the record and moves the
  generation, but clears nothing (`.accepted(replacedEndedLease:mayClearTheMark:)`). § 5's flow is
  untouched, so a re-apply can neither postpone the terminal action nor rearm the budget (#180).
- **A lease given up stays refused.** `beginFinalising(fanAt:for:)` records the lease in
  `Registry.givenUp` for that fan, and nothing clears it. `register` refuses that lease in place of
  `finalising[index] != lease`. The same call ends that lease, and an ended lease is never live
  again, so every answer about it is stale whenever the registration began. `finalising` keeps
  release's skip (#346).
- A registration under any other lease still clears the mark. One live lease covers a fan, so such a
  registration means a newer engagement holds the fan.

**How the guards divide one lease's registrations.**

| When the registration lands | What happens to it |
|---|---|
| Before the diverging judgement | Accepted, and it clears the mark |
| From that judgement to the terminal action's entry | Accepted, and it clears nothing |
| From the entry onwards | Refused |

The second row holds only while the episode is open: once a cycle that reads the target held has
closed it, a registration behaves as in the first. The refusal is per fan: a sibling fan's re-apply
under the same lease is refused by the revocation's release notice, and with that notice lost falls
to `.leaseLapsed` on the next cycle. The entry's generation bump stays, for another lease's
registration in flight across the entry.
Mid-episode the registration is accepted rather than refused, because a refusal makes A6 hand the
fan back, and that restore supersedes § 5's own re-assert (D4).

**A6's contract.** Its shape is unchanged.

- Item 2 gains two sentences. A registration under the lease a terminal action gave the fan up for
  is refused, while the terminal action runs or after. One accepted mid-episode leaves the fan
  reported as reclaimed until § 5 reads its target held, or gives the fan up as reclaimed and keeps
  the mark. An episode that escalates through blind cycles ends `.supervisorBlind` instead, because
  the ledger's last diagnosis wins, and the fan is then not reported as reclaimed.
- Item 5 is unchanged. After the terminal action the lease is gone, so `.leaseNotLive` maps to the
  lease fault.

**What remains.**

- A same-lease re-apply that engages the fan mid-episode leaves `isReclaimedBySystem` true until the
  next readable cycle: one cycle, or at most `blindCyclesBeforeDivergence` if reads fail.
- A clear queued just before the judgement can run after the mark, because Swift's actors do not
  promise to run jobs in the order they arrive. The window is one latch hop plus one ledger hop, as
  on `main`.
- The blind path opens no episode. A same-lease registration inside its `markSupervisorBlind` hop
  clears the `.supervisorBlind` entry: one ledger hop, which is not on the wire (#355).
- The re-assert acted on the target and mode it judged before its envelope read, so a re-apply
  inside that read was overwritten (target) or logged as a failed write (mode). Closed by #381: see
  the amendment below.

**Alternatives considered.**

- *Stop § 5 when the generation moves.* A client that re-applies every cycle postpones the terminal
  action indefinitely.
- *Refuse a same-lease registration while an episode is in flight.* A6's hand-back of the refused
  engagement supersedes § 5's re-assert, and § 5 then blames the system for it.
- *Bump the generation at the terminal action's exit.* It also refuses a newer lease's registration
  whose lease hop straddles the exit.
- *Registration never clears a mark the terminal action kept.* For the second defect, the next
  cycle's `.leaseLapsed` hand-back clears the mark anyway.
- *A rule in the ledger.* The ledger learns of an episode after a hop that nothing orders against
  the registration's clear.
- *The episode as a `Registry` store keyed by fan.* Four transitions end a record (`register`
  replacing it, `release`, `forget` and `dropLease`), and each would also have to end the episode.
- *Re-mark at the terminal action's entry.* It adds a suspension, and logs a "resolved" and a second
  "detected" line for one event (#346).
- *Clear when the re-assert's write returns.* A returned write is not the firmware holding it (U4,
  `.reverted`).
- *Keep the mark until both signals converge.* It stays a false report for every re-assert from
  below the target.

**Revisit if:**

- a run shows firmware reading back `F<n>Tg` while not honouring it (U4 failing that way);
- `.supervisorBlind` reaches the wire;
- A6 serialises a fan's engagements across § 5's whole re-assert;
- leases that can overlap on a fan are proposed;
- a mark is lost with no registration near it.

The ruling is the architect's #366 consult, run on Opus.

**No `AeolusXPCVersion` bump.** `isReclaimedBySystem` keeps its type and its documented meaning.

This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under. **Status
stays Proposed.**

## Amendment (2026-10-16, [#381](https://github.com/blamechris/Aeolus/issues/381)) — § 5's re-assert writes the fan as it stands, and leaves a fan its own lease re-engaged to that engagement

An A6 precondition, found by the architect's #366 consult. Unreachable on every build on `main`,
where a `.notBuilt` plane grants no lease. It is `CLAUDE.md` rule 6 in the direction that claims
control Aeolus is not honouring as asked: on every route the fan stays bounded and inside its lease.

**The defect.** § 5 decided what to write before its suspensions and wrote it after them.
`diverged(_:fanAt:heldUnder:)` read the record's target before its ledger hop and passed it to
`reassert`, whose re-engage was decided from the cycle's reading. A re-apply under the same lease is
accepted inside any of those suspensions, because a same-lease registration keeps the record (#180).
Then:

1. *Target diverged.* The re-assert commanded the old target over the client's new one and recorded
   it.
2. *Mode reclaimed.* The mode write found the fan already manual, the driver refused it as
   `.notAutomatic`, and § 5 logged a `.fault` that it could not re-engage the fan and spent an
   attempt.
3. *During the command write.* A report that arrived during § 5's own write was overwritten in the
   record. If the client's write landed last, the next cycle read it as diverged and re-asserted the
   old target over it.

**Decision.**

- **The examination stamps the record.** `Registry.beginExamination(ofFan:)` records the fan's
  registration generation on `HeldFan.examinedAtGeneration` before the control-state read. A
  same-lease registration keeps the record and moves the generation, so the two differ.
- **A same-lease registration since the stamp stands the re-assert down.**
  `Registry.reassertTarget(ofFan:under:)` answers `nil`. The re-fetches after the envelope read and
  after the first step stop there: § 5 writes nothing more for that examination and says so. So
  does a first step refused `.notAutomatic` while that answer is `nil`. While one engagement of a
  fan runs at a time, that refusal wrote nothing: the engagement took the fan off automatic control
  first, so it is logged as the stand-down, not as a failed write
  (`reengageRefused(fanAt:heldUnder:error:)`). It is decided on the error type, and the driver
  throws the same `.notAutomatic` after a step has written when two engagements of the fan overlap;
  that case is the two-engagements residual below. The attempt booked in `diverged` stays
  spent, because that engagement's writes are this round's. The mark is left to the episode (#366).
- **The target is the record's as it stands after the last suspension before the write.** `reassert`
  no longer takes one.
- **The record keeps a newer report.** `recordReassertedTarget(_:decidedOn:ofFan:)` records § 5's
  write only over the target it was decided on.
- **Only the writes stand down.** A re-apply stops neither the judgement, the budget check, the
  envelope-failure branch nor any terminal action. A client re-applying every cycle still meets the
  terminal action when the budget runs out (#180, #366).

| When the same-lease re-apply lands | What § 5 does with that examination |
|---|---|
| Before the stamp | Judges a reading that includes it |
| Stamp to the first-step re-fetch, registering | Writes nothing more; the attempt stays spent; the mark is left to the episode |
| Stamp to the first-step re-fetch, report only | Re-asserts the reported target |
| During § 5's command write | The record keeps the report; the firmware keeps whichever write landed last |

**A6's contract.** Its shape is unchanged.

- Item 2 gains: *Register each fan before this `apply`'s first command write to it, a fan already
  engaged under the lease included. A registration accepted while § 5 is examining the fan leaves
  that examination's re-assert to this engagement.*
- Item 3 gains: *Report after the write returns, never before. § 5 re-asserts the target last
  reported, and a report that arrives during its own command write wins the record.*
- A control-loop step that only commands is covered by the re-fetch, not the stand-down.
- Item 5 is unchanged.

**What remains.**

- *A client write issued during § 5's command write can land first.* The fan then holds § 5's
  re-fetched target, which is older than the client's, until the next readable cycle reads it as
  diverged and re-asserts the client's: one cycle, one more attempt, and the mark kept for that
  cycle. Only mutual exclusion over the write closes it.
- *Two engagements of one fan under one lease remain an A6 precondition.* The plane's in-progress
  record is still per fan. A same-lease engagement that completes during § 5's own mode write now
  stands § 5 down rather than being commanded over, and one that completes before § 5's first step
  stands it down there, without a `.fault`. One that completes during § 5's yield wait, between two
  of its driver's steps, clears the shared record, so § 5's next step is admitted as a first step
  and refused `.notAutomatic` after § 5's driver has written. The driver hands the fan back, and § 5
  logs the stand-down, whose line says nothing was written; until `reengageRefused`, that case
  logged a `.fault`. The fan ends on automatic control and the mark is kept, so the snapshot is
  truthful, but the log line is not, and the client's engagement believes it holds a fan it does
  not. Tracked as [#389](https://github.com/blamechris/Aeolus/issues/389), an A6 precondition.
  Routing on whether the driver wrote would change the driver's error vocabulary, which level 6 also
  maps, so that choice is #389's.
- *A same-lease re-apply just before a genuine re-reclamation stands that cycle's re-assert down.*
  It costs one cycle and one attempt, in the direction of giving the fan up sooner.
- *So does a re-apply that registers without engaging a fan the system has taken back.* Item 2
  registers a fan already engaged under the lease without engaging it again, and the system may
  have reclaimed it since. The stand-down leaves the fan on automatic, with the client's target
  written where nothing honours it, until the next cycle reads the mode reclaimed and re-engages
  it: one cycle and one attempt, in the same safe direction. Requiring A6 to engage such a fan
  would close it; it is listed rather than required, because the direction is safe and the next
  cycle bounds it.
- *The judgement's own view is not covered.* A target reported between § 5's read and its judgement
  is compared against a reading that predates it; tracked as
  [#383](https://github.com/blamechris/Aeolus/issues/383), an A6 precondition.

**Alternatives considered.**

- *A6 serialises a fan's engagements across § 5's whole re-assert.* Engagements are not writes, so a
  target-only re-assert still races the client's command. A turn taken at the re-assert meets a
  judgement made before it, so the re-fetch and the stand-down are needed under it anyway. A shared
  turn parks § 5's whole sequential sweep behind any holder that never releases, and D_cycle watches
  § 3, not § 5.
- *Re-read the target after the envelope read.* It leaves the mode half as it was and the driver's
  steps open. Recording over a newer report re-creates the overwrite one cycle later.
- *Stop § 5 whenever the generation moves.* A client re-applying every cycle postpones the terminal
  action indefinitely.
- *Refund the attempt on a stand-down.* The same unbounded contest. The cancellation refund is for a
  round in which no write reached the wire, and here the client's did.
- *Stamp at the judgement.* It misses a re-apply during the read or the lease hop, and the mode half
  still reports a failed write.
- *A per-fan command epoch checked inside the plane's write turn.* Exact, but it needs reports
  before writes and changes a write verb across every conformer (ADR 0008).

**Revisit if:**

- A6 adds a per-fan forward-write turn: § 5's re-assert then takes it from the stamp to the record;
- A6 or #17 reports a target before writing it;
- leases that can overlap on a fan are proposed;
- a hardware run shows the write race landing.

The ruling is the architect's #381 consult, run on Opus. **No `AeolusXPCVersion` bump:** nothing
crosses the boundary. This amendment corrects clauses of a Proposed ADR rather than the decisions
they sit under. **Status stays Proposed.**

## Assumptions and what would invalidate them

| # | Assumption | Basis | If it fails |
|---|---|---|---|
| U0 | Apple's own management reads raw `F<n>Md = 0` | Observed only with no load and nothing holding a fan (26.5.2, 27.0.1). "Mode 3" is reported. Never read under load (#208) | **Any non-zero raw value, `1` included:** before run 1, `FirmwareFanMode`'s fold and every E5 confirmation read are re-decided, and D3 polls by reading (Y-read) |
| U14 | Apple's own management leaves raw `Ftst = 0`, under load included | Every raw read on record is `0`; none was taken under load | The preparation step would clear Apple's own state at each start, and D3 step 3 would write over it. Both go to the architect before run 1 |
| U1 | A naive `F<n>Md = 1` succeeds when the system is not actively asserting control, and is refused with `0x82` when it is | Reported. `0x82` has been seen here only on reads of function keys | **Accepted and applied under load:** no force key is needed on this machine; recorded. **Accepted, then taken back within § 5's cycles:** write `Ftst` before the mode write, a conformer-internal change. **Another code:** treated as "held" only after architect review |
| U2 | `Ftst = 1` is accepted, and the mode write after it | Reported | No unlock by this route. E4 stops, the snapshot says manual control is unavailable and why, the matrix says so, and it goes back to the architect. Never coded around |
| U3 | The yield arrives within 3.5 s | Reported at about 3 s; budgets of about 30 s suggest a tail | Raise the budget and give `apply` its own client deadline. Beyond about 4 s, asynchronous engagement before merge |
| U4 | An accepted `F<n>Md` reads back raw `1`, and `F<n>Tg` reads back within `ReclamationLimits.targetToleranceRPM` (1 RPM) of what was written | Unobserved. § 5's primary signal rests on the second half | **Mode:** D3 refuses, which is correct. **Target:** re-derive the 1 RPM tolerance from the observed quantum before merge — a safety-limit change — or every § 5 cycle reports a reclamation |
| U5 | The reverse-order restore is accepted for a fan the plane engaged | Unobserved | The retry already runs the other order. If only that one lands, D5's order flips, in one place. A refused keystone in any run goes to the architect with #343's decision (ADR 0009, 2026-10-15) before the next run |
| U5b | `F<n>Md = 0` written to a fan already in automatic is accepted, with or without the force key, whatever the thermal manager is doing | Unobserved. Tested by 1b′ and by every `.everyFan` | Refusal accounting changes before run 2 (Consequences). A refused keystone in any run goes to the architect with #343's decision (ADR 0009, 2026-10-15) before the next run |
| U6 | With `Ftst = 1` and every raw `F<n>Md = 0`, Apple's management drives the fans | Unknown | D5's gate goes: every restore clears the key, and every engagement re-sets it. § 4's never-issued keystone becomes a priority residual |
| U7 | `Ftst = 1` does not change the behaviour of a fan Aeolus did not engage | Unknown | A one-fan lease would take the others off Apple's management while the snapshot calls them automatic (rule 6). Engagement becomes all-fans-or-nothing on such firmware, and the lease shape is the maintainer's call |
| U8 | Every write round trip stays under 50 ms (D/100), the teardown restore's and 1b′'s included | Reads: 11.45 ms worst. Writes: unmeasured | D8's decision rule |
| U9 | Manual mode and the force key persist after the writer dies (ADR 0012 H3) | Reported | If they revert on close, ADR 0012 and the preparation step get cheaper; nothing changes |
| U10 | `ioreg` lists every `AppleSMC` user client with its creating process | Hypothesis | D9's census gate is dropped |
| U11 | A power cycle returns raw `F<n>Md` and `Ftst` to `0` | `RECOVERY.md` step 7 asserts that the force key resets. That `F<n>Md` does not persist is `docs/SAFETY.md` row 7's unverified assumption, and ADR 0011's | D8's recovery steps end in a loud fan and `RECOVERY.md` § 8. Run 1's target choice is what makes that acceptable |
| U12 | Sleep resets `Ftst` | Reported. Not depended on (D5) | Only the never-issued-keystone residual widens |
| U13 | Apple's controller never commands above the declared `F<n>Mx` | The highest fan speed recorded under Apple's control is 3,683 RPM, against 5,777 declared (2026-08-20; key not recorded). The highest recorded `F0Tg` is 2,195 RPM. The pre-flight records `F<n>Tg` through a load and its soak | 1b's "at or above demand" fails by the excess. Aborts 9 and 1 catch it |
| — | The preparation step can enumerate the fans and record both restore keys' types | `FNum`, `F<n>Md` and `Ftst` have read on every capture. Both are `ui8`, one byte, on 27.0.1 | `.everyFan` writes the touched set's fans and the force key, then throws `.fanSetUnknown`. An unknown key is written as one zero byte (D5, D7). Start 0 stops |
| — | One engagement per fan at a time | True today: § 5 is the driver's only caller and its sweep is single-entrant. **Assumed and not enforced** — the ledger keeps one in-progress record per fan index, and a first-step retry that removes a stale record could remove a concurrent engagement's | An A6 precondition: before level 6 engages beside § 5, serialise engagements per fan or key the record per engagement. Also: § 5's `finaliseRelease` restores and then revokes the leases, so for that window a genuine restore has not yet ended the lease; harmless while § 5 is the only caller, and its order matters once A6 adds a concurrent one. Across leases, a second engagement now fails safe (the 2026-10-15 identity amendment): the stale one's next check asks about its own ended lease and undoes, and the undo supersedes the other. Under one lease this remains an A6 precondition |
| — | One lease-table entry, one production plane | True today | Concurrent leases or a second plane: re-check D4's epoch scope and D5's gate. Since the 2026-10-15 amendment, no lease is granted while § 7's panic verb or § 4's handback runs (`sealingGrants(during:)`). The seal is machine-wide, so concurrent leases or a second plane re-check that it still covers every restore that can undo a grant. |
| — | A re-grant after § 5's terminal action is a client's request | `AeolusXPCClient` and ADR 0013 D1 never re-acquire; the app has no control UI yet | A self-re-acquiring client makes the contest with the system unbounded: a measured, time-limited ledger refusal, mirrored in the snapshot |
| — | At most one live lease covers a fan | One lease at a time (`.leaseHeldByAnotherClient`) | Overlapping leases: § 5's records keyed per (fan, lease), and registration's arbitration re-decided |
| — | Every lease-core restore notice for a fan precedes any grant over it, and precedes the fan leaving `releasing` | `releasing` is held from before the restorer's notices until it returns; `HelperFanRestorer` awaits each notice before its write | A restore path bypassing `releasing` lets the index-keyed `manualControlReleased(fanAt:)` erase a newer lease's record, and a notice delivered after the restorer returns ends #368's wait before it arrives; either way the notice must then carry the lease |
| — | The snapshot's `F<n>Mn`/`F<n>Mx` read and the grant's `readEnvelope(ofFan:)` fail together and reach one plausibility gate (#270) | Code: one scheduler and connection, the same two keys. Each path checks finiteness before the gate: the plane at its seam, and the snapshot's in `SMCFanEnumeration`, which turns a non-finite read into `.notDecodable`. A non-finite bound is therefore `.notMeasured` on both, and both end at that gate as `.boundsImplausible`. Unverified on Intel and M1/M2 | The grant refuses leases the snapshot offers, or the reverse. Fix the read in the same change; do not debounce |
| — | The cache keeps the snapshot's sighting to one curated read per period (#269) | Measured on `Mac16,5` (27.0.1, 26A434) with § 3 stopped, in four runs: one curated read per cold snapshot, 40 of 40, and one per burst of 16 concurrent snapshots, 12 of 12, never more than one `.supervisor` turn held; none warm. Not measured with § 3 running beside an expired cache, nor on Intel or M1/M2 | The cost question reopens: a `.built` snapshot's check would queue `.supervisor` turns ahead of § 3. Fix the cache's coalescing; do not move the check off the snapshot |
| — | The snapshot's `F<n>Md` read and the grant's fresh read fail together | Code: one scheduler and connection, the same key and `FirmwareFanMode(declaredByFirmware:)` decode behind the same finiteness rule; a `.snapshot` read waits and never fails for its priority. They differ only in priority and instant. Every recorded `F<n>Md` read on `Mac16,5` answered, and none was taken while reads were failing | The #360 rung refuses leases the helper grants. Fix the read, and re-decide here. The same holds for a platform whose mode is not `F<n>Md` (Intel, `FS! `): the snapshot's read must take the plane's branch, or share its decode, in the same change |

Every observation above is `Mac16,5`; the write-path rows are hypotheses until D8 runs. Intel and
M1/M2 ship `untested`.

## Revisit when

Revisit this ADR when any of U0–U7, U5b, U13 or U14 is contradicted, by the pre-flight or by a
run. That is the expected case: amend this ADR, and do not code around it.

Also revisit it when:

- a write round trip exceeds 50 ms;
- the yield does not fit a synchronous `apply`;
- concurrent leases or self-renewing leases are proposed;
- a second production plane exists;
- a report arrives from M1/M2 or another M3+ machine.

The ruling is the architect's E4 consult, run on Opus.
