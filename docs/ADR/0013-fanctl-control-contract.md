# ADR 0013 — `fanctl`'s control contract

- **Status:** Proposed
- **Date:** 2026-10-07
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (amends [#15](https://github.com/blamechris/Aeolus/issues/15)'s
  `auto [<fan>]` checkbox; extends [ADR 0011](0011-reconciliation-and-foreign-manual-control.md)'s
  asymmetry between moving toward and away from automatic control)

## Context

`fanctl` gains its first commands that move fans, and the question each one answers is the same:
what may a command-line process promise, to a script or to a person on an SSH session who cannot
see the machine?

Three facts frame it.

- **A manual hold is a lease.** `docs/SAFETY.md` makes manual control something a client keeps
  proving it still wants, and the helper ends it when it stops. A lease is no route back for a
  fan that has to be returned: it is granted only over a fan that is already automatic, and
  refused over one that is not.
- **Returning to automatic is the one request that is always valid.** `restoreAllToAutomatic` is
  exempt from the version handshake, consumes no bounds, clamp or sensor reading, and is safe to
  send at any time ([SAFETY.md § 7](../SAFETY.md#7-panic-path)). `fanctl reset --all` already
  sends it and reports what the helper *accepted*.
- **The snapshot can be wrong in one direction.** The helper reports a fan whose `F<n>Md` it could
  not read as `automatic`, because protocol version 1 has no way to say "not known"
  ([#178](https://github.com/blamechris/Aeolus/issues/178)), and on Intel the register does not
  exist, so every fan reads `automatic`. The field that does say "the helper has not cleared this
  fan" is `manualControlAvailability`, and the helper restates its reasons with no guard on the
  mode. So a fan can read `automatic` and carry `restoreToAutomaticFailed`, `handbackUnconfirmed`
  or `supervisorBlind` in the same snapshot.

`reset --all` answers "did the helper take the request". Nobody has yet answered "is it done", and
the obvious ways to build that answer each import a failure.

## Decision

### D2 — `auto` is machine-wide, never takes a lease, and sends at most one restore

`fanctl auto` (and `fanctl auto all`, the same command) asks the helper to return every fan to
automatic control and then checks what the helper reports.

1. **Sequence.** Handshake, then one snapshot. With no lease and every fan **cleared** (D3) it
   exits 0 having written nothing. Otherwise it sends `restoreAllToAutomatic` **once** and reads
   the snapshot every second for up to ten seconds, on `ContinuousClock`, until it reports no
   lease and every fan cleared. A fan the helper has not cleared is a reason to send the request
   whatever its mode reads: the request carries the `restoreAbandoned` sweep, which is a
   stranded fan's only route out ([#189](https://github.com/blamechris/Aeolus/issues/189)).
   **If the first snapshot failed with the handshake still in force**, it sends the one request
   anyway and then reads again: the helper is identified and its state is inconsistent, which is
   what SAFETY.md § 7 says the panic verb must serve. If the snapshots keep failing it exits 8
   and names `fanctl reset --all`. A first snapshot that times out, or whose helper restarts
   under it, drops the connection and the handshake with it: nothing is sent, the exit is 1, and
   the message opens "No restore request was sent." and names `fanctl reset --all` (see the
   assumptions below).
2. **At most one restore per run.** It is never re-sent, whatever the reply was and however the
   wait ends. Another writer on the same fans would otherwise be answered with a second write, and
   then a third: the standing fight [ADR 0011](0011-reconciliation-and-foreign-manual-control.md)
   D2 declines.
3. **It never acquires a lease.** Not to make a per-fan form possible and not briefly.
4. **It may end any Aeolus client's lease, and names the holder.** Commands that move *toward* the
   safe state may override another client; commands that move *away* from it may not (`set` gets
   exit 5). Refusing would fail exactly when a hold was orphaned or forgotten, which is when
   someone runs this. The client whose lease ended sees its lease lost, which is accurate. The
   output says only what it observed — the lease listed before the request is no longer listed —
   because it may also have expired inside the window.
5. **A fan pinned by another program is reported, and `auto` exits non-zero.** It is never
   touched beyond the single restore; what that request reaches is the helper's decision, and
   `auto` inherits any change to it with no CLI change.
6. **No index.** `fanctl auto <index>` exits 64. No request the helper accepts returns one fan on
   behalf of another process, so an index would either do nothing or quietly return other fans
   too. A per-fan form can be added later without breaking anyone; the reverse cannot.

The check that decides the ending — **0, 8 or 9 from a snapshot sequence** — is one function
(`SafeState`), shared with `fanctl set` when it ends. `auto` adds exit 5 on top of it, because a
lease present at the end is worth naming; `set` maps that case as its own contract says.

### D3 — exit 0 means "the helper reports", and 9 means "waiting will not help"

Exit 0 means **the helper reports every fan cleared and no lease**. It does not mean the fans are
automatic: the helper reports an unreadable mode as automatic (#178). Every string `auto` prints
for a confirmation names the helper as its source and the time it captured the snapshot, and no
run that did not end in the safe state says it did on either stream.

**A fan is cleared when its mode reads automatic and its availability does not say otherwise.**
The availability is read for every fan, whatever its mode, and each reason is classified once, in
one exhaustive switch (`SafeState.clearance(of:)`) with no `default:` arm, so a reason added to
the vocabulary is a compile error until it has been decided. *2026-10-19:* the switch is now
`ManualControlAvailability.clearance` in `FanKit`, with `FanState.isClearedToAutomatic` beside it,
so the app shares the definition ([#153](https://github.com/blamechris/Aeolus/issues/153));
`SafeState.clearance(of:)` and `SafeState.isCleared(_:)` delegate to them, and the table is
unchanged:

| Class | Reasons | Effect |
|---|---|---|
| **Durable** | `foreignManualControl`, `restoreToAutomaticFailed` | **9**, whatever the mode reads. Waiting will not change it: nothing in Aeolus put the first there, and the firmware refused every attempt at the second. *2026-10-10:* on a plane that can write, the request includes the machine-wide restore ([ADR 0014](0014-apple-silicon-unlock.md) D5), which can return a foreign-held fan to automatic; how a durable refusal is then reported is [#351](https://github.com/blamechris/Aeolus/issues/351). |
| **Pending** | `releaseInProgress`, `handbackUnconfirmed`, `restoreToAutomaticUnconfirmed`, `supervisorBlind`, `systemSleeping`, `unknown(_)` | **8**, whatever the mode reads: the helper has not established the fan's mode, or a restore is outstanding. Keep waiting. |
| **Silent** | `writePathNotBuilt`, `boundsImplausible`, `leaseHeldByAnotherClient`, `selfRenewalNotBuilt`, `noThermalTelemetry`, `reclaimedBySystem` | The mode decides: automatic is cleared, anything else is 8. These are about manual control being *granted*, not about the fan. `writePathNotBuilt` is every fan on today's helper, and `auto` against it still exits 0; a lease is judged from `activeLease`, not from `leaseHeldByAnotherClient`. |

`.available` is silent. A fan whose mode reads manual is 8 unless its reason is durable.

**`supervisorBlind` is 8, not 9.** 9 asserts the fan is still held in a way retrying cannot
change. A blind fan's state is *unknown*, not manual — reconciliation can leave it blind for the
life of the process, but that is the helper not having looked, and the answer is the one 8
carries: the reason, its advice, and the helper restart that advice leads to.

A new code, **9, `cannotReturnToAutomatic`**: the helper reports a durable reason for a fan,
**whatever mode the fan reads**. That is the opposite of what 8 ("not yet") tells a script to do,
which is why it is its own number. The message carries the reason, its own summary and advice,
the mode the fan reads, and the `docs/RECOVERY.md` step.

| Code | Meaning for `auto` |
|---|---|
| 0 | The helper reports every fan cleared and no lease |
| 9 | A fan carries a durable reason (`foreignManualControl`, `restoreToAutomaticFailed`) |
| 5 | A lease is listed when the window ends |
| 8 | Not confirmed within the window, a pending reason, or the helper stopped answering after the request, or no snapshot could be read after a handshake |
| 3 | Helper unreachable |
| 7 | Version mismatch. The exempt restore is still sent once; the result cannot be verified across versions |
| 64 | Usage |

Precedence when several apply: **9, then 5, then 8.** 9 is judged at the end of the window rather
than on first sight, because a fan mid-handback can carry a transient reason that clears.

`--json` carries `capturedAt`, as `status --json` does, and `snapshotFollowsRestore`: whether
`fans` and `lease` were read after the request was sent, so a script need not parse prose to know
whether the document describes the helper before the request or after it.

### D1 — `set` is a bounded hold for the life of the process (decided; built in #317, held)

Recorded here so the three decisions read as one contract.

`fanctl set` requires `--for`, from 10 seconds to 8 hours, and holds its lease for that long,
renewing it for the life of the process **and its parent**. It exits 6 on any loss the helper
reports: a renewal error, a snapshot without its lease ID, a covered fan reclaimed by the system,
or a thermal emergency. It never retries and never re-acquires. When it ends it releases and runs
D2's safe-state check. The reasoning and the output contract are
[#317](https://github.com/blamechris/Aeolus/issues/317)'s.

**As built.** `set` is implemented against the simulated helper and **does not reach `main`
before E5 (#7) and the owner-supervised E4 acceptance (#9), per #15**; nothing here has driven a
fan. `main`'s helper answers every lease with `writePathNotBuilt`, so `set` against it exits 4 and
writes nothing. A helper built with the write plane **writes the fan**: since #465 the branch's
daemon holds a write channel on macOS 14 or later, its plane answers `.built`, and `set` against it
takes the lease, commands the speed and holds it (below macOS 14 it answers `writePathNotBuilt` as
`main`'s does). The points below are where building it had to decide something the contract
left open. Each is the direction that ends a hold earlier or reports less, never the one that
claims more.

- **The percentage mapping is `FanControlEnvelope.target(forPercent:)`**, once, in `FanKit`. The
  gate is `FanState.controlEnvelope == .success` for a percentage and an rpm alike; an rpm outside
  `[lowest, highest]` (`0rpm` included) is exit 2 and never clamped on the client.
- **A covered fan the snapshot no longer reports** ends the hold as a loss (6). The contract's
  list names `isReclaimedBySystem`; a fan that is simply absent cannot be called held.
- **Every ending and every loss releases the lease and checks the safe state.** The ordinary
  endings (`--for`, a signal, a parent that exited, a standard output that stopped draining) ran
  it from the first version. *Amended 2026-10-18, below:* so does **every outcome before
  `started` once `apply` has been sent** (an `apply` that was refused or got no answer, a lease
  that could no longer be shown to be held, a confirming snapshot that failed or showed no hold,
  a keeper that could not pace itself) and **every loss once the hold is under way** (a renewal
  refused, a snapshot that does not list the lease, a fan reclaimed or without a held target at
  a heartbeat, a thermal emergency). The first version skipped it for a loss and for a refused
  `apply`, on the assumption that there was nothing to confirm a return to and that the check can
  take its whole ten-second window against a thermal emergency that will not clear; both
  assumptions are withdrawn. **The one outcome before `started` that is not checked** is a signal
  that lands while `acquireLease` is in flight: the lease is released, no speed is sent, and the
  run exits 1 (*carved out 2026-10-31*, #438; the residual is in the 2026-10-18 amendment's
  point 2).
- **A lease still listed when the check ends is 8, not 5.** `auto` maps it to 5 to name the
  holder; for `set` the lease may be its own (the release did not take), and the message says
  whose it is.
- **A signal that arrives before the lease is taken is exit 1**, with nothing written to a fan.
- **`endedBecause` is `refused` for 2, 4 and 5 before a hold, and for an `apply` the helper
  answered with a fault only if the safe-state check that followed found every fan automatic and
  no lease**; `null` for 3, 7 and 1 before a lease: those are not a "no" to this request. An
  `apply` fault followed by anything else is `controlLost`, because "the helper said no" is then
  not known to be all that happened (*amended 2026-10-18*).
- **Standard output is written with `write(2)`, and never polled before a write.** A hold's
  failure to write is an ending, not a crash. (A first version polled pipes and sockets for room
  and wrote in chunks; "A write may park", below, is why that was withdrawn.)
- **No stderr output while holding in text mode.** There is no change during a hold that does not
  end it, so there is nothing for the contract's "changes to stderr" to carry.
- **An `apply` that got no answer is not a refusal** (review of #324). Only an `AeolusXPCFault` is
  the helper answering. A transport failure after the request was sent (`helperNeverAnswered`,
  `replyNotDelivered`, `helperRestarted`) means the speed may have been applied: the lease is
  released best-effort, the safe-state check **looks**, and the exit is the failure's own
  classified code (non-zero) unless the check found something worse, reported as `endedBecause:
  controlLost`. This revised the "refused `apply` skips the check" point above for the unanswered
  case; the 2026-10-18 amendment revises it for every `apply` fault, and gives the unanswered
  case a fault's exit rule: the check's verdict where that is worse (9, then 8).
- **A signal ends the hold, whenever it lands.** Before the lease it is exit 1 with
  `endedBecause: signal`; while `acquireLease` is in flight it releases the lease and sends no
  speed (exit 1, `signal`); while `apply` is outstanding it takes effect when `apply` returns and
  ends the run before `started` (*amended 2026-10-18*, below); while holding it is the ordinary
  signal ending.
- **A write may park; the hold never waits on it** (review of #324, which closed the case it
  found three times and found the next each time). On macOS `poll` calls a pipe writable at
  `PIPE_BUF` (512) bytes free and a `set --json` line is 560 to 1,127 bytes; a pipe at the
  system's pipe-memory ceiling is called writable while full and cannot grow; a terminal under
  XOFF parks a write; a pipe shared with another writer can lose the room it was promised. No
  check before a write holds, so `set` does not write: each line is handed to a `LinePump`, a
  writer thread of its own per stream, which may park in `write(2)` for as long as the kernel
  makes it. The hold never waits on it.
  - *A consumer that is not draining* is judged by the writer's **progress**: the oldest line
    handed over not completely written within 2 s, or a failed write, ends the hold as
    `outputClosed`. A stop request (signal, parent exit, deadline) is the reason whenever there is
    one and never waits on the writer.
  - *On every ending the lease is released and the safe state checked first.* Only then is the
    closing event handed over, and the run waits for each stream at most 1 s.
  - *The closing event goes to exactly one stream, whole:* standard output if it is idle (so at a
    line boundary), otherwise standard error as the same line. Standard output is never given an
    event to glue onto a fragment; both streams unable to take it within the bound means it is
    dropped and the exit code stands alone.
  - *Process exit abandons a parked writer thread.* That is deliberate. Bytes already written
    stay in the pipe, so standard output can end with an incomplete final line.
  - This replaces the first as-built description (chunks of `PIPE_BUF`, a `poll` between them, a
    2 s bound on the wait), which was right for the state the first review found and wrong for
    each state after it.
- **SIGPIPE is ignored for the length of each write**, not blocked on the writing thread: measured
  on macOS, the signal is raised at the process and delivered to another thread that has it
  unblocked, so a thread mask does not stop a multi-threaded command being killed by it.
- **`status` and `auto` write to the end.** A write that gave up on a slow reader, applied to
  every command, dropped a line whenever a pipe had under 512 bytes free while its reader was
  still there. EPIPE leaves their exit codes alone, and an inherited non-blocking descriptor
  (`EAGAIN`) is waited on with `poll` and retried, so "delivered whole" holds there too.
  `reset --all` does not use `Terminal`.
- **Each renewal is scheduled from the last one**, not from the end of the work after it, so a
  slow write shortens the next sleep instead of eating the two heartbeats the lease can miss.
- **After the release, only what was read after the release is described.** When the check read
  nothing, the text says the helper accepted the release and then stopped answering and that the
  state of the lease and the fans is unknown; `snapshotFollowsRelease: false` in `--json` says the
  same of the data.

*Amended 2026-10-18 ([#324](https://github.com/blamechris/Aeolus/pull/324), fix rounds 1 to 3).*
Two independent reviews of the carried `set` found that three things on `main` had changed underneath
it: [#414](https://github.com/blamechris/Aeolus/issues/414) let `apply` take up to 57 seconds for
one fan and 109 for two; level 6 (`LeaseApplier`) can engage a fan and then answer with a fault; and
[#426](https://github.com/blamechris/Aeolus/issues/426) states a fan's held target only when the
same snapshot shows the fan held. None of it was reachable on hardware while the branch's write
plane was unbuilt, as it was when this amendment was written.
[#465](https://github.com/blamechris/Aeolus/pull/465) has built it, so on the branch's helper
(macOS 14 or later) all of it is. Three rulings follow, each in the direction that ends a hold
earlier or says less.

1. **The lease is renewed from the moment it is asked for, a lapse is control lost, and a lapse is
   not a refusal.**
   - *The defect.* The helper's thirty seconds start at the grant (`LeaseAuthority`: deadline =
     grant + `timeToLive`). `set` took its first `renewedAt` only after `apply` **and** the
     confirming snapshot, so the first renewal landed ten seconds after those. An `apply` of 20
     seconds or more left no margin and one of 30 or more let the lease lapse in the middle of
     the `apply`. The helper restores automatic control when that happens, which is safe, but
     `set` then said "Holding … under lease X" over a lease that had ended (the `apply` was
     accepted, the lease lapsed before the first renewal), or "did not accept the speed" for a
     speed that may have been applied (`apply` answered `leaseExpired` once it found the lease
     gone).
   - *The ruling.* `LeaseKeeper` renews on the heartbeat from the first instant, **read before
     `acquireLease` is sent** (never after its answer: the grant is no earlier than the send, so a
     schedule from the send is never later than the helper's own clock), for as long as `apply`
     and the confirming snapshot are outstanding. `renewLease` is not sequenced behind `apply`
     (`HelperMessage.sequenced`), so a renewal sent now is answered now. When both are answered,
     the keeper is stopped **and any renewal on the wire is waited for** before anything is
     released or the hold's loop starts, and the loop takes the keeper's `renewedAt` as its own.
     There is one schedule, and no renewal is sent after the release. Only the keeper's wait is
     cancelled, never a call in flight: a cancelled task's XPC call can fail at once for no reason
     the helper gave. The first renewal that fails is final; nothing retries.
   - *A lapse is control lost.* A renewal that failed while `apply` was outstanding, or `apply`
     answered `leaseExpired`, `leaseUnknown` or `leaseNotHeldByThisConnection`, is **control lost,
     in its own words**: "Control was lost before the hold began", never "refused" and never "did
     not accept". `endedBecause` is `controlLost`. The lease is released and the safe state
     **looked at**. The exit is 6, or 9 or 8 if the check found something worse.
   - *What the text claims.* That control of the lease "could no longer be shown to be held", and
     not that the lease **ended**: nobody saw an end (a reply that is not delivered leaves the
     lease live, and a renewal still in flight leaves it unknown). It then states what was seen,
     in order (the renewal that failed, what `apply` said, what the snapshot after it showed),
     and, after the release, the check's verdict and nothing else about the fans.
   - *Words that are not quoted.* `leaseExpired`'s own description says the fans "have returned
     to automatic control" and tells the client to acquire a new lease; `helperRestarted`'s says
     any manual control "ended with it; ask for the fans again"; `helperNeverAnswered`'s and
     `connectionAbandoned`'s say the helper "returns those fans to automatic control when it
     handles that". Nothing here observed any of that (`CLAUDE.md` rule 6), and a run that never
     re-acquires has no use for the advice. `set` says what it saw instead ("The helper answered
     that the manual-control lease had expired."; "The connection to the helper was interrupted
     while the request was in flight."), in a lapse, in an unanswered `apply` and in a renewal
     refused during the hold.
   - *A renewal that failed takes precedence.* If the keeper recorded a failed renewal while
     `apply` was outstanding, that is the diagnosis whatever `apply` then said, and the text
     states both facts. A renewal that times out makes the client give up the connection
     (`HelperClient`), and the `apply` in flight is then answered `connectionAbandoned`: judged
     first, that is "`apply` got no answer", exit 1 if every fan is automatic, and the renewal is
     never mentioned.
   - *A signal during `apply`.* It is remembered and cannot cut `apply` short: releasing the lease
     under an `apply` that is working is a design change this contract does not make. The wait is
     bounded by `apply`'s own deadline. When `apply` returns, a pending signal ends the run
     **before `started`** (release, check, an ordinary ending with `endedBecause: signal`), so
     "Holding" is never said to a person who has already asked to stop; and if the run ends in
     any other way, the signal stays in the report (`signal` is not null) and in the text. The
     text says the hold was not begun, not that it ended, and that the signal landed "while the
     speed was being applied or confirmed": the pending signal is looked for once `apply` and the
     confirming snapshot are both answered, so it may have landed during either (#438).

2. **Every outcome before `started` once `apply` has been sent is followed by a release and the
   safe-state check.** (This point said "every outcome before `started`" until #438; the one it
   never covered is carved out at its end.)
   - *The defect.* Every `AeolusXPCFault` from `apply` skipped the check, on the assumption that a
     refused `apply` had changed nothing. Level 6 can engage fan 0, fail on fan 1, have the undo
     refused and still answer only the original fault, and a release whose restore is refused is
     still answered "accepted". `set` then said "Nothing is held" and exited 1 without reading a
     snapshot, where exit 9 and its recovery advice exist for exactly this. The same goes for
     `thermalEmergencyActive` after every fan was written.
   - *The ruling.* After **any** `apply` fault, release, then the check `apply`'s unanswered case
     already ran. The exit is the check's verdict where it is **worse** (9, then 8) and otherwise
     the fault's own code. The words "did not accept the speed" are said, and `endedBecause` is
     `refused`, **only if the check found every fan automatic and no lease**. In every other case
     the text says the answer does not settle what happened to the fans, and `endedBecause` is
     `controlLost`.
   - *The unanswered `apply` follows the same rule.* It may have engaged a fan exactly as a
     refused one may, so the operator gets exit 9 and its recovery advice in both cases: the
     exit is the check's verdict where that is worse (9, then 8) and otherwise the failure's own
     classified code. `endedBecause` is `controlLost` either way. A failure that classifies to 3
     (the helper unreachable) is therefore usually 8, because the check cannot read either.
   - *So does everything after an **accepted** `apply` that is not yet a hold* (fix round 2): a
     confirming snapshot that cannot be read, one that `loss(in:)` rejects (a fan with no held
     target, a lease not listed, a thermal emergency), and a keeper that could not pace the
     heartbeat. These went to the hold's loss path, which releases and exits 6 **without** the
     check, and said "Nothing is held by this process now". The failure that matters is the one
     the first hardware run is most likely to meet: the fan is engaged, the first snapshot reads
     its mode as automatic (the mode-register lag this ADR predicts), the release is answered
     accepted and its restore is refused. The operator must get exit 9's recovery advice, not a
     6 and "nothing is held". All three are now "control lost before the hold began": released,
     the check looked at, exit 6 or the check's verdict where that is worse, and "Nothing is held"
     is not said unless the check confirmed it. A keeper that cannot pace itself is 6 here (it was
     1): control could no longer be shown to be held.
   - *And so does every loss once the hold is under way* (fix round 3): a renewal refused, a
     snapshot that does not list the lease, a fan reclaimed or without a held target at a
     heartbeat, a thermal emergency, and the hold's own timer failing. This **reverses** the
     original point that "exit 6 skips the safe-state check", and the reason is the same as for
     B1 moved into the hold: a fan is engaged, the release is accepted, its restore is refused,
     and `set` said "Nothing is held by this process now" while the fan stayed pinned. That is a
     claim nothing observed (`CLAUDE.md` rule 6), made by the tool the first hardware run relies
     on. The exit is 6, or the check's verdict where that is worse (9, then 8); the hold's own
     timer is 1 in the same way. **"Nothing is held" is no longer said at all:** the only
     confirmation is the check's own sentence, in the helper's voice. The original reason for
     skipping the check against a thermal emergency, that it would spend its ten-second window,
     does not hold: waiting costs the fans nothing, because § 3 is driving them either way, and
     an honest 8 or 9 is worth ten seconds. During an emergency the text says, in the helper's
     voice, that the helper reports its thermal protection, not this run, in control of the fans
     (its evidence is the emergency flag alone, and an emergency that clears inside the check's
     window leaves every fan automatic, #438), and what the check saw.
   - *Carved out: a signal while `acquireLease` is in flight* (#438, ruled 2026-10-31). A signal
     that lands while the lease is on its way releases the lease when it comes back, sends no
     speed, and exits 1 with "Nothing was sent to a fan" and `endedBecause: signal`, **without**
     the safe-state check (`SetCommand.perform`; `docs/CLI.md`). The ruling keeps it so, on three
     facts. Nothing was sent to a fan, so nothing this run did can have engaged one. The helper
     read each covered fan afresh at the grant and refuses one in manual that Aeolus does not
     hold (`LeaseAuthority.refuseIfForeignManualControl`), so the fan was automatic at the grant
     as far as the helper could read it. And a fan whose handback the helper gives up on is
     refused to the next grant with `restoreToAutomaticFailed` (`LeaseAuthority.acquireLease`), so
     the next `set` gets exit 4 with the reason.
     **The residual.** `LeaseAuthority.releaseLease` restores the covered fans whether or not an
     `apply` was sent, and that restore can be refused. If it is, this run has already said
     "Nothing was sent to a fan" and exited 1, which is true of this run and silent about the
     helper's restore: the fan's `restoreToAutomaticFailed` is first reported by the next `fanctl
     status`, `set` (exit 4) or `auto` (exit 9), never by this run's exit 9.

3. **"Holding" needs the helper's evidence that the fan is held.**
   - *The defect.* `loss(in:)` checked the lease ID, a thermal emergency, missing fans and the
     reclaimed flag, but neither mode nor `targetRPM`. A snapshot that lists our lease while the
     fan reads `automatic` with `targetRPM: nil` (the firmware took it back, and the reclamation
     watchdog has not marked it yet) gave `started` and then `holding` every ten seconds, and a
     test held that to be right.
   - *The ruling.* `started`, and each `holding`, require that **every covered fan carries the
     helper's held target**: `targetRPM` non-nil and positive. #426 sets it only when the same
     snapshot shows the fan in manual under the live lease, with no reclamation and no thermal
     override. At the confirming snapshot, a covered fan without one is control lost before the
     hold began (released and checked, as above); during the hold it is a loss and ends the hold
     with `controlLost`. The mode is still never read on its own: the held target
     is what says what the mode cannot (#178).
   - *Freshness: the snapshot `set` reads after `apply` cannot predate the engagement, so the
     first one decides.* A snapshot is a fresh round trip with nothing cached on the client
     (`HelperClient`'s own documentation). `snapshot` and `apply` are both in
     `HelperMessage.sequenced`, and the helper's `MessageSequencer` starts a message only after
     the one before it has returned and its reply block has been called, so the helper begins
     reading after `apply`'s reply, and `set` sends it only after that reply arrives.
     `ReadOnlyFanAuthority.observe()` reads each fan's `F<n>Md` and every sensor afresh for each
     snapshot (its cache "holds metadata only"), and stamps `capturedAt` after those reads.
     `LeaseApplier` replies only after each fan's step has engaged it (a plane step is "a fresh
     key info, the write, and its read-back"), § 5 has recorded the target, and the lease and § 3's
     latch have been checked again. So there is no snapshot that is older than the engagement and
     answers it. The snapshot carries `capturedAt`, the helper's **wall-clock** `Date`, and no
     sequence number; `set` does not compare it with anything, because a step in the wall clock
     would then decide whether a hold is confirmed, which is what this contract refuses for its
     deadline.
   - *What remains, and what it would change.* A completed write that the firmware's mode
     register does not yet reflect on the next read would show as "not held", and `set` would end
     with exit 6: the safe direction, and a false negative that would be visible. The record the
     held target comes from is "a confirmation only once B1's command turn reads the target back"
     (`HeldTargetReport`), and since #465 that turn does: `SMCWriteTurns.command` writes
     `F<n>Tg`, reads it back in the same turn, and throws `targetNotConfirmed` outside
     `ReclamationLimits.targetToleranceRPM` (`writeTarget`). That confirms the target register. It
     does not confirm the mode register, which is what the paragraph above is about, and the
     read-back says nothing about `F<n>Md` lagging it. No write has been performed on hardware by
     this branch, so this is **unobserved**.
     If the owner-supervised E4 acceptance sees it, the remedy is a bounded wait in
     `SetCommand.establish` for a snapshot that shows every covered fan held (a window of two
     supervisor cycles plus the snapshot's age), ending as "the helper accepted the speed, but no
     snapshot showed the fan held", release, check, and exit 6 or worse. It would not be a client-side
     sequence number. The reliance on ordering is held by `HelperClientSequencingCensusTests` (the
     census of sequenced messages) and by `FanctlSetRenewalTests`, which asserts the confirming
     snapshot follows `apply`'s answer.

The tests that hold these are `FanctlSetRenewalTests` (virtual time, with a simulated helper whose
leases have a real lifetime), `FanctlSetLostBeforeHoldTests`, `FanctlSetApplyFaultTests`,
`FanctlSetLapseWordingTests`, `FanctlSetSignalDuringApplyTests`, `FanctlSetHeldTargetTests` and
`SetLossTests`. The simulated helper keeps a lookup of a lapsed lease (refused `leaseExpired`,
nothing changed, as `LeaseAuthority.heldLease` does) apart from the sweep that takes the lease and
returns its fans; it has no supervisor to run one at the deadline, so a test calls
`sweepExpiredLeases()` where it wants one to have run.

## Rationale

The cheapest correct answer to "make it automatic" is the one `reset --all` already sends. What
this ADR adds is not a new capability — `auto` can do nothing `reset --all` cannot — but an
*observation*, and the discipline to report only what was observed.

The asymmetry in D2.4 is what makes the command usable. A hold that cannot be dropped by the
person who needs the fans cool is not a safety feature; it is the failure SAFETY.md § 7 exists to
prevent. Overriding another client's lease costs that client its hold, which it is told about, and
which the lease's own expiry would have cost it anyway.

## Alternatives considered

### Per-fan: acquire a lease, apply `.automatic`, release

Rejected. It reaches only fans that are already automatic: a manual fan with no lease is refused
at acquire (`foreignManualControl`, `restoreToAutomatic{Unconfirmed,Failed}`,
`handbackUnconfirmed`, `releaseInProgress`), and a fan under another lease answers 5. Releasing an
automatic fan then writes a restore to every fan the lease covered, which can push it into
`restoreToAutomaticUnconfirmed` or the terminal `restoreToAutomaticFailed`. It is a command that
works exactly when it is not needed.

**Revisit if** the protocol gains a verb that returns one fan on behalf of another process.

### `auto <index>`

Rejected for now, by D2.6. **Revisit if** a per-fan verb exists on the wire; the exit-64 refusal
is what keeps that change compatible.

### Refuse with exit 5 when another client holds a lease

Rejected. `auto` would fail when a hold was orphaned or forgotten, and succeed only when no one
needed it. [SAFETY.md § 7](../SAFETY.md#7-panic-path) and the asymmetry in ADR 0011 D1 both put the
direction on the side of moving toward automatic control.

### Re-send the restore until the helper confirms

Rejected, by D2.2. A write repeated against a live writer is a fight, and the fight is over the
machine's cooling.

### Exit 0 on the mode alone

Rejected, and it was the first version. The mode is `automatic` for a fan nobody has read (#178)
and for every fan on Intel, while the availability says what the helper has not cleared; reading
the mode alone exits 0 about such a fan, and on the first snapshot sends no restore, which is
that fan's only route out. D3 reads both.

### Exit 0 only when the mode was actually read

Only partly buildable. The wire cannot say "not known" about a mode until #178 lands, but it does
say it about the fan in two places: `supervisorBlind` ("cannot read this fan's control state") and
the other pending reasons, which D3 reads. What remains unbuildable is a fan whose mode could not
be read with *no* reason beside it. **Revisit when** #178 changes the snapshot: exit 0 can then
be strengthened, and a fan whose mode could not be read can be given its own outcome.

> **Note, 2026-10-15 (#355).** One case this section relied on is gone. Since #355, § 5's
> blindness no longer produces `supervisorBlind` on the wire: § 5's ledger is reported as a
> fact, not an availability. So a fan § 5 gave up blind that is *still* unreadable reads
> `automatic` with `available` beside it, and on a plane that can write `auto` would exit 0
> without sending its restore: the outcome "Exit 0 on the mode alone" rejects, reached by a
> residue this section accepted only while a reason sat beside the fan. It is tracked as
> [#360](https://github.com/blamechris/Aeolus/issues/360), which must close before A6. *Closed on a
> helper that can write by the amendment below.*

*Amended 2026-10-15 ([#360](https://github.com/blamechris/Aeolus/issues/360)).* On a helper that
can write, the remaining case is built. A fan whose mode did not read on a snapshot carries
`supervisorBlind`, the grant's own reason, unless Aeolus is accountable for it. A fan Aeolus is
accountable for is either leased, which `auto` judges from `activeLease`, or in a handback register,
which carries its own pending or durable reason. So on such a helper, exit 0 means every fan's mode
was read on the last snapshot. On a `.notBuilt` helper, every build on `main`, the gap stands, and
#178 owns it.

### `supervisorBlind` as 9

Rejected. It can last the life of the process, but 9 asserts the fan is held in a way retrying
cannot change, and a blind fan's state is unknown. 8 with the reason, its advice and the restart
is the honest answer. **Revisit if** the helper gains a way to tell "blind for a moment" from
"blind until restart"; the latter might deserve 9.

### One code (8) for everything unconfirmed

Rejected. A script retries on 8. Retrying a fan that another program holds, or that the firmware
refused, is a loop that changes nothing; 9 is how a script learns to stop.

### A longer or open-ended window

Rejected. A command that waits for a helper which may never answer is one a caller has to
time-box from outside. Ten seconds covers the restore's expected latency. **Revisit when** E4
hardware rows measure the restore's real latency.

## Consequences

- **`reset --all` is unchanged**, including its exit codes (0 or 1) and its refusal to say the
  fans are restored. `auto` sends the same verb and then verifies; it adds no capability.
- **The client whose lease the request drops sees exit 6**, in `set`'s terms. That is accurate,
  and the holder's name is on the terminal of whoever sent the request.
- **A restore that lands late is reported as 8**, with the one request already sent. A script that
  wants to wait longer polls `fanctl status`.
- **`auto` and `set` cannot disagree about "confirmed"**, because there is one function.
- `AeolusXPCVersion` does not move, and nothing in `Sources/AeolusHelper` or `SMCCore` changes.
- Exit-code 9 is a public number from this ADR on, and is never reused.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| The helper ends every lease and attempts every fan it is accountable for when it takes `restoreAllToAutomatic` | `LeaseAuthority.releaseEveryLease` and SAFETY.md § 7, as built. *2026-10-10:* on a plane that can write, the request also includes the machine-wide restore ([ADR 0014](0014-apple-silicon-unlock.md) D5), which can return a foreign-held fan to automatic; how a durable refusal is then reported is [#351](https://github.com/blamechris/Aeolus/issues/351) | `auto` reports what is left, as 5, 8 or 9. No CLI change. |
| Ten seconds covers the restore's visible latency | Not measured. No restore has been performed on hardware | Raise the window, or `auto` reports 8 for a restore that was working. |
| `foreignManualControl` and `restoreToAutomaticFailed` are the only durable reasons, and the pending and silent classes above are right | `ManualControlAvailability`'s own documentation, and the classification decided on review of #321 | A new reason is a compile error in `ManualControlAvailability.clearance` (`SafeState.clearance(of:)` until 2026-10-19, #153), and has to be decided there. |
| The helper's `mode`, read beside the availability, is the best statement of a fan's state | `mode` alone is not (#178); the availability is the other field. *2026-10-15:* on a helper that can write, an unread mode is stated by the availability (#360) | #178 gives the wire a way to say "not known", and exit 0 is strengthened. |
| A snapshot that fails after a successful handshake is the helper's state being inconsistent, and the request is safe to send | SAFETY.md § 7; the request needs no snapshot | `auto` would send a request the helper cannot act on, and exit 8. |
| A first snapshot that fails with the handshake still in force proves the helper is identified; one that times out, or whose helper restarts under it (XPC 4097), does not | `HelperClient.translate` discards the connection on `helperNeverAnswered`, and `connectionWasInterrupted` clears the negotiated handshake on 4097; either way `negotiated` is `nil` afterwards | Those two cases send nothing and exit 1; the message opens "No restore request was sent." and tells the user to run `fanctl reset --all`. Unchanged unless the client keeps the evidence. |
| Another client's lease may be ended by a command moving toward automatic | The maintainer's decision, D2.4 | `auto` would refuse with 5 and fail when a hold was orphaned. |

Every observation cited is from `Mac16,5` on macOS 26.6.2, and none of it is a fan write: no
restore has been sent to hardware by this command. Intel and M1/M2 are `untested`.
