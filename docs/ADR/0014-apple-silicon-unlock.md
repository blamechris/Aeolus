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

When this ADR was written, the production plane answered `writeCapability == .notBuilt`,
`SMCConnection.write(_:to:)` threw, and no write selector existed under `Sources/`. *(On
`e4/bring-up` since [#431](https://github.com/blamechris/Aeolus/pull/431), the last two are not
true: `write(_:to:)` sends one `WRITE_BYTES` round trip, and `selectorWriteBytes`, 6, is declared
in `SMCConnection`. The plane still answers `.notBuilt`, and the helper calls the write only in
the daemon's `private` forwarder, which nothing invokes, by the B1 seam amendment.)*

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

1. **Level 6 does not exist.** `SupervisedFanAuthority.apply` refuses unconditionally. *(Until
   the A6 PR-3 amendment, which wires it to `LeaseApplier`.)*
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
   *(U0 failed in P1; see the P1′ amendment.)*

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
    *(Withdrawn by the A6 amendment below: level 6 engages through its own driver.)*

  The driver's sources are stored properties set at composition, never arguments:
  - the lease core's per-fan liveness query (#180);
  - § 3's latch;
  - its writer's level;
  - § 3's registration role.

  So its verb is `engageManualControl(of: CommandableFan)` as well, and it always asks about the
  permit's own index. The fan whose lease is checked cannot differ from the fan being written.

  How `WriteVerbAllowlistTests` classifies the new functions:
  - The driver's engage and `engageUnderLease(of:)` join `permitBearingVerbs`. *(`engageUnderLease`
    is withdrawn, and `GovernedFanWriter.hold(_:of:)` joins instead: the A6 PR-2 amendment.)*
  - **The driver's undo takes the fan's index, never the permit.** It joins `permitFreeFunctions`,
    because it reaches a write only through `restoreToAutomatic`.

  **As built on `main` (slice A4 of #9, with #181):**
  - § 5's re-assert calls the driver; `SafetyActorWriter.engageManualControl(of:)` is the
    one-step pass-through the driver steps through, and nothing else in `Sources/` calls it.
    `EngagementDriverTests.onlyTheDriverEngages` holds that.
  - § 5 runs the unlock only for a reclaimed mode. D3's first step refuses a fan whose raw mode is
    not `0`, so a fan still in manual whose target diverged is re-commanded alone, after the
    driver's `requireEntitlement(for:)`. *(Since the P1′ amendment, a reclaimed mode reads `0` or
    `3`, and D3 admits both.)*
  - `permitBearingVerbs` gained the driver's `engageManualControl(of:)`, `firstStep(of:)` and
    `requireEntitlement(for:)`, and § 3's role requirement `manualControlEngaged(_:)`.
    `permitFreeFunctions` gained `handBack(fanAt:)` (the undo), `handbackAccepted(fanAt:)`, the
    preparation step's requirement and its conformer, and `HelperComposition.prepareWritePath()`.
  - A restore no longer erases an engagement's epoch record, so a restore of the engaging fan or a
    machine-wide one supersedes it; a fresh engagement that finds an earlier one's record out of
    date retries its first step once, after the entitlement (see `EngagementDriver.firstStep`).
    *(Since the #410 ticket-and-seal amendment the engagement's ticket clears that record, and the
    retry takes a fresh ticket before its entitlement.)*
  - The restore's plan is decided when it is issued, inside its turn (`PlaneWriteLedger`).
  - **B1 preconditions this leaves.** `PlaneWriteLedger` records the force key's presence but
    not the declared type and size of each `F<n>Md` and of `Ftst`, which D7's encoding of a
    restore needs; B1 adds them to the preparation record. B1's production step must call
    `recordModeWriteIssued(fanAt:)` for every mode write it issues. And B1's restore must call
    `restoreRequested()` synchronously when it is called, **before** it waits for its scheduler
    turn, and `issueRestore(fanAt:)` / `issueMachineWideRestore()` **inside** that turn: the
    scripted double runs both in one actor turn, so no test on `main` can show the split.
    *(Superseded by the #410 ticket-and-seal amendment: the calls are now
    `restoreRequested(_ scope:)` before the turn and `plan(for:)` inside it, and the amendment's
    "B1's obligations" is the list B1 implements.)*

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

  *(Decided by the P1′ amendment: the fold and the pre-state read Apple's set `{0, 3}`, the poll
  stays Y-write, and U14 holds.)*

**For one fan *n*:**

1. **Pre-state and the first write.** The driver asks the entitlement (D4). Then, in one plane
   turn:
   1. Check the restore epoch (D4).
   2. Read raw `F<n>Md` as the pre-state. If it is not `0`, throw `.notAutomatic` and write
      nothing: a fan that is not automatic is not Aeolus's to take. *(Since the P1′ amendment: a
      raw value the fold does not call automatic, which means one outside `{0, 3}`.)*
   3. Resolve `F<n>Md`'s type and order from a fresh `READ_KEYINFO` (ADR 0004).
   4. Write `F<n>Md = 1`.

   *(Superseded in part by the B1 amendment: B1 will take the fresh key info before the pre-state
   read. Both come before the first write; the amendment says what the order changes.)*
2. **On `0x00`**, read raw `F<n>Md` in the same turn:
   - **`1`** → `.engaged`, with the force key untouched. This is evidence of engagement only
     because the same turn read `0` immediately before the write. When the system is not actively
     asserting control, this is the reported first step. Under load it disagrees with the report.
     It is recorded either way. *(Since the P1′ amendment, the same turn read a value in Apple's
     set, which never includes `1`, and the turn also holds the target at or above the floor.)*
   - **`0`** → accepted is not applied
     ([#291](https://github.com/blamechris/Aeolus/issues/291)): throw.
   - **Any other value** → throw, and back to the architect.
3. **On `0x82`**, it depends on the force key's state:
   - **`Ftst` recorded present, and the plane's force-key flag (D5) clear:** in the same turn,
     re-check the epoch, take a fresh `READ_KEYINFO`, and write `Ftst = 1`. `0x00` sets the flag
     and returns `.awaitingYield`; anything else throws. *(Superseded in part by the B1 amendment:
     every issued `Ftst = 1` sets the flag, whatever it answers, because a refusal does not prove
     the key unset. `0x00` still alone returns `.awaitingYield`.)*
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
     nothing written. Otherwise, proceed as Y-write. *(Withdrawn by the P1′ amendment.)*

   When `UnlockLimits.yieldBudget` elapses — 3.5 s for run 1, so at most 35 steps — the driver
   undoes and refuses. **No turn is held between steps.** The step records the time from `Ftst`'s
   acceptance to `.engaged`, and the step count.
5. **On `.engaged`**, the driver registers the fan with § 3, runs D4's after-check and returns.
   `apply` then registers the fan with § 5, commands its target, and reads `F<n>Tg` back.

On any throw, the driver undoes (D4, D5) and refuses — with two exemptions, both before anything
of the engagement's was written: a first step refused `.notAutomatic` (undoing it would be ADR
0011's contest), and a first step superseded at its admission, which the driver retries once after
asking the entitlement again (as built, `EngagementDriver.firstStep`; since the #410 ticket-and-seal
amendment the retry takes a fresh ticket first). A step superseded after its
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
  engagement takes the epoch before its entitlement and its first step is admitted under it (the
  #410 ticket-and-seal amendment). Once the epoch has moved, the engagement writes nothing more and
  throws `.superseded`.

  A turn is one indivisible occupation of the connection. So no forward write **after an
  engagement's first step** lands after a restore that was *requested* before that write's turn
  began. The first step itself is the exception: it records the epoch, so a restore requested before
  its turn is not seen — ADR 0009 D1's residual, below. *(Since the #410 ticket-and-seal amendment a
  first step is admitted only under the epoch its engagement took before the entitlement, so a
  restore requested after that is seen at its admission.)*
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
- **What remains:** the epoch does **not** make the entitlement check atomic with the write. A lease
  can end, or § 3 can latch, between the driver's check and the step's turn — and a restore
  requested before an engagement's first step is not seen by the epoch at all. Every genuine restore
  ends the lease (immediately before or right after the restore) or latches § 3, so the driver's
  next check sees it. *(Closed for § 4, § 6 and § 7, and narrowed elsewhere to writes a later
  restore covers: the #410 ticket-and-seal amendment.)*

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
queued ahead of it at `.supervisor` (D7). *(Since ADR 0012's 2026-10-18 amendment a restore § 3
causes — its bridge job's and its revocation's — is admitted in § 3's lane and waits for the turn
in flight alone; every other restore waits as this says.)*

### D5 — The force key is the plane's, reference-counted by what the plane engaged, cleared last, and checked at every start

- **An engaged set.** A fan joins when its mode write is accepted *and* raw `F<n>Md` reads back
  `1`, after a pre-state of `0` read in the same turn (D3). It leaves when any restore covering it
  is **issued**, whatever the firmware answers. *(Since the P1′ amendment: after a pre-state in
  Apple's set.)*
- **A touched set, which never shrinks.** It holds every fan index this plane has engaged or
  restored by index in this process. It lives in memory beside the engaged set, and is never read
  from the SMC.
- **A force-key flag.** It is set when this plane's `Ftst = 1` is accepted, and cleared when a
  restore **issues** `Ftst = 0`. *(Superseded in part by the B1 amendment: it is set when this plane
  issues `Ftst = 1`, accepted, refused or unanswered — issued, not landed.)* Between the key's
  write and the first fan joining, the engaged set is empty while the flag is set. So a
  `.fan(n)` restore in that window — the undo of an engagement that never joined — clears the key,
  which is correct.
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

  It still cannot command a fan. *(Since the A6 PR-3 amendment it also holds level 6's `apply`, as
  `any LeaseApplying`, whose one verb takes the client's settings, the lease and the connection.
  The authority still names no plane, writer or permit.)*
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
  either from a call site, and the test's message says so. *(Superseded in part by the #410
  ticket-and-seal amendment: B1's restore builds its plan from `PlaneWriteLedger.plan(for:)` and
  branches on no scope of its own, and `PlaneWriteLedger.swift` is the file in the set that names
  the scopes to decide them; see the amendment's "B1's obligations".)*

  Without this change, `fanctl reset --all` — D8's first recovery step — clears no stray force key.

**The keystone holds, and its one data-dependent branch is named.**

- **No restore write consumes trusted data:** no bounds, no reading, no lease, no permit (D7). The
  fan set, the key types and `Ftst`'s presence come from the preparation step. The touched set comes
  from the plane's own memory. Nothing is read at restore time.
- **The one data-dependent branch is the engaged set's.** It decides only whether `.fan(n)` *also*
  clears the key, and it can err only toward leaving the key set.
- **Every `.everyFan` removes the key.** That covers § 4 before sleep, § 6's teardown, § 7's panic
  verb, and reconciliation's fallback wherever its pass cannot see (ADR 0011 D3). The preparation
  step removes it again at the next start. *(§ 6's final keystone issues `.forExit`, whose plan
  is `.everyFan`'s, so it removes the key too: the #410 ticket-and-seal amendment.)*
- **Whether a key left set with every fan automatic is harmless is U6.** If it is not, the gate
  goes.

### D6 — Engagement happens at the first `apply`, never at grant, and an `apply` is all or nothing

`LeaseAuthority` stays hardware-free; a grant writes nothing. The first `apply` does four things:

1. It engages the fans its settings name, through `GovernedFanWriter.engageUnderLease(of:)` and
   the driver (D2–D4). The driver registers each fan with § 3. *(`engageUnderLease` is withdrawn, and
   the order is per fan: the A6 amendment below.)*
2. It registers each fan with § 5 at the landing.
3. It commands each fan's target through `GovernedFanWriter`.
4. It reads each target back.

If any fan's engagement fails, every fan that `apply` engaged is restored, and the call is
refused. *(All or nothing for the fans an `apply` engages. A re-apply refused part-way may already
have re-commanded fans an earlier `apply` engaged, and those are not undone: the A6 PR-2
amendment's "What remains". The client contract says so since the A6 PR-3 amendment.)*

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

*Amended by ADR 0012's 2026-10-18 amendment: each write takes one turn **at its plane's admission**
— `.supervisor`, or § 3's lane through the view § 3 is given (`FanControlPlane.admitted(at:)`) —
and § 3's bridge is one job, a command and then a `.fan(n)` restore, in one turn
(`FanControlPlane.bridgeThenRestore(_:)`). Read "supervisor turn" below with that.*

- **Forward verbs** — an engagement step, and `commandTarget` — take one `.supervisor` turn. The
  turn covers a fresh `READ_KEYINFO` (ADR 0004), the write and its read-back.
- **`restoreToAutomatic` takes one `.supervisor` turn per call and issues no read.** It encodes
  `F<n>Md = 0` and `Ftst = 0` from the types and sizes the preparation step recorded (D5), and
  writes them. *(Superseded in part by the B1 amendment: a restore writes zero bytes of the recorded
  size and never goes through `encode`.)* Both keys are `ui8`, one byte, so there is no byte order
  for ADR 0004 to resolve. A key recorded absent is not written. A key recorded unknown gets one
  zero byte, and the restore reports what the firmware said.

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
*(Restated by the P1′ amendment: it adds item 7, the P1′ vocabulary; see D8, as restated.)*

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
  - `log stream` on the helper's subsystem, at debug. *(Restated by the run-1 amendment, item 3:
    two samplers, and the stream filtered to the daemon's process.)*

**Start 0, and toward-automatic writes at start.** The branch helper's first start runs the
preparation step and then reconciliation, and either can write toward automatic.

- **In run 1's session, the branch build is installed only after D9's exclusion, census and
  quiescence have passed, with the recorder already running.** That first start is recorded as
  start 0. On the quiescent machine D9 requires, it should do three things:
  - read `Ftst` and every `F<n>Md` as `0`;
  - write nothing;
  - log that the preparation step's enumeration succeeded.

  *(Restated by the P1′ amendment: every `F<n>Md` reads in Apple's set; see D8, as restated.)*
- **Stop if start 0 logs no successful enumeration.** In that case `.everyFan` knows only the fans
  this process touches.
- **Stop if start 0 writes anything.** A write means one of two things: the quiescence check was
  wrong, or a read failed (the preparation step's, or the one that sent reconciliation to its
  keystone). Either way, stop and record which.
- **In later sessions**, D9's reboot starts the installed branch helper before any recorder can
  run. Any toward-automatic write it makes is recorded in the helper's own log, and the gates apply
  to forward writes.

**The run: start 0, then four steps, all on fan 0.** *(Five since the P1′ amendment: 1d follows 1c.)*

**The safety argument is the choice of target.** Every hold asks for more cooling than Apple's
controller would ask for *at that moment*. So every stuck state it can produce — an unlock that
will not undo, a restore the firmware refuses — is a loud fan, not a hot one.

- **At rest, 50 % (3,564 RPM) is far above** any speed recorded under Apple's control at rest.
- **Under load, 50 % is not.** The fans reached 3433/3683 RPM in the 45 s after a 40 s twelve-way
  load. So the loaded hold runs at the fan's declared maximum, the one target no automatic demand
  can exceed (U13).
- **Fan 1 is left automatic on purpose.** Its behaviour under `Ftst = 1` is U7. Its `F1Tg` is a
  live proxy for what Apple would ask of fan 0 (abort 9). *(At rest it cannot be seen. 1d is its
  test, and 1b is one if `Ftst` is written there: the P1′ amendment.)*

The four steps:

- **1a — at rest:** `fanctl set 0 50% --for 60s --json`, after 60 s of baseline. This is where the
  report says the naive write succeeds, because the system is not actively asserting control.
  *(Restated by the P1′ amendment: the refusal is predicted here, and the engaged turn raises
  the target to the floor; see D8, as restated.)*
- **1b — under a twelve-way load:** `fanctl set 0 100% --for 60s --json`, which commands `F0Mx`,
  5,777 RPM.
  *(Restated by the P1′ amendment: under the sixteen-way busy loop; see D8, as restated.)*
  - **Engaged once `F0Tg` has stayed at least 300 RPM above `F0Mn` for 30 s,** so Apple's
    controller is actively managing the fan. This is where the report says the naive write is
    refused and the unlock is needed.
  - **Its abort baseline is the loaded steady state.**
- **1b′ — still under load, with no lease held:** `fanctl reset --all`, once. That sends
  `.everyFan` to two fans already in automatic while the thermal manager asserts control (U5b).
  Then stop the load, and wait until the package is within 3 °C of its pre-run baseline and `F0Tg`
  is back at rest.
  *(Restated by the P1′ amendment: the sixteen-way load, and "at rest" means `F0Tg` at `F0Mn`
  or 0; see D8, as restated.)*
- **1c — at rest, 30 s at 50 %:** ended early from an SSH session with `fanctl reset --all`. This
  is row 18's hardware half.

**After each hold's release (D5's restore), check with `fanctl status --json`:** no lease listed,
and fan 0's mode and availability cleared in ADR 0013's sense.

- **Why not `fanctl auto`:** `auto` sends one `restoreAllToAutomatic` — on the branch, an
  `.everyFan` — whenever a fan is not yet cleared. That would be an unlabelled U5b test. 1b′ is that
  test, labelled.
- **Then observe for 120 s,** including a 20 s twelve-way load that must move `F0Tg` and `F0Ac`.
  The fan following load is the only proof that Apple's management came back.
  *(Restated by the P1′ amendment: a target proof replaces the load; see D8, as restated.)*

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
  point. *(Restated by the P1′ amendment: 1d's record.)*
- **The client:** `apply`'s and each heartbeat's client round trip (#325).
- **The examination gate:** how long each hold lasts, the actor hops made under a hold, and how
  late the gate's timers wake: what `FanExaminationGate.examinationMargin` assumes (the A6 PR-2
  amendment).
- **Exclusion:** that no third-party SMC client was present.

**Abort.** The maintainer runs `fanctl reset --all` at once on any of these: *(Except abort 4, which
is verified first; and abort 12 is added: the run-1 amendment, items 5 and 6.)*

1. **A curated temperature** 10 °C above the hold's baseline, or above 85 °C. The target is at or
   above Apple's demand, so a rise means the fan is not doing what was written.
2. **`F0Ac` or `F1Ac` more than 20 % below its automatic speed** for 10 s.
3. **An unexplained change**, meaning one that no helper write explains:
   - during a hold, from the first accepted forward write until the restore is issued: any change to
     raw `F0Md` or to `F0Tg`;
   - at any time: any change to `Ftst`.

   Fan 1 stays automatic, so `F1Tg` moving is Apple's controller; that is recorded, not an abort. A
   change in raw `F1Md` is recorded for U7, and guarded by abort 2.
   *(Restated by the P1′ amendment: a raw mode outside `{0, 3}` at any time; see D8, as
   restated.)*
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
10. *(Added by the P1′ amendment: raw `F0Md = 1` with `F0Tg` below `F0Mn` for more than 1 s.)*
11. *(Added by the P1′ amendment: in 1d, `F1Tg` still 0 60 s into the load, or at a curated 50 °C.)*

**If the restore does not land**, take these steps in order. Take each step only if raw `F0Md`,
`F1Md` and `Ftst` are not all `0` on the recorder 10 s after the previous step.
*(Restated by the P1′ amendment: outside Apple's set, not "not all `0`"; see D8, as restated.)*

1. **`fanctl reset --all`.** Every lease is released, then `.everyFan` writes the mode of every
   enumerated and every touched fan and then the key, each attempted. This rests on D5's § 7 precondition. On a build without it, this step
   restores covered fans by name only and clears no stray force key (`docs/SAFETY.md` row 18), so
   go straight to step 2.
2. **`sudo launchctl bootout`.** This runs § 6's teardown, which issues two more machine-wide
   restores, `.everyFan` and then `.forExit`, which writes the same and seals the write path.
   launchd will not restart the helper.
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
- **Hypotheses:** any contradiction of U0–U7, U5b, U13, U14 or U15 → `docs/SMC-RESEARCH.md` first,
  then the architect, per `CLAUDE.md`.

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
- U7 observed holding, or the maintainer's lease shape built. *(Added by the P1′ amendment, item 9.)*

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
  *(Restated by the P1′ amendment: three classes, passing when "other" is zero; see D9, as
  restated.)*
  - That `ioreg` exposes each client with its creating process is U10. It is checked in the
    pre-flight session before anything relies on it.
  - The census counts clients and names no product. Nothing in the helper reads it.
- **Quiescence, read-only.** 120 s at 2 Hz in which raw `F0Md`, `F1Md` and `Ftst` read `0` on every
  sample. This sees a writer that is holding, not one that is idle; on 2026-09-05 those two states
  were minutes apart on this machine. So quiescence backs the exclusion rather than replacing it.
  *(Restated by the P1′ amendment: `F<n>Md` in Apple's set, and no `3` above a zero target; see
  D9, as restated.)*
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
   with § 3 armed. *(P1's twelve-way load held Apple's demand at `F0Mn`, so "below automatic" is
   meaningful only under a heavier load: the P1′ amendment.)* It needs D8's before-run-2 list. It covers:
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
    `permitBearingVerbs` *(`engageUnderLease` is withdrawn, and `hold(_:of:)` joins instead: the A6
    PR-2 amendment)* — as built, with the driver's `firstStep(of:)` and
    `requireEntitlement(for:)` and § 3's role requirement `manualControlEngaged(_:)` (D2).
    *(`engageUnderLease(of:)` is withdrawn by the A6 amendment below. `GovernedFanWriter.hold(_:of:)`
    joins `permitBearingVerbs` instead, with the A6 PR-2 amendment.)*
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
  - `SMCFanControlPlane.swift` (its scope switch and preparation step, on the branch). *(The
    scope switch is superseded by `PlaneWriteLedger.plan(for:)`: the #410 ticket-and-seal
    amendment's "B1's obligations".)*

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
  confirmation read is re-examined before run 1. *(U0 failed in P1; the P1′ amendment is the
  classification.)*
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
    wake, and a post-wake acquire re-runs the unlock. (Since the #410 ticket-and-seal amendment it
    holds for an engagement in flight when the handback begins, when the handback's restores take
    effect: the engagement's first step is refused if admitted after the handback's restore
    request, and otherwise covered by the restore that follows, so no engagement in flight undoes
    a restore that took effect. The ticket does not make the firmware cooperate: a restore the
    firmware refuses leaves its fan as it was, and the handback still acknowledges the sleep.)
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
  `expectPermitIsTheOnlyParameter` requires exactly one parameter. Since #362, `SeamScanner`
  finds a parameter list by balanced parentheses, so a closure parameter is listed and refused
  there; before it, the `\([^)]*\)` match could not span a closure's `()`.
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
that did. *(Restated by the P1′ amendment: the report's mode 3 is this machine's rest state, so 1a
is the likelier place for the unlock. 1b stays for the engagement from `0`, the 100 % hold, and U5
and U5b under load.)*

### `fanctl auto` as the post-hold check

Rejected for run 1. `fanctl auto` sends `restoreAllToAutomatic` whenever a fan is not yet cleared
(ADR 0013 D2), and on the branch that is an `.everyFan`. That would mix an unlabelled U5b test into
every hold's record. `fanctl status --json` reads the same snapshot and writes nothing.

### Poll by reading the raw mode byte

Not rejected — conditional. It is better than polling by writing whenever a read can tell "held by
the system" from "yielded". D3's pre-flight decides whether this machine offers such a read.
*(Rejected by the P1′ amendment: under load Apple's management reads `0`, and at rest it leaves `3`
to spin the fan, not to yield.)*

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
every plane, `.notBuilt` included, and never § 4's or § 6's machine-wide restores (*amended by the
#364/#347 amendment below: it counts § 4's handback too*; § 6's are `.everyFan` and then
`.forExit` since the #410 ticket-and-seal amendment). It
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
  already wrong the same way, and D3 re-decides the fold before run 1. *(U0 failed in P1: the
  system's hold reads `0` or `3`, and the P1′ amendment's fold calls both automatic.)*
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
3. In `apply`, take the fan's examination gate for each step: issue the command write, report the
   `CommandedTarget` that write returned, never one built from the request, with
   `commandedTarget(_:under:)` after the write returns and never before, and release the gate after
   the report, or after the write has thrown. Hold one fan's gate at a time, and nothing under it
   but that write and its report. Engage under the same gate, taken by `apply` around the driver:
   `EngagementDriver` and `SafetyActorWriter` never take it. § 5 re-asserts the target last
   reported, and a report that arrives during its own command write wins the record (#381). § 5
   judges every reading against the record (#383).
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
  above its straight-line region, and the seal check is inside it. *(Superseded in form by the
  #128/#270/#269 amendment below: the seal is step 10 of one first-match ladder and states
  `.releaseInProgress` over every fan no higher rung refuses. Step 5 is still above it.)*
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
So: **the snapshot agrees with the grant on whether a grant is refused, for every refusal a
snapshot states per fan, and on the reason, except that a machine-wide refusal `fanctl auto` reads
as silent is never stated over a fan's own durable or pending reason.** Two refusals are not stated
per fan, so a fan nothing else refuses reads `.available` beside them: another client's lease,
which a snapshot cannot attribute, and § 3's latch, stated machine-wide. Step 5's manual arm over
step 6 was the first instance; step 12 is the second. Where they part, both refuse. Step 11 is
pending, so it follows the grant's order exactly; if ADR 0013 classes it silent, it drops below
steps 3 and 10 in the same change.

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
never held more than one `.supervisor` turn, parked or in flight. The test was then cut to ten warm
rounds, three cold snapshots and one burst, for its cost on every local `swift test`, 126 s to 39 s;
run once alone at that size, it met all three again: warm p50 0.96 µs and no curated read, one read
per cold snapshot, and one read and one `.supervisor` turn for the burst. A snapshot-path failure
is remembered as a grant-path one is, so the snapshot can produce the blindness a grant is refused
on — the same read. On a `.built` seam, during a sealed sleep after the teardown returns, `fanctl
auto` exits 8 where it exited 0: `systemSleeping` is pending (ADR 0013). § 3's latch stays
machine-wide only.

**No `AeolusXPCVersion` bump.** No field, case or method changes: `.systemSleeping` and
`.noThermalTelemetry` are on the wire and already thrown.

**Assumption added.** The cache keeps the snapshot's sighting to one curated read per period. It is a
row of the table below, which also says why, with § 3 running, that read is spent on every cycle
rather than in an edge case ([#393](https://github.com/blamechris/Aeolus/issues/393)).

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
  cycle. Only mutual exclusion over the write closes it, and the
  [#383](https://github.com/blamechris/Aeolus/issues/383) amendment below adds it: under the fan's
  examination gate a client write waits out § 5's re-assert, so the case remains only past § 5's
  bound, when § 5 examines without the gate, or for a write that bypasses the gate. *(Superseded by
  the A6 amendment below: past the bound § 5's re-assert stands down and writes nothing, so the case
  remains only for a write that bypasses the gate.)*
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
  maps, so that choice is #389's. *(Closed by the A6 PR-2 amendment below: level 6 engages only
  under the fan's examination gate, which § 5 holds through its re-assert, so a same-lease
  engagement attempted during § 5's yield wait waits for it. The driver's vocabulary is unchanged.)*
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
  is compared against a reading that predates it; to be resolved by A6's ordering, not by excuse:
  see the [#383](https://github.com/blamechris/Aeolus/issues/383) amendment below.

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

- A6 adds a per-fan forward-write turn: § 5's re-assert then takes it from the stamp to the record
  (fired: the #383 amendment below adds the fan's examination gate);
- A6 or #17 reports a target before writing it;
- leases that can overlap on a fan are proposed;
- a hardware run shows the write race landing.

The ruling is the architect's #381 consult, run on Opus. **No `AeolusXPCVersion` bump:** nothing
crosses the boundary. This amendment corrects clauses of a Proposed ADR rather than the decisions
they sit under. **Status stays Proposed.**

## Amendment (2026-10-16, [#383](https://github.com/blamechris/Aeolus/issues/383), [#395](https://github.com/blamechris/Aeolus/pull/395)) — § 5 judges every reading against the record, and level 6 keeps its steps out of § 5's examinations

An A6 precondition, found by the architect's #381 consult. Unreachable on every build on `main`,
where a `.notBuilt` plane grants no lease.

**The defect.** § 5 reads a fan's control state and then suspends on the lease check before it
judges the reading against the record. A level-6 step can land on either side of the read: reported
after the read, so the reading predates the record, or written before it and reported after the
judgement, so the record predates the reading. Either way an ordinary step reads as
`.targetDiverged`: the fan is marked, "Reclamation detected" is logged at `.fault`, an attempt is
spent, and in the second order § 5 re-asserts the old target over the new one. A loop phase-locked
to § 5's sweep does this on consecutive cycles and reaches the terminal action mid-ramp.

**Decision.**

- **§ 5 judges every reading against the record, and excuses none.** No announcement, report, stamp
  or timing makes a reading other than the record's target anything but a divergence. Whatever
  level 6 does, it can cost § 5 a false fault, in the safe direction, and never a false claim of
  control.
- **Level 6 keeps each step out of § 5's examination of the fan.** One examination or one step per
  fan at a time, under an exclusion A6 adds, the fan's examination gate. § 5 holds it from the
  examination's stamp to its last act, re-assert included. Level 6 holds it for each step, from the
  command write until the step is reported or its write has thrown, and A6's engagement holds it
  across its engage steps. Level 6's `apply` takes it; `EngagementDriver` and `SafetyActorWriter`
  never do, because § 5's re-engage runs through the same driver while § 5 holds the gate, and a
  driver or writer that took it would have § 5 wait on a gate it already holds. Under it, the
  record at the read is exactly level 6's last write that returned, so the comparison is exact in
  both orders. The same gate keeps a client step out of § 5's re-assert (#381) and keeps two
  engagements of one fan apart (#389).
- **§ 5 never waits long on level 6.** Its wait for the gate is bounded; past the bound it examines
  without the gate, and because it excuses nothing, the cost is a false fault at most. *(Corrected by
  the A6 PR-2 amendment: a false divergence past the bound also spends an attempt, and at the budget
  takes the terminal action.)* § 3's writes, the terminal action's restore and every other restore
  never take the gate.
- **The record refuses a target that is not a number or is below the floor every permit is clamped
  to, a target that is not a number diverges, and every RPM a log line states is written out by one
  conversion that cannot trap** (#395). Both writers of the record, a report and a re-assert's
  return, pass the one check, and a refusal is logged at `.fault`. The check is a floor and no
  ceiling: the record holds no envelope, so a target above a fan's maximum is not caught there.
  These stand however the steps are ordered.

| The step | When it runs | § 5 judges the fan |
|---|---|---|
| Under the gate, before the examination | Written and reported | Against the record, which is the step |
| Under the gate, after the examination | Written and reported | At the next examination, against the record |
| Without the gate, a contract breach | Anywhere | Against the record: possibly a false divergence, with its mark and a spent attempt *(corrected by the A6 PR-2 amendment)*, never a hold |
| Its write throws | Not reported | Against the record, which the fan still holds |
| Past § 5's bound | In flight | Without the gate: possibly a false divergence, which spends an attempt and at the budget takes the terminal action. With the A6 PR-2 bound, only once the contract is broken, the helper is outside ADR 0012's design point, or the wait spans a system sleep |

**A6's contract.**

- Item 3 becomes: *In `apply`, take the fan's examination gate for each step: issue the command
  write, report the `CommandedTarget` that write returned, never one built from the request, with
  `commandedTarget(_:under:)` after the write returns and never before, and release the gate after
  the report, or after the write has thrown. Hold one fan's gate at a time, and nothing under it
  but that write and its report. Engage under the same gate, taken by `apply` around the driver:
  `EngagementDriver` and `SafetyActorWriter` never take it. § 5 re-asserts the target last
  reported, and a report that arrives during its own command write wins the record (#381). § 5
  judges every reading against the record (#383).* The #381 clause stays because
  `recordReassertedTarget(_:decidedOn:ofFan:)`'s decided-on check still implements it, and it
  still decides the record past § 5's bound, when § 5 writes without the gate. *(Superseded by the
  A6 amendment below: past the bound § 5 writes nothing away from automatic control, so the check
  decides the record only against a write that bypasses the gate.)*
- `GovernedFanWriter` needs no change: the step it computes is written and reported under the gate.
- Items 2, 4 and 5 are unchanged.

**#381's amendment.** The gate adopts what #381's *Alternatives considered* rejected, "A6 serialises
a fan's engagements across § 5's whole re-assert", widened from engagements to every step, and it
answers both of that alternative's objections. It gates each step, the command write and its report
as well as the engage steps, so a target-only re-assert no longer races a client's command, and
§ 5 takes it at the stamp, before the read, so the judgement is under it too. And § 5's wait for it
is bounded, so a holder that never releases costs one examination its bound and does not park the
sweep. #381's first *Revisit if*, "A6 adds a per-fan forward-write turn", has fired: this gate is
that turn, and § 5 holds it from the stamp past the record. #381's first "What remains" bullet now
names the gate as the exclusion that closes it, and its last, the judgement's own view, is to be
resolved by A6's ordering, not by excuse, under this amendment.

**What remains.**

- *A level-6 write that bypasses the gate* can land around an examination as before: a false fault,
  in the safe direction. *(Corrected by the A6 PR-2 amendment: a false divergence, with its mark and
  a spent attempt.)*
- *A step that lands and then throws* leaves the fan at a target nothing reports: a false fault, and
  the re-assert restores the record.
- *A report no plane can write, below the floor or not a number, is treated as no report.* The fan
  is judged against the step before it, so a write that landed and returned such a target reads as
  diverged, and the step before is re-asserted: bounded, inside the lease, and logged at `.fault` as
  a defect on the write path. A report above a fan's maximum is recorded, because the record holds
  no envelope; every permit clamps to it, so only a defective plane returns one.
- *A system target equal to the record* is read as Aeolus's, as it always was (#119).
- *Until A6*, nothing takes the gate, and nothing steps. *(From the A6 PR-2 amendment, level 6's
  `apply` takes it for every step, and from the A6 PR-3 amendment the composition builds it.)*

**Alternatives considered.**

- *Excuse a reading the fan could have been holding* (#383's first ruling, and three rounds of
  #390). § 5 held a `.targetDiverged` reading that matched the target reported when the examination
  began, or a step level 6 announced before writing it. It then bounded the hold with a credit
  renewed by a report, and then with a settlement at the next examination and a barred target. Each
  round's review found a sequence that held a system target indefinitely:
  - a stale announcement;
  - a report followed by another before § 5 looked again, found both by Codex and, on A6's contract,
    by the delta review's fallback;
  - a stamp's target superseded inside every examination;
  - a 1-RPM tolerance chained across settlements;
  - a system alternating its own target past a single barred slot.

  The class cannot be closed. A level 6 that announces, writes and reports, one step a sweep, the
  target the system held one cycle earlier is indistinguishable from a reverse-phase ramp, so any
  excuse built on what the lease holder says can be met on contract. It was a supervisor's bound
  resting on the supervised.
- *The plane's own last-written target, returned with the read in the same scheduler turn.* It is
  exact for any writer and needs no announcement, and no `AeolusXPCVersion` bump, because
  `FanControlState` never crosses the boundary. But it designs E4's write ordering now:
  `SMCReadScheduler` is read-only and the production write path is `.notBuilt`, so the suite would
  certify an ordering only `ScriptedControlPlane` provides. It changes `FanControlState` and every
  control-state reader. And § 5 would then need a rule for a fan that holds Aeolus's last write
  while the record names another target: #381's overwritten step, or a write that lands and throws.
  Kept for if A6 cannot take the gate.
- *Withdraw the excuse and order nothing.* The false faults are in the safe direction, but a loop
  phase-locked to § 5's sweep diverges on consecutive cycles: a `fanctl set` from 50 to 100 percent,
  about thirteen governed steps at 200 RPM a second, would be handed back after four. Ordering is an
  A6 precondition, not an option. *(A6 builds no loop that steps on its own, so the A6 PR-2
  amendment holds this as thirteen re-applies 200 RPM apart, each landing inside an examination.)*
- *Run level 6's steps on the supervisor's tick, after § 5's cycle.* No new primitive, but an
  `apply` arriving between ticks either waits up to a sweep for its first write, or races the
  examination.

**Revisit if:**

- A6 needs a step that cannot take the gate, or writes several fans in one SMC transaction;
- a gated step is observed to keep § 5 waiting past its bound;
- false faults are observed with every step gated;
- E4's write path is designed, when the plane register costs less than it does today;
- leases that can overlap on a fan are proposed.

The ruling is the architect's #383 consult and its #390 consults, run on Opus, and it withdraws the
excuse the first of them introduced. **No `AeolusXPCVersion` bump:** nothing crosses the boundary.
This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under.
**Status stays Proposed.**

## Amendment (2026-10-16, A6, [#383](https://github.com/blamechris/Aeolus/issues/383), [#389](https://github.com/blamechris/Aeolus/issues/389)) — the examination gate as built, and level 6's `apply`

A6's plan. Unreachable on every build on `main`, where a
`.notBuilt` plane grants no lease, so § 5's registry is always empty and its cycle returns before
it reaches the gate. A6 lands in steps. This amendment arrives with the first, which builds the
gate and has § 5 take it; level 6's `apply` takes it in the next.

**Decision: the gate.**

- **It is `FanExaminationGate`:** a lock-guarded exclusion with one first-in-first-out lane per
  fan, on the composition's monotonic clock. It is not an actor, because `leave(_:)` has to be
  synchronous so the `defer` in the frame that entered can call it. Whether a wait was granted, ran
  out or was cancelled is decided once, under the lock.
  - § 5 enters through `enterForExamination(fanAt:)`, and level 6 through `enterForStep(fanAt:)`.
  - A pass is minted only in the gate's file, and leaving one that does not hold releases nothing.
  - The composition builds exactly one gate and hands it to § 5, and to level 6 when it exists.
  - `EngagementDriver`, the writers, the plane, the lease core, § 3 and every restore path never
    name it. A census holds that. A composed test holds the consequence: with a pass held for good
    and the clock frozen, every hand-back still finishes.
  - The lock order is the gate before a scheduler turn, never the reverse.
- **§ 5 takes the gate, then stamps.** `cycle()` enters the fan's gate before
  `examine(fanAt:inBound:)`, whose first act is the #381 stamp, and leaves it after the
  examination's last act. A step that held the gate, its registration included, is then before
  the examination and never inside it. Taken after the stamp, a registration made under the gate
  would stand § 5's re-assert down.
- **§ 5's wait is bounded by `examinationWait`:** `UnlockLimits.yieldBudget`, two
  `WatchdogLimits.roundTrip` and `stepWait`, 14.5 s. *(Re-derived by the A6 PR-2 amendment below:
  `stepWait`, `lawfulHold` and `examinationMargin`, 32 s.)*
  - 13.5 s of it is the longest hold item 3 allows level 6 before ADR 0012 ends the helper: one
    engagement's polling, its last step's turn, then its undo's turn or its command's. Level 6's
    hand-back runs outside the gate. *(Wrong: it took a turn as one round trip. The A6 PR-2
    amendment re-derives the bound from G: 32 s, with what running out now means.)*
  - `stepWait` is there because a step queued ahead of § 5 is granted within `stepWait` of
    arriving or refused, so the last step ahead of § 5 is granted at most `stepWait` after § 5
    arrives, and may then hold for 13.5 s. This amendment first had the bound without it, 13.5 s,
    and that ran out inside a lawful hold: § 5 examined without the gate during a step and logged a
    breach that was not one. A `ManualClock` test pins the sequence. *(The hold it may then make is
    `lawfulHold`, 30 s: the A6 PR-2 amendment.)*
  - So a wait that runs out means the contract was broken, for example by a pass never released,
    with one exception. The bound is measured on the composition's clock, which counts time asleep
    (ADR 0007; unverified on this machine), so a wait that spans a system sleep can run out on wake
    inside a lawful hold. That `.fault` is a false breach, and diagnostic only: past the bound § 5
    writes nothing away from automatic control. *(Wrong: it took a turn as one round trip. The A6
    PR-2 amendment re-derives the bound from G: 32 s, with what running out now means.)*
  - A clock whose sleep fails for any reason but cancellation ends the wait as the bound would,
    rather than leaving it to a grant that may never come.
  - The first expiry against a holder is logged at `.fault` and remembered. Later examinations
    against the same holder do not wait, so a stuck holder costs § 5 one bound in all, not one
    per cycle.
- **Past the bound, an examination judges, marks and restores, and writes nothing away from
  automatic control.**
  - It is stamped out of bound (`HeldFan.examinedInBound` is `false`), so
    `Registry.reassertTarget(ofFan:under:)` answers `nil`. The re-assert stands down at its first
    re-fetch, through #381's path, and the attempt stays spent.
  - The judgement, the ledger mark, the budget, and every restore and terminal action happen as
    before, so a stuck holder cannot keep a fan from being given up.
- **A cancelled wait is not an expiry.** It returns at once without the gate and is not stood
  down. The cancellation guard before the re-assert's first write still refunds the attempt (#144).
  It is stamped in bound though it holds nothing: the stamp names the bound, not the gate. Its
  examination runs without the gate, so a step can land inside it, and its judgement can then
  mark the fan and log a false `.fault`. It writes nothing away from automatic control, because that
  guard stops its re-assert's writes, and the next converged cycle clears the mark (#366's episode).
  A restore and a revocation, through `finaliseRelease`, it can still make, as any examination can.
- **`diverged` decides on the live record.** Whether anything was commanded, and the attempt
  count, are read from the record re-fetched after the ledger hop, not from the copy taken before
  it. Under the gate no step can land in that hop. Past the bound one can, and the copy would give
  up a fan whose first command had just been reported, revoking a healthy lease (#383's ledger-hop
  window).
- **Level 6 waits at most `stepWait`, 1 s, and never engages a fan or commands a target without the
  gate.** *(Corrected by the A6 PR-2 amendment, from "never writes": its undo's hand-back is a
  restore, and takes none.)*
  `UnlockLimits.yieldBudget` plus `stepWait` stays under `HelperClientDeadlines.gatedVerb`'s 5 s,
  leaving room for the envelope read, the command write and its report. Past it the fan's step is
  refused. The figure is provisional:
  [#325](https://github.com/blamechris/Aeolus/issues/325) measures the round trips it rests on.

With these in place, the #383 amendment's "the cost is a false fault at most" is true. Past the
bound, a contract breach costs one bound and false faults, and every act § 5 takes is toward
automatic control. *(Not so: the A6 PR-2 amendment states what a false divergence past the bound
also costs, an attempt, and at the budget the terminal action, which revokes a healthy lease.)*

**Decision: level 6's `apply`, for A6's next steps.** The items are numbered as in the #353/#357
amendment.

- **Item 0 (new).** `apply` honours `.fixed(rpm:)` only. These are refused with
  `invalidParameter(name: "settings")` and fixed text, before anything is read or written:
  `.curve` (no evaluator until #17), `.automatic`, a fan the lease does not cover, a fan named
  twice, and an empty list.
- **Item 2 gains an undo order.** If a registration is refused, every fan this `apply` engaged is
  undone. Its § 5 record is dropped first, under the lease (`manualControlHandedBack(fanAt:
  under:)`), and then the fan is handed back through level 6's driver, outside the gate and never
  waiting for one. A newly engaged fan whose command write throws is an engagement failure in the
  same way. `LeaseApplier` keeps the set of fans it engaged under the current lease, reset when the
  lease changes and cleared by its undo.
- **Item 3 becomes one hold per fan.**
  - Under the fan's gate: engage (only if this lease has not engaged the fan), register, ask the
    entitlement, write and report. Then release it.
  - Nothing else is done under it: no envelope read, no other fan, no second gate and no hand-back.
    *(But the driver's own: an engagement that throws is undone inside it, under the hold. The A6
    PR-2 amendment.)*
  - Fans are taken one at a time, in index order. Each fan's envelope is read and its permit minted
    before its gate is taken.
  - Each `.fixed` setting is written whole, through `GovernedFanWriter.hold(_:of:)`, and the
    writer's ramp memory is reset at every engagement and hand-back. `docs/SAFETY.md` § 8 says so
    until E8a's loop shapes the steps a control loop takes.
  - The read-back is the plane's, inside the command's turn: `apply` issues no read.
  - `requireEntitlement` is asked before each command.
- **Item 4 also asks § 3's latch** before replying.
- **Item 5 maps every outcome:**

| Cause | Answer |
|---|---|
| `heldLease` fault | That fault |
| `.notBuilt` | `writePathNotBuilt` |
| Validation (item 0) | `invalidParameter(name: "settings")` |
| Envelope read failed, or implausible | `supervisorBlind`, or `boundsImplausible(fanIndex:detail:)` |
| `stepWait` passed, superseded, or `leaseNotLive` | `releaseInProgress`, unless the lease has gone |
| `preempted`, or § 3's latch set at item 4 | `thermalEmergencyActive` |
| `notAutomatic` | `foreignManualControl` |
| `yieldDidNotArrive`, `firmwareRefusedControl`, `engagementNotConfirmed` | `helperFailed`, with fixed text |

- **D2: `GovernedFanWriter.engageUnderLease(of:)` is withdrawn.** It could not take a lease (ADR
  0008's one-permit list), and a driver that takes its level from an ungoverned writer cannot be
  asked about level 6. Level 6 gets its own `EngagementDriver`, over a `SafetyActorWriter` used
  only for the step and the undo, with its arbiter level passed explicitly (`init(…, level:)`):
  `.controlLoop` for level 6, `.reclamationWatchdog` for § 5. The control loop then holds no writer
  it can command through, because its driver exposes no target verb.
- **D3: the new reason cases wait for run 1 (D8).** Until those outcomes are observed, they answer
  `helperFailed`. Run 1 also logs the raw `F<n>Tg` in the turn that reads `.engaged`.
- **D6: per fan, in index order, as item 3 says.** The read-back is the plane's.

**What remains.**

- *A contract breach costs one bound and false faults.* A pass never released makes § 5 wait one
  `examinationWait`, logged at `.fault`, and then examine without the gate until the holder leaves.
  That is possibly a false fault each cycle, in the safe direction, and a fan reclaimed meanwhile is
  given up once its budget is spent. *(A false divergence spends an attempt too, so a healthy fan
  can be given up the same way: the A6 PR-2 amendment.)*
- *A write that bypasses the gate* is judged against the record, as the #383 amendment says: a
  false fault at most, with #381's re-fetches still answering it. *(Corrected by the A6 PR-2
  amendment: a false divergence, with its mark and a spent attempt.)*
- *A cancelled examination's judgement* can leave a false mark and a false `.fault`, and never a
  write away from automatic control: the next converged cycle clears the mark. § 5's wait is
  cancelled when its loop is stopped.
- *A wait that spans a system sleep* can run out on wake inside a lawful hold: a false breach
  `.fault` and one examination without the gate, diagnostic only. *(Not diagnostic only: a false
  divergence in that examination spends an attempt. The A6 PR-2 amendment.)*
- *A fan the system took back before a re-apply* is #381's one-cycle residual.
- *The bounds rest on U3's 3.5 s yield,* and routine holds are assumed to last milliseconds.
  Neither is measured. *(Run 1 (D8) measures both, with the actor hops under a hold and how late
  the gate's timers wake: the A6 PR-2 amendment.)*
- *Until level 6 takes the gate,* it excludes nothing but § 5 from itself, and the assumption row
  "One engagement per fan at a time" stays as written. *(Superseded by the A6 PR-2 amendment below:
  level 6 takes the gate, and the row now reads "enforced by the gate".)*

**Alternatives considered.**

- *An actor gate.* Its release would need an `await`, so a `defer` could not make it.
- *The gate's state inside § 5.* A continuation is not a value, it costs actor-body lines, and every
  level-6 step would become a § 5 hop.
- *A scoped-closure gate.* § 5's body would run outside its isolation.
- *A non-copyable pass released in `deinit`.* The release would rest on where the compiler ends a
  lifetime.
- *An unbounded § 5 wait, or one of about 1 s.* The first parks § 5 behind any stuck holder. The
  second is shorter than the hold the contract allows.
- *Level 6 writing without the gate past its bound.* That is the race the gate exists to close.
- *The plane's last-written target, read in the same turn.* It stays the fallback, as the #383
  amendment keeps it.

**Revisit if:**

- run 1 (D8) shows routine gate waits much longer than milliseconds, or `stepWait` refusing ordinary
  applies. Then `apply` needs its own client deadline (#325);
- a step must write several fans in one transaction;
- a client that re-applies ships before E8a's loop;
- leases that can overlap on a fan are proposed;
- any trigger the #383 amendment lists fires.

**No `AeolusXPCVersion` bump:** no field, case or method changes, and `apply`'s version-1 meaning is unchanged. This amendment corrects
clauses of a Proposed ADR rather than the decisions they sit under. **Status stays Proposed.**

## Amendment (2026-10-16, A6 PR-2, [#383](https://github.com/blamechris/Aeolus/issues/383), [#389](https://github.com/blamechris/Aeolus/issues/389)) — level 6's `apply` as built and one at a time, § 5's bound re-derived, and what a cancelled examination writes

A6's second step builds level 6's `apply` as `LeaseApplier`, tested and not yet wired:
`HelperComposition` does not build it, `SupervisedFanAuthority.apply` still refuses
`.writePathNotBuilt`, and A6's next step wires it to the privilege boundary. Unreachable on every
build on `main` either way. A `.notBuilt` plane grants no lease, and `apply` asks
`heldLease(id:from:)` before anything else, so it answers the faults it answers today, in the same
order after the authority's shutdown refusal, and never enters the gate. The shutdown refusal stays
the authority's: A6's next step keeps `refuseIfShuttingDown` ahead of `LeaseApplier`.

**Decision: `apply`, as built.** The A6 amendment's items 0 and 2–5 stand. This records what
building them decided.

- **The order.** `heldLease(id:from:)`, then the claim (one `apply` at a time, below), then the
  write capability (`.writePathNotBuilt`), then item 0, before anything is read or written. Then
  each fan in index order: its envelope read and its permit, then its gate (`enterForStep(fanAt:)`).
  Under that one hold: engage if this lease has not engaged the fan, register with § 5,
  `requireEntitlement(for:)`, `GovernedFanWriter.hold(_:of:)`, and report the `CommandedTarget` that
  write returned. Then leave. Then item 4: `heldLease(id:from:)` and § 3's latch again.
- **Item 0's checks,** in this order: an empty list; then, setting by setting, `.automatic`,
  `.curve`, a fan the lease does not cover, and a fan named twice. Each answers
  `invalidParameter(name: "settings")` with a fixed detail that quotes nothing the client sent.
- **Level 6's driver is its own,** at `.controlLoop`, now that `engageUnderLease(of:)` is
  withdrawn. `EngagementDriver.init(…, level:)` takes the arbiter level as a required, stored
  parameter, and the driver no longer reads its writer's. § 5's is composed at
  `.reclamationWatchdog` and level 6's at `.controlLoop`. Level 6's driver holds a
  `SafetyActorWriter` for the step and the undo alone; the level-6 file never names that type in
  code, and the driver has no target verb. `apply` binds the driver to the lease it authorised, per
  call.
- **§ 5 through a role.** `ReclamationRegistrationRole` carries registration, the report and
  `manualControlHandedBack(fanAt:under:)`, and nothing else; the report answers what § 5 did with it
  (below). `ReclamationWatchdog` is its one conformer. The hand-back notice drops a fan's record only
  if that lease holds it, and clears the ledger's mark as a release does, unless the terminal action
  is giving the fan up.
- **The undo (item 2 and the half-landed engagement).** Any refusal inside the per-fan loop undoes
  every fan this `apply` engaged, in index order, after the gate is left, and without entering any
  gate. § 5's record is dropped first, under the lease, so § 5 never reads the restore as a
  reclamation; then the driver's `handBack(fanAt:)` restores the fan; and only once that returns do
  the ramp memory and the engaged set forget it (a refused hand-back keeps both, below). A
  half-landed engagement, a newly engaged fan whose command throws, is undone like a failed
  engagement, because the firmware may hold it at any target. The driver registered the fan with
  § 3, which keeps one whose restore is refused. A fan an earlier `apply` under the lease engaged is
  not undone. A refusal at item 4 undoes nothing: every step completed, so each fan already has an
  owner for what follows. A lease that ended is restored by its own teardown, and with § 3's latch
  set § 3 bridges every fan the driver registered.
- **The engaged set** is a value type keyed by lease. A fan joins it when the driver's engagement
  returns, the first engagement under another lease drops every other lease's entry, and the fan
  leaves it when the undo's hand-back returns or § 5 answers its report `.notHeld`. Dropped at
  authorisation instead, an `apply` whose lease ended between `heldLease` answering and its
  resumption would erase the set of the lease granted since, whose next re-apply would re-engage its
  own fans and be refused `.notAutomatic`. A stale `apply` cannot engage, because its driver's
  entitlement refuses it. (Extended by #410's refused-hand-back amendment: `keep` opens a
  `.handBackRefused` account, and `read` ends one.)
- **Item 5's residue.** The table's rows stand as written, and two join them: an `apply` in flight
  and a report § 5 did not record (both below). `CancellationError` is rethrown, the envelope
  read's included, because it says nothing about the machine. Any other error the table does not
  name answers `helperFailed` with a fixed detail. A gate wait ended by cancellation takes the
  `stepWait` row.
- **The ramp memory,** which lasts the helper's life, so a fixed setting is written whole and the
  memory is reset at each engagement and hand-back. `hold(_:of:)` writes the clamped goal whole, in
  one write, and records it as the target last written. The memory is reset for a fan at every
  engagement `apply` makes and for every fan its undo hands back, once the hand-back returns. A fan
  a lease's own teardown handed back is reset at the next engagement, which comes before any write
  under a newer lease. Nothing reads the memory but `command(towards:of:since:)`, which nothing
  calls until E8a's loop.

**Decision: § 5's bound is re-derived from what ADR 0012 bounds.** This replaces this amendment's
first draft, which added a margin to 14.5 s.

- **What the A6 amendment got wrong.** Its 13.5 s took each turn of a step as one
  `WatchdogLimits.roundTrip`. D bounds one stamped round trip, not a turn. A command turn is three
  round trips: key info, the write and the read-back. An engagement's force-key first step is five
  (`writeTurnRoundTrips`). The wait for a turn comes before it, and ADR 0012 ends the helper for no
  wait: G logs and ends nothing.
- **It ran out inside a lawful hold.** At ADR 0012's design point, 12 supervisor readers at the
  measured worst round trip, a supervisor-priority waiter may wait 6.43 s for each turn (9.40 s
  since ADR 0012's 2026-10-18 amendment, which puts § 3's lane turns in that wait; the hold below
  takes each slot at G, which did not move). An engagement whose last step queued at 3.4 s,
  followed by its command, held the gate about 16.4 s, and § 5's 15.5 s ran out inside that lawful
  hold.
- **One turn's slot is taken at G.** A slot is the wait plus the turn. G exceeds the wait plus the
  longest write turn at the design point, for every curated set, in ADR 0012's two **modelled
  cases** (2026-10-18 amendment), and `WatchdogLimitsTests` holds that. The histories review
  counted beyond them stay under G, but one is open: a take-back with writes recurring every § 3
  cycle would make a slot 10.58 s, `lawfulHold` 31.75 s, and leave `examinationWait` short by
  about 1.75 s, at an expiry's cost below.
- **A hold is at most three slots, or the yield budget and two:**
  - an engagement's first step, its one retry, then its undo or its command;
  - or its last poll, which starts inside `yieldBudget`, then its undo or its command.

  A re-apply holds one. `lawfulHold` = max(`yieldBudget` + 2·G, 3·G) = 30 s.
- **The bound.** `examinationWait` = `stepWait` + `lawfulHold` + `examinationMargin` = 32 s.
  `stepWait` is the longest a step queued ahead of § 5 waits for its grant. The margin covers that
  step's timer waking late, and the actor hops inside a hold: level 6's registration, entitlement,
  ramp reset and report, and the driver's own entitlement around each step, its registration with
  § 3 and its after-check. Neither is measured; run 1 measures both (D8).
- **What a wait that runs out means.** The contract was broken; or the helper is outside ADR 0012's
  design point (more than 12 readers since ADR 0012's 2026-10-18 amendment, 20 before it, or
  round trips slower than measured), where G's own alarm can fire for a queue that is moving; or
  the wait spanned a system sleep, which the composition clock counts. Each costs what an expiry costs:
  - a `.fault`;
  - an examination without the gate, whose re-assert stands down;
  - possibly a false divergence: the fan is marked for a cycle and an attempt is spent, which the
    next converged cycle resets. At the budget, that divergence takes the terminal action.
- **What a stuck holder costs.** One `examinationWait`, 32 s in which § 5 examines no fan, once per
  holder.
- **Not the bound ADR 0012 enforces.** Held to what actually ends the helper, a turn queued behind
  § 3's read ends before § 3's next completion, so a slot can last two § 3 gaps, about 34 s, and a
  hold about 103 s. That bound is rejected below.
- **Nothing else bounds § 5's cycle below 32 s.** The wait holds no scheduler turn and stamps no
  round trip, so ADR 0012's round-trip trigger does not see it. Its cycle trigger counts § 3's
  completions, not § 5's, and its gate-waiter alarm watches the scheduler's gate, not this one. No
  caller awaits § 5's cycle under a deadline.

**Decision: one `apply` at a time.**

- `LeaseApplier` admits one `apply` at a time, whatever its lease or connection. The claim is taken
  after `heldLease(id:from:)`, with no suspension between the check and the claim. It is given up
  when `apply` returns or throws, its undo and item 4 included.
- A second `apply` is refused before anything is read or written, and is never queued:
  - **under the same lease:** `helperFailed`, with fixed text;
  - **otherwise:** the `apply` in flight is unwinding a lease that has ended, so the answer is item
    5's `releaseInProgress` row, unless the caller's lease has gone.
- **Why.** A refused `apply` undoes what it engaged without taking a gate, and its hand-back cannot
  tell whether another `apply` has since commanded the fan.
  - Under one lease, the second `apply`'s report then reached no record, and it was answered applied
    for a fan on automatic.
  - Under two leases, the undo of an `apply` whose lease had ended restored a fan the newer lease had
    just engaged and commanded. That `apply` was answered applied, and § 5 then marked the fan
    reclaimed.
- **What XPC contains, and what it does not.** XPC keeps two applies under one lease apart: a lease
  is bound to one connection, and that connection's `MessageSequencer` starts an `apply` only after
  the one before it has replied. That is ordering, not this guarantee, and it does nothing for two
  leases.
- **Consequence for ADR 0012's reader count.** Level 6 is now at most one outstanding supervisor
  reader, whatever the number of connections.

**Decision: `apply` answers applied only for a report § 5 recorded.**

`commandedTarget(_:under:)` answers `.recorded`, `.notHeld` or `.refused`.
- **`.notHeld`:** the fan leaves the engaged set and the step is refused, with the
  `releaseInProgress` row unless the lease has gone.
- **`.refused`:** a target no permit can produce. `helperFailed`, and the step is refused.

Under one `apply` at a time, every other path that drops a record ends the lease or sets § 3's
latch, and item 4 refuses those. This is for the next such path.

**Decision: a refused hand-back keeps the fan's account.**

§ 5's record is still dropped first. If the driver's hand-back throws, the fan stays in the
engaged set and its ramp memory is kept (nothing reads that memory until E8a's loop). § 3 keeps
the fan registered until a restore of it is confirmed, the lease's teardown restores it, and the
next `apply` under the lease that names the fan registers it with § 5 under its gate without
re-engaging. Forgetting it sent that re-apply to the raw-mode check, which answered
`foreignManualControl` about Aeolus's own fan. The refused `apply`'s `.notice` names such a fan
apart, and never says it was handed back.

Two conditions bound the rule. A fan this `apply` newly engaged whose report § 5 answered
`.notHeld` has already left the engaged set before the undo, so a refused hand-back of it is not
kept. And a hand-back can throw after the fan's mode write landed, as when `F<n>Md = 0` takes and
the force key's clear is refused: the fan is then on automatic and still kept, so the next
re-apply that names it is answered applied on an automatic fan for one § 5 cycle, which marks the
fan reclaimed by the system and spends an attempt before its re-assert takes the fan back (What
remains). *(Both conditions changed with #410's refused-hand-back amendment below: every fan whose
hand-back throws is kept as one whose hand-back was refused, the `.notHeld` fan included, and its
next re-apply runs the driver, which reads where the fan is instead of assuming it.)*

**Corrections.**

- **What a cancelled examination writes.** The cancellation guard stops the re-assert's writes, and
  only those. A cancelled examination can still restore and revoke, through `finaliseRelease`. "It
  writes nothing" and "never a write" above now say "away from automatic control".
- **What past the bound costs.** The #383 amendment's table said "possibly a false fault". Past the
  bound, a false divergence also spends an attempt, and at the budget it takes the terminal action,
  revoking a healthy lease. Reaching the bound takes a broken contract, the helper outside ADR
  0012's design point, or a wait that spans a sleep. The rows, and the #383 amendment's other "a
  false fault" sites, now say so.
- **What a write that bypasses the gate costs.** A false divergence, with its mark, its `.fault`
  and its spent attempt, and a re-assert of the record's own target: never a target the system
  chose. Repeated on every cycle, it reaches the terminal action. A test holds the first half, with
  level 6's writer and report used around the gate by hand.
- **The A6 amendment's bound.** Its "13.5 s of it is…" and "So a wait that runs out…" bullets are
  marked wrong, and its "a false fault at most", "diagnostic only" and "never writes without the
  gate" sites are corrected where they stand.
- **Not claimed.** The two cancellation guards in the gate's timer, in its `catch` and after its
  sleep, are equivalent mutants: removing either leaves every gate test green, because the timer is
  cancelled only once its wait is decided, and a decision that arrives late finds it decided. They
  stay as defence, and no test claims them.
- **#383's ramp item, held as thirteen re-applies.** A6 builds no loop that steps on its own, so
  #383's "a ramp phase-locked to § 5's sweep" is thirteen re-applies 200 RPM apart, each landing
  inside an examination. None reaches the terminal action.
- **"One engagement per fan at a time"** is enforced by the gate, and #389 is closed by it. A
  same-lease engagement attempted during § 5's yield wait waits for the gate, so neither engagement
  undoes the other, and no line says nothing was written when something was. *(Not for two applies,
  as this amendment first stood: a refused `apply`'s undo takes no gate, so it could restore a fan
  another `apply` had engaged and commanded since. One `apply` at a time closes that, and the
  assumption row says so.)*
- **D6 and the Consequences.** `engageUnderLease(of:)` is withdrawn, and `hold(_:of:)` joins
  `permitBearingVerbs`; `manualControlHandedBack(fanAt:under:)` joins `permitFreeFunctions`. D6's
  "all or nothing" holds for the fans an `apply` engages, not for a re-apply's earlier fans (What
  remains).
- **`docs/SAFETY.md`.** § 5's bound is replaced by the one above. § 8 says that a fixed target is
  written whole until E8a's loop shapes a control loop's steps; Precedence says the control loop
  will hold no writer it can command a target through but `GovernedFanWriter`.

**What remains.**

- *A re-apply refused part-way* may have re-commanded the fans an earlier `apply` engaged, at the
  targets it reported for them before the refusal. Only what it engaged is undone, and the client is
  told only that it was refused. Whether `apply`'s client contract says so is A6's next step's.
  *(It says so: the A6 PR-3 amendment.)*
- *§ 3 latching after the entitlement and before the command lands* lets one command write reach a
  fan § 3 is about to bridge. Item 4 refuses the reply, and § 3 takes the fan.
- *A fan the system took back under a lease that still counts it engaged* is registered and
  commanded without a re-engage: #381's one-cycle residual. So is a fan kept after a hand-back
  that threw once its mode write had landed: its next re-apply is answered applied on an automatic
  fan, and § 5's next cycle falsely marks it reclaimed by the system and spends an attempt before
  re-asserting it. `LeaseApplierHandBackTests.aKeptFanWhoseModeWriteLandedIsEngagedAgain` pins that
  the cycle no longer happens. *(The second half is closed by #410's refused-hand-back amendment
  below: the kept fan's re-apply runs the driver, which engages it again. The first half, #381's
  twin, stands.)*
- *A step the driver could not undo itself* (an engagement that threw after its mode write landed,
  then a refused restore) leaves the fan in manual outside the engaged set and § 5's watch, held by
  § 3 alone, and the next `apply` that names it answers `foreignManualControl`. The refusal's
  `.notice` no longer says the `apply` engaged no fan. Tracked as
  [#406](https://github.com/blamechris/Aeolus/issues/406). *(Closed by #410's refused-hand-back
  amendment below: the driver throws `EngagementUndoRefused`, and level 6 keeps the fan.)*
- *A stuck holder costs § 5 32 s once,* and outside the design point the bound can run out inside a
  lawful hold.
- *A stuck `apply` refuses every later one until it returns.* That fails closed: nothing is written.
- *A fan whose hand-back was refused* is unwatched by § 5 until the next `apply` that names it, or
  the lease's end.
- *A6's next step's:* the composed level-6 driver and the pin on its level, the shutdown refusal
  ahead of `LeaseApplier`, teardown with an `apply` in flight, and a test that the connection's
  sequencer still carries `apply`. *(All four: the A6 PR-3 amendment.)*
- *The client's deadline.* A fan's step can take `stepWait` and an engagement's yield budget, so an
  `apply` that engages several fans can outlast `gatedVerb`'s 5 s. #325 decides it. *(#410's item
  4: landed client-side by #414's amendment below; #325 stays open for run 1's hardware row.)*

**Alternatives considered.**

- *Reset the engaged set at authorisation.* The stale-`apply` erasure above.
- *Use § 5's records as the engaged set.* § 5 drops a record at its own hand-backs and keeps it
  through a reclamation, so it answers a different question.
- *Map the outcomes the table does not name to new reasons.* D3's reasons wait for run 1 (D8).
- *Undo at item 4.* Every step completed, so item 4 has nothing left to own: an undo would repeat a
  teardown that already ran, or restore a fan § 3 is bridging and tell § 3 the hand-back was
  accepted. *(Corrected: the first draft gave the race with § 3's bridge as the reason, but the
  loop's own undo runs that race when § 3 latches inside a step.)*
- *The bound ADR 0012 enforces, about 105 s.* It silences only expiries outside the design point,
  and triples what a stuck holder costs on every fan.
- *Turns × (G + operations × D).* This mixes regimes: when round trips approach D, G is suppressed
  and bounds no wait.
- *A hold budget on level 6's side.* The turn already in flight, and the driver's undo, cannot be
  refused.
- *An expiry that follows holder progress.* SMC progress cannot tell a leaked pass from a lawful
  wait.
- *Deferring a held fan to the next cycle, with a breach on the holder's age.* Kept as the next
  step.
- *Queueing a second `apply`.* It would outlive `gatedVerb`.
- *A token per `apply`, or an ownership check before the hand-back.* Neither closes a restore racing
  a newer lease's engagement without the plane's help.

**Revisit if:**

- #332 or D8 moves G or the design point. *(Fired 2026-10-18: #332's lane, ADR 0012's amendment
  of that date, moved G's reach from 20 readers to 12 and left G at 10 s. The hold is taken at G,
  so `lawfulHold` and `examinationWait` stand in ADR 0012's modelled cases: a supervisor wait of
  9.40 s plus the longest write turn is still under G for every curated set, which
  `WatchdogLimitsTests` holds.)*
- ADR 0012's open take-back bound is settled the wrong way: if take-backs with writes can recur
  every § 3 cycle, a slot passes G and `examinationWait` must be re-derived from the longer slot;
  *(Widened 2026-10-31, on #465's review: any of ADR 0012's open families shown to recur. The
  refused-revocation family's slot is over G, at 10.01 s since ADR 0012's #332 amendment and
  10.15 s on `e4/bring-up`, but three such slots and `stepWait` come to 31.44 s, inside
  `examinationWait`. The take-back family's come to 33.16 s on the branch, outside it.)*
- run 1 measures holds, hops or timer wakes longer than assumed;
- an outwaited `.fault` is ever logged, which would argue for deferral;
- E8a needs concurrent applies, or `apply` leaves the sequencer.

**No `AeolusXPCVersion` bump:** every answer is an existing case, no field, case or method changes,
and `apply`'s version-1 meaning is unchanged and still unreachable. This amendment corrects clauses
of a Proposed ADR rather than the decisions they sit under. **Status stays Proposed.**

## Amendment (2026-10-17, A6 PR-3, [#405](https://github.com/blamechris/Aeolus/issues/405)) — level 6's `apply` reaches the privilege boundary

A6's third step wires `LeaseApplier` to the privilege boundary. `HelperComposition` builds one, and
`SupervisedFanAuthority.apply` delegates to it. Every build on `main` is still `.notBuilt`, and a
`.notBuilt` plane grants no lease. So an `apply` answers exactly what it answered before, in the
same order, and reaches no write. B1 is what makes it reachable, and what must land first, and
when, is on [#410](https://github.com/blamechris/Aeolus/issues/410).

**Decision: the role the authority holds.**

- **`LeaseApplying` has one requirement, `apply(_:leaseID:from:)`.** It refines `Sendable` and
  nothing else, and takes no permit: its arguments are the client's settings, the lease and the
  connection, which is what a decoded message carries. `LeaseApplier` is its one conformer. It is
  never extended, refined or converted, and its verb is called only from
  `SupervisedFanAuthority.swift`. A census holds where its name and its verb are written, and the
  authority file's conversion ban holds the rest.
- **`SupervisedFanAuthority` gains exactly one stored property,** `private let control: any
  LeaseApplying`, a required initialiser parameter with no default. The authority still names no
  plane, no writer and no permit, and `theAuthorityStoresOnlyItsAllowedProperties` gains exactly
  that line.
- **The shutdown refusal comes first.** `apply` asks `refuseIfShuttingDown` and then delegates. An
  `apply` that arrives once the teardown has begun reaches no `LeaseApplier`: it is answered by
  neither the claim, the lease core nor the plane.
- **On `.notBuilt` the answers are unchanged.** The shutdown refusal, then `heldLease(id:from:)`'s
  faults, then `.writePathNotBuilt`: the authority's order before this step and `LeaseApplier`'s
  order after the refusal. A composed `.notBuilt` helper can hold no lease, so through the listener
  the answers are the shutdown refusal and `leaseUnknown`, and the gate is never entered.

**Decision: the composition.** It builds exactly one `LeaseApplier` from:

- the composition's one examination gate;
- the `ReclamationWatchdog` instance the supervisor cycles, as `ReclamationRegistrationRole`;
- an `EngagementDriver` of its own at `.controlLoop`, over a `SafetyActorWriter` at `.leaseExpiry`.
  The writer's level is provenance nothing reads; the lease is what level 6 writes under;
- a `GovernedFanWriter` over the plane;
- the lease core, § 3's latch and § 3's registration role;
- and the plane, as the envelope reader and the write capability.

It is stored on the composition, so a composed test can pin its driver's level by property and
show that it waits on the gate § 5 examines. The authority holds it only as the role.

**Decision: ordering.** `apply` stays on the connection's `MessageSequencer`.

- `LeaseHeartbeatStarvationTests.theSequencedVerbsAreTheOnesAClientPipelines` already names the
  four sequenced verbs, `apply` among them, and `MessageOrderingTests` counts them. `apply`'s place
  on that list now carries this claim as well, and both say so.
- A test pipelines two applies on one connection through the real listener. Each is answered on its
  merits, and neither meets the claim.
- The sequencer is what keeps a well-behaved client from ever meeting `LeaseApplier`'s refusal of a
  second `apply`. The claim covers any overlap the sequencer does not order: another connection's,
  or an ended lease's.

**Decision: ADR 0012's reader count gains level 6.** Level 6 is at most one outstanding
supervisor-priority reader, whatever the number of connections, because `LeaseApplier` admits one
`apply` at a time and its envelope reads, engagement steps and commands are sequential. ADR 0012's
design point, N = 12, is a stated number and not this list's sum, so the allowance formula is
unchanged. `WatchdogLimitsTests.theBoundsAreDerivedAndConstant` was re-run and nothing moved.
[#332](https://github.com/blamechris/Aeolus/issues/332) still bounds the client-driven terms. Today's
build stays at N = 3: on `.notBuilt`, `apply` refuses before it reads.

**Decision: teardown with an `apply` in flight is ruling D19's residual, which level 6 inherits.**
*(Closed by the #410 ticket-and-seal amendment: the engagement's ticket refuses the first step at
its admission, and the exit's `.forExit` seal, at the final keystone, refuses it and a command after
it inside their own turns; a command before it lands, and that keystone restores the fan.
`SignalTeardownInFlightApplyTests` now holds that nothing is written after the keystone.)*
`SignalTeardown`'s control gate refuses an `apply` that arrives, and one already in flight runs on:

- Every step whose entitlement is asked after `releaseEveryLease()` has emptied the table refuses on
  the lease. That covers an engagement, § 5's registration, the entitlement before a command, and
  item 4.
- Its undo's hand-back is a restore. After the keystone it is redundant, and it takes no gate.
- A command whose entitlement was answered before the table emptied can land after a keystone, on a
  fan the keystone has restored: a target write to a fan on automatic.
- **An engagement whose entitlement was answered before the table emptied can have its first step
  admitted after the final keystone.** The plane records the restore epoch at an engagement's first
  step, so a restore requested between the driver's entitlement and that step's turn does not
  supersede it: ADR 0009 D1's residual, and `PlaneWriteLedger`'s "What the epoch cannot see". The
  step writes `F<n>Md = 1`, and on the force-key path `Ftst = 1` as well. The only undo is the
  driver's after-check, and it runs after the teardown's process-end call, whose outcome is
  `.restored`.

That is the residual ruling D19 on [#197](https://github.com/blamechris/Aeolus/pull/197) accepts for
§ 5's re-assert, recorded in `SignalTeardown`'s step 5 and `docs/SAFETY.md` § 6. § 3's fire does
not carry it: it commands the maximum and then restores, and never engages. Level 6 adds at most one
such engagement per teardown: one `apply` at a time, the gate refuses arrivals once it is closed,
and every later entitlement refuses on the emptied table.

**What it costs on a plane that can write.**

- On the naive path, the after-check's undo races the exit.
- On the force-key path, the first step answers `.awaitingYield`, and the after-check waits behind
  the driver's 100 ms poll sleep, which an exiting process does not outlive. So if the step's
  writes land, `Ftst = 1` is in practice left set, with exit code 0. That is not an occasional race.
- Nothing outside the process reconciles it. Exit code 0 means launchd does not restart the helper,
  and a bootout or an uninstall restarts nothing.

So D19's acceptance does not extend to a plane that can write. The fix is #410's items 1 and 1a,
landing with item 1b in one change on `main` **before B1's first `.built` commit**:

- item 1, a `.forExit` restore scope that seals the plane against every forward write, steps and
  commands, from every writer;
- item 1a, an engagement ticket taken before the entitlement, so that a first step admitted after
  a restore request is refused before it writes. That also closes the same window across a system
  sleep, and the panic verb's transient;
- item 1b, a test of the seal's command half.

This step only documents and pins the residual: `SignalTeardownInFlightApplyTests` parks the step
past the recorded exit, so the after-check's undo runs in the test; in production the race is
between `exit()` finishing and the step's write. *(Closed by the #410 ticket-and-seal amendment,
which inverts that test: the step is refused at its admission and writes nothing.)*

**Decision: the client contract.** `apply`'s documentation in `AeolusXPCProtocol` says what a
refused re-apply means: it may already have re-commanded fans an earlier `apply` engaged, at the
targets it reported for them before the refusal, so the client re-reads the snapshot. That is the
A6 PR-2 amendment's open question, answered in the documentation alone.

**What the snapshot reports after `apply`.**

- `mode` is `.manualFixed`, from the snapshot's own `F<n>Md` read.
- `activeLease` is the lease.
- `manualControlAvailability` is `.available`, step 9's answer for a fan under lease.
- `isReclaimedBySystem` is `false`.
- `targetRPM` stays `nil`. `ReadOnlyFanReport.fanState` states it unconditionally, so on a `.built`
  plane the snapshot says the fan is in manual and asking for nothing while level 6 is commanding a
  target. The end-to-end test pins it as it is, and #410's item 5 decides it. *(Decided by #410's
  snapshot-target amendment below: the snapshot states the target § 5 holds, and the end-to-end
  test pins that.)*

**What remains ([#410](https://github.com/blamechris/Aeolus/issues/410)).** Each item is reachable
only once B1 makes the plane `.built`, and #410's rulings say when each lands:

- **Items 1, 1a and 1b, teardown with an `apply` in flight** (above), and the same window across a
  system sleep: one change, before B1's first `.built` commit. *(Closed by the #410 ticket-and-seal
  amendment below.)*
- **Items 2 and 3**, in one change after #405 and before run 1:
  - [#406](https://github.com/blamechris/Aeolus/issues/406), a refused undo inside the engagement
    driver losing level 6's account of the fan;
  - the landed-mode kept-entry residual (#405's comment): a hand-back that throws after
    `F<n>Md = 0` landed keeps a fan level 6 believes engaged, and its next re-apply is answered
    applied on an automatic fan for one § 5 cycle.

  *(Both closed by #410's refused-hand-back amendment below.)*
- **Item 4, [#325](https://github.com/blamechris/Aeolus/issues/325)'s client deadline**, before run
  1 and before #324 merges. Its client half has landed (#414, the amendment below); #325 stays open
  for run 1's hardware row.
- **Item 5, the snapshot's `targetRPM` after `apply`** (above): before run 1 if possible, and
  required before E4 merges. *(Closed by #410's snapshot-target amendment below.)*

E8a's obligations to level 6 are on [#12](https://github.com/blamechris/Aeolus/issues/12): the
real loop re-runs #383's ramp item, takes the gate for each step, never runs beside a client's
`apply` under the same lease, and steps through `GovernedFanWriter.command(towards:of:since:)`.

**Alternatives considered.**

- *The authority holding `LeaseApplier<Plane>` itself.* That makes the authority generic over the
  plane, and puts the plane's type one name from a decoded client message: the shape E2 froze this
  boundary against, and `AuthorityRoleTripwireTests` refuses.
- *Delegating before the shutdown refusal.* An `apply` arriving during the teardown would reach the
  claim and the lease core, and be answered by them: `applyInProgress` beside an `apply` in flight,
  where the truthful answer is that the helper is shutting down.
- *Closing the teardown residual in this step.* The fix, #410's items 1 and 1a, changes the plane's
  rules for every writer and the driver's order, and lands before B1's first `.built` commit. A
  teardown that waited for level 6's `apply` instead would leave § 5's re-assert where D19 left
  it.

**Revisit if:**

- `apply` leaves the sequencer;
- a second caller of `LeaseApplying`'s verb, such as E8a's loop, is proposed;
- B1 makes the plane `.built`, which is #410;
- #332 or D8 moves N or G.

**No `AeolusXPCVersion` bump.** No field, case or method crosses the boundary, and `apply`'s
version-1 meaning is unchanged: on every shipped build it answers what it answered, in the same
order. Its documentation gains one sentence about a refused re-apply. This amendment corrects
clauses of a Proposed ADR rather than the decisions they sit under. **Status stays Proposed.**

## Amendment (2026-10-17, [#410](https://github.com/blamechris/Aeolus/issues/410), [#325](https://github.com/blamechris/Aeolus/issues/325)) — `apply`'s client waits as long as the helper may

The fourth of the five items A6 left for before B1 builds the Apple Silicon write plane, landed on
its own. It is unreachable on every build on `main`, where a `.notBuilt` plane grants no lease, and
it lands on `main` before run 1. Only the client's own deadline and its error text change.

**The defect.** [#325](https://github.com/blamechris/Aeolus/issues/325): `gatedVerb`'s 5 s bounds
every gated verb. An `apply` that engages fans can lawfully take a gate wait, a yield and several
turns per fan, so a first `apply` of two fans outlasts it with nothing wrong. Cut off, it discards the
connection: the helper ends the lease, and the client reports an unresponsive helper that was inside
its contract.

**Decision.**
- `HelperClientDeadlines.applyPerFan` is `FanExaminationGate.examinationWait` plus two
  `WatchdogLimits.gateWaiterAlarm`, 52 s: the envelope read's turn before the gate, the gate wait and
  hold § 5's bound already counts, and one undo's turn after it, each turn taken at G. It is copied
  into the client and held by a test that imports both modules.
- `apply`'s deadline is `gatedVerb` plus `applyPerFan` for each distinct fan its settings name: 57 s
  for one, 109 s for two. Every other verb keeps its own.
- **Derived, not measured,** as `handshakeVerb` is: it states what the helper may lawfully take.
  Cutting an `apply` below that ends a lease the helper was honouring and misreports it.
- **Past it, the client says what is true.** The connection is discarded as before, because the
  helper is then outside its contract. `helperNeverAnswered` says the request may have taken effect,
  and that abandoning the connection ended any manual control this client held.
- `UnlockLimits.yieldBudget` is no longer sized to the client. The helper's bounds set the client's
  deadline, so D8's and U3's "give `apply` a client deadline of its own" is met in advance.

**What remains.**
- A helper hung where ADR 0012 cannot see it answers an `apply`'s caller only at the deadline. Its
  fans stay under § 3, § 5 and the lease's TTL meanwhile.
- A sequenced verb sent behind an `apply` on one connection waits for it at the helper while its own
  deadline runs from its send. No client pipelines one today; before any does, a sequenced verb's
  deadline runs from when the sequenced verbs sent before it have settled
  ([#413](https://github.com/blamechris/Aeolus/issues/413)).
- [#419](https://github.com/blamechris/Aeolus/issues/419) chose that the UI never cancels a sequenced verb it means to send again: the app's control sends through `AppComposition`'s synchronous entry points, each on a task of its own, and `LeaseDriver` never cancels an `acquireLease` or an `apply` (`InFlightMessages`'s note).

**No `AeolusXPCVersion` bump:** the wire is unchanged. No field, case or method changes, and
`helperNeverAnswered` is an existing client-side case; only the client's own deadline and its error
text move. **Status stays Proposed.**

## Amendment (2026-10-17, [#410](https://github.com/blamechris/Aeolus/issues/410) items 1, 1a and 1b, the ticket-and-seal amendment) — an engagement proves its entitlement came after every restore, and the orderly exit seals the write path

Cited elsewhere as the #410 ticket-and-seal amendment, so as not to be confused with #414's
client-deadline amendment above. The first of the five items A6 left for before B1 builds the Apple
Silicon write plane, with the two items #410 added to it: item 1, the exit seal; item 1a, the same first-step window across a system
sleep and the panic verb; and item 1b, a test of the seal's command half. They land together, on
`main`, **before B1's first `.built` commit**, because B1's plane implements `beginEngagement`,
`admitStep`'s rule, `admitCommand` and `.forExit`. All of it is unreachable on every build on
`main`: a `.notBuilt` plane grants no lease, `SMCFanControlPlane`'s writes throw
`.controlPathNotBuilt`, and it refuses `.forExit` exactly as it refuses `.everyFan`.

### An engagement proves its entitlement came after every restore, and the orderly exit seals the write path

**The defects.** An engagement's first step recorded the restore epoch at its own turn, so a restore
requested between the driver's entitlement and that turn did not supersede it (D4's residual).
Every machine-wide path met it with an engagement in flight:
- *§ 6, the exit.* Ruling D19 on [#197](https://github.com/blamechris/Aeolus/pull/197) re-issues
  the keystone after the supervisors stop, and `SignalTeardown`'s documentation of that step
  accepted that a write could still land between that restore and the exit. A6's wiring showed level 6's `apply`, past its
  entitlement, admitted after the final keystone and after the exit was called, writing
  `F<n>Md = 1`, and on the force-key path `Ftst = 1`. Its undo was left to a process that was ending.
- *§ 4, a sleep.* The same step, admitted after the handback's `.everyFan`, writes before the
  acknowledgement. On the force-key path the after-check waits out a poll interval, so the machine
  can sleep with the fan in manual and the force key set, and the undo runs at the first wake the
  process gets. That falsified this ADR's restatement under maintainer question 3, that § 4's
  handback leaves raw `F<n>Md = 0` and `Ftst = 0` at wake. § 5's re-engage, which shares the
  driver, had the same window.
- *§ 7, the panic verb.* The same step writes after the panic's `.everyFan` and is undone one poll
  interval later: a safe transient, which its own read-back could still observe.

**Decision: the ticket.**
- The driver takes the engagement's epoch from the plane **before** it asks the entitlement:
  `beginEngagement(fanAt:)`, synchronous and writing nothing, with no suspension between it and the
  entitlement. The first-step retry takes a fresh one before its own entitlement.
- `PlaneWriteLedger.admitStep(fanAt:)` admits a first step only if its ticket equals the current
  epoch, and refuses a missing or stale one with `.superseded`, having recorded nothing. A ticket
  clears the stale record an earlier engagement's undo left, so a fresh engagement no longer needs
  its retry for that.
- **Why this closes the machine-wide paths.** § 4, § 6 and § 7 end every lease, and § 3 latches,
  before they request a restore. An entitlement that passed was therefore asked before that request,
  and the ticket before the entitlement. A first step admitted after the request is refused inside
  its own turn, before it writes. One admitted before it is in a turn that precedes the restore's
  turn, which covers the fan (D5's touched set).
- **What it does not close.** The entitlement is still a question asked of other actors. A lease
  can end with its restore not yet requested when the step is admitted. That write is covered by the
  restore that follows it, and the after-check still undoes it, so D1's residual narrows to writes a
  later restore covers. The after-check, the § 3 registration and the undo all stay.
- **Commands.** No ticket. A command landing after a restore writes `F<n>Tg` on an automatic fan
  and moves no mode — reported harmless on Apple Silicon, and untested on Intel (`CLAUDE.md` rule
  11) — so § 4's restatement holds. Every restore but the exit's accepts this already.

**Decision: the exit seals the write path.**
- `FanRestoreScope` gains `.forExit`: the plan `.everyFan` issues. From the moment it is requested,
  synchronously and before it waits for a turn, the plane admits no forward write for the rest of the
  process. `PlaneWriteLedger` holds the seal and decides by scope (`restoreRequested(_:)`,
  `plan(for:)`). A sealed `admitStep` refuses before anything else, and `admitCommand()`, called
  first in every command's turn, refuses a target command. Restores are never refused, and nothing
  unseals.
- `SignalTeardown`'s first keystone issues `.everyFan`, and its last, after the supervisors stop,
  issues `.forExit`: the seal begins once § 3's supervisor has been stopped — `stop()` cancels a
  cycle already running rather than draining it, which is the residual below. Sealing at the first
  keystone refused § 3's bridge to maximum on a fan whose restore the firmware had refused, while
  § 3 still ran: the bridge D4 relies on to cover a refused undo. Sealing at the last costs the exit
  nothing. No first step past its entitlement is admitted after the release's restores are
  requested, because its ticket is stale, and every command admitted between the two keystones runs
  before the last one's turn, which covers the fan. `.forExit` still moves the epoch, as every
  restore does: D3 step 3's in-turn re-check and the force-key rule read the epoch alone, and the
  seal adds to supersession rather than replacing it. The exit codes are unchanged.
- Nothing but that final keystone names `.forExit`. On a `.notBuilt` plane both keystones are
  refused `.controlPathNotBuilt`, which is still `.nothingToRestore`.
- **Why the exit is sealed as well as ticketed.** D1's discharge needs a process that outlives the
  write, and the exit's does not. Nothing outside the process reconciles it either: a zero exit is
  not restarted, and `bootout`, `SMAppService.unregister()` and a shutdown restart nothing. So the
  exit refuses target commands too, whose effect on an automatic fan is reported harmless on Apple
  Silicon and untested on Intel. Its step half is a second line beside the ticket.
- **Why `.superseded`.** Every caller already routes it toward automatic control with nothing
  written.

**What remains.**
- A restore requested between a ticket and its admission supersedes the step for any fan. The one
  retry takes a fresh ticket; a second refusal answers `releaseInProgress`, which fails closed.
- A first step whose ticket a refused entitlement left behind is admissible only if no restore has
  been requested since. The tripwire holds the ticket's callers to the driver.
- A forward write from outside this process (D9).
- A § 3 fire in flight across `stop()`, whose bridge to maximum takes its turn after the last
  keystone was requested, is refused. `ThermalSupervisor.stop()` cancels the cycle without joining
  it, so the teardown does not wait for that fire: the seal permits its restore, which runs only if
  execution reaches it before the process ends. The exit code comes from the final keystone alone. A
  refused § 3 restore does not set it; a refused final keystone is what makes the exit non-zero, and
  launchd then restarts the helper where it restarts at all. Once the process has ended, nothing
  raises a fan the firmware would not hand back: that was so before the seal.
- Every ticket and seal test runs against `ScriptedControlPlane`. If B1's plane skipped
  `admitCommand()`, or called it after the target write, none of them would turn red, so B1 must
  carry its own: the in-flight tests at the exit, a sleep and the panic verb, or a plane-agnostic
  contract suite, run against `SMCFanControlPlane` over a fake SMC; or a source tripwire that every
  `.built` conformer calls `admitStep` and `admitCommand` first in their turns
  ([#9](https://github.com/blamechris/Aeolus/issues/9)).
- *Not claimed:* sealing at the issue rather than the request is equivalent for the exit; no test
  claims it.

**Alternatives considered.**
- *A sleep seal that reopens at wake.* It would need a second copy of #347's sleep-seal pairing
  below the seam, or a lease core that drives the plane. A wake missed or mis-paired leaves the
  plane sealed for the process's life, refusing every `apply` with a false reason; one that opens
  early returns the residual. It also seals commands nothing needs sealed.
- *§ 4 waiting for an in-flight `apply`.* The wait is bounded by the 5 s acknowledgement budget,
  while a step may lawfully hold for 32 s at the design point, so the budget wins in exactly the
  cold-unlock case. It leaves § 5's re-engage and § 7 open, and as a gate barrier it puts a restore
  path on the gate, which a census forbids.
- *Ask the entitlement before every poll sleep.* It narrows the force-key path's delay to a race,
  and closes nothing.
- *Restate the restatement.* It is the maintainer's accepted text, and the ticket makes it true.

**B1's obligations** ([#9](https://github.com/blamechris/Aeolus/issues/9)), stated as contracts on
`FanControlPlane`'s verbs: forward `beginEngagement(fanAt:)` to the ledger; call
`ledger.restoreRequested(scope)` before each restore's turn; call `admitStep(fanAt:)` first inside
every step's turn, and `admitCommand()` first inside every command's turn, before key info or any
write; keep a step's or a command's admission and its writes in one exclusive turn (U15, D7), on
which the seal's command half depends; build each restore from `ledger.plan(for: scope)`, never from
a scope switch of its own, so `.forExit` plans exactly what `.everyFan` plans; and carry the
plane-level tests or tripwire "What remains" names.

**No `AeolusXPCVersion` bump.** No field, case or method crosses the boundary. `.forExit` and
`beginEngagement(fanAt:)` are below the seam, in the helper, and no client can name either. On every
shipped build each verb answers what it answered, in the same order, and the exit codes are
unchanged. This amendment corrects clauses of a Proposed ADR rather than the decisions they sit
under. **Status stays Proposed.**

## Amendment (2026-10-17, [#410](https://github.com/blamechris/Aeolus/issues/410) items 2 and 3, [#406](https://github.com/blamechris/Aeolus/issues/406), the refused-hand-back amendment) — a refused hand-back is read, not assumed

Cited elsewhere as the #410 refused-hand-back amendment. The second and third of the five items A6
left for before B1 builds the Apple Silicon write plane, landed together because they share level
6's accounts. All of it is unreachable on every build on `main`: a `.notBuilt` plane grants no
lease, so level 6 never engages, keeps or re-reads a fan, and no driver undo is ever issued. It
lands on `main` before run 1.

### A refused hand-back is read, not assumed

**The defects.** When the engagement driver's own undo is refused, it rethrows the step's error,
and level 6, which records a fan only when the engagement returns, loses it: the next `apply` under
the lease answers `foreignManualControl` about Aeolus's own fan
([#406](https://github.com/blamechris/Aeolus/issues/406)). And a hand-back that throws after
`F<n>Md = 0` landed keeps a fan level 6 believes engaged: its next re-apply is answered applied on an
automatic fan, and § 5 then marks it reclaimed by the system and spends an attempt (the A6 PR-2
amendment's "What remains"). As first stated, the rule kept a fan for every refused undo and ended an
account only on level 6's own hand-back; review showed both a refused undo of a step that wrote
nothing and a driver hand-back that returned leaving a fan re-adoptable, and the Decision below
closes both.

**Decision.**
- **The driver says when its undo was refused.** It throws `EngagementUndoRefused(fan:cause:)`,
  carrying the step's own refusal, when the undo of an engagement that issued a write was refused,
  and only then. Every router reads the cause: § 5's re-assert routes it exactly as before, and level
  6 keeps the fan, its answer chosen by the cause.
- **Issued, not landed, is the line.** A write is issued when the plane makes the firmware call,
  whatever the firmware answers. Neither answer says whether it took effect: acceptance is not
  application (#291), and a refusal or a lost answer does not prove the register unchanged. So an
  engagement that issued a write is undone, a refused mode write included, and a refused undo of it
  keeps the fan's account.
- **A first step that issues nothing says so.** Once admitted, a first step that fails before it
  issues any write, because its pre-state read of `F<n>Md` or a read the write needs did not answer,
  throws `FanControlPlaneError.failedBeforeFirstWrite(index:detail:)`. With `.superseded` (its
  admission) and `.notAutomatic` (its pre-state), these are the only refusals of a first step that
  issued nothing. The driver neither undoes, registers with § 3, nor wraps any of them, so it never
  writes `F<n>Md = 0` to a fan it has not read (ADR 0011). Only a first step throws it. Its answer is
  `.readFailed`'s, so no new reason crosses the boundary (D3).
- **Level 6 holds two accounts per lease:** `.engaged`, when the driver's engagement returned or a
  kept fan was re-adopted, and `.handBackRefused`, when level 6's undo, or the driver's undo of an
  engagement that issued a write, was refused.
- **An account survives a refusal only when the refusal shows the fan untouched and unread.** For a
  fan level 6 holds no `.engaged` account of:

  | The driver | No account | `.handBackRefused` |
  |---|---|---|
  | returned | `.engaged` | `.engaged` |
  | `EngagementUndoRefused` | `.handBackRefused` | `.handBackRefused` |
  | `.notAutomatic`, the engaged value | none: `foreignManualControl` | re-adopted, then `.engaged` |
  | `.notAutomatic`, any other value | none: `foreignManualControl` | ended: `foreignManualControl` |
  | `.failedBeforeFirstWrite` | none | unchanged |
  | anything else | none | ended |

  "Anything else" is a refusal after an undo that landed, which is the hand-back returning; the
  entitlement refused before the first step, which comes only with a lease that is ending or § 3's
  latch; or `.superseded`, which also follows an undo that landed when a later step was superseded,
  and so ends the account. A hand-back that returns, level 6's or the driver's, removes the fan.
- **An `.engaged` fan is re-applied without the driver**, as before. #381's residual stands.
- **A `.handBackRefused` fan is re-applied through the driver,** whose first step reads its raw mode
  in its own turn. `0`: the restore landed, or the system took the fan, and it is engaged afresh.
  The value D3 confirms engagement by (`EngagementRules.isEngagedMode`, shared with the read-back):
  the driver's `.notAutomatic` refusal is read as the engagement returning, with nothing written, and
  the fan is re-adopted. Any other value: someone else's fan, and the account ends.
- **A re-adopted fan is registered with § 3 again** (`EngagementDriver.reAdopted(_:)`), before
  anything that commands it, as a returning engagement is. Both routes that open a
  `.handBackRefused` account leave the fan in § 3's registry, and most routes by which § 3 forgets
  a fan end the account (a hand-back of level 6's or the driver's that returns) or every lease (a
  lease teardown, § 3's own bridge, § 4, § 6, § 7). One ends neither: a hand-back of the same fan
  by § 5 that lands while the lease is live, before or after level 6's refused undo of it — § 5's
  re-engage undone by its own driver, or its `restoreAndForget`. § 3 confirms it and forgets the
  fan while the account stands. So the emergency's reach over a re-adopted fan rests on
  registering it again, not on the account's history, and costs over-firing at worst.
- **The wrapper ends at the answer.** Level 6's step throws the driver's refusal as it came, and
  `refusal(for:)` answers a wrapper by its cause and never returns one, so no `EngagementUndoRefused`
  reaches the boundary.
- **Why read rather than infer.** A write's acceptance is not its application (#291), so which of a
  restore's writes landed does not say where the fan is. The pre-state read is in the turn that would
  write, and inside the hold `lawfulHold` already counts. The § 3 registration adds no SMC turn.

**What remains.**
- **A contest.** A kept fan that is no longer Aeolus's when it is re-applied, because its restore
  landed after the refusal, a hand-back of it by § 5 landed while the lease was live, or the write
  its engagement issued never took effect, and to which another program has written the engaged
  value, is re-adopted, registered with § 3 and commanded. § 5's budget bounds the contest (ADR
  0011), and the notice says only what was read.
- **A false "foreign", closed.** A kept fan whose re-apply's first step is superseded twice by
  restores that do not end the lease (in production, § 5's undo of another fan's re-engage) loses its
  account with nothing written. Its next re-apply answers `foreignManualControl` about a fan Aeolus
  may still hold. Nothing is commanded, § 3 still holds the fan, and the lease's teardown restores it.
- **The force key under a re-adopted fan.** A re-adoption reads the mode and nothing else, and the
  plane's engaged set does not hold a re-adopted fan. So the fan can be held with `Ftst = 0`: a
  per-fan restore of another fan clears the key, or the fan's own refused hand-back did, with
  `F<n>Md = 0` refused and `Ftst = 0` accepted, because a restore attempts every write. If the
  firmware then takes the fan back where § 5 can see it, § 5 re-engages it: one cycle and one
  attempt. If it keeps the mode and ignores the target, § 5 re-commands it up to its budget. Which
  happens is U6.
- **#381's twin**, a fan level 6 still counts `.engaged` after something else handed it back, is
  unchanged. That includes a fan whose § 5 re-engage was undone, or half-undone, by its own driver:
  level 6's next re-apply is answered applied on a fan that may be automatic, and § 5's next cycle
  marks it reclaimed and spends an attempt on a hand-back that was Aeolus's own.
- **The plane's contract.** That only a first step throws `.failedBeforeFirstWrite`, and that a
  first step that issued nothing throws nothing but the three refusals above, is the plane's to keep.
  A plane that broke the first would leave a stale account after an undo that landed; the § 3
  re-registration bounds that to the contest above.
- **One engagement of a fan at a time.** `.notAutomatic` comes only from a first step, which holds
  while the examination gate admits one engagement of a fan (#389).

**Alternatives considered.**
- *Keep the account for every refused undo.* A first step whose pre-state read failed was undone as
  one that wrote; when that undo was refused, which is likely together on a connection that has gone
  stale, the fan gained an account its lease never earned, and another program's later write of the
  engaged value made it Aeolus's.
- *Do not keep on a read failure.* It breaks the converse: a read-back that fails after the mode
  write landed, with the undo refused, leaves Aeolus's fan in manual and unaccounted. Only the plane
  knows whether its failing read came before its write.
- *The driver says on the wrapper whether a write was issued.* It needs the plane's distinction
  anyway, and still undoes, and registers with § 3, a fan whose mode it never read.
- *Accept the never-written case.* Its trigger is correlated rather than rare, and it lets the raw
  value alone make a fan Aeolus's.
- *Landed rather than issued.* A refused mode write that did take effect would get no undo, no § 3
  registration and no account: a fan off automatic control that no emergency bridges.
- *End the account on every bare refusal.* It also ends it on `.failedBeforeFirstWrite`, so a kept
  fan whose re-apply could not read it is answered `foreignManualControl` once the SMC recovers:
  #406's false answer again.
- *Keep the account on `.superseded`.* `.superseded` also follows an undo that landed, and keeping
  the account there leaves it stale on a fan § 3 then forgets.
- *A second wrapper for an undo that landed.* Exact, but it changes the driver's throw for every
  undone refusal at both routers and in every test that expects one, and a router matching the bare
  type would misroute it. The one case it would disambiguate, `.superseded`, is decided closed.
- *Rely on the account's history for § 3.* It does not hold: a hand-back of the fan by § 5 that
  lands beside level 6's refused undo leaves the account standing after § 3 has forgotten the fan,
  and without the registration that fan would be commanded outside the emergency's reach.
- *Give level 6 § 3's registration role.* A second § 3 handle beside its latch; the driver already
  holds the role, and registration is part of what an engagement owes § 3.
- *Level 6 throws the cause.* `refusal(for:)` then returned the wrapper for a cause the table leaves
  unchanged, a cancellation, so the answer's first arm was not the defence it was said to be.

**Revisit if:**
- B1's plane cannot tell a first step's failure before its first write from one after it;
- run 1 shows a refusal code that reliably means a write did not take effect;
- run 4 shows another program writing the engaged value to Aeolus's fans;
- `foreignManualControl` is seen after supersessions under a live lease;
- the examination gate admits two engagements of one fan.

**No `AeolusXPCVersion` bump.** No field, case or method crosses the boundary. The wrapper, level
6's two accounts, `.failedBeforeFirstWrite` and `reAdopted(_:)` are inside the helper, and no client
can name any of them: every answer a client can receive is one item 5's table already gave, chosen by
the same cause, the new refusal answers as `.readFailed` did, and a re-adopted fan is answered as an
engaged one is. On every shipped build each verb answers what it answered, in the same
order. This amendment corrects clauses of a Proposed ADR rather than the decisions they sit under.
**Status stays Proposed.**

## Amendment (2026-10-17, [#410](https://github.com/blamechris/Aeolus/issues/410) item 5, the snapshot-target amendment) — the snapshot states the target § 5 holds

Cited elsewhere as the #410 snapshot-target amendment. The fifth and last of the five items A6 left
for before B1 builds the Apple Silicon write plane. It is unreachable on every build on `main`: a
`.notBuilt` plane grants no lease, so § 5 records no target and every fan's `targetRPM` is `nil`, as
before. It lands on `main` before run 1.

### The snapshot states the target § 5 holds

**The defect.** `ReadOnlyFanReport` states `targetRPM: nil` unconditionally. After `apply` on a
`.built` plane, the snapshot would say a fan is in manual and asking for nothing.

**Decision.**
- A fan's `targetRPM` is the target § 5 recorded for it under the snapshot's live lease, reported
  only when the same snapshot read the fan's `F<n>Md` as manual, § 5's ledger carries no
  `.systemReclaimed` mark for it, and no thermal emergency is active. Otherwise `nil`. So it is never
  set beside `isReclaimedBySystem`, `isThermalEmergencyActive` or an automatic mode. *(The thermal
  emergency condition was added in #426's review: § 3 holds the fan at maximum and outranks level 6
  (ADR 0007), and the lease outlives the latch until `fire` revokes it.)*
- **Reclaimed:** no target, the mode as read, and the mark once § 5 has judged it. The target returns
  when § 5's re-assert converges.
- **What makes the record confirmation:** a forward write's turn reads its target back and aborts on
  a mismatch (ADR 0004; D7). B1's command turn keeps that within `targetToleranceRPM` (U4), so a
  returned `CommandedTarget` is a register that held it.
- **No wire change.** A non-nil value means what v1 says; `nil`, which every v1 client already
  renders, also covers a target the snapshot cannot confirm the fan is holding.

**As built.**
- The rule is `ReadOnlyFanReport.heldTarget`, a pure function with one guard per condition: the
  live lease covers the fan; § 5 holds a record of it under that lease's id, with a target; the same
  snapshot read `F<n>Md` as manual; § 5's ledger carries no `.systemReclaimed` cause for it; and the
  same snapshot's `isThermalEmergencyActive` is false. The mode, the mark and the latch come from
  the one machine read the fan was built from, never a second hop.
- **A condition the implementation added: § 3's latch.** `ThermalEmergency.fire` writes each held
  fan to maximum and then restores it, and revokes every lease only after the last fan, so until
  then the lease view lists the lease and the other four conditions can hold for a fan held at
  maximum, its restore refused included. A fifth necessary condition only narrows the claim.
- `SupervisedFanAuthority` holds § 5 as `ReclamationReporting`, a role with one synchronous getter,
  `recordedTargets(under:)`, and no verb. The snapshot asks it once, after `activeLeaseView()`, and
  only when the view reports a lease. Any hop order only under-claims, because the filter is on the
  lease id.
- The wire's `Lease` does not carry its fans, so `activeLeaseView()` carries them beside it, from the
  same table entry in the same hop, as `LeaseAccountability.leasedFans`.
- **Not yet a confirmation.** The record is one only once B1's command turn reads the target back
  and throws outside `targetToleranceRPM` ([#9](https://github.com/blamechris/Aeolus/issues/9)).
  Until then the tests here pin the rule against the scripted double's read-back.
  `ScriptedControlPlane.commandTarget` returns the requested value for a target its in-turn
  read-back finds: an `.honoured` write's, and, of the writes the firmware discards, only a
  `.reverted` one's, held at the read-back and discarded after it. A target the firmware never
  held (`Stage.targetsNotHeldAtReadBack`) throws `.targetNotConfirmed`. *(Corrected on
  `e4/bring-up`: this said the double returned the requested value even for a write its firmware
  discarded, which, of the discarded writes, has held only for `.reverted` since
  [#430](https://github.com/blamechris/Aeolus/pull/430).)*

**What remains.**
- **A target-only reclamation is stated until § 5 judges it.** The rule reads `F<n>Md`, not
  `F<n>Tg`. If the system rewrites `F<n>Tg` while `F<n>Md` stays manual, the snapshot states § 5's
  record until § 5's next examination marks the fan, at most one § 5 period. The same holds for one
  hop after a re-apply's command lands and before it is reported, and after a re-command of an
  engaged fan throws, which leaves the record standing. Closing it, for example by reading `F<n>Tg`
  as a confirming condition, needs a further ruling.

**Alternatives considered.**
- *`F<n>Tg`, the request, or level 6's memory as the snapshot's target.* The first changes v1's
  meaning; the other two miss § 5's re-asserts and the clamp.

**Revisit if:**
- U4 fails in either half.

**No `AeolusXPCVersion` bump:** no field, case or method changes; `apply`'s and `snapshot`'s
version-1 meanings stand; a non-nil `targetRPM` carries v1's meaning and `nil` is a value every client
renders. This amendment corrects clauses of a Proposed ADR. **Status stays Proposed.**

## Amendment (2026-10-17, B1) — one job per turn, a plane that cannot write unless the daemon asks, and restores that encode nothing

Cited elsewhere as the B1 amendment.

B1 is the first code at or below rule 1's line, built on `e4/bring-up` only. This amendment decides
what D1–D7 left to the conformer. The write seam's design is the architect's ruling for B1,
summarised on [#9](https://github.com/blamechris/Aeolus/issues/9#issuecomment-6236891320). The
amendment lands on `main` with P0, the vocabulary both planes share; the rest of what it decides is
for the branch, and none of that exists on `main`.

**Decided for B1, built on `e4/bring-up`.**
- **A step, a command or a restore will be one synchronous job on the connection's actor, inside one
  scheduler write turn.**
  - `SMCReadScheduler.withWriteTurn(_:)` will take a turn at its plane's admission and never
    wait for a discovery walk: `.supervisor`, or § 3's lane since ADR 0012's 2026-10-18 amendment
    (#332), whose `PlaneAdmission` has no `.snapshot` case. A write closes no handle, and D4 bounds
    a restore's wait to the turns ahead of it, which in § 3's lane is the turn in flight alone.
  - The turn function will take an `isolated` channel. Its first statement will be the ledger's
    admission, and nothing inside it will suspend.
  - So U15 will hold by construction, a `CancellationError` will not be able to arise after
    admission, and `RestorePlan.attemptEvery` and `EngagementRules` will serve both planes
    unchanged.
- **The seam will be the helper's.**
  - `SMCWriteChannel: Actor` will be declared in the helper, and `SMCConnection` will conform
    through an empty extension. *Reversed by the B1 seam amendment, below: `SMCConnection` conforms
    to nothing, and the daemon's channel is a `private` forwarder in `AeolusHelperMain.swift`.*
  - SMCCore will gain one public read, `freshKeyInfo(for:)`. Its SPI members stay at two.
  - No SMCCore protocol will carry `write`, because a public requirement witnessed by the SPI member
    would let every client name the write.
- **Write capability will be what the plane holds.**
  - `.built` will mean the plane holds a channel.
  - `HelperComposition.production` will withhold the channel unless the caller passes `writePath:
    .connection`, and only `AeolusHelperMain` will. *Now `writeChannel:`, a closure over the
    factory's one connection, by the B1 seam amendment, below.*
  - So every test composition, hardware-gated or not, will be `.notBuilt` unless it names a fake. A
    wrong default in either direction fails safe.
- **B1's restore will write `restorePayload(for:)`** (built here, below), never `encode`'s output.
- **Forward writes:**
  - fresh key info, then the raw pre-state read (what this amends, below);
  - the declared types must be the observed ones;
  - a command will read its target back within `targetToleranceRPM` and return the permit's rpm, or
    throw `.targetNotConfirmed`.
- **`Ftst` will be absent only on the firmware's not-found answer.**
- **The branch is never rewritten.** It takes `main` by merge-commit PRs and runs CI on its own PRs.
  It is to be protected like `main` except for linear history, a repository setting that is the
  owner's to apply. Until it is, every PR into it is gated by hand: its three checks and its thread
  resolution, verified before the merge.

**Built here (P0, on `main`).**
- `FanControlPlaneError.targetNotConfirmed(index:commandedRPM:readBackRPM:)`, the error B1's command
  turn throws. Level 6 answers it as it answers `.engagementNotConfirmed`.
- `FirmwareWriteAnswer.unanswered(detail:)`. **An unanswered write counts as issued:**
  `EngagementRules` throws for it on every step, it is never retried and never read as `0x82`, and
  the driver undoes it.
- **The force-key flag is set on every issued `Ftst = 1`**, whether it is accepted, refused or
  unanswered (`PlaneWriteLedger.recordForceKeyIssued()`), not only on an accepted one.
  - *Why:* issued, not landed. Neither a refusal nor a lost answer proves the register unchanged
    (the #410 refused-hand-back amendment), so the restore that undoes the engagement owes the key
    a clear.
  - D5's gate still decides when. A `.fan(n)` restore clears the key only with no engaged fan left
    and no engagement in progress under the current epoch, so the key is never cleared under
    another fan.
  - *The cost* is one more `Ftst = 0` in such an undo, written zero over zero when the write did not
    land (U14).
  - *The side effect, accepted:* after a write that did not land, while another fan stays engaged,
    the flag says the key is set over a clear key. A later first step answered `0x82` then waits
    under it, by D3 step 3's second branch, and is refused when `yieldBudget` runs out. That fails
    safe, under a reason that names the yield.
- **The restore payload.** The preparation step records each restore key's declared size, and
  `restorePayload(for:)` answers zeros of that size, or one zero byte when it is unknown.
  - A recorded size outside 1–32 bytes, which no SMC payload carries, is taken as unknown, so the
    restore write is still attempted.
  - Zero is all-zero bytes in every numeric type and either byte order, so the keystone gains no
    way to fail.
- **The scripted double:**
  - a `.reverted` target write is held at the in-turn read-back and discarded after it;
  - a stage can hold a target nowhere, so the command throws `.targetNotConfirmed`;
  - an engagement's writes can go unanswered, landed or lost.
- **The driver** logs each step's attempt index, with the retried first step as attempt 2. Its
  closing lines state attempts, the retried first step included; a yield timeout's detail also
  states steps, which leave the retried first step out.

**What this amends.**
- **D5's force-key flag bullet and D3 step 3's first branch**, which set the flag on an accepted
  `Ftst = 1` alone, by the rule above.
- **D7's restore bullet**, "It encodes `F<n>Md = 0` and `Ftst = 0` from the types and sizes": a
  restore writes zero bytes of the recorded size and never goes through `encode` (see the
  alternatives). The sizes are still the preparation step's, and nothing is read at restore time.
- **D3 step 1's order**, the pre-state read and then the fresh `READ_KEYINFO`: B1 will take the key
  info first.
  - Both come after admission and before the first write, so `.failedBeforeFirstWrite` covers a
    failure of either and nothing is written.
  - One classification moves. A failing key-info read now takes precedence over `.notAutomatic`: a
    kept fan whose key info cannot be read keeps its account that tick (`.failedBeforeFirstWrite`)
    instead of being re-adopted, and is read again on the next. That fails safe.
  - Taking the key info first will make every turn take the same number of round trips, whatever
    the cache holds, within `writeTurnRoundTrips`.

**What remains.**
- A test written deliberately to pass a real connection as a channel will be caught only by the
  tripwire B1 adds, which looks for the two in the same file. *Superseded by the B1 seam amendment,
  below: a real connection passed as a channel no longer compiles.*
- The real write body meets the plane first at run 1.
- `.built` on a platform without `F<n>Md` is decided before the merge (#360's revisit clause).
- Restore turns on machines with more than four fans exceed `writeTurnRoundTrips`.
- The branch's protection is the owner's to apply (above).

**Alternatives considered.**
- *An async turn of several hops.* It works, but it needs a second, async `attemptEvery`. That would
  be the drift between the double and production that `RestorePlan` exists to prevent, and it puts
  suspensions inside an admitted step.
- *A fake at the IOKit call, as a kernel closure in SMCCore.* It is the most faithful option, but it
  puts a substitution point at the one call site the round-trip watchdog stamps.
- *An identity or parent-PID guard in the write body.* It is structural, but it is a runtime mode.
  Orphan reparenting defeats the parent-PID check, and an identity check couples SMCCore to the
  helper. Kept as the fallback.
- *Using `withExclusiveAccess` for writes.* A keystone would wait behind a walk of 5.9–24.9 s.
- *`encode(0)` for restores.* It adds an encoder failure to the keystone and gains nothing.
- *Two plane types, or a read-only factory for tests.* The hardware tests would then exercise a
  graph that never ships.
- *Setting the force-key flag only on an accepted or unanswered `Ftst = 1`*, as this PR first
  proposed it. A refused write that landed would then be left out of the undo, and the key would
  stay set until the next machine-wide restore or the next start's preparation step, which is
  harmless only if U6 holds.
- *Splitting the flag* into "a clear is owed", read by the restore, and "accepted", read by D3. It
  removes the side effect above. Deferred: it fails safe as it stands.

**Revisit if:**
- any write from a test process is observed;
- P1 or run 1 contradicts U0–U7, U14 or U15;
- the `isolated` form will not build;
- a second production plane, or a second caller of `write`, is proposed;
- run 1 shows a refusal code that reliably means a write did not take effect.

**No `AeolusXPCVersion` bump**: nothing crosses the boundary. **Status stays Proposed.**

## Amendment (2026-10-18, B1, [#436](https://github.com/blamechris/Aeolus/pull/436)) — the daemon's write channel is a file-private forwarder, and `SMCConnection` conforms to nothing

Cited elsewhere as the B1 seam amendment.

**Why.** The B1 amendment had `SMCConnection` conform to the helper's `SMCWriteChannel` through an
empty extension. A conformance is visible wherever its protocol is, and `@testable import
AeolusHelper` makes an internal protocol visible to every helper test. So, with no `@_spi(FanWrite)`
opt-in:
- `connection.write(bytes, to: key)` on a concrete `SMCConnection` typechecks. Lookup finds the
  internal requirement, and the SPI member witnesses it.
- Once b2 lands, so does any helper function that takes an `isolated any SMCWriteChannel`, called
  with a real connection.

On `e4/bring-up` the write has a body, so the first route was live. #431's rule, "the test files
that can write are exactly the test files that opt into the SPI", was false. The tripwires added to
compensate were text scans, and they missed function values, raw strings, interpolation and bound
methods.

**Decision.**
- `SMCConnection` conforms to no helper protocol, and `SMCWriteChannel.swift` does not import the
  SPI.
- The daemon's channel is `DaemonWriteChannel`, a `private actor` in `AeolusHelperMain.swift`.
  - It adopts the connection's executor (`nonisolated var unownedExecutor {
    connection.unownedExecutor }`).
  - It forwards each requirement to the same-named `SMCConnection` member through
    `connection.assumeIsolated`.
  - So a job on it runs on the connection's actor with nothing suspended, and the write still
    crosses the one stamped IOKit call site (ADR 0012).
- `HelperComposition.production` takes `writeChannel: (SMCConnection) -> (any SMCWriteChannel)? = {
  _ in nil }` and applies it to its one connection. Only `main()` passes one. `ProductionWritePath`
  is removed.
- The channel is given only on macOS 14 or later, the first runtime with SE-0392's executor
  semantics. Earlier, the plane holds none and answers `.notBuilt`.
- `withWriteTurn(on:_:)` takes the channel and a synchronous `@Sendable (isolated any
  SMCWriteChannel) throws -> T`. One job per turn, no suspension and no re-entry into the scheduler
  now belong to the type. A job cannot `await`; a `Task` it spawns escapes the turn, so no
  write-turn job spawns one, and a scan holds every call site to that.
- A test that composes the real SMC requires `!plane.holdsWriteChannel` on its first use of the
  binding, in place of `writeCapability == .notBuilt` before each drive. The channel is a `private
  let` of a plane held as a `let`, so one check covers every later call. It can also fail on a build
  whose capability is constant.
- Write latency (U8) is measured from the daemon's per-write log lines, never by a test.

**What this proves.** Measured on Swift 6.4 at `e2d738c`. From a file with `@testable import
AeolusHelper` and a plain `import SMCCore`, each of these fails to compile:
- a concrete or bound `connection.write`;
- a test-module `extension SMCConnection: SMCWriteChannel {}`, with or without `@retroactive`;
- a channel-taking function called with a real connection;
- naming the forwarder;
- a test's own forwarding wrapper.

With `@_spi(FanWrite)`, the wrapper and the conformance compile. So the opt-in is again the only way
a test file reaches a real write.

The architect's model package ran its forwarder through 400 writes against concurrent reads with no
overlap, at `-Onone` and `-O`, and compiled it for a 13.0 target. In this repository no test can
execute the forwarder. `ExecutorSharingTests` runs a stand-in held word for word to the forwarder's
pinned text: 200 writes in 100 turns against 100 concurrent direct reads, with no overlap, in debug
and release, on macOS 27.0.1 (the `Mac16,5`) and on 26.6.2 (CI run 39125154937). With
`unownedExecutor` removed from the stand-in, it trapped at its first call ("Incorrect actor executor
assumption") before reaching the inner actor.

At fix round 2 (`06171ae`, typechecked against a clean build), the entry point fails likewise in
every spelling: its bare name, a typealias of it, and `.self.main()` each answer "cannot find
'AeolusHelperMain' in scope".

**What remains.**
- A test that adds `@_spi(FanWrite) import SMCCore` can write. #431's rule is the control. It now
  also matches the `_spi` token in the raw text of every file under `Tests/` and `Tools/` against a
  fixed list, so no string, comment or backtick hides an ordinary opt-in, and refuses
  `@_silgen_name`, `dlsym` and `@_private(` imports there the same way. The raw text under
  `Sources/` is held to a fixed `_spi` list too, so a scoped `import class SMCCore.SMCConnection`
  or a backticked `` @`_spi` `` in `fanctl` is a new file to justify. These censuses catch
  accidents and ordinary spellings. Against a test written to evade them, the compiler's seam
  above is the control, a residual the B1 plan accepted.
- **No test can call the daemon's entry point.** `AeolusHelperMain` is a `private` type (fix round
  2), so the compiler refuses every spelling of it outside its own file. A scan holds it `private`,
  and a token scan over the code under `Tests/` and `Tools/` is depth beneath that. Until fix round
  2, `main()` was accepted here as a residual held by a name scan, which a typealias and `.self`
  both evaded.
- No test can execute the forwarder. Its text is pinned, and its mechanism is tested on a stand-in,
  in debug and release. Its first real run is the installed daemon's preparation step, which reads
  through the channel before anything writes. So a broken executor share ends the daemon before its
  first write.
- Executor sharing is observed, on the stand-in, on macOS 26.6.2 (CI) and 27.0.1 (`Mac16,5`). It is
  unobserved on 14.0–26.5. The macOS 14 gate's basis is SE-0392's runtime (Swift 5.9, macOS 14),
  the first with custom-executor semantics.
- A composition built in another file and driven without the require is a residual of the second
  layer only. It also needs `production`'s default to have changed.

**What this amends.**
- The B1 amendment's "`SMCConnection` will conform through an empty extension". Reversed.
- The B1 amendment's `writePath: .connection`. Now `writeChannel:`.
- The first bullet of the B1 amendment's What remains. A real connection passed as a channel no
  longer compiles.
- ADR 0008's control on populated `extension SMCConnection` declarations. It now covers any
  extension, empty or not, in any spelling, in the helper and its tests, backed by a runtime check
  that `SMCConnection` does not conform to `SMCWriteChannel`.
- `SMCConnection.write` now has exactly one caller in the helper, the forwarder. Write turns call
  the requirement.

**Alternatives considered.**
- *Keep the conformance and contain it with scans.* Rejected. Every route is a spelling, four were
  found in one review, and each turn function b2 adds would be another route.
- *An SPI group on the helper's protocol and conformance.* Rejected. It hides the member from a file
  without the opt-in, but not the conformance. Measured: such a file can still pass a real
  connection to a function taking `isolated any SMCWriteChannel`. It would also put the opt-in in
  every file that uses the fake.
- *A forwarder that tests can construct over a fake inner actor,* generic over the actor and holding
  closures. Safe, because a real write closure still needs the opt-in, but it adds machinery to the
  root daemon to test four forwarded lines whose failure is a trap before the first write. Deferred.
- *An async turn of several hops, to avoid `assumeIsolated`.* Rejected, for the B1 amendment's
  reasons.

**Revisit if:**
- Swift changes how `@testable` treats `private` declarations, or how `assumeIsolated` and executor
  sharing behave;
- the forwarder traps in the field;
- a test is proposed that needs a real connection as a channel;
- writes are needed on macOS 13;
- a second production caller of `SMCConnection.write` is proposed;
- `-enable-private-imports` is adopted for any target, since an `@_private(sourceFile:)` import
  sees the forwarder and the entry point;
- `-disable-access-control` is passed to any target, which opens every `private` and SPI member to
  a plain-import test. A manifest tripwire refuses both flags, and `unsafeFlags`, in
  `Package.swift`.

**No `AeolusXPCVersion` bump**: nothing crosses the boundary. **Status stays Proposed.**

**Erratum and addition (fix round 2 of [#436](https://github.com/blamechris/Aeolus/pull/436)).** This
corrects two statements, and it closes one residual. The first statement was "the forwarder ran 400
writes", which described the architect's model package, not this repository's test. The second was
"unobserved on any runtime before macOS 27", which CI's macOS 26.6.2 run disproved. The residual was
`main()`, now a `private` entry point. It also adds `-enable-private-imports` to Revisit if. None of
this changes the decision.

## Amendment (2026-10-19, B1 b2) — the write plane's bodies, and what the plan left open

Cited elsewhere as the b2 amendment.

b2 gives `SMCFanControlPlane` its write bodies and `.built`, on `e4/bring-up` only, as the B1 and B1
seam amendments decide. It also settles five points those amendments left to the conformer, and it
marked the points that waited on P1, the owner-present read-only pre-flight. P1 ran on 2026-10-31,
and the P1′ amendment below decides them; "Settled by P1′" records how the bodies take it.

**Decided.**
- **The turn bodies are `SMCWriteTurns`**, a free `enum` whose functions take an `isolated any
  SMCWriteChannel`. The plane takes one write turn per verb, at its own `admission`, through
  `SMCReadScheduler.withWriteTurn(at:on:_:)`, whose admission has no default. The ledger's
  admission, or a restore's issue, is each turn's first statement.
- **The preparation step also takes each enumerated fan's `F<n>Tg` key info, and records it
  nowhere.**
  - *Why:* the step that reads back engaged also reads the raw target, which the A6 amendment's D3
    bullet asks run 1 to log. That read costs one round trip only when the key's info is cached.
    Taking it here keeps that turn at five, inside `writeTurnRoundTrips`. Nothing in the helper
    clears the cache. *(Since P1′ the same read decides the floor hold, and the turn that raises
    is eight, `engagedStepRoundTrips`: see "Settled by P1′".)*
  - *Cost:* one round trip per fan at bring-up, so 34 at ten fans, inside D_bringUp.
  - *Residual:* a fan whose target key info did not answer here costs its first engaged turn one
    more round trip, if the key answers later.
- **The forward encoder has a file of its own, `SMCWriteEncoding`.** It is the third importer of
  `@_spi(FanWrite)`, beside the daemon's forwarder and the reachability probe, and it names `encode`
  alone. The turn file writes only through the channel's requirement and holds no opt-in, so it
  cannot name `SMCConnection.write(_:to:)`. The SPI's members stay two.
- **The command refuses a target below the permit's floor, before it encodes or reads.**
  - `AuthorisedFanTarget` carries the envelope it was clamped through, from the same read, and the
    floor is `max(lowestCommandableRPM, minimumManualRPM)`.
  - No permit can carry such a target, so the refusal is defence in depth: `encode` accepts zero,
    negatives and subnormals.
  - The refusal is `WriteTurnRefusal`, not a new `FanControlPlaneError` case, so the vocabulary
    shared with `main` does not move. Every caller routes it as a refused command.
- **Every write failure without a result byte is `.unanswered`.** That includes a refusal SMCCore
  makes before any round trip. It is the conservative reading — counted as issued, thrown, and
  undone — and nothing distinguishes the two causes of `connectionFailed`.
- **§ 3's telemetry holds a read-only role**, `CriticalTemperatureReading`, which `FanControlPlane`
  refines. On a plane that can write, the telemetry site therefore names no write verb by the
  compiler's rule.

**Settled by P1′** (the P1′ amendment below; [#465](https://github.com/blamechris/Aeolus/pull/465)
after the sync of `main` through #637).
- **U14 holds.** `Ftst` read `0` on every P1 sample, through both loads and both soaks. The
  preparation step keeps taking a non-zero `Ftst` at start to be a dead holder's, and clears it.
- **U0 resolves to Apple's set.** A first step's pre-state is admitted by
  `EngagementRules.requireAutomatic`, which reads the fold: raw `0` or `3`. The engaged value stays
  `1`, outside the set, so the read-back of `1` is the plane's own write.
- **The poll stays Y-write** (decision 3). Every later step writes and logs its raw pre-state.
- **`Ftst`'s not-found answer was not probed.** `SMCWriteTurns.forceKeyNotFoundAnswer` stays `nil`,
  which fails safe: no failure classifies the key absent, every one is unknown, and D5 treats it as
  present. On a machine that truly lacks the key (M1/M2, untested), the cost is one logged
  machine-wide restore at every start.
- **The engaged turn holds the floor** (decision 4). `SMCWriteTurns.step` takes the step's
  permit, and after the read-back of `1` its `holdFloor` reads `F<n>Tg` and decides by
  `EngagementRules.engagedTarget(reading:of:)`, the rule the scripted plane decides by. Below the
  floor it writes the permit's target at `lowestCommandableRPM` through the command turn's own
  body, `writeTarget`: a fresh key info, the observed `flt` of four bytes, the encoding, the write,
  and a read-back within `targetToleranceRPM`. An unreadable or non-finite target, a refused or
  unanswered floor, or a read-back that does not hold it throws, and the driver undoes. The fan
  joins the engaged set only once the hold has held, as on the scripted plane. `SafetyLog` records
  the raw target, the floor raised to, and the answer. The b2 C25 row is inverted: a target that
  will not read now fails the step.
- **The step takes a permit below the seam.** The rule needs the permit's envelope, and it is not
  reimplemented: `step` and `holdFloor` take the `CommandableFan`, and its index is the fan
  written. Both are on the write-verb allowlist's permit list, with the ledger, the log and the
  `isolated` channel as their keyed companions.
- **The turn bound is split.** `WatchdogLimits.engagedStepRoundTrips` is 9: the step that reads back
  `1`, whatever it writes and whatever the key-info cache holds. It raises in eight with `F<n>Tg`'s
  key info cached and nine without, and holds in five and six. `writeTurnRoundTrips` stays 5,
  § 3's bridge job and every other turn, so D_cycle is unchanged. `readerTurnRoundTrips` is the
  larger, 9, and G's slot adds it. *D_cycle counts the turn in flight ahead of each of § 3's turns
  at 64 read round trips, 733.0 ms at the measured worst read. Under D_cycle's own model, § 3's
  reads at 11.453 ms and its writes at W, the cold raise (seven reads, two writes) fits that count
  while 80.2 ms + 2W is at most 733.0 ms: up to a W of about 326 ms. That is far above the 86.98 ms
  break-even of § 3's own writes, so they still bind first, and both are above G's write
  break-even of about 20.5 ms (ADR 0012's 2026-10-31 amendment). The 81.4 ms this paragraph first
  gave (64 × 11.453 / 9; 91.6 ms at eight) took all nine round trips at one latency, another model,
  under which D_cycle itself breaks at about 14.1 ms, so comparing it with 86.98 ms mixed two
  models. It erred safe.*
- **G, re-run at N = 12** (ADR 0012's 2026-10-31 amendment, which records it;
  `scripts/gate-wait-model/engaged_step.py`). Every queued reader at the engaged step fails G: four
  of the histories ADR 0012 counts closed pass it (874–892 round trips at eight). So the queue counts
  **at most one engaged step per fan**, at nine, and every other reader at five
  (`WatchdogLimits.readerTurns`). One engagement per fan at a time is enforced by the examination
  gate, its steps are sequential, and only the step that reads back `1` is long. On `Mac16,5`
  (K = 34, F = 2):
  - the queue is 64 + 34 + (9·2 + 5·7) + 64·6 = 535, against 527 before;
  - the modelled case is **829 round trips, 9.49 s**, and the slot with the nine-round-trip turn
    838, 9.60 s. G = 10 s holds to N = 12 and not at 13 (932, 10.67 s);
  - the closed histories are 795–839 (9.11–9.61 s), and the event model's worst 619 (7.09 s), all
    under G;
  - **the open families stay open.** A take-back with writes every cycle is 927 (10.62 s), over G as
    before. A refused revocation every latched cycle is 867–877 (9.93–10.04 s), and its upper
    member's wait passes G. That member's slot was already over G before the engaged step existed
    (874, 10.01 s).
- **Ruled on #465's review (2026-10-31): the second fallback is not taken.**
  - **What the instruction meant.** "Fails", in the P1′ amendment's instruction to re-run G, means
    ADR 0012's closed criteria: the modelled cases and the slot, the closed histories, and the event
    model. It never meant the open families, one of which has been over G since ADR 0012's #332
    amendment.
  - **What passing G costs in the open history.** It ends nothing and writes nothing away from
    automatic control. It logs the gate fault, and its hold is 31.44 s, inside `examinationWait`.
  - **What the fallback would cost.** It would leave every fan engaged at rest in manual at a target
    of 0 for up to a slot, which is the window decision 4 closed. In exchange it would take that
    family's wait by 0.09 s, to 0.047 s under G (877 to 869 round trips, 10.044 s to 9.953 s), and
    leave both families' slots over G.
- **Re-adoption, and the state it can meet.** Level 6's re-adoption of a kept fan
  (`LeaseEngagements.read`) runs no floor rule. The state it can meet is raw `1` at target 0, at
  rest: a fan in manual control and stopped. Five routes reach that state, and the first three
  leave the fan kept, for the re-apply to meet:
  - a floor hold that throws — the floor refused, unanswered or not held, or the target unreadable
    — with the driver's undo refused;
  - the mode write accepted and its read-back lost, so the step throws before any floor hold, with
    the undo refused;
  - the mode write unanswered and landed, with the undo refused;
  - ADR 0012's D ending the helper between the mode write and the raise, which no undo follows;
  - the driver's undo answered `0x00` and not applied: firmware that takes the mode write and
    leaves the fan manual (#291's `reverted`, unobserved: ADR 0011's assumption table). The undo is
    not refused, so the fan is not kept and the re-apply does not meet it. The driver registered
    the fan with § 3 before the undo, and `handbackAccepted` marks it owed a read-back: it stays
    registered until § 3's own cycle reads `F<n>Md` automatic.

  The re-adopted fan is commanded in the same step, at its clamped target, before the step
  returns; `ProductionReAdoptionTests` holds that over the production plane, and
  `ProductionEngagementAtRestTests` that the driver's own undo hands the fan back when it lands.
  Between a refused undo and the re-apply the fan is held stopped. It is bounded by the re-apply,
  § 5, the lease's teardown and its three attempts, § 3's bridge (the driver registers the fan with
  § 3 before the undo, and it stays in that registry), § 4, § 6 and § 7; the fourth route by
  reconciliation at the next start. The fifth has the same bounds bar the re-apply, which meets
  only a kept fan: § 3 keeps the fan registered and owed a read-back until it reads automatic. Run 1
  watches for it with aborts 7 and 10. A fan kept the same way under load is not stopped: it holds
  Apple's last target (#406). `docs/SAFETY.md` § 2 names this residual beside "0 RPM is not
  reachable".

**What remains.** The real write body, `freshKeyInfo` and the forwarder meet the plane first at
run 1. Write latency (U8) is measured from the per-write log lines, never by a test. Restore turns
on machines with more than four fans exceed `writeTurnRoundTrips`. A fan whose `F<n>Tg` key info
has not answered before its engaged turn, at preparation or at any grant's control-state read,
makes that turn one round trip longer: nine when it raises, which `engagedStepRoundTrips` counts.
The preparation step's priming now saves that round trip and bounds nothing. G's modelled slot
holds at N = 12 while a write round trip stays under about 20.5 ms (ADR 0012's 2026-10-31
amendment), so run 1's per-write lines are read against that as well as U8's 50 ms.

**Revisit if:**
- a probe defines `Ftst`'s not-found answer;
- the helper gains a call to `SMCConnection.invalidate()`: every cold key info, which ADR 0012 keeps
  in the margin as once per key per process, would recur;
- a second caller of the channel's write is proposed;
- `freshKeyInfo` stops replacing the cache entry: the floor's read-back would then be cold too, and
  the turn ten;
- an open family of ADR 0012's histories is shown to recur, or a worst write round trip above 20 ms
  is measured (ADR 0012's 2026-10-31 amendment).

**No `AeolusXPCVersion` bump**: nothing crosses the boundary. **Status stays Proposed.**

## Amendment (2026-10-31, P1′) — Apple's management reads two raw modes, a stopped fan is engaged at its floor, and the operator's gates read what Apple writes

Cited elsewhere as the P1′ amendment.

P1, D8's read-only pre-flight, ran on 2026-10-31 on `Mac16,5`, macOS 27.2 (26B123), owner present,
with the `main` helper at `bfa1fe6`, which cannot write, and `smc-sampler` at `5b0d191`. It recorded
raw `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac` and `F1Ac`: 41,631 samples at 9.08 Hz over
4,586 s, idle and through two loads and their soaks, plus 240 samples in the quiescence window and
60 before the exclusion. No read failed. The record is `docs/SMC-RESEARCH.md`'s section "Apple's own management reads `F<n>Md = 3` when it stops the fans, and `0` when it spins them — P1, macOS 27.2". U0
failed, so D3's rule brought the fold, the pre-state and the poll here before run 1.

**Scope.** Everything here was observed on `Mac16,5` with macOS 27.2. The code applies Apple's set
on every machine (rule 9), but the evidence is that machine's only; Intel and M1/M2 stay `untested`
(rule 11).

**What P1 showed.**
- **Two raw modes, both Apple's.** Raw `F<n>Md` read `3` while Apple's controller had the fan
  stopped (target 0, actual 0), and `0` while it spun the fan, at every target from 1350 to
  3731 RPM, apart from the edges counted below. No other value appeared in 41,931 samples, before or after the exclusion. In the main
  capture, per fan:
  - `3` with target 0: 27,722;
  - `0` with a target above 0: 13,872;
  - `0` with target 0: 37, all at the edges;
  - `3` with a target above 0: **none**.

  Both fans changed mode in the same sample, every time.
- **Apple orders its writes.** Across five transitions (2 up, 3 down; first-seen stamps, late by up
  to 0.11 s in the main capture and 0.53 s in quiescence), mode `0` came 1.00–1.09 s before the
  target left 0, and mode `3` came 0.99–1.07 s after the target reached 0.
- **`Ftst` read `0` on every sample**, through both loads and both soaks. U14 holds.
- **Demand.**
  - A twelve-way `yes` load held the targets at 1350/1458 for the rest of the ten-minute load.
  - A sixteen-way busy loop raised them to 3455/3731, reached about 76 s in.
  - After 10-minute loads, no soak rose above the load plateau.
  - `F1Tg` ran 1.076–1.080 times `F0Tg`.
  - U13 holds.
- **Census.** Every `AppleSMC` user client carried `IOUserClientCreator`, so U10 holds. Seven
  remained after the reboot: the helper, five Apple daemons and one third-party browser.

**Decided.**
1. **Apple's management is a set of raw values, defined once.**
   - `FirmwareFanMode.systemManagedRawModes` is `{0, 3}`, with this amendment as its provenance.
   - `FirmwareFanMode(declaredByFirmware:)` answers `.automatic` for a value that is exactly a byte
     in the set. It answers `.manual` for anything else: `1`, an unobserved byte, a fraction, or a
     non-finite value. Its asymmetry is kept.
   - Every E5 confirmation read therefore reads a fan Apple has stopped as automatic. No consumer
     treats `3` differently from `0`, so the enum keeps two cases.
   - **The engaged value stays `1`, outside the set**, and a test holds the two disjoint. D3's
     read-back can attribute a `1` to the plane's own write only because Apple produced none in
     41,931 samples.
2. **D3 step 1's pre-state admits exactly what the fold calls automatic.**
   `EngagementRules.requireAutomatic` is `FirmwareFanMode(rawByte:) == .automatic`, so the grant's
   read and the pre-state cannot disagree. `1`, and any value outside the set, throws
   `.notAutomatic` and writes nothing.
3. **D3's poll stays Y-write.** Every step's raw pre-state is logged. U0's pre-committed switch to
   Y-read is withdrawn (see the alternatives).
4. **The turn that reads back engaged holds the target at or above the fan's floor.** After the
   read-back of `1`, the same turn reads `F<n>Tg`:
   - **At or above the floor:** the turn answers `.engaged` and writes nothing more.
   - **Below it** (`0` at rest, where Apple's stopped state leaves it): the turn takes `F<n>Tg`'s
     fresh key info, writes the floor and reads it back within `targetToleranceRPM`, then answers
     `.engaged`. Any other outcome throws, and the driver undoes.
   - **Unreadable, undecodable or non-finite:** the turn throws, and the driver undoes.

   The floor is the permit's: `CommandableFan.target(for: envelope.lowestCommandableRPM)`, never
   below `FanSafetyLimits.minimumManualRPM`. ADR 0008's parameter list is unchanged.

   *Why:* without this, a fan engaged at rest sits in manual at a target of 0 until the command's
   turn, which can wait up to G under contention. Every stuck state from then on is a stopped fan.
   That breaks D8's safety argument and #201's run-1 tolerance at rest, and it allows 0 RPM
   (`CLAUDE.md` rule 3). *Under load*, Apple's target is already above the floor, so nothing is
   written.
5. **The restore is unchanged.** Every `F<n>Md = 0`, then `Ftst = 0`, in zero bytes, with no read.
   "Restored to automatic" means the fold's `.automatic`, so a fan that Apple stops after the
   handback, and that then reads `3`, is confirmed. A restore never writes `3`.
6. **D9's census and quiescence read what Apple writes** (see D9, as restated).
7. **D8 is restated where P1 changed its premises** (see D8, as restated).
8. **Run 1 tests U7 where it can fail (1d).** Item 2 lets a hold start at rest, and U1 now predicts
   `Ftst = 1` there, written while every fan the hold does not cover reads Apple's `3`. If U7 fails,
   those fans stay stopped when load rises, and nothing in run 1 as first planned sees it:
   - 1a and 1c have no load, and a fan nobody manages reads `3` with target 0, as a fan Apple has
     stopped does;
   - 1b engages under load, with fan 1 already spinning;
   - abort 2 compares fan 1 against an automatic speed of 0.

   So run 1's record of fan 1, which #9's gate counts toward U7, could not fail. 1d loads a hold
   engaged at rest, at the maximum, and abort 11 ends it if fan 1's target has not left 0.
9. **E4's merge waits on U7's observation, and no mechanism watches a fan no lease holds.** E4 does
   not merge to `main` with a lease narrower than every enumerated fan reachable on `Mac16,5` until
   U7 is recorded as observed holding (see U7). Otherwise the maintainer decides the lease shape
   first, and E4 carries it. This binds E4 itself, not only #154's PR 8b: `fanctl set` holds a
   one-fan lease for up to 8 hours (ADR 0013). It does not block run 1. On `main` every grant is
   refused, and on the branch run 1's operator is the only client.

   *Why no mechanism:* at rest a managed and an unmanaged stopped fan read the same mode and target,
   so a mode watch cannot see the failure. A temperature watch needs Apple's start point, and P1
   shows that is not a temperature (see the alternatives). If U7 fails, the all-fans shape removes
   the state. If it holds, a watcher guards nothing.

**D8, restated.**
- **On `main`, item 7 (new, before run 1): the P1′ vocabulary.** It contains:
  - Apple's set, with the fold and the pre-state reading it;
  - the engaged-turn floor rule in `EngagementRules`;
  - a scripted double that can script Apple's stopped state (raw `3`, target `0`);
  - a recorded mutation for each of: the fold reverted to `!= 0`, the pre-state admitting `1`, and
    the floor raise skipped or made unconditional.

  The branch takes item 7 by sync before #465's review closes.
- **Start 0** reads `Ftst` as `0` and every `F<n>Md` in Apple's set. It writes nothing and logs a
  successful enumeration.
- **1a** is now where the report's `0x82` is predicted, because the report ties it to "mode 3",
  which is this machine's rest state. Its engaged turn raises the target from 0 to the floor, and
  the log shows the raise.
- **1b and 1b′ use P1's sixteen-way busy loop** (`sh -c 'while :; do :; done'` × 16). P1's
  twelve-way `yes` load held `F0Tg` at `F0Mn` for the rest of the ten-minute load, and would never
  meet 1b's engagement
  condition, which stands. In 1b′, "back at rest" means `F0Tg` at `F0Mn` or 0.
- **The post-hold proof** replaces the 20 s twelve-way load. Within 10 s of the restore's log line,
  `F0Tg` must read a value other than the last commanded target, with no helper write to `F0Tg`
  logged since then. That is Apple's controller writing it. In P1 it rewrote the target about once a
  second while the target was moving, and not at all over plateaus of 8 and 13 minutes; whether it
  rewrites an unchanged target is unobserved. The 10 s is run 1's threshold, not a P1 figure: P1
  issued no restore. The run records each restore's latency to Apple's first target write, and the
  window is re-derived from it. At rest, observation continues until `F0Md` reads `3` with `F0Tg`
  at 0, or for 5 min.
- **Abort 3 adds:** raw `F0Md` or `F1Md` outside `{0, 3}` at any time, except `F0Md = 1` during a
  hold. Apple's own moves between `0` and `3` are recorded, not aborted.
- **Abort 10 (new):** raw `F0Md = 1` with `F0Tg` below `F0Mn` for more than 1 s.
- **The recovery ladder** takes each step only if, 10 s after the previous step, raw `Ftst` is not
  `0`, or raw `F0Md` or `F1Md` is outside `{0, 3}`.
- **Abort 9's margin stands:** `F1Tg / F0Tg` was 1.076–1.080.
- **Also recorded:**
  - Apple's transitions between `0` and `3`, with the target's order (U16);
  - the engaged turn's raw `F0Tg`, and whether the floor was raised;
  - each restore's latency to Apple's first target write.
- **1d (new), last, after 1c: a hold engaged at rest, then load.** *(Added on #637's review.)*
  - **Start:** both fans read `3` with target 0 for 60 s, `Ftst` reads `0`, and the hottest curated
    temperature is within 3 °C of the pre-run baseline.
  - **The hold:** `fanctl set 0 100% --for 120s --json`, so it engages from `3`, as 1a did. It is at
    100 % because the hold meets load.
  - **The load:** once `F0Tg` has read the commanded target for 10 s, P1's sixteen-way busy loop
    (`sh -c 'while :; do :; done'` × 16). Its start time is logged and its PIDs recorded.
  - **Pass:** `F1Tg` leaves 0 before abort 11. Hold the load 20 s more, then stop it and kill every
    load-generator PID, leaving none. The hold runs to its end, and the post-hold proof applies.
  - **Basis (P1):** under the same load, fan 1 left `3` about 13 s in, and its target left 0 about
    14 s in, with the hottest curated key at 40.0 °C. Under the twelve-way load, about 42 s and
    43 s, at 44.1 °C. The fans stopped with it at 42.9 °C and 42.5 °C.
- **Abort 11 (new, 1d only).** From the load's start, while `F1Tg` reads 0, whatever `F1Md` reads,
  run `fanctl reset --all` and then stop the load, at the first of:
  - **60 s after the load started.** That is above the slowest start P1 recorded under either load,
    and about four times the sixteen-way start, because fan 0 at its maximum may delay Apple's;
  - **any curated temperature at 50 °C or above.** That is 5.9 °C above every temperature at which
    P1 saw Apple start or stop the fans. Under the same load, with both fans running, P1 reached it
    37 s in.

  The abort's `.everyFan` writes `F1Md = 0` itself, so afterwards only `F1Tg` shows Apple. Record
  whether it leaves 0 within 30 s of the restore's log line.
- **In 1d, from the load's start:**
  - abort 1's baseline clause reads 74 °C: P1's highest curated temperature under the same load,
    64.0 °C, plus 10 °C. A hold at the maximum should run no hotter than P1's same load did;
  - abort 2 cannot fire for fan 1 while `F1Tg` reads 0, and abort 11 stands in for it. Once `F1Tg`
    leaves 0, abort 2 applies to fan 1 against `F1Tg`;
  - abort 9 stands, at 5,199 RPM. P1's fan-1 peak was 3,731.
- **1d's verdict.**
  - **Pass, with `Ftst` written by 1d's engagement:** U7 is recorded as observed holding, for a
    rest-to-load transition.
  - **Abort 11 on the temperature clause:** U7 failed, for E4.
  - **Abort 11 on the time clause, with every curated key below 50 °C:** not shown. The step cannot
    tell U7 failing from fan 0's cooling delaying Apple.
  - **No `Ftst` written:** 1d records fan 1 under fan 0's mode write alone. U7 is then seen only at
    1b.
- **1b's fan-1 record counts toward U7 only if `Ftst` was written there and `F1Tg` changed after it
  was accepted.** On P1's figures, 1b's condition is met about 56 s into the load, and fan 1's target
  rose until about 76 s, changing 20 times. After the plateau it did not change.
- **Also recorded, in 1d:**
  - whether its engagement wrote `Ftst`;
  - the time from the load's start to `F1Md` leaving `3`, `F1Tg` leaving 0 and `F1Ac` leaving 0,
    with the hottest curated temperature at each;
  - whether fan 1 went back to `3` before the restore, with `Ftst` still set;
  - every helper write from the engagement to the restore. None may name an `F1` key. If one does,
    fan 1 leaving `3` is not Apple's, and 1d is void and goes to the architect.
- **Decided on the result, added:** if neither 1d nor 1b records U7 as observed holding, every later
  hold covers both fans, and the lease shape goes to the maintainer before E4 merges (item 9).
- **Before the merge, added:** U7 recorded as observed holding, or the maintainer's lease shape
  built (item 9).

**D9, restated.**
- **Census, read-only.** It runs at the same points as before. Each `AppleSMC` user client's
  creator is put in one of three classes:
  - the Aeolus helper or the runbook's sampler, by PID;
  - an Apple platform binary, signed by Apple's Software Signing authority: a yes/no
    `anchor apple` check, and nothing else is read from a client that is not Apple's;
  - other.

  **The gate passes when "other" is zero.** The record holds the three counts and names no
  process, and nothing in the helper reads it. Apple's daemons are the thermal management every
  run measures against. A third-party client that only reads cannot be told apart from one that
  writes, so it is quit.
- **Quiescence, read-only.** 120 s at 2 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg` and `F1Tg`. On every
  sample:
  - `Ftst` reads `0`;
  - `F<n>Md` reads `0` or `3`;
  - no fan reads `3` with `F<n>Tg` above 0 (U16).

  P1's quiescence capture passes this rule. The rule is the operator's, and it is stricter than
  the fold (U17). It still sees a writer that is holding a fan, not one that is idle.

**What remains.**
- **The mode byte cannot tell a third-party hold that reads `0` or `3` from Apple (U17).** Aeolus
  claims control only on its own read-back of `1`, and § 5 re-checks every cycle, so the remaining
  risk is misattribution: the snapshot calls such a fan automatic, reconciliation leaves it alone,
  and a grant contests it. Every mechanism that confirms a handback reads it as handed back:
  - (a) § 3 forgets an owed handback, so that fan leaves § 3's coverage;
  - (b) the lease core lifts `.restoreToAutomaticFailed`;
  - (c) § 5 records `isReclaimedBySystem`;
  - (d) reconciliation never restores the fan at startup.

  Bounded by D9, which excludes this case through run 3, and by every machine-wide restore, which
  writes `0` without reading.
- **U5b has two arms.** A machine-wide restore at rest writes `0` over Apple's `3` at every sleep,
  every exit and every `reset --all`. Run 1 tests the arm over `3` at 1c and the arm over `0` at 1b′.
- **The engaged turn's floor write is the plane's first `F<n>Tg` write at rest.** It uses the same
  key, type and encoding as the command.
- **A command landing after a restore at rest, once Apple has written `3`,** would produce mode `3`
  with a target above 0. That has not been observed, and it is recorded if it is seen.
- **`Ftst`'s not-found answer was not probed in P1.** `forceKeyNotFoundAnswer` stays `nil`, which
  fails safe.
- **A hold that does not cover every fan, engaged at rest, leaves the others at Apple's `3` under
  `Ftst = 1`, if its engagement wrote the key.** No read the helper takes can tell such a fan from
  one Apple keeps stopped, and § 5 examines only held fans. If U7 fails, that fan stays stopped as
  load rises, the snapshot calls it automatic, and only § 3's ceiling or the lease's end clears the
  key. Under `fanctl set`, the lease can last 8 hours. Nothing reaches this on `main`. E4's merge
  waits on U7 (item 9). *(On `e4/bring-up` it is reachable: since #465 the plane's steps write, so
  a one-fan lease engaged at rest that writes `Ftst` reaches it. Run 1's 1d is its test, and the
  branch has no client but run 1's operator.)*
- **1d's time clause cannot tell U7 failing from fan 0's cooling delaying Apple's start.** That
  outcome reads "not shown". #153's row 3, restated, holds fan 0 at its floor and has no such
  confound. It is a hold below Apple's demand, so it runs under run 2's preconditions.
- **1d holds fan 0 with fan 1 free.** The converse is assumed to behave the same.
- **Whether clearing `Ftst` brings back a fan Apple had stopped managing is seen only if abort 11
  fires,** and then with the load stopping. § 3's and the lease's bound rest on it.
- **U7, if 1d shows it, holds for `Mac16,5` on 27.2 only.**

**Alternatives considered.**
- *Count `3` as Apple's only when `F<n>Tg` reads 0.*
  - It puts U16 into every confirmation read.
  - If Apple enters `3` with a target still set, it misreports the handback and refuses grants
    with a false "another program".
  - It makes the snapshot read two keys under #360.

  It separates one shape of U17 failing: a hold that reads `3` above a non-zero target, which U16
  says Apple never produces. It does not separate a hold that reads `0`, or one that reads `3` at a
  target of 0, from Apple's. It is a possible mitigation, not a remedy; run 4 decides whether to
  adopt it.
- *A third `FirmwareFanMode` case.* Every consumer decides `3` exactly as it decides `0`.
- *Pre-state `0` only.* It refuses every engagement at rest.
- *Y-read.*
  - Under load Apple reads `0`, so Y-read degenerates to Y-write.
  - At rest, leaving `3` means Apple is spinning the fan up, not yielding.
  - If the yield does not move the byte, Y-read never writes.
- *Raise the floor in a separate turn, or leave it to the command.* The fan waits in manual at 0
  for up to G. This is the second fallback: it applies if ADR 0012's arithmetic will not take the
  turn even when it counts at most one long turn per fan with an engagement in progress (see the
  cost below), with abort 10 as run 1's tripwire.
- *Write `F<n>Tg` before the mode write.* That writes into a state Apple is managing, which has not
  been observed.
- *Restore to `3`.* The keystone reads nothing, so it cannot know whether the fan is at rest, and
  `3` with a target above 0 is a pair Apple never produced.
- *Key the census on user ID.* That rests on the unverified claim that non-root clients cannot
  write.
- *Drop the census.* U10 held, and the census found a third-party client that was present after the
  reboot.
- *Watch an unleased fan's mode in § 5 while `Ftst` is set.* At rest a fan Apple has stopped and one
  nobody manages read the same mode and target, so it cannot see the failure. It would see only a
  foreign writer (U17).
- *Detect, in § 3, a fan still stopped once a curated temperature passes Apple's start point.* P1
  shows the start point is not a temperature. Apple started the fans at 40.0 °C under one load and
  44.1 °C under the other, and stopped them at 42.5–42.9 °C. A threshold set from two transitions on
  one machine and one OS would be a safety mechanism with an uncalibrated trigger. It would revoke
  leases when it misfired, and it would be dead code once U7 is settled either way.
- *Report a fan outside the lease as `unknown` while `Ftst` is set.* It fixes the claim, not the
  stopped fan, and puts a state on the wire for a hypothesis 1d settles before merge.
- *Restrict every hold to all fans now.* It removes `fanctl set <fan>`, ADR 0015 D5 and #153's
  per-fan Custom, on a hypothesis a two-minute step tests. It is U7's "If it fails" branch.
- *Load 1a's own hold.* 1a holds at 50 %, which D8 rules out under load. It is the first write, so its
  restore and post-hold proof stay at rest.
- *1d right after 1a.* 1d is the only step in which U7 failing leaves a fan stopped under load, so it
  goes last. By then 1c has shown its abort working in the same state. Its answer changes nothing in
  1b's or 1c's safety.
- *1d at 50 %.* Under this load P1's fan-0 target reached 3,455 against 3,564, and abort 9 at 50 %
  (3,208) sits below fan 1's plateau (3,731).
- *Abort on `F1Md` alone.* Mode `0` with target 0 is still a stopped fan. P1's mode led the target
  by about 1 s, so `F1Tg` costs 1 s.
- *A time bound alone.* It cannot tell U7 failing from a delayed start. The temperature clause can.
- *P1's twelve-way load.* It started the fans about 42 s in and held them at the minimum.

**Cost.** An engaged step that raises the floor takes eight round trips: key info, pre-state, mode
write, read-back, target read, target key info, target write, target read-back. *(Nine when
`F<n>Tg`'s key info is not cached, so `engagedStepRoundTrips` is 9: the b2 amendment, as settled by
P1′, and ADR 0012's 2026-10-31 amendment.)*

**Not built on `main`.** `WatchdogLimits` has `writeTurnRoundTrips` = 5,
`readerTurnRoundTrips = max(modeReadKeys, writeTurnRoundTrips)` and no `engagedStepRoundTrips`;
the real plane's turn bodies are #465's. Nothing on `main` can issue the eight-round-trip turn.
*(On `e4/bring-up`, #465 issues it, and did each of the following; G's result is in the b2
amendment, "Settled by P1′".)* #465 is to:
- split the bound: `engagedStepRoundTrips` = 8 *(9, counting a cold target key info: ruled on
  #465's review)*, with `writeTurnRoundTrips` = 5 left as § 3's bridge job, so § 3's cycle
  arithmetic is unchanged;
- take `readerTurnRoundTrips` as the larger of the two;
- re-run ADR 0012's G at N = 12 before the plane's first production write. If it fails, count at
  most one long turn per fan with an engagement in progress; if that fails too, raise the floor
  in a separate turn (see the alternatives). *("Fails" means ADR 0012's closed criteria, never its
  open families. Ruled on #465's review, 2026-10-31: see the b2 amendment's "Settled by P1′".)*

**Revisit if:**
- a raw `F<n>Md` outside `{0, 1, 3}` is recorded, or Apple produces `3` with a non-zero target;
- Apple produces `1` outside a hold;
- run 1 reads back a value other than `1` after an accepted mode write;
- run 4 records a third-party hold reading `0` or `3`;
- the firmware rewrites `F<n>Tg` on an accepted mode write;
- the gate arithmetic will not take the eight-round-trip turn;
- a report arrives from another OS or machine;
- 1d ends on abort 11, or its engagement writes no `Ftst`;
- any run or report records a fan Aeolus did not engage at raw `3` under load while `Ftst` reads `1`.

**No `AeolusXPCVersion` bump:** raw `3` crosses the boundary as `.automatic`. **Status stays
Proposed.**

## Amendment (2026-10-31, run 1) — run 1 as executed: one recorder per rate, a watcher that alerts and never writes, and the terms the aborts read

Cited elsewhere as the run-1 amendment.

Drafting run 1's operator runbook from D8, as the P1′ amendment restated it, found places where D8
cannot be run as written, contradicts itself, or uses a term it never defines. This amendment
settles them before run 1. It changes no code and adds no mechanism to the helper. It sets two
thresholds D8 left undefined. One of them, 1b's abort 1, is more lenient than a literal reading,
and item 8 says why.

**Scope.** `Mac16,5`, macOS 27.2, run 1. Runs 2 to 4 take these terms unless their own amendment
says otherwise. Intel and M1/M2 stay `untested`.

**Decided.**
1. **The build.** Run 1 builds `Full Release` from #324's branch, synced onto `e4/bring-up` after
   #465 merged, with #438's fixes folded in at that sync. Its tree is `e4/bring-up`'s head plus
   #324 and #438's fixes, and nothing else, and the build record names its head (D1). D8's branch
   review covers #465 on `e4/bring-up`. The sync and #438's fixes are reviewed as a delta before
   run 1. #324 merges into `e4/bring-up` after run 1. *(D1 said the head of `e4/bring-up`, which
   carried no `fanctl set` when run 1 was planned.)*
2. **"No build or agent session" means quiescence.** From the reboot to the final captures there
   is no build, no test run, and no agent session other than the run's coordinator. The coordinator
   spawns no subagent. It runs only the recorders, the watcher (item 4), the load, and read-only
   reads. Before start 0, the 1-minute load average is below 3.

   *Why:* the clause's reason is #227, load that distorts SMC timing, and U8 is what run 1
   measures. P1 ran with its coordinator at a load of about 2.
3. **The recorder is two samplers and one log stream.**
   - `smc-sampler` at a requested 10 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac` and
     `F1Ac`, each as its decoded scalar;
   - a second `smc-sampler` at 1 Hz on its default set: the curated package keys, and `F<n>Ac`,
     `F<n>Mn` and `F<n>Mx`;
   - `log stream --style ndjson --level debug` on `subsystem == "dev.aeolus.AeolusHelper" AND
     process == "AeolusHelper"`.

   *Why two samplers:* P1 recorded the seven fan keys at 9.08 Hz, with no gap over 0.146 s.
   Adding the 34 curated keys to the 10 Hz loop would take the recorder's own SMC reads from about
   70 a second to about 410, during the run that measures write latency (U8). Under the same load,
   P1's hottest curated key rose at most 1.39 °C between two 1 Hz samples, and 5.15 °C in 10 s. So
   aborts 1 and 11 are late by at most one sample, 1.1 s in P1, which is inside the maintainer's
   own reaction. "10 Hz" is the requested rate; the achieved rate is recorded for every hold.

   *Why the process clause:* test processes log under the helper's subsystem. In the three days
   before this amendment, 42,687 lines came from `swiftpm-testing-helper` and 25 from the daemon.
4. **A watcher evaluates the aborts, and only alerts.** It is a read-only process. It runs from
   before the census to the final captures, and evaluates aborts 1 to 12 from:
   - the two samplers' files and the log stream;
   - the coordinator's phase log;
   - the helper's process ID;
   - the system's thermal pressure level.

   It alerts the maintainer aloud and in a window at the machine, and the maintainer acts on the
   alert without waiting for the coordinator. It opens no SMC connection and sends no XPC message.
   It runs no `fanctl`, `sudo`, `launchctl` or `kill`.

   Before run 1, it is replayed against P1's captures, where it must raise no alert. It is also
   replayed against injected violations: each must raise its own alert and no other, and none may
   raise it once its own check is removed. On the day, it runs through the quiescence window with
   no alert, and the maintainer hears its test alert.
   - *Why it is needed:* the coordinator is an agent, and its loop is a model turn: seconds at
     best, unbounded at worst. D8's "at once" cannot rest on it.
   - *Why not sub-second:* no abort needs it. Each guards a harm that unfolds over seconds or
     longer, under a target at or above Apple's demand. The 10 Hz record resolves afterwards what
     an alert cannot.
     - The helper acts on its own for abort 4 (the driver's undo), abort 5 past D (ADR 0012's
       watchdog), abort 7 (restart and reconciliation) and abort 8 (the lease's end).
     - It does not act for aborts 1, 2, 6, 9, 10 or 11: § 3's ceiling is far above their
       thresholds.
   - *Why it never writes:* see the alternatives.
5. **Abort 12 (new): the record goes blind during a hold.** The fan sampler writes no sample for
   2 s, or the package sampler none for 5 s, or the log stream or the watcher stops. Outside a
   hold, no forward write is made until the record is whole again.

   *Why:* every other abort is read from that record. A hold that no abort can see is a hold that
   no abort can end.
6. **Abort 4 is the one the maintainer verifies before resetting.** The driver's undo is the first
   restore, and `engagementRefused`'s line says whether it landed. The maintainer runs
   `fanctl reset --all` at once if any of these holds:
   - the line says the hand-back was refused, or `engagementUndoRefused` is logged;
   - the first recorded sample after the line shows `Ftst` other than `0`, or `F0Md` or `F1Md`
     outside Apple's set;
   - any other abort's condition holds;
   - 10 s pass after the alert with no verdict.

   Otherwise the abort is verified, the recovery ladder is not taken, and the post-hold check
   runs. When in doubt, reset.

   *Why:* a reset on top of a landed undo is a second machine-wide restore over fans already in
   Apple's set. That is an unlabelled U5b test, which is why D8 refuses `fanctl auto` after a
   hold. And the undo has already run before anyone can see its line, so verifying adds no
   exposure in the cases where it ran.
7. **After an abort, the session writes nothing forward.** Any abort called, even one the record
   later shows did not hold, ends the session's forward writes. Recovery and the post-hold check
   run, and the recorders run on for 5 minutes. Each of these ends them too, without an abort:
   - a step that does not pass;
   - a helper start other than start 0;
   - a write round trip above 50 ms (U8). The hold that showed it runs to its end.

   A `fanctl set` that the helper refused before any write is not an abort. It may be repeated
   once, if the coordinator records an operator error as its cause.

   The next session repeats every gate from the exclusion. With the build unchanged, it resumes at
   the step that ended; a revised build starts again at 1a.

   *Why:* D10 orders runs by thermal risk, and run 1's steps keep that order. Going on past an
   unexplained event takes a riskier step on less understanding. And a false call was still a
   machine-wide restore, made under time pressure.
8. **The terms D8 uses without defining them.**
   - **Hottest curated:** per package sample, the highest of the curated keys that read. On
     `Mac16,5` they are the 34 `TPD*` and `TRD*` keys of `CriticalSensorSet`.
   - **The pre-run baseline, T0:** the median of the hottest curated over the quiescence window.
     It must be below 50 °C. **"Within 3 °C of T0"** means at most T0 + 3 °C: a cooler machine
     passes.
   - **At rest:** both fans read raw `3` with target 0 for 60 s, `Ftst` reads `0`, and the hottest
     curated is at most T0 + 3 °C. It is the entry for 1a, for 1b's load, for 1c and for 1d, and
     the cool-down after every post-hold check. If it does not hold within 30 minutes, the session
     writes nothing forward. 1b′'s "back at rest", `F0Tg` at `F0Mn` or 0, stays the end of 1b′.
   - **The hold's baseline (abort 1):** for a hold at rest, the mean of the hottest curated over
     the 10 s before the `set`. Under the sixteen-way load, from the load's start, abort 1 reads
     74 °C in 1b as it does in 1d. 85 °C applies throughout.

     1b's "loaded steady state" is P1's plateau under that load, 64.0 °C. When 1b engages, the
     temperature is still rising toward it (P1: 55.3 °C at 56 s). Starting 1b's load from rest, as
     the entry requires, also reproduces P1's load B, which gave that figure.
   - **"Its automatic speed" (abort 2):** for an automatic fan, its `F<n>Tg` while above 0, in
     every step. For the held fan, its commanded target, counted from 10 s after `F<n>Tg` first
     reads it, so a spin-up from rest is not an abort. P1's longest automatic lag was 4.35 s. The
     10 s allowance is run 1's threshold, re-derived from row 9's step response.
   - **The restore's log line:** the last `Wrote` line of the restore's turn. Its latency to
     Apple's first target write is recorded from both the turn's first line and its last.
   - **Engage (abort 8):** the engagement's first `Wrote F0Md = 0x1`, whatever it answered.
   - **Row 9's running-fan arm:** 1b's step, from Apple's speed at engagement. "About 2,400 RPM"
     was a figure from 26.5.2. Row 9's downward arm is run 2's (D10).
9. **What D8 records, as instrumented.** None of these decides run 1.
   - **Client round trips (#325).** No client instrument exists. Run 1 records:
     - whether any `set` call failed against its deadline: 57 s for `apply` on one fan (the
       #410/#325 amendment), and `gatedVerb`'s 5 s for the heartbeats;
     - each `apply`'s span in the helper, from its first step's attempt line to the command's last
       `Wrote`;
     - the cadence of `renewed` lines.

     #325's sleep-handback arm is run 3's (D10), so #325 does not close on run 1.
   - **§ 7's reply round trip:** the wall time of `fanctl reset --all` under `/usr/bin/time`. That
     is an upper bound, since it includes the process's start and the handshake; the restore
     turn's own lines bound it from below. It is read against the client's `panicVerb` deadline,
     10 s.
   - **The examination gate:** no line measures hold lengths, actor hops or timer lateness. Run 1
     records only whether the gate's fault lines appear, and
     `FanExaminationGate.examinationMargin` stays unmeasured.
10. **A session ends with the `main`-build helper installed.** While the recorders still run, and
    before the third-party fan utility's background item is switched back on (D9), the maintainer
    reinstalls a `main` `Full Release` build, which cannot write. Each later session installs its
    branch build after the census and quiescence, as run 1 does, so every session has a start 0.
    This replaces D8's "In later sessions, D9's reboot starts the installed branch helper before
    any recorder can run."

    *Why:* the branch helper writes a machine-wide restore at every sleep, at every exit, and in
    every start's preparation step. With the third-party fan utility re-enabled, those writes meet
    its holds. That would be run 4's first contact (D9), unrecorded and ahead of runs 2 and 3. And
    the P1′ amendment's "the branch has no client but run 1's operator" then holds by what is
    installed, not by what is remembered.

**What remains.**
- The install procedure is the maintainer's and unverified on 27.2: stopping the `main` helper,
  replacing the bundle, starting the branch helper, and any approval in Login Items & Extensions.
  A rehearsal with a `main` build, which cannot write, settles it before run 1.
- **Remote Login is the maintainer's machine setting, and he has decided (2026-10-31) to turn it on
  for run 1 only:** his account only, and off again right after the session. So 1c and 1d run.
  1c ends its hold with `fanctl reset --all` from an SSH session, which is row 18's hardware half.
  - The helper admits a client by code signature, not by session, so `ssh localhost` serves, with
    the app not running. No one has run it, so that stays an assumption until 1c does.
  - Without Remote Login, 1c would not run, and neither would 1d, which follows 1c by design.
- The watcher is an operator's instrument, not a safety mechanism, and nothing in the helper
  depends on it.
  - If it misses an abort, the maintainer, the helper's own mechanisms, the hold's length and
    § 3's ceiling remain.
  - If it alerts falsely, that costs a session (item 7).
- Abort 2's 10 s allowance for the held fan, and abort 12's 2 s and 5 s, are set without data from
  a write. Row 9's step response and the samplers' achieved rates re-derive them before run 2.

**Alternatives considered.**
- *The coordinator polls, with no watcher.* Its loop is a model turn, so "at once" would mean
  "when the coordinator next looks".
- *A watcher that runs `fanctl reset --all` itself.* It would be a second client making
  machine-wide restores on an unreviewed trigger, and the coordinator's side holds no write by
  design. The helper already acts on its own where the design calls for automation. These aborts
  are measurement boundaries: a false one costs a session, and a missed one is bounded by the
  hold's length, the target choice and § 3.
- *Every key at 10 Hz in one sampler (D8's text).* It is about six times the recorder's SMC reads
  during the write-latency measurement. It gains at most a second on temperatures that move about
  a degree a second.
- *Reset at once on abort 4 too (D8's general rule).* An unlabelled U5b test on top of an undo that
  has already run.
- *Continue after an abort that the record shows was false.* The call was a machine-wide restore
  made under time pressure, and the next step is riskier, by D10's order.
- *Keep the branch helper installed between runs (D9's text).* See item 10.
- *1b's abort 1 at the temperature at engagement plus 10 °C.* That is about 65 °C, about 1 °C above
  the plateau P1 reached with less cooling. It would abort on a warmer room, not on a fan.
- *"Within 3 °C" in both directions.* A machine cooler than it was in the quiescence window would
  fail the entry for being cool.
- *The held fan's abort 2 against Apple's demand, `F1Tg` / 1.08.* At rest Apple's demand is 0, so
  a stalled held fan could never fire. Comparing against Apple is abort 9's job.

**Revisit if:**
- the watcher alerts falsely, or misses an abort that the record shows held;
- a fan sampler's achieved rate falls below 8 Hz in a hold, or a package gap exceeds 2 s;
- row 9's step response from rest takes more than 10 s to reach 80 % of the target;
- the install rehearsal finds the approval lost, or the helper started unobserved;
- "at rest" is not reached within 30 minutes.

**No `AeolusXPCVersion` bump:** nothing crosses the boundary. **Status stays Proposed.**

## Assumptions and what would invalidate them

U0, U1, U4, U5b, U6, U7, U10, U11, U13 and U14 are restated, and U16 and U17 added, by the P1′
amendment.

| # | Assumption | Basis | If it fails |
|---|---|---|---|
| U0 | Apple's own management reads raw `F<n>Md` in `{0, 3}`: `0` while it spins the fan, and `3` while it has the fan stopped | Observed in P1 on 27.2, across 41,931 samples, idle and under two loads, before and after the exclusion. Every earlier raw `0` was taken with the fans spinning | A third value under Apple's management folds to manual and the pre-state refuses it. That fails safe, but it misattributes the fan. It goes to the architect before the next run, and a value joins the set only on P1-grade evidence |
| U14 | Apple's own management leaves raw `Ftst = 0`, under load included | Observed in P1: `0` on all 41,931 samples, through both loads and both soaks | The preparation step would clear Apple's own state at each start, and D3 step 3 would write over it. Both go to the architect before run 1 |
| U1 | A naive `F<n>Md = 1` succeeds when the system is not actively asserting control, and is refused with `0x82` when it is | Reported, and placed at "mode 3", which is this machine's rest state. So the refusal is predicted at 1a, and possibly not at 1b. `0x82` has been seen here only on reads of function keys | **Accepted and applied under load:** no force key is needed on this machine; recorded. **Accepted, then taken back within § 5's cycles:** write `Ftst` before the mode write, a conformer-internal change. **Another code:** treated as "held" only after architect review. **Refused under load and accepted at rest:** recorded; nothing changes |
| U2 | `Ftst = 1` is accepted, and the mode write after it | Reported | No unlock by this route. E4 stops, the snapshot says manual control is unavailable and why, the matrix says so, and it goes back to the architect. Never coded around |
| U3 | The yield arrives within 3.5 s | Reported at about 3 s; budgets of about 30 s suggest a tail | Raise the budget and give `apply` its own client deadline. Beyond about 4 s, asynchronous engagement before merge |
| U4 | An accepted `F<n>Md` reads back raw `1`, and `F<n>Tg` reads back within `ReclamationLimits.targetToleranceRPM` (1 RPM) of what was written | Unobserved. § 5's primary signal rests on the second half. In P1 Apple never produced `1`, so a `1` after the plane's accepted write is the plane's | **Mode:** D3 refuses, which is correct. The re-adoption of a kept fan reads the same predicate. **Target:** re-derive the 1 RPM tolerance from the observed quantum before merge — a safety-limit change — or every § 5 cycle reports a reclamation |
| U5 | The reverse-order restore is accepted for a fan the plane engaged | Unobserved | The retry already runs the other order. If only that one lands, D5's order flips, in one place. A refused keystone in any run goes to the architect with #343's decision (ADR 0009, 2026-10-15) before the next run |
| U5b | `F<n>Md = 0` is accepted over a fan already under Apple's management, both over `0` and over `3` | Over `0`, tested at 1b′. Over `3`, tested at 1c on fan 1, and exercised by every machine-wide restore at rest, which means every sleep and every exit | Refusal accounting changes before run 2 (Consequences). A refused keystone in any run goes to the architect with #343's decision (ADR 0009, 2026-10-15) before the next run |
| U6 | With `Ftst = 1` and every raw `F<n>Md` in Apple's set, Apple's management drives the fans | Unknown. Run 1's post-hold proof is its first test while the key is set | D5's gate goes: every restore clears the key, and every engagement re-sets it. § 4's never-issued keystone becomes a priority residual |
| U7 | `Ftst = 1` does not change the behaviour of a fan Aeolus did not engage | Unknown. At rest it cannot be seen: a fan nobody manages reads `3` with target 0, as one Apple has stopped does, so 1a and 1c cannot show it. **Observed holding** means one of: 1d passes with `Ftst` written by its engagement; or, if `Ftst` is written only under load, `F1Tg` changes at 1b after `Ftst` is accepted, for which P1's figures leave about 20 s of Apple's ramp. Anything else leaves U7 unobserved | A one-fan lease would take the others off Apple's management while the snapshot calls them automatic (rule 6). At rest an unengaged fan reads `3` and the fold calls it automatic, so U7 failing at rest means a stopped fan that Apple no longer manages, reported as automatic. No mode read and no § 5 cycle can see it, and only § 3's ceiling or the lease's end clears `Ftst`. Engagement becomes all-fans-or-nothing on such firmware, the lease shape is the maintainer's call, and ADR 0015 D5 is revoked. **E4 treats unobserved as failed** (the P1′ amendment, item 9) |
| U8 | Every write round trip stays under 50 ms (D/100), the teardown restore's and 1b′'s included | Reads: 11.45 ms worst. Writes: unmeasured | D8's decision rule |
| U9 | Manual mode and the force key persist after the writer dies (ADR 0012 H3) | Reported | If they revert on close, ADR 0012 and the preparation step get cheaper; nothing changes |
| U10 | `ioreg` lists every `AppleSMC` user client with its creating process | Observed in P1: 7 after the exclusion, each with `IOUserClientCreator`; 10 before it (count only retained) | D9's census gate is dropped |
| U11 | A power cycle returns raw `F<n>Md` to Apple's set and `Ftst` to `0` | `RECOVERY.md` step 7 asserts that the force key resets. That `F<n>Md` does not persist is `docs/SAFETY.md` row 7's unverified assumption, and ADR 0011's. P1, after a reboot: the fans ran at minimum reading `0`, then stopped and read `3`, about 5 minutes after the reboot | D8's recovery steps end in a loud fan and `RECOVERY.md` § 8. Run 1's target choice is what makes that acceptable |
| U12 | Sleep resets `Ftst` | Reported. Not depended on (D5) | Only the never-issued-keystone residual widens |
| U13 | Apple's controller never commands above the declared `F<n>Mx` | Before P1, the highest fan speed recorded under Apple's control was 3,683 RPM, against 5,777 declared (2026-08-20; key not recorded), and the highest `F0Tg` was 2,195 RPM. P1 raised both: targets 3455/3731 and actuals 3546/3818 RPM under a sixteen-way load. The pre-flight records `F<n>Tg` through a load and its soak. Observed in P1: a peak of 3455/3731 under a 16-way load, against 5777; 1350/1458 under a 12-way load; no soak peak after 10-minute loads on 27.2 | 1b's "at or above demand" fails by the excess. Aborts 9 and 1 catch it |
| U15 | A plane's step or command admission and its writes are one exclusive turn (D7), and `beginEngagement` precedes the entitlement. The order is what holds: a suspension between the two only makes the ticket older, which refuses more | D4 (the turn rule) and D7 | The ticket and the exit seal narrow the window instead of closing it |
| U16 | Apple writes mode `0` before it raises `F<n>Tg` from 0, and mode `3` after the target reaches 0, so it never produces `3` with a target above 0 | P1's five transitions, about 1.0 s each way, both fans together, and none of the forbidden pair in 41,931 samples | Only the operator's gate and the run analysis use it. The quiescence rule is re-decided, and the fold is unchanged |
| U17 | No writer other than Apple leaves a fan it holds at raw `0` or `3` | Unknown. Aeolus writes only `1`, and `0` on restore. A third-party hold is unrecorded by design (D9). The 2026-09 non-zero readings are confounded | The fold calls such a hold automatic, which is a rule-6 misattribution, and every mechanism that confirms a handback reads it as handed back: § 3 forgets an owed handback, so the fan leaves § 3's coverage; the lease core lifts `.restoreToAutomaticFailed`; § 5 records `isReclaimedBySystem`; reconciliation never restores the fan at startup. Bounded by D9 through run 3, and by every machine-wide restore, which writes `0` without reading. A possible mitigation for one shape of it is to count `3` as Apple's only when `F<n>Tg` reads 0, in the fold and in the snapshot's read (see the alternatives). It does not cover a hold that reads `0`, or `3` at a target of 0. What would is open, and is decided at run 4 with what a held fan reads |
| — | The preparation step can enumerate the fans and record both restore keys' types | `FNum`, `F<n>Md` and `Ftst` have read on every capture. Both are `ui8`, one byte, on 27.0.1 | `.everyFan` writes the touched set's fans and the force key, then throws `.fanSetUnknown`. An unknown key is written as one zero byte (D5, D7). Start 0 stops |
| — | One engagement per fan at a time | **Enforced by the gate** (the A6 PR-2 amendment): § 5 re-engages only inside an examination, which holds the fan's examination gate, and level 6 engages only under that gate, one holder at a time. *(It was false for two applies until the same amendment admitted one `apply` at a time: a refused `apply`'s undo takes no gate, so it could restore a fan another `apply` had engaged and commanded since, under the same lease or a newer one. The claim closes that.)* The ledger still keeps one in-progress record and one ticket per fan index, and a ticket taken by one engagement clears the record and replaces the ticket of another of the same fan, which the gate keeps from existing | An engagement that bypasses the gate, a contract breach, brings back #389's overlap, and one engagement's ticket could admit the other's first step: key the record and the ticket per engagement. Also: § 5's `finaliseRelease` restores and then revokes the leases, so for that window a genuine restore has not yet ended the lease; level 6's driver then finds the lease live. A step already past its first is caught by the restore's epoch; a first step superseded by that restore takes a fresh ticket in its retry, past the restore, so only the after-check catches it (#410's ticket-and-seal amendment). Across leases, a second engagement fails safe (the 2026-10-15 identity amendment): the stale one's next check asks about its own ended lease and undoes, and the undo supersedes the other. *Since #465, G's queue also counts at most one engaged step per fan (ADR 0012's 2026-10-31 amendment). With every reader at the engaged step, four of ADR 0012's closed histories pass G.* |
| — | One lease-table entry, one production plane | True today | Concurrent leases or a second plane: re-check D4's epoch scope and D5's gate. Since the 2026-10-15 amendment, no lease is granted while § 7's panic verb or § 4's handback runs (`sealingGrants(during:)`). The seal is machine-wide, so concurrent leases or a second plane re-check that it still covers every restore that can undo a grant. |
| — | A re-grant after § 5's terminal action is a client's request | `AeolusXPCClient` and ADR 0013 D1 never re-acquire; the app asks for a lease only on a user's click, and its lease driver never re-acquires after a loss (`LeaseDriver`, #153) | A self-re-acquiring client makes the contest with the system unbounded: a measured, time-limited ledger refusal, mirrored in the snapshot |
| — | At most one live lease covers a fan | One lease at a time (`.leaseHeldByAnotherClient`) | Overlapping leases: § 5's records keyed per (fan, lease), and registration's arbitration re-decided |
| — | Every lease-core restore notice for a fan precedes any grant over it, and precedes the fan leaving `releasing` | `releasing` is held from before the restorer's notices until it returns; `HelperFanRestorer` awaits each notice before its write | A restore path bypassing `releasing` lets the index-keyed `manualControlReleased(fanAt:)` erase a newer lease's record, and a notice delivered after the restorer returns ends #368's wait before it arrives; either way the notice must then carry the lease |
| — | The snapshot's `F<n>Mn`/`F<n>Mx` read and the grant's `readEnvelope(ofFan:)` fail together and reach one plausibility gate (#270) | Code: one scheduler and connection, the same two keys. Each path checks finiteness before the gate: the plane at its seam, and the snapshot's in `SMCFanEnumeration`, which turns a non-finite read into `.notDecodable`. A non-finite bound is therefore `.notMeasured` on both, and both end at that gate as `.boundsImplausible`. Unverified on Intel and M1/M2 | The grant refuses leases the snapshot offers, or the reverse. Fix the read in the same change; do not debounce |
| — | The cache keeps the snapshot's sighting to one curated read per period (#269) | Measured on `Mac16,5` (27.0.1, 26A434) with § 3 stopped, in four runs: one curated read per cold snapshot, 40 of 40, and one per burst of 16 concurrent snapshots, 12 of 12, never more than one `.supervisor` turn held; none warm. With § 3 running, the shared cache expires for part of every § 3 cycle by construction: § 3 sleeps its interval after each cycle, the cache's age bound is that interval, and § 3 records when its read finishes, so the entry is expired for the whole of § 3's next read and any gap before it. So a snapshot can add one curated read per period, a duplicate whose result the cache drops, or queue its read ahead of § 3's and delay that cycle by one read. ADR 0010's bound still holds — at most one other read in flight — so that is a cost on every cycle, not a safety failure. Unmeasured with § 3 running ([#393](https://github.com/blamechris/Aeolus/issues/393), before E3 makes `.built` reachable), and on Intel or M1/M2 | The cost question reopens: a `.built` snapshot's check would queue `.supervisor` turns ahead of § 3. Fix the cache's coalescing; do not move the check off the snapshot |
| — | The snapshot's `F<n>Md` read and the grant's fresh read fail together | Code: one scheduler and connection, the same key and `FirmwareFanMode(declaredByFirmware:)` decode behind the same finiteness rule; a `.snapshot` read waits and never fails for its priority. They differ only in priority and instant. Every recorded `F<n>Md` read on `Mac16,5` answered, and none was taken while reads were failing | The #360 rung refuses leases the helper grants. Fix the read, and re-decide here. The same holds for a platform whose mode is not `F<n>Md` (Intel, `FS! `): the snapshot's read must take the plane's branch, or share its decode, in the same change |

Every observation above is `Mac16,5`; the write-path rows are hypotheses until D8 runs. Intel and
M1/M2 ship `untested`.

## Revisit when

Revisit this ADR when any of U0–U7, U5b, U13, U14 or U15 is contradicted, by the pre-flight or by
a run. That is the expected case: amend this ADR, and do not code around it.

Also revisit it when:

- a write round trip exceeds 50 ms;
- the yield does not fit a synchronous `apply`;
- concurrent leases or self-renewing leases are proposed;
- a second production plane exists;
- a report arrives from M1/M2 or another M3+ machine.

Since the P1′ amendment, also revisit it when:

- a raw `F<n>Md` outside `{0, 1, 3}` is recorded, or Apple produces `3` with a non-zero target;
- Apple produces `1` outside a hold;
- run 1 reads back a value other than `1` after an accepted mode write;
- run 4 records a third-party hold reading `0` or `3`;
- the firmware rewrites `F<n>Tg` on an accepted mode write;
- the gate arithmetic will not take the eight-round-trip turn;
- a report arrives from another OS;
- 1d ends on abort 11, or its engagement writes no `Ftst`;
- any run or report records a fan Aeolus did not engage at raw `3` under load while `Ftst` reads `1`.

The ruling is the architect's E4 consult, run on Opus.
