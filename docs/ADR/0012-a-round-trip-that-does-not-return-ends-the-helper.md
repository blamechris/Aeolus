# ADR 0012 — A round trip that does not return ends the helper

- **Status:** Accepted (2026-10-08) — D provisional pending [#296](https://github.com/blamechris/Aeolus/issues/296) conditions 3–4 and E4's write-selector measurement
- **Date:** 2026-09-20 (amended 2026-10-08, 2026-10-18 and 2026-10-31; see the amendments at the end)
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s helper-death recovery;
  answers [#293](https://github.com/blamechris/Aeolus/issues/293) and
  [#135](https://github.com/blamechris/Aeolus/issues/135)'s open questions 2 and 3)

## Context

`SMCConnection` is an actor that calls `IOConnectCallStructMethod` synchronously inside
itself (`Sources/SMCCore/SMCConnection.swift`), and one connection serves every helper read
and write (`HelperComposition`, per [ADR 0006](0006-single-smc-reader.md)). A round trip
that never returns holds the actor for good:

- § 3 cannot read a temperature, and § 5 cannot read a mode.
- `ConnectionHealth` counts nothing, because it only sees outcomes that complete. Its
  `reconnect()` runs `close()`/`open()` on the same actor, so it queues behind the wedge.
- The SIGTERM teardown (`Sources/AeolusHelper/Lifecycle/SignalTeardown.swift`) awaits
  `releaseEveryLease()` and then the keystone. Both queue behind the wedge, so the orderly
  exit never arrives.

Nothing in Swift concurrency can time out a synchronous call. This is harmless while the
plane answers `.notBuilt`. It becomes a safety property once E3/E4 can grant a lease. No
wedge has been observed: #68 ran 10,570 ticks with no hang.

What waits on [#296](https://github.com/blamechris/Aeolus/issues/296) is the value of D.
The Decision's ordering (the watchdog lands before E3 and is a precondition of any lease
grant on a build with a write path) does not depend on any H1 result, because latency
over healthy reads cannot show whether a call can wedge.

## Decision

**If the helper cannot complete an SMC round trip within D, or a safety cycle within
D_cycle, it logs one `.fault` and exits non-zero through the single exit seam
(`TeardownExit.process`), as a new `TeardownOutcome.blind`.** launchd then restarts it,
and startup reconciliation ([ADR 0011](0011-reconciliation-and-foreign-manual-control.md))
restores automatic control **if its pass reaches its keystone**; the amendment's "What the
ending buys, and what it does not" says where that stops being true. The restart relies on
`KeepAlive = { SuccessfulExit = false }`, which lands in the order ADR 0007 sets. Nothing in the
process abandons a round trip, times one out, or reopens the connection.

Detection runs on a timer on a dispatch queue the watchdog owns. It reads round-trip stamps
(sequence, key, selector, and an age on the suspending clock), published under a lock,
without an actor hop.

- D is a constant, set from a measured per-round-trip maximum.
- No message or configuration can disarm D or lengthen it.
- The watchdog is armed before reconciliation's first read and stays armed through
  teardown (the round-trip trigger alone; see I6).
- It lands before E3, and is a precondition of any lease grant on a build that has a write
  path.

### Invariants

*I1, I3, I4, I5, I6, I7 and I8 are amended, and some rows of the table below are superseded: read
them with the 2026-10-08 amendment at the end of this document.*

1. **I1.** Every helper round trip is stamped. The stamp is taken on the calling thread
   immediately before `IOConnectCallStructMethod` and cleared in a `defer`. It lives in
   state that can be read without entering `SMCConnection`.
2. **I2.** The watchdog runs on a `DispatchSourceTimer` on a queue it owns. It never awaits
   an actor. The lock it reads is never held across an IOKit call.
3. **I3.** Age is measured on `SuspendingClock`, so a call in flight across a sleep does not
   age. A verdict needs the same in-flight sequence number on two ticks.
4. **I4.** Three triggers:
   - A round trip in flight for longer than D.
   - No completed § 3 cycle for longer than D_cycle. This one is armed only while the
     supervisors run.
   - A gate waiter past #135's bound. This raises `.fault` only.
5. **I5.** A verdict logs one `.fault` naming the key, the selector and the age. It then
   terminates through `TeardownExit.process` with a non-zero `.blind`. This path runs no
   orderly teardown and makes no IOKit call. The first terminate wins.
6. **I6.** The watchdog is armed before reconciliation's first read, and stays armed
   through the orderly teardown. (Amended: through the teardown only the round-trip trigger
   is armed, because stopping § 3 ends the cycle trigger, and a teardown restore with a
   single round trip longer than D is therefore cut off; see H6.)
7. **I7.** Nothing is abandoned in-process. Nothing resumes the caller of a round trip that
   has not returned. Nothing closes or opens the connection while another round trip is
   stamped in flight. (The amendment stamps `IOServiceOpen` and `IOServiceClose` themselves,
   so "a round trip" would have contradicted I1.)
8. **I8.** D is a constant. No XPC message and no configuration can disarm it or lengthen
   it. The amendment extends this to every bound the watchdog applies: D_cycle, D_bringUp,
   G, the tick, and the rule that a verdict needs two consecutive over-bound ticks.

### Tests, each with the mutation that must turn it red

| Test | Mutation that must turn it red |
|---|---|
| `aWedgedRoundTripEndsTheProcessNonZero` | Delete the `terminate` call. Separately, map `.blind` to exit code 0. |
| `continuousShortRoundTripsNeverTrip` | Drop the same-sequence check. |
| `aRoundTripSpanningSleepIsNotAWedge` (the comparer mints the instant) | Swap in `ContinuousClock`. |
| `theWatchdogNeverEntersTheConnectionActor` (the actor is really blocked on a semaphore, not a mock that only suspends) | Read the stamp through an actor hop. |
| `theStampBracketsTheIOKitCall` | Take the stamp after the call. (Amended: see the PR A table at the end.) |
| A tripwire: exactly one `IOConnectCallStructMethod` site, source normalised before matching | Add a second call site. |
| `theWatchdogIsArmedBeforeReconciliationReads` | Arm it after `reconcileFans()`. |
| `aWedgedTeardownEndsBlindExactlyOnce` | Remove the first-terminate-wins guard. |
| The existing exit-count tripwire | Have the watchdog call `exit` directly. |

## Rationale

Process death is the only abandonment that **can be** ordered. The argument rests on two
assumptions from the table below, neither yet observed on this machine. First, a task is
fully reaped only after its in-flight kernel calls have unwound. Second, launchd starts no
successor until that reaping is complete (H2). If both hold, whatever the wedged call does
happens before the next reconciliation reads the mode keys. If either fails, the ordering
argument fails with it, and the table says what to revisit. A false positive ends the helper, and the successor's reconciliation puts the fans back to
automatic once its pass reaches its keystone, which is the safe direction. The recovery it triggers
already exists and is tested; a wedge that outlives the restart is the case it does not cover
(see Consequences).

## Alternatives considered

### Run the round trip on an abandonable thread, with a deadline, and reopen

This is the strongest alternative. It keeps leases alive through a wedge that is confined
to one handle, it costs no restart, and the helper keeps answering clients throughout.

It is rejected because its failure modes are worse than the ones it removes:

- **An abandoned write can land at any later time.** That might be after the helper has
  restored the fan, released it, or granted a new lease on a new handle. The result is a
  pinned fan that nothing tracks, a silent breach of hard rule 6.
- **Abandonment cannot close the old handle.** `IOServiceClose` with a call in flight is an
  unspecified race inside the user client. So every wedge leaks a thread and a port.
- **The reopen may wedge too.** If the wedge is in the driver's single coprocessor mailbox
  rather than in the handle, every reopen wedges again.
- **Its gain is capability, not safety.** A false positive (abandoning a write that was
  just slow) fails in the unsafe direction.
- **It is costly to reverse.** It needs connection generations throughout `SMCCore`, which
  `fanctl` and the app share, and every caller must handle an abandoned result.

**Revisit if** hardware shows wedges that are frequent and transient enough that restarts
become a cost users see. Even then, apply it to reads only, never writes.

### Both, with a last-gasp keystone on a fresh handle before the exit

This covers one case the decision does not: a wedge on one handle combined with an exit
that cannot complete. It is rejected for now for two reasons. It adds a second write path
that bypasses [ADR 0009](0009-precedence-at-the-write.md), and a leaked earlier write can
still land after it. **Revisit if** evidence shows that exits hang while a round trip is in
flight.

## Consequences

- **A wedge drops every lease.** The user sees the helper restart and manual control end.
- **A recurring wedge produces a throttled restart loop of a root daemon, and a loop is not
  a recovery.** Each new process's reconciliation hangs on a read in the same driver, so the
  **round-trip trigger** ends it about D + 1–2 s after that read began (the bring-up trigger
  covers only a stall that is not a stamped round trip), launchd throttles the next start, and
  **nothing restores a fan until the driver answers.** This ADR does not claim that every
  iteration ends in the safe state. What it accepts is that no pass of the loop writes
  anything: each is ended at a read, before the restore, and a fan the driver will not answer
  for is left as it is.
- **A restart is not guaranteed.** Where launchd is itself removing or stopping the job — a
  bootout, `SMAppService.unregister()`, a shutdown — exit code 2 is not followed by a start,
  and nothing restores the fans.
- **The orderly teardown is bounded by D.** Only the round-trip trigger stays armed through
  it (stopping § 3 ends the cycle trigger: a stopped supervisor is not a stall), so a teardown
  restore in which any single round trip takes longer than D is cut off mid-restore. D is
  confirmed for reads only; see H6.
- **Exit codes:** `TeardownOutcome` gains a non-zero case. The exit-count tripwire stays at
  one.
- **#135:** its observer is the `.fault` from the gate-level trigger, built as PR C of #329
  (see "The gate trigger, as built").
- **[#292](https://github.com/blamechris/Aeolus/issues/292):** keeps handling "returned
  with an error" through `ConnectionHealth`, and never tries to detect "did not return".
  D applies per round trip, never per walk: a 25 s contended walk is not a wedge.
- **[#295](https://github.com/blamechris/Aeolus/issues/295):** may read back on the
  teardown path, because D now bounds that read. ADR 0007's rule that nothing is read ahead
  of the keystone still holds. So § 3 deregistration is **deferred** to a read after the
  keystone, not read inline: staying registered longer is the safe direction.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| launchd starts no successor until the old process is fully reaped | Documented kernel and launchd behaviour, not yet observed here (H2) | The ordering argument fails, and a late write could follow reconciliation. Revisit. |
| A process with an IOKit call in flight can finish exiting | Unknown. It cannot be measured without a real wedge. | The last-gasp keystone alternative becomes worth its cost. |
| Manual mode persists after the writer dies | Reported in SAFETY § 6. Verify at E4 (H3). | If firmware reverts on client close, this ADR gets cheaper. No change needed. |
| Per-round-trip latency stays at least 100× below D, under contention and in dark wake | To be measured on `Mac16,5` (H1). **Partly measured, 2026-10-07, on macOS 27.0.1:** idle, and contended by one and by three concurrent `fanctl` walkers, reads only. The worst round trip was 11.45 ms, so 100× is 1.15 s and the expected D of about 5 s is about 437× that maximum. **Not yet measured:** dark wake and the first read after wake. D is set provisionally at 5 s (see the amendment). | Raise D, or false positives will cost users their manual control. |

## To measure on Mac16,5 before relying on this (hypotheses, not facts)

- **H1 (sets D).** Per-round-trip maximum and p99.99 latency in four conditions: idle,
  during a contended `fanctl` walk, during failing dark-wake reads, and on the first read
  after wake. The expected D is about 5 s.

  **Partly measured, not complete.** One session on `Mac16,5` on 2026-10-07, on macOS
  27.0.1 (26A434), with `smc-sampler --latency` on `SuspendingClock` and a maximum over
  reads of every status. The full record is in [SMC-RESEARCH.md](../SMC-RESEARCH.md), under
  "Per-round-trip SMC latency on Mac16,5 — idle and contended (issue #296)".

  | Condition | Reads | p99.99 | Maximum |
  |---|---|---|---|
  | 1. Idle, paced at 50 ms | 12,000 | 10.025 ms | 11.453 ms |
  | 1b. Idle, back to back | 100,000 | 1.755 ms | 4.332 ms |
  | 2. Contended: back to back beside one `fanctl sensors` loop | 400,000 | 2.359 ms | 11.330 ms |
  | 2b. Contended: back to back beside three `fanctl sensors` loops at once | 400,000 | 3.662 ms | 10.071 ms |

  No read failed in any run, and no slow or hanging call was observed. The worst round
  trip was 11.453 ms (condition 1; 11.330 ms under contention), so 100× is 1.15 s, and the
  expected D of about 5 s is about 437× it. **Provisionally, D must be at least 1.15 s on
  this evidence, and the expected 5 s is not contradicted. That is a lower bound from two
  of the four conditions, not a value for D. When it was taken D was not set; the
  amendment at the end of this document sets it, provisionally, at 5 s.** Every figure is an
  upper bound on the round trip: the timed span includes the Swift around the call and the
  task's wake-up. Condition 1's p99.99 is its second-largest read, one event, not a tail
  estimate.

  **Still missing.** Conditions 3 and 4 (failing reads in a dark wake, and the first read
  after wake) need one attended lid close, and have not been taken. Dark wake is the
  condition in which reads were already seen to fail (the 34-key critical read, #210).
  The numbers above are reads only, so a write selector's latency is still unmeasured. H2
  below is not run. #296 stays open for all of these.

  **Disagreement with #296's premise.** #296 says contended walks "have measured
  22–24.9 s here". A `fanctl sensors` walk took about 1–2 s in this session, and each of
  three concurrent walks took about 2–3 s, so contention among `fanctl` processes does not
  by itself explain the figure. The repository's history records 22–24.9 s in test-suite
  comments about the helper's discovery walk with other walks running concurrently (and,
  copied from them, in a source constant and the sampler README). The most likely reading,
  which is an inference and not something the
  history states, is that no `fanctl` walk was ever measured at that length. Which factor
  accounts for the gap is not established: a debug build, an OS change (the 22.0 s figure
  was recorded on 26.6.2; the OS of the 24.9 s figure, committed 2026-08-02, is not
  recorded), the helper's own discovery path and host load all remain candidates. Conditions
  2 and 2b approximate the original workload and do not reproduce it. This ADR's rule that
  D bounds a round trip and never a walk does not depend on the figure. The evidence is in
  SMC-RESEARCH.md.
- **H2.** `kill -9` the helper during a walk. It should die promptly, and the successor
  should start only after the old process is reaped. **Not run:** it needs an installed
  helper.
- **H3 (E4).** After the writer is killed, `F<n>Md` and `Ftst` stay manual.
- **H4.** How quickly launchd restarts a non-zero exit after a long uptime.
- **H5.** Whether launchd's SIGKILL follows `ExitTimeOut` when the teardown is parked.
- **H6 (E4).** The latency of each round trip in a **teardown restore**, as well as in a
  supervised write. The orderly teardown stays armed for the round-trip trigger alone, so a
  restore in which any single round trip exceeds D is cut off by the watchdog before it
  finishes. The first supervised E4 write must record its per-round-trip latency *including a
  teardown restore*, and D is raised, or the restore split, if it does not clear D with margin.
- **Not measurable here:** whether a wedge is confined to one handle or covers the whole
  driver, and whether the kernel wait can be interrupted.

Every observation cited is from `Mac16,5`. Those made before 2026-10-07 were on macOS 26
(26.6.2 where the OS is recorded; it is not recorded for every early figure, such as the
24.9 s walk); #296's measurements (H1) are on macOS 27.0.1 (26A434). Intel and M1/M2 are
`untested`.

## Amendment (2026-10-08, [#329](https://github.com/blamechris/Aeolus/issues/329)) — accepted, the constants, and the corrections

**Status.** Accepted. Two things were decided on 2026-10-08, and they are different decisions.
The **ordering** — the watchdog lands before E3 and before any lease grant on a build with a
write path, the supervised E4 experiment ([#9](https://github.com/blamechris/Aeolus/issues/9))
included — was the owner's, recorded on
[#293](https://github.com/blamechris/Aeolus/issues/293). This **amendment**, and the split of the
work into three pull requests (the stamp, the watchdog, the #135 gate trigger), was decided on
architect review.

**The constants below were corrected on architect review of
[#331](https://github.com/blamechris/Aeolus/pull/331), the pull request that carried this
amendment.** The first draft had D_cycle = 2·D = 10 s, G = D and D_bringUp = budget + D_cycle.
Its derivation of D_cycle took 256 round trips as the worst a cycle can wait, a figure with no
source in the tree; the review replaced it with the scheduler's own turn rules (below), which
moves D_cycle to 15 s, G to 10 s, and leaves D_bringUp at 15 s by a different sum.

D stays provisional: it is confirmed for reads only, and not for write selectors or for dark
wake. It is revisited when [#296](https://github.com/blamechris/Aeolus/issues/296)'s conditions
3 and 4 are measured and when the first supervised E4 write has recorded its own
per-round-trip latency. A persistent wedge becomes a throttled restart loop, not a recovery:
see Consequences, and "What the ending buys, and what it does not" below. (The first draft of
this paragraph said every pass ended in reconciliation. It does not: each pass is ended by the
round-trip trigger at one of its reads, before the restore.)

### The constants

| Constant | Value | Bounds | Derivation |
|---|---|---|---|
| **D** | 5 s (provisional, reads only) | One stamped round trip. | About 437× the worst of 912,000 measured reads (11.45 ms; the four conditions in H1, [#296](https://github.com/blamechris/Aeolus/issues/296)). |
| **D_cycle** | 3·D = 15 s | No completed § 3 cycle, while armed. | *Superseded by the 2026-10-18 amendment: with § 3's own admission the allowance has no N, 632 round trips and 13.34 s on `Mac16,5`.* At least the interval (1 s), plus timer slop (0.1 s), plus D, plus the allowance at the design point of 12 outstanding supervisor reads (596 round trips × 11.453 ms = 6.83 s, re-run for ADR 0014's write turns; 576 and 6.60 s before them): 12.93 s. See below. |
| **D_bringUp** | `ReconciliationLimits.budget` + 2·D = 15 s | Arming to `ThermalSupervisor.start()`. | The reconciliation budget (5 s) plus 2·D. Independent of the outstanding-read count: no client can reach the helper before `listener.resume()`. Re-checked for ADR 0014 D5's preparation step, which runs before reconciliation: at most 24 round trips for ten fans (0.27 s), inside the 2·D margin with a whole D to spare. |
| **G** | 2·D = 10 s, per parked waiter | [#135](https://github.com/blamechris/Aeolus/issues/135)'s gate-waiter `.fault`. | *Re-derived by the 2026-10-18 amendment with § 3's lane occupancy: 821 round trips and 9.40 s at N = 12, holding to N ≤ 12.* Must exceed the longest supervisor wait at the design point (a reader behind both critical reads: the allowance less the cycle's writes and its own turn, 561 round trips × 11.453 ms = 6.43 s since ADR 0014's write turns, 543 and 6.22 s before them; corrected in PR C from 512 and 5.86 s, which counted § 3's own read as the worst waiter) and stay below D_cycle − interval − 2 ticks (12 s). Suppressed while a stamp is older than one tick. |
| **Tick** | 1 s | The watchdog's timer, a `.strict` `DispatchSourceTimer`. | A verdict needs two over-bound ticks, so it lands at most two ticks after the bound is crossed. |

**A verdict needs two consecutive over-bound ticks on the same sequence** (the same round-trip
sequence number, or the same cycle-completion count). I3 already required the same in-flight
sequence on two ticks; the progress trigger is held to the same rule on its cycle-completion
count. One over-bound observation is not a verdict.

### Outstanding reads, and why D_cycle is 15 s

How long a § 3 cycle can legitimately take is **not a constant**. It depends on *N*, the number of
supervisor-priority reads outstanding at once, § 3's own read among them, and nothing in the helper
bounds N. (Since the 2026-10-18 amendment § 3's read is in its own lane, so N still counts it and
the supervisor queue holds N − 1.) Besides the
fixed readers (§ 3's cycle, § 5's cycle, the grant path's curated read, which is single-flight,
and a reconnect's exclusive turn) there is one mode or bounds read per connection with an
`acquireLease` in flight — sequential within a grant, and a bounds read's two keys fit the reader
turn below ([#270](https://github.com/blamechris/Aeolus/issues/270)) — and one per in-flight
`restoreAllToAutomatic`, and nothing caps connections or those
messages ([#332](https://github.com/blamechris/Aeolus/issues/332)). Level 6's `apply` is one
more, and at most one whatever the number of connections: `LeaseApplier` admits one `apply` at a
time, and its envelope reads, engagement steps and commands are sequential (ADR 0014's A6 PR-2 and
PR-3 amendments). Today's build is N = 3: the write path is not built, so `acquireLease` refuses
before it reads, and `apply` before it reads anything. The client-driven terms arrive with E3.

D_cycle is therefore sized for a stated **design point of N = 12**. The scheduler admits
supervisor reads first-come first-served, in turns of at most `maxKeysPerTurn` (64) keys, and
forces a snapshot turn after every `maxConsecutiveOvertakes` (2) of them, so the allowance a
cycle has to survive, in round trips, is

> 64 + 34 + 5·(N − 2) + 64·(⌊(N − 1)/2⌋ + 1) + 34 + 30

term by term: **64**, the turn already in flight; **34**, the grant path's curated critical read
(single-flight); **5·(N − 2)**, the other outstanding readers' turns, each taken at the longest a
reader may take; **64·(⌊(N − 1)/2⌋ + 1)**, the snapshot turns the overtake quota forces; **34**,
§ 3's own read; **30**, a firing cycle's writes and read-backs on two fans. Every round trip is taken at the
measured worst, as everywhere in this ADR.

**The reader term was 3·(N − 2) — every other reader a 3-key mode read — until ADR 0014 D7 gave
writes turns, and it was re-run in the change that added them** (slice A4 of
[#9](https://github.com/blamechris/Aeolus/issues/9)), as the paragraph below requires. D7's
longest write turn is an engagement's first step on the force-key path: the raw `F<n>Md`
pre-state, a fresh key info, the mode write, the force key's key info and its write — five
round trips (`WatchdogLimits.writeTurnRoundTrips`). A Y-write and a `commandTarget` take three;
a restore takes one write per key and no read, three on `Mac16,5` for the machine-wide one.
**Five is the longest turn only for a machine of up to four fans:** the machine-wide restore is
fans + 1 writes, so a fifth fan makes it six and this term is re-run again. *(On `e4/bring-up`
the longest turn is nine, the engaged step, per the 2026-10-31 amendment.)* One
engagement in progress is one outstanding reader while it waits for a turn and none while it
sleeps between steps, so writes enter N as readers with a longer turn, not as new readers.

At N = 12 that is 596 round trips, and at the measured worst of 11.453 ms each, 6.83 s. Adding the
interval, the slop and D gives **12.93 s**, which 15 s clears. At N = 16 the allowance is 744
round trips (8.52 s) and the requirement 14.62 s; at N = 17 it is 813 (9.31 s) and 15.41 s. **15 s
holds for N ≤ 16**, as it did before the re-run (576, 716 and 783 round trips; 12.70, 14.30 and
15.07 s).

*(Withdrawn by the 2026-10-18 amendment, which gives § 3's cycle its own admission and takes N
out of its bound.)* **Above the design point, the cycle trigger firing is the correct outcome**: the helper ends and
the fans return to automatic, which is the safe direction. It is not a safety precondition to
bound N, but a watchdog that fires under ordinary multi-client load costs users their manual
control, so bounding N is [#332](https://github.com/blamechris/Aeolus/issues/332), recommended
before E3 grants exist. **E3's write verbs must state how they take scheduler turns: if writes
queue at supervisor priority they add to N, and this arithmetic is re-run in the change that adds
them.** PR B's `theBoundsAreDerivedAndConstant` computes the allowance from the named scheduler
constants, not from a literal.

### Which clock the progress and bring-up triggers age on

The round-trip trigger reads an age from `SMCRoundTripMonitor`, which measures on
`SuspendingClock`. The D_cycle and D_bringUp triggers have no monitor to read, so they need a
clock of their own, and it must be named. It is **`SuspendingClock`, supplied by an injected
clock, and never the composition's `MonotonicClock`.** That one is `ContinuousClock`, which keeps
counting while the machine sleeps. The supervisors are not stopped across a sleep: the power
responder hands the fans back on `.willSleep` and unseals on `.didWake`, so the trigger stays
armed through every sleep. On a continuous clock, the first two ticks after an hour-long lid
close would both see about an hour since the last completed cycle, and a first cycle after wake
that took longer than one tick would end the helper `.blind` and drop every lease. § 3 itself
sleeps between cycles on the composition's `MonotonicClock`, which is `ContinuousClock`; that is
its sleep, not the clock the watchdog reads.

**There is no wake allowance.** On the suspending clock, time spent asleep is not counted, so
after a wake the trigger sees only awake time and the first cycle after a wake is held to the
same D_cycle as any other. A wake grace window would hide a genuine § 3 stall on exactly the
transition where the SMC is least observed, and it would be a number with nothing measured
behind it. A false positive there costs a restart, not a lease: § 4 drops every lease on the
delivered `.willSleep`, and the sleep seal refuses grants until `.didWake`, so dark wakes add no
client load either; the two-consecutive-ticks rule allows one extra tick. What
is exposed is that the first read after a wake is slower than any read measured so far, which
is H1 condition 4 and has not been taken. **If the first read after a wake exceeds 50 ms** (D/100,
the margin the assumptions table requires of D), **raise D.**

### What a completed § 3 cycle is

"No completed § 3 cycle" needs a definition, because `ThermalEmergency.cycle()` begins with
`guard !isCycling else { return }`, and a dropped entry returns exactly as a finished one does.
`ThermalSupervisor.stop()` cancels without awaiting, so an outgoing loop routinely finishes after
its replacement has started. If progress were counted on `cycle()` returning, a replacement loop
whose entries the reentrancy guard keeps dropping would advance the count every second while the
outgoing cycle sat parked in an await that is not a round trip, and neither D nor D_cycle would
fire.

**A completed cycle is one for which `ThermalEmergency.cycle()` returned `true`, and it returns
`true` on every exit after the `isCycling` guard, including the blind path.** A cycle that could
read nothing still ran to its end, and § 3 handles a blind cycle on its own path; D_cycle watches
for a cycle that does not finish, not for one that finishes blind. An entry the guard drops
returns `false` and is not progress.

### Corrections to the Decision

1. **I1 extends to `IOServiceOpen` and `IOServiceClose`.** `SMCConnection.open()` and `close()`
   are stamped as `.open` and `.close`, because `ConnectionHealth.reconnect()` runs them and either
   can block in the kernel exactly as a read can. Three groups of IOKit calls remain unstamped:
   - **`SMCConnection`'s `deinit`.** The reason is *not* that nothing could read a stamp from it:
     the monitor is a separate object, and a watchdog holding `roundTrips` outlives the
     connection. It is safe because the helper builds one connection and never releases it before
     the process exits, so the `deinit` never runs while a watchdog is armed. **A reconnect that
     replaces the connection object breaks that**; whoever writes it must stamp the call or keep
     the old connection alive until it is closed through `close()`.
   - **`IOServiceGetMatchingService`, the registry read (`IORegistryEntryCreateCFProperty`) and
     `IOObjectRelease` in `open()`.** These run on the connection actor, so a hang in one holds
     the actor. On a machine **with a curated critical set** that starves § 3, which D_cycle
     catches; D does not. On unidentified hardware (every Mac but `Mac16,5` today) the set is
     empty, § 3's read takes no scheduler turn, and a blind cycle completes every second, so
     **nothing here catches it**: the cost is a daemon that hangs until launchd's SIGKILL, with
     no lease reachable and so no fan under manual control.
   - **`SMCConnection.isHardwareAvailable()`.** It is static and runs off every actor, so a hang in
     it blocks only its caller. D_cycle catches it only if that caller is on § 3's path, and only
     where a curated critical set exists. "Caught by D_cycle" therefore does not hold in general,
     and a reader reasoning about a reconnect must not conclude that it can only hang inside the
     stamped `IOServiceOpen`.
2. **I4's progress trigger is armed from bring-up, not only while the supervisors run.** As
   written, the trigger was armed only after § 3 started, so a bring-up that stalled anywhere other
   than inside a stamped round trip, or that returned without ever starting the supervisor, was
   watched by nothing. It is armed with the watchdog, bounded by D_bringUp until
   `ThermalSupervisor.start()` and by D_cycle from then until `stop()`: § 3's `start()` and
   `stop()` switch its phase. A stopped supervisor is not a stall. It ages on the clock named
   above, and counts completed cycles as defined above.
3. **I5's first-terminate-wins guard wraps the seam in `ProcessTermination`, shared with the
   SIGTERM teardown, and never consults `hasBegun`.** A lock-guarded `ProcessTermination` sits in
   front of `TeardownExit.process`, and both `SignalTeardown` and the watchdog end the process
   through it. It must not ask whether the teardown has begun, for two reasons. `SignalTeardown`
   sets `hasBegun` before it awaits the gate close and the lease release, and both queue behind a
   wedge, so a guard that read "the teardown has begun" would silence the watchdog in exactly the
   case I6 keeps it armed for. And `hasBegun` is private actor state, so reading it from the
   watchdog's queue would mean awaiting `SignalTeardown`, which I2 forbids. The exit-count
   tripwire stays at one site, and its pattern extends to `_exit(`.
4. **The gate trigger's `.fault` is suppressed while a stamped round trip is older than one tick.**
   A waiter parked behind a stamp older than one tick is explained by that stamp. The threshold is
   **one tick, not D**: a stamp between one tick and D old suppresses the fault though it is not
   yet a verdict, and its alarm is D if it keeps going, or D_cycle if it starves § 3. A reader who
   takes "overdue" to mean older than D would suppress too little and bring back the duplicate
   `.fault` this correction removes. The gate trigger still raises `.fault` only and never ends
   the process.
5. **I8 covers every bound the watchdog applies.** D, D_cycle, D_bringUp, G, the tick and the
   two-tick rule are constants; no XPC message and no configuration can disarm or lengthen any of
   them. Lengthening the tick lengthens every verdict (at a 60 s tick, "two ticks" is two
   minutes), and the bounds are derived and constant (PR B's `theBoundsAreDerivedAndConstant`).
6. **A monitor is reached through its connection.** `SMCRoundTripMonitor.init()` is internal (a
   source test refuses `public` or `package` on it), and today the only public way to a monitor is
   `SMCConnection.roundTrips`. That second half is held by review, not by a test: a public factory,
   or a public `SMCConnection.init(roundTrips:)`, would reopen the hole this closes and needs the
   same review as widening the initialiser. `HelperComposition` takes the
   monitor with no default (PR B), so a watchdog cannot be handed a monitor that no connection
   stamps and then watch nothing for ever. `inFlight()` is callable from any thread but not from a
   signal handler: its lock is an `os_unfair_lock`, which is not async-signal-safe.

### Two clock families in the helper

The helper now measures time on two different clocks, deliberately. Leases run on
`MonotonicClock`, which is backed by `ContinuousClock`: a lease must keep running while the machine
sleeps, so that it expires. The watchdog runs on `SuspendingClock`, through `SMCRoundTripMonitor`
and through the injected clock of the progress and bring-up triggers: a round trip in flight
across a sleep must **not** age (I3). **Unifying them is not a tidy-up.** Moving the watchdog onto
the continuous clock reintroduces the sleep false positive, and moving leases onto the suspending
clock stops them expiring across a sleep. The monitor's clock is one `typealias`
(`SMCRoundTripMonitor.MeasuringClock`), and a test asserts the type rather than a clock it built.

### The ending is synchronous (PR B, reviewed on #333)

**The "synchronous terminate seam" alternative, rejected when PR B was designed, is reversed.**
PR B first handed a verdict from the watchdog's queue to the process ending through a `Task`,
because the seam (`TeardownExit.process`) was typed `async` so that test recorders could await an
actor journal. That was a convenience of the tests, and it cost the one property the ending exists
for. The concurrency review of #333 established three things:

- **A parked pool prevents the hand-off.** The decision does not use the cooperative pool (the
  `.strict` timer runs on a queue of its own and fires with every pool thread parked), but a
  `Task` created on that queue needs a pool thread in its QoS bucket. With the pool's
  `.userInitiated`-and-above threads parked, the verdict was reached and `Task { exit(2) }` did
  not run in 5 s; with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a pool of one), the process ended
  only after the held connection was released. One wedged thread on a one-thread bucket was enough.
- **No `ExitTimeOut` bounds it.** The launch daemon plist sets none, and `ExitTimeOut` only times
  the gap between SIGTERM and SIGKILL when launchd *stops* a job; nothing stops a helper that is
  merely wedged. SIGTERM is no fallback either: the teardown also hands off through a `Task` and
  then queues behind the same wedge.
- **`fired` blocks a retry.** It is set in the locked step that decides the verdict, so no later
  tick tries again, and the log line had already said "Ending the helper".

**Decision.** `tick()` takes the claim (`ProcessTermination.claim(_:)`) first. If it is granted,
it logs the one `.fault` and calls the terminate seam, **synchronously, on the watchdog's own
queue**. `TeardownExit.process` is `exit` underneath and needs no executor, so the seam is a
synchronous closure and the recorders in the tests are lock-guarded. There is no `Task` on the
verdict path, and `WriteVerbAllowlistTests`' count of unstructured `Task` spawns stays where it
was. There is still exactly one `exit(` site. If the claim is refused because the teardown holds
it, the watchdog still logs the verdict (it is as real as it was) but says that the process is
already ending as the holder and **promises no restart**; it does not claim an ending that is not
its own. The ADR's wording that the process ends *while* the connection is held is restored as a
test: `theWatchdogNeverEntersTheConnectionActor` drives `tick()` from a dedicated thread with the
real connection held, and asserts the seam was called once before the connection is freed, on a
pool of any width.

### What the ending buys, and what it does not

Ending the helper is not restoring a fan. The log line, `docs/SAFETY.md` § 6 and this ADR now
say the same thing:

- launchd restarts a job it is keeping alive, and the next process's reconciliation restores
  automatic control **if its pass reaches its keystone**: every read before the restore
  returns, and then the restore does. A first read that returns and a later one (a fan's
  `F<n>Md`) that hangs restores nothing either.
- A wedge that outlives the restart hangs one of those reads. The **round-trip trigger** ends
  the new process about D + 1–2 s after that read began, not the bring-up trigger at D_bringUp
  (which covers a stall that is not a stamped round trip, such as a hang in `open()`'s unstamped
  matching or registry calls). launchd throttles the loop, and nothing restores a fan until the
  driver answers.
- Where launchd is removing or stopping the job (`launchctl bootout`,
  `SMAppService.unregister()`, a shutdown), exit code 2 is not followed by a start.
- The orderly teardown is bounded by D, through the round-trip trigger alone (H6).
- D_bringUp is bounded at `ThermalSupervisor.start()`. A stall later in `bringUp()` —
  `observeSystemPower()` (a synchronous, unstamped `IORegisterForSystemPower`), the signal
  teardown's install, anything before `listener.resume()` — leaves a daemon that serves nothing
  and is never ended, because § 3 keeps completing cycles. That is fail-safe for the fans, since
  reconciliation has run and no lease is reachable, and it is not recovered; extending D_bringUp
  to the end of `bringUp()` is a further amendment.

### Tests added or sharpened by the stamp (PR A)

| Test | Mutation that must turn it red |
|---|---|
| `theStampBracketsTheIOKitCall` (stamped inside the body; cleared on return and on throw) | Take the stamp after the body. Separately, clear outside the `defer`. |
| `sequenceNumbersStrictlyIncrease` (the first stamp is 1; strictly increasing across returns and throws) | A constant sequence. Separately, take the sequence before the increment. |
| `aRoundTripClearsOnlyItsOwnStamp` (A begins, B begins, A returns first: B's stamp survives) | Clear the slot unconditionally. |
| `theLockIsNotHeldAcrossTheCall` (a reader is not blocked while the body is parked) | Run the body inside `withLock`. |
| `anAgeIsNeverNegativeUnderContention` (a writer stamps while a reader reads, no clock bound) | Read "now" before copying the stamp out. |
| `theStampIsReadableWhileTheConnectionIsOccupied` (the actor is really held: a queued call stays queued) | Make `occupyForTesting` `nonisolated`. At compile time, drop `nonisolated` from `roundTrips`. |
| `aCallStampsTheKeyAndSelectorItSends` (CI, on a handle that reaches no driver) and the Mac16,5 count test (the live path) | Stamp `.call(key: 0, selector: 0)`. |
| The tripwire: exactly one `IOConnectCallStructMethod` under `Sources/` and `Tools/`, inside `roundTrips.bracket(.call(`; `IOServiceOpen` and `IOServiceClose` stamped across all of `Sources/SMCCore`, `SMCConnection`'s `deinit` excepted; no sibling entry point to a user client. Source normalised before matching. | Add a second call site. Hoist the call out of the bracket. Add a new `SMCCore` file with an unbracketed `IOServiceOpen` or `IOServiceClose`, including one in a `deinit`. |
| `theMonitorHasNoPublicInitializer` | Make the initialiser public. |
| `aRoundTripSpanningSleepIsNotAWedge`, the half CI can run (`Instant == SuspendingClock.Instant`; the age comes from the monitor's own clock, when it is asked, from the moment the call began) | Swap in `ContinuousClock`. Compute the age when the stamp is taken. Measure it from the monitor's creation. |

The debug-build trap on an overlapping bracket is not in the table: its only observable effect is
a trap, which no test can assert on. It was run once by hand and is described on the pull request.

The watchdog's own tests, and the gate trigger's, are listed on
[#329](https://github.com/blamechris/Aeolus/issues/329) and carry their mutations in the pull
requests that add them (the gate trigger's are in the pull request that closes #135). The
hardware half of `aRoundTripSpanningSleepIsNotAWedge` (a real lid close with a round trip in
flight) has not been observed; it is H1 conditions 3 and 4.

### The gate trigger, as built (PR C, [#135](https://github.com/blamechris/Aeolus/issues/135))

This closes #135's three open questions, and each answer is the smallest that satisfies the
acceptance criteria.

- **A deadline observer, not a deadline.** `GateWaitMonitor` is a `SchedulerObserving` conformer
  that mirrors the scheduler's per-priority FIFO from `waiterParked` and `turnGranted`, and the
  watchdog's tick asks it for the oldest waiter at each priority. The gate stays non-cancellable:
  the monitor holds no continuation (`WatchdogTripwireTests` holds that) and nothing in this
  change resumes or drops one.
- **Nothing beyond reporting.** A waiter parked longer than G logs one `.fault` naming the
  priority, the age and the queue depth, and **the helper does nothing more**. A gate that never
  turns starves § 3 behind it, which is the case D_cycle already ends, so the fault is the
  diagnosis and the cycle trigger is the action. *(G's lower side below is superseded by the
  2026-10-18 amendment: 9.40 s at N = 12, holding to N ≤ 12. The upper side and G = 10 s stand.)*
  G = 2·D = 10 s sits above the longest legal
  supervisor wait at the design point (6.43 s: a reader that arrived last, behind both 34-key
  critical reads, 561 round trips; 6.22 s and 543 before ADR 0014's write turns) and below
  D_cycle − interval − 2 ticks (12 s); it holds for up to 20 outstanding supervisor reads on
  `Mac16,5` (a wait of 9.82 s), and fails at 21 (10.61 s). Past that the line is logged for a
  queue that is long and moving, and it says so.
  The first draft's G = D was under the first side. **The snapshot priority's waiter is not
  derived:** it waits behind the other snapshot clients' turns as well, 64 round trips each, so
  on the order of a dozen concurrent snapshot clients outlast G with nothing wrong. The wait is computed
  from the named scheduler constants (`WatchdogLimits.gateWaitRoundTrips`), as D_cycle's is.
- **What the line promises, by phase.** While § 3 runs, a gate that never turns starves it and
  the cycle trigger ends the helper; before § 3 has started, the bring-up trigger does; once the
  supervisors are stopped (the orderly teardown) neither is armed, and the line says that nothing
  will end the helper for this. There is also no fault at all when § 3's own read holds the leaked
  turn and nothing else is waiting: § 3's next cycle cannot begin until the stuck one finishes, so
  nothing parks, and D_cycle acts alone (with the round-trip trigger, if the stuck call is a
  stamped one).
- **Where it lives.** Not in the scheduler, which reports and decides nothing (`SchedulerObserving`
  says why), and not in a lifecycle owner of its own: the watchdog already owns the tick, the
  lock-guarded reads and the `.fault` vocabulary, and the monitor is a fourth thing it reads.
  `SchedulerObservers` is how the scheduler's single observer slot feeds both `ConnectionHealth`
  and the monitor, in that order, synchronously, with nothing changed for the first.

What the monitor does, and does not, rely on:

- **A grant takes out the waiter it names.** `turnGranted` carries the `queuedAt` the waiter was
  parked with, and a fast-path grant carries its own grant instant with no waiter behind it, so a
  grant that matches no parked waiter is the fast path and pops nothing. Popping the head on every
  grant is right only while the mirror is in step, and when it is not it hides the waiter this
  exists to see.
- **It ages on the suspending clock, from its own park, and the comparer mints the instant.** The
  scheduler's `ContinuousClock` instant names a waiter and is never a start of waiting; a waiter
  parked across a sleep does not age by the sleep. `MonotonicClock` is not involved.
- **One fault per waiter.** The rate-collapse is the ticket of the last waiter logged at each
  priority, so a waiter that stays parked is logged once and the next one is logged in its own
  right. The verdict's `fired` is not reused: a gate fault must not stand in the cycle trigger's
  way.
- **Suppressed while a stamp explains it.** A stamped round trip older than **one tick** (not D)
  suppresses the fault, as correction 4 above says; a suppressed waiter is not recorded, so once
  the stamp clears a waiter still parked is logged.

| Test | Mutation that must turn it red |
|---|---|
| `aParkedWaiterPastTheBoundFaultsOnce` | Remove the emission. Separately, remove the rate-collapse. |
| `aProviderThatNeverReturnsFaultsTheReadParkedBehindIt` (the real scheduler, a provider that never returns the turn) | Remove the emission. Separately, ignore `turnGranted`. |
| `aSecondWaiterFaultsInItsOwnRight` | Collapse on the priority alone. |
| `theGateFaultIsSilentWhileAStampedRoundTripExplainsIt` | Drop the suppression. Separately, record a suppressed waiter as logged. |
| `aVerdictOutranksAGateFaultDueOnTheSameTick` | Return the gate faults ahead of `if let confirmed` in `tick()`. |
| `theGateFaultPromisesOnlyWhatThePhaseMakesTrue` | Promise the cycle trigger in every phase. Swap the cycling and bring-up wording. |
| `aStampExplainsTheWaitOnlyWhenOlderThanATick` | Suppress only past D. `>=` for `>` against the tick. Suppress on any stamp. |
| `aWaiterAtExactlyGIsNotPastIt`, `aWaiterGrantedJustUnderGNeverFaults` | `>=` for `>` against G. Ignore `turnGranted`. |
| `aFastPathGrantPopsNothing` | Pop the head on every grant. |
| `theGateFaultNeverEndsTheProcess`, `aGateThatNeverTurnsIsEndedByTheCycleTrigger` | The gate path takes the claim and ends the process. Separately, set `fired` in the gate path. |
| `theGateBoundIsDerivedAndConstant`, `theGateWaitIsTheLongerOfTheTwoWaiters`, `theGateBoundHoldsForEveryCuratedSet` | G = D. G = D_cycle. Count § 3's read as the worst waiter. Take only the mode read off the allowance. `max` for `min`. G + 1 s. |
| `SchedulerObserversTests` | Drop the first observer. Reverse the order. Deliver through a `Task`. |
| `theGateMonitorHoldsNoContinuationAndNamesNoConnection` | A `CheckedContinuation` in the monitor, however it is spelled. A connection named in it. |

## Amendment (2026-10-18, [#332](https://github.com/blamechris/Aeolus/issues/332), B1) — § 3's cycle is admitted ahead of every other turn, and D_cycle no longer depends on N

**Status.** Accepted on architect review of #332, under ADR authority. It supersedes the D_cycle
row of the constants table and the reasoning of "Outstanding reads, and why D_cycle is 15 s" above
for § 3's cycle, and re-derives G's lower side. D, D_bringUp, the tick and the two-tick rule are
unchanged, and so are the values of D_cycle and G.

### Context

The allowance above counted one queue wait per § 3 cycle, plus a flat 30 round trips for a firing
cycle's writes. Under [ADR 0014](0014-apple-silicon-unlock.md)'s B1 amendment every command and
every restore is a turn of its own, first-come first-served at `.supervisor`. Counted from the
code:

- `ThermalEmergency.fire(_:from:)` bridges every fan in `engagedFans ∪ restoredUnconfirmed`, two
  disjoint sets, so at most F fans, and each bridge was two turns: the maximum command (three round
  trips) and a `.fan(n)` restore (one or two), the restore attempted whatever the command did.
- The revocation that follows goes through `LeaseAuthority.restore`, `HelperFanRestorer` and
  `BoundedFanRestorer`: up to `RestoreLimits.attemptBudget` (3) attempts per fan, each a `.fan(n)`
  restore turn. It does not skip a fan § 3 has just restored; it is the idempotent second restore.

So a firing cycle is 1 + 3F turns with every restore accepted and 1 + 5F with every one refused,
seven to eleven on `Mac16,5`; a quiet cycle with owed read-backs is 1 + F. Each turn waited behind
every outstanding reader. Modelled event by event against the scheduler's own policy at the
measured worst round trip, `Mac16,5` needed about 44 s at N = 12 with the restores accepted and
about 66 s with them refused, and a quiet cycle with one owed read-back held only to N ≤ 9.

The false `.blind` verdict that follows fails safe: launchd relaunches the helper, and the
successor's preparation step and reconciliation hand the fans back before `listener.resume()`. But
the same queue delays § 3's own bridge and restore by seconds per turn under client load, and that
delay — not the verdict — is the defect. Only N ≤ 2, which is no load worth serving, keeps a firing
cycle inside a D_cycle worth having (see the alternatives below).

### Decision

- **`SMCReadPriority.thermalCycle`, a third admission class, for § 3's cycle alone:** its critical
  read, its owed read-backs, its bridge jobs, and the restores
  `FanRestoreCause.thermalEmergencyRevocation` causes. `SMCReadScheduler.nextTurn()` admits it
  ahead of every waiting turn, behind only the turn in flight, and it neither spends nor resets the
  snapshot's overtake quota.
- **Only § 3 reaches it**, two ways *(one since the #440 amendment below, which supersedes the
  second)* (and the two words that reach it, `thermalCycle` and
  `thermalEmergencyRevocation`, are counted file by file in `Sources/AeolusHelper`):
  - a **view** of the one plane, `FanControlPlane.admitted(at: .thermalCycle)`, which holds the
    plane's scheduler and connection (and, on a plane that can write, its channel and
    `PlaneWriteLedger`) and differs only in its `PlaneAdmission`. The composition builds § 3's
    telemetry, read-back reader and writer over it. The telemetry view keeps the cache source's
    `DegradationMemo`, and the read-back is reconciliation's own loop (`PlaneHandbackReadBack`);
  - *(Superseded by the #440 amendment below: a cause routes nothing, and § 3's revocation
    reaches the lane through a handback § 3 holds and lends.)* `HelperFanRestorer`, which routes a
    restore through its writer's lane view when the cause is
    `.thermalEmergencyRevocation`, and every other cause through the writer at `.supervisor`. The
    cause was `.thermalEmergency` in the first draft and was renamed in review: the word was shared
    with `SafetyActorLevel.thermalEmergency`, so no scan could count the cause by its name, and a
    pattern-matching scan of how it is passed missed a ternary, a computed property and five other
    spellings. A word only the cause spells is counted whatever expression it sits in.
- **§ 3's bridge is one plane job per fan**, `FanControlPlane.bridgeThenRestore(_:)`: the `.fan(n)`
  restore is requested first, before the job waits for its turn, and then, inside one turn, the
  command's body and the restore's, each attempted whatever the other answered and both reported
  (`BridgeOutcome`). That is three round trips and then at most two, `writeTurnRoundTrips`.
  `SafetyActorWriter.bridgeToMaximumThenRestore(of:)` is § 3's verb and replaces
  `commandMaximum(of:)`; `GovernedFanWriter` declares neither.
- **So each of § 3's turns waits for at most one turn in flight.** The lane never holds more than
  one waiter — § 3 runs one cycle at a time (`isCycling`) and its calls are sequential — and § 3
  re-queues only after `admitNext()` has handed the connection on, so it never takes two turns in a
  row while another waiter is parked. § 3's read is one turn because every curated set is at most
  64 keys (`everyCuratedSetFitsOneTurn`); a longer one would run its slices back to back.
- **The lane's value sets are pinned by the compiler.** `PlaneAdmission` is exactly
  `.supervisor` and `.thermalCycle`, and `SMCReadPriority` exactly its three cases:
  `ThermalCycleLaneValueSetTests` switches over both with no `default`, so a new case does not
  compile until the pin places it, and the pin holds that only `.thermalCycle` reaches the lane.
  Without it, a case mapped to the lane beside `.thermalCycle` reached it from any file, at any
  call site, with every word count unchanged (review's N1, N1e and N7).
- **The one-waiter premise is observed at run time, not only at the source.** The scheduler counts
  lane requests outstanding, queued or holding the connection, from `takeTurn` to `endTurn`, keyed
  on the queue a request joins (`isLane(_:)`, the same mapping `enqueue` and `queuedTurns` use), so
  a priority folded into the lane is counted. When one arrives while another is outstanding it
  reports `SchedulerEvent.thermalCycleLaneOverlapped`, which `ThermalCycleLaneWatch` writes to the
  safety log at `.fault`, and admits the request in the lane as normal: it never traps, blocks or
  demotes. It reports again at each new depth, and each time the cumulative overlapping arrivals
  reach a power of two (1, 2, 4, 8, …), every line carrying the depth and the count. Both are
  needed: § 3 has at most one request outstanding, so a second producer making one call at a time
  only ever reaches depth 2, which any transient overlap has already reported; on depth alone one
  early overlap would mask it for good, while the powers of two keep it writing lines and grow
  the log only logarithmically. Demoting the newcomer was considered and refused: a rogue request admitted while
  § 3 is idle would make § 3's own next request the newcomer, and § 3 would be the one demoted.
  Refusing it would fail a safety read. `ThermalCycleLaneOverlapTests` runs § 3's firing episode —
  a firing cycle with every write refused, a latched cycle, the release and the read-backs — over
  a plane whose every call holds a real scheduler turn, and the scheduler reports nothing;
  bridging or reading back in a task group makes it report. A second test drives a latched
  cycle's take-back with writes the same way; a blind cycle, which takes back through the same
  code, is sequential by inspection.
  `ThermalCycleLaneCounterTests` holds the count's lifetime through a throw, a multi-slice read and
  a cancellation.
- **D_cycle's allowance, with no N** (`WatchdogLimits.allowanceRoundTrips(criticalReadKeys:fans:)`):

  > (1 + F + F·attemptBudget)·maxKeysPerTurn + K + F·writeTurnRoundTrips + F·attemptBudget·fanRestoreRoundTrips

  one turn in flight ahead of each of § 3's turns in a firing cycle with every restore refused, then
  its read, its bridge jobs and its restores. F is the curated machine's **recorded** fan count,
  `CriticalSensorSet.fanCount` (2 on `Mac16,5`, from `FNum` in `docs/SMC-RESEARCH.md`), never one
  read at run time. On `Mac16,5` it is **632 round trips, 13.34 s** with the interval, slop and D,
  and 14.19 s with every round trip of § 3's write turns at 50 ms.
- **D_cycle stays 15 s.** D, D_bringUp, G, the tick and the two-tick rule are unchanged.
- **G's lower side is re-derived with the lane's occupancy, as two modelled cases**
  (`WatchdogLimits.gateWaitRoundTrips(outstandingReads:criticalReadKeys:fans:)`). The worst
  supervisor waiter is behind the supervisor queue — N − 1 waiters, § 3's own read no longer among
  them — and § 3's lane turns, in the longer of two windows: (a) one firing cycle, then latched
  cycles of the read alone; (b) quiet cycles of the read plus a read-back of every fan — at most one
  cycle starting per interval plus § 3's read, solved as a fixed point. **9.40 s at N = 12** (821
  round trips), and the cases fit to N ≤ 12 (10.58 s at 13; they held to N ≤ 20 before).
  *(On `e4/bring-up`, re-run for ADR 0014's engaged step at rest by the 2026-10-31 amendment below:
  829 round trips, 9.49 s, still to N ≤ 12.)*
- **The two windows are modelled cases, not a bound over every history § 3 produces.** Review
  found two histories they do not cover. Read-backs follow a firing once the latch releases, so a
  firing, its release and the read-backs after it can fall inside one window. And a latched cycle
  can take fans back (`takeBackAnythingEngagedSinceFiring`, 56 round trips), so latched cycles are
  not always the read alone. Counted correctly — the firing head once, cycle starts spaced by the
  interval plus the cycle's own round trips — those histories are **817–831 round trips, 9.36–9.52
  s**, under G; an event model of the shipped policy gives at most **611 round trips, 7.00 s**.
  The scripts that produce them are in [`scripts/gate-wait-model/`](../../scripts/gate-wait-model/),
  committed because they back a safety bound: `closed_mixed.py`, `starts.py` and `starts2.py` for
  the closed form's counts, `event.py` with `event_run.py`, `event_run2.py` and `event_search.py` for the
  event model (review first recorded 599 from a narrower search of it). G stays 10 s. **Open:**
  how many take-backs with writes can follow one firing. `requireEntitlement` and the abandoned-fan
  refusal appear to bound it, which is not proven; if one recurred every cycle the count would be
  **919 round trips, 10.53 s**, over G. The same open family includes latched cycles whose
  refused revocation recurs every cycle: **859–869 round trips, 9.84–9.95 s** (`starts2.py`),
  under G but above the 817–831 of the histories counted as closed. *(Under G as a wait only. The
  slot of its upper member, wait and turn, was 874 round trips, 10.01 s, over G. On `e4/bring-up`
  the wait is 867–877 and that slot 886, 10.15 s; the 2026-10-31 amendment below bounds the
  family's fully refused form and states what passing G costs in it.)* **That costs more than a
  `.fault`.** G is also the slot
  ADR 0014's examination gate counts its lawful hold in: in that history a slot is 10.58 s, the
  three slots of `lawfulHold` 31.75 s against the 30 s derived, and § 5's 32 s `examinationWait`
  could run out inside a lawful hold, at an expiry's cost — a `.fault`, an examination without
  the gate whose re-assert stands down, and possibly a false divergence that spends an attempt.
- **This reopens [ADR 0010](0010-coalesced-supervisor-reads.md) D2 for § 3's cycle alone.** D1's
  first-come first-served admission stands for every other supervisor reader, and D3's coalescing
  is unchanged. D2's revisit trigger had already fired: #270's per-fan bounds read on the grant,
  and level 6's per-apply envelope reads.

**Why it is safe.** Every in-turn property is decided inside the turn, from the plane's one state:
ADR 0014's U15, D4's restore epoch, the exit's seal, #305's re-engagement check and D5's force-key
gate. Every order the lane produces is one first-come first-served admission could have produced
under a different arrival timing, and the view shares the state those properties read, so none of
them depends on admission order.

**The arithmetic is reproducible.** The architect's model is a discrete-event simulation of
`SMCReadScheduler`'s policy and a closed form of the two bounds; `WatchdogLimitsTests` derives
both independently from the named constants and pins 632, 13.34 s, 14.19 s, 821 and 9.40 s, with
three negative controls: K = 34 with F = 3 needs 16.40 s and fails, a curated set with no recorded
fan count has no bound, and G fails at N = 13.

### What remains

- **Write round trips are unmeasured** (ADR 0014's U8; H6 above). With every read at the measured
  worst, the bound holds while a write round trip stays under **86.98 ms** (the ruling's "about
  87 ms"), and D8 records it.
- **A curated machine with three or more fans breaks it**: 16.40 s at F = 3. No such machine is
  curated, and `WatchdogLimitsTests` fails the day one is.
- **G can log a `.fault` for a full but moving queue above N = 12**, or in a history the two
  modelled cases do not cover (see the Decision; the take-back bound is open). The fault ends
  nothing; the open history would also stretch ADR 0014's lawful hold past its derivation.
- **F is recorded, never cross-checked.** D_cycle's allowance uses `CriticalSensorSet.fanCount`,
  and nothing compares it with the fans the machine enumerates at run time. A `Mac16,5` that
  enumerated a third fan would need 16.40 s for a firing cycle with every write refused: the cycle
  trigger would end the helper, which fails safe. A check that the enumerated count equals the
  curated F before the bound is claimed is the optional remedy.
- **Two pre-existing costs are inside the margin, not in the allowance.** A discovery walk takes no
  turn, so its round trips interleave with lane turns on the connection actor: about 72 round
  trips, roughly 0.8 s at F = 2, inside the 1.66 s between the 13.34 s allowance and D_cycle's
  15 s. And a cold key-info lookup doubles the round trips of a slice that needs it.
- **The lane's one producer is held, not enforced.** The value sets are pinned by the compiler,
  the uses by per-file counts at the source and a positive census of every stored plane, and the
  premise is observed at run time. Nothing refuses a second producer at run time, by the ruling.
  Two shapes no census sees: a plane captured by a closure or a `Task` (today only
  `ConnectionHealth`'s recovery plane), and a restore cause stored and replayed into the restorer,
  which is a capability question for before b2's write bodies
  ([#440](https://github.com/blamechris/Aeolus/issues/440)). *(The second is closed by the #440
  amendment below: a cause selects nothing, and the lane's restorer is lent, never held, by the
  lease core.)*
- **Other supervisor readers still slow under load** — § 5, the grant, level 6, and the § 4, § 6
  and § 7 keystones. The lane reorders the connection's time and adds no capacity; #332 stays open
  for them. The level-1 keystones are not on the lane.
- **"Above the design point, the cycle trigger firing is the correct outcome"**, in "Outstanding
  reads" above, is withdrawn: § 3's cycle has no design point now.
- **The fast path's test of the lane's queue is a second line**, as its tests of the other two are:
  while `admitNext()` keeps the in-flight flag the queue tests are redundant, so deleting the lane's
  alone changes nothing a test can see.
  `SchedulerTurnLifecycleTests.aQueuedLaneWaiterKeepsTheFastPathClosed` holds it with the flag
  gone too.
- **On `main` nothing writes.** `SMCFanControlPlane` refuses the bridge without reading; the
  scripted plane models B1's job. B1's write turns will take their plane's admission, in the
  change that builds them on `e4/bring-up`.

### Where the implementation differs from the ruling on #332

- The case is `.thermalCycle`, as suggested. The view is `FanControlPlane.admitted(at:)` over a
  `PlaneAdmission` with two cases and no `.snapshot`, the form B1's write turn will take.
- The break-even write round trip is stated as 86.98 ms, which the ruling rounds to 87 ms.
- The fast path's lane test is recorded above as redundant while the flag holds, rather than as a
  mutation a single test kills.

### Tests, each with the mutation that must turn it red

| Test | Mutation that must turn it red |
|---|---|
| `SMCReadSchedulerLaneTests.theLaneIsGrantedNextAndLeavesTheQuotaAlone` | The lane checked after `.supervisor`. A lane grant that spends the quota. One that resets it. |
| `SchedulerTurnLifecycleTests.aLaneArrivalCannotBargeOntoAHeldTurn`, `aQueuedLaneWaiterKeepsTheFastPathClosed` | Delete `isTurnInFlight = true` from `admitNext()`. That, and the lane's queue test in the fast path. |
| `SMCReadSchedulerLaneTests.laneTurnsAlternateWithASustainedReader`, `aLaneReadLongerThanOneTurnRunsItsSlicesBackToBack`; `WatchdogLimitsTests.everyCuratedSetFitsOneTurn` | A lane reservation. Admit before enqueue in `yieldTurn`. `mac16x5`'s die-cluster prefixes widened to four, 68 keys. |
| `ThermalCycleLaneRoutingTests.onlySectionThreeTakesTheLane`, `theProductionPlaneGrantsSectionThreeInTheLane`, `aFiringCyclesWritesAreInTheLane` | The cache's source over the lane view. § 7's read-back over it. § 3's read, read-back or writer at `.supervisor`. The scheduler's read defaulted to the lane, with the snapshot path's priority dropped. |
| `ThermalCycleLaneWriterTests` | § 5's writer, § 4's, § 6's `panic:` writer or the teardown's built over the lane view. A new admission mapped to the lane with the value-set pin updated to match, given to § 5's writer. |
| `ThermalCycleLaneValueSetTests` | A new `PlaneAdmission` case mapped to the lane, used for § 5's or § 6's writer or at a call site in § 5 (fails to compile). A new `SMCReadPriority` case queued in the lane (fails to compile). `.supervisor` mapped to the lane. The scheduler queuing `.supervisor` in the lane. |
| `PlaneViewTests` | A view over a second firmware. A stored value on `SMCFanControlPlane` its view does not share. A view's reads at `.supervisor`. |
| `ThermalCycleLaneRoutingTests.sectionThreesRevocationRestoresInTheLane`, `everyCauseRoutesByWhoCausedIt`, `everyOtherCauseRestoresAtSupervisor` *(replaced by the #440 amendment's K1, K2 and K6)* | Route on the wrong cause. Route every cause to the lane. Route none. Move any one other cause, or several, into the lane's arm. |
| `ThermalCycleLaneTripwireTests` | One more naming of the lane in any file — a computed property in `PlaneAdmission`, a lane view for § 5 in the composition, a lane default on the scheduler's read. The cause named from `ReclamationWatchdog.swift`, in any of the fixture spellings. An enumeration of the cases through a type alias or a metatype. A second reader built in place of `PlaneHandbackReadBack`. A symbolic link under `Sources`. File discovery broken. A scan that keeps comments or drops its word guards. |
| `EngagementRouteTripwireTests.noRawStringHoldsAQuoteAndACommentMarker` | A literal nested in an interpolation holding `//`, which blinds the stripper to the rest of its line. |
| `ThermalCycleLaneSharingTests` | A second `DegradationMemo` for § 3's telemetry, in the composition or in the view. § 3's read-back reader over the plane rather than its lane view, or a reader of its own type. |
| `ThermalCycleLaneOverlapTests`; `SchedulerObservingTests.everyEventKindIsEmittedInAScriptedRun`; `GateMonitorWiringTests.theLaneWatchIsWiredToTheScheduler` | The overlap report deleted, or a request not counted out. § 3's bridges or its read-backs run in a task group. The watch dropped from the scheduler's observers, or one that does not log. |
| `ThermalCycleLaneCounterTests` | A request counted out on the success path only, so a throw leaks one. `yieldTurn` counting a lane request out too, or counting each slice in. A request not counted out when it was cancelled while queued. The report latched after the first, or made on every overlapping arrival, or without its power-of-two arm, or without its depth arm. |
| `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite`, `aRefusedMaximumStillRestores`; `ThermalEmergencyBridgeTests`; `SMCFanControlPlaneTests.theBridgeRefusesWithoutReading` | A governor in the command half. The restore skipped after a refused command. The epoch moved inside the turn. § 3 calling the two old verbs. A read on `.notBuilt`. The verb declared on `GovernedFanWriter`, or in an extension of it. A second verb that restores inside a permit. |
| `WatchdogLimitsTests.theBoundsAreDerivedAndConstant`, `theAllowanceIsDerivedFromTheNamedConstants`, `theCycleBoundHoldsForEveryCuratedSet` | The revocation term dropped. The read counted as one round trip. A literal allowance. F taken as 1. A curated set with no fan count. |
| `WatchdogLimitsTests.theGateBoundIsDerivedAndConstant`, `theGateWaitIsTheLongerOfTheTwoWaiters` | The lane term omitted. The firing cycle omitted from window (a). |
| `GateWaitMonitorLaneTests` | The lane missing from the mirror. Lane outcomes ignored by `ConnectionHealth`. |

**Alternatives considered**, each rejected on the arithmetic or on authority:

- *Re-derive D_cycle* for first-come first-served admission: about 45–66 s, and still dependent on
  N.
- *Lower N*: it would have to be at most 2.
- *Precedence for writes only*: 17.1 s.
- *The per-fan bridge job alone*: holds to N ≤ 3.
- *Exclude § 3's own waits from the cycle trigger*: it blinds the trigger to the case it exists for.
- *Skip the revocation's second restore*: it entangles the handback ledger and removes the only
  retry.
- *One re-entrant turn for the whole firing response*: authority the turn model does not give.
- *A bound computed at run time*: it breaks I8.

ADR 0010 D2's objections are answered: the "survivable amplification" is load at the design point,
and actions cannot be coalesced; "the quota is the cost" does not apply, because the lane is exempt
from the quota; "a level somebody will use" is held by tripwires that keep the case to § 3's wiring.

**Revisit if:** a second user of the lane is proposed, or the scheduler ever logs a lane overlap; D8
or H6 measures a worst write round trip above 50 ms *(about 20 ms, for G: the 2026-10-31
amendment)*; a curated set lands for a machine with three or
more fans, or with more than about 40 keys (G's wait at N = 12 passes 10 s at 40 keys on two fans);
H1's conditions 3 and 4 raise the worst read; owed read-backs come to run on a latched or firing
cycle; a mixed history — a firing, its release and its read-backs in one window, or take-backs with
writes after a firing — is shown to recur in a way that passes G, or the take-back bound is proven
or refuted; the plane gains state its view does not share; or a level-1 keystone's latency under
load becomes a requirement.

**No `AeolusXPCVersion` bump**: nothing crosses the boundary.

## Amendment (2026-10-18, [#440](https://github.com/blamechris/Aeolus/issues/440)) — § 3's lane is reached by holding it, and a restore cause selects nothing

**Status.** Accepted on architect review of #440, under ADR authority. It supersedes two passages
of the #332 amendment above: the second way "Only § 3 reaches it" — `HelperFanRestorer` choosing
the lane by a restore's cause — and the sentence under "What remains" that left a stored and
replayed cause open for b2. The constants, both bounds, the lane's admission policy, the view and
the run-time overlap report are unchanged.

### Context

Both of the #332 amendment's bounds assume one thing: only § 3 puts requests in the lane. That
amendment let a request reach the lane two ways.

- **By capability.** A mechanism had to hold a view of the plane, and a view is minted only where
  `.thermalCycle` is spelled. The value-set pins and the per-file counts hold that.
- **By value.** `HelperFanRestorer` switched on `FanRestoreCause`, and sent
  `.thermalEmergencyRevocation` to the lane. Every teardown path in the lease core carries a cause,
  so code that keeps a cause and passes it again later reaches the lane without spelling the lane's
  word or the cause's.

Review of #439 built the second shape: `revokeEveryLease` keeping its last cause and
`expireLapsedLeases` restoring under it, so after a firing every TTL expiry restored in the lane
beside § 3. It also contradicted `FanRestoreCause`'s own contract, which says the cause is a log
label and decides nothing. Nothing on `main`, or on `e4/bring-up` before b2, reaches it.

### Decision

- **The lane is reached by holding a view of it, and in no other way.** A restore's cause is a label
  again: `HelperFanRestorer` restores every cause at `.supervisor`.
- **§ 3 holds its handback.** `ThermalCycleHandback` is a bound over the keystone attempt whose
  writer it admits at `.thermalCycle` itself, notifying through the one `HelperFanRestorer`. The
  composition builds one — over a writer at § 3's level on the plane, which the handback admits in
  the lane — and gives it to `ThermalEmergency` alone, as a required stored property. Building a
  handback is a mint, so the composition is the one place that does.
- **The lease core now restores at two levels**, both provenance: its standing restorer at
  `.leaseExpiry`, and § 3's lent handback at `.thermalEmergency`, the level § 3 itself writes at.
  Nothing reads a writer's level today; if something comes to, the lent value is § 3's own, which
  fails safe.
- **The lease core borrows it for one call.** `LeaseAuthority.revokeEveryLease(handingBackThrough:)`
  takes it as a `borrowing` parameter of a generic constrained `FanRestoring & ~Copyable`, labels the
  revocation `.thermalEmergencyRevocation` itself, and hands back inside
  `restore(_:because:through:)` — the body and bracket every teardown uses, which
  `restore(_:because:)` forwards to with the lease core's own restorer.
- **Lent, and never kept, by the compiler — in safe Swift, through the parameter.** `FanRestoring`
  suppresses `Copyable`, which is additive: every conformer, `any FanRestoring` and
  `some FanRestoring` stay copyable. A `borrowing` parameter of a generic that suppresses it cannot
  be kept, and the refusals come from different places:
  - the **type checker** refuses copying it, storing it, boxing it into an existential and casting
    it;
  - the **move checker** refuses consuming it, and capturing it in an escaping closure, a `Task`,
    an `async let` or a deferred `Task` — so `-typecheck` alone accepts these, and only a full
    compile refuses them. The deferred `Task`'s refusal (and, in review, a task group's) is the
    compiler's own "this is a compiler bug" diagnostic, which a later toolchain may stop emitting;
    that fragility is why CI compiles each shape;
  - a **key path** to it is refused only by a compiler crash, and could not keep it anyway; it is
    the one refused shape CI does not probe.

  The guarantee has two stated limits. `withoutActuallyEscaping` and the `Unsafe*` family can move
  the bits out of the move checker's sight — a bitwise copy into an `UnsafeMutablePointer` outlives
  the call at every optimisation level — and a borrowed value can be forwarded to any generic
  function in the module, so only the helper's two IOKit bridges may name them, pinned per file.
  And the borrower
  reaches whatever `FanRestoring` offers, so a requirement that handed back something derived from
  `self` would hand it a copy; the protocol is pinned to its one requirement, and nothing extends
  it. Within those limits a borrower may still call the handback more than once in the call, which
  is § 3's own sequential use and which K2 pins to one.
- **`HelperFanRestorer` is cause-blind and holds no lane.** Its § 5-before, § 3-after notice sequence
  is written once, in `handBack(_:because:through:)`, which borrows on the same terms and serves
  both routes. No second `HelperFanRestorer` is built: it would need a second `bind`, and a restore
  through one that missed it would skip both notices — said at `.fault`, and lost all the same.
- **Neither `LeaseAuthority` nor `HelperFanRestorer` names an admission, a priority or a view.**
  Only the composition, which mints views, the handback, and the plane, which honours them, know
  admission.
- **The handback is a copyable struct**, because `Mirror` reflects a noncopyable stored field as `()`
  and the stored-plane census could not see what § 3 holds.

**What each defence holds.**

| Defence | Holds |
|---|---|
| The value-set pins and the per-file counts of the lane's word | Where the lane is named, and as often as it is named |
| The names of `ThermalCycleHandback`'s type, per file; no `typealias` of it; and the shape of the two files that may name the lane — the handback's holds the handback alone, with no nested type or static member and its one mint inside its own `init`, and the composition names the lane only inside its `init` | The accidental ways to mint a lane writer: by `admitted(at:)`, by building a handback by name, or by a property that returns a view. Lexical scans do not converge on deliberate evasions, so they claim only this |
| The positive stored-plane census, at rest and after a firing | Which reachable stored planes are in the lane. A plane captured by a closure or a `Task` is not reachable, and is not covered |
| The compiler, with a source pin on the three lending signatures, `FanRestoring` pinned to its one requirement, and no unsafe spelling outside the two IOKit bridges | That a lent handback is not kept, in safe Swift, through the parameter |
| CI's lending probes (`scripts/lending-probes/check.sh`), ten refused shapes compiled in full on the runner's own toolchain, each required to fail only with its own diagnostic, its whole message compared as text and never as a fragment, at its own line | That the toolchain CI ships with still refuses them — every shape but the key path |
| K6, and `SupervisorWriterAdmissionTests` | That no other mechanism writes in the lane, by behaviour, on the paths they drive: K6's teardowns after a firing (the TTL, invalidation, release, § 5's revocation, the panic verb's drop, § 4, § 6 and the teardown's own `run`), every call each makes, reads included, on a frozen clock with no supervisor running; level 6, § 5's re-assert, give-up and lapse hand-back (`restoreAndForget`), § 7 and § 6's machine-wide restore, at rest and after a firing; and the two closures `bringUp()` installs, the signal teardown and the power observer's sleep and wake, each fired through the source it was given and checked for every write it makes, a restore, command, engagement or bridge, and every envelope read, which § 3 never makes. § 3 reads in its lane while the supervisors run, so a control-state or critical-temperature read in the lane cannot be told from its own there, and these two drives do not check one. A path neither drives is not covered, and is held by the lexical scans alone |
| The overlap report | The one-producer premise, at run time |

The cause census stays. Its reason is now provenance — who may label a restore § 3's — and not
routing.

### Tests, each with the mutation that must turn it red

All runs are local, over the whole non-hardware suite; CI does not run mutations.

| ID | Test | Mutation that must turn it red |
|---|---|---|
| K1 | `ThermalCycleLaneRoutingTests.theRestorerIsCauseBlind` — every `FanRestoreCause`, § 3's included, restores once, and every call it makes is at `.supervisor` | A lane bound in `HelperFanRestorer`, chosen by a switch on the cause. A lane writer kept by the composition and bridged through by `HelperFanRestorer` on `.thermalEmergencyRevocation` (K1b); a check on the `.fan(0)` restores alone passed it |
| K2 | `ThermalCycleLaneRoutingTests.sectionThreesRevocationHandsBackThroughItsHandback` — a firing over two fans with every restore refused is three and three `.fan(n)` attempts, all in the lane, in one `cycle()` | `admitted(at: .thermalCycle)` dropped from the handback's initialiser. The verb lending `restorer` instead of its parameter. A second `restore(through: handback)` in the verb |
| K3 | `HelperRestorerTests`' registry tests, run over the release and over § 3's handback; `HandbackLendingBracketTests.sectionThreesFiringTellsSectionFive`, § 3's own route through `cycle()` | The handback restoring through its bound directly, bypassing `handBack`. § 3's three revocations lending a hand-built bound over its writer instead of the handback |
| K4 | `HandbackLendingBracketTests` — the fan is mid-handback throughout, a grant meanwhile is refused `.releaseInProgress`, and a refusal is recorded abandoned | Lending outside `restore`'s bracket. Lending the standing restorer, which fails at once rather than at the time limit |
| K5 | `ThermalCycleLaneWriterTests`' census, at rest and after a full § 3 episode: the same four lane sites, the handback's at `ThermalEmergency.handback.bounded.attempting.writer.plane` | The signatures weakened to copyable and the handback stored in `LeaseAuthority` for `expireLapsedLeases`: red after the episode, naming the stored field. Unweakened, it does not compile |
| K6 | `ThermalCycleLaneRoutingTests.afterAFiringEveryOtherPathRestoresAtSupervisor` — TTL, invalidation, release, § 5's revocation, the panic verb's drop, § 4, § 6 and the teardown's `run` with a closure of the test's own, every call each makes at `.supervisor`, reads included (the closures `bringUp()` installs, the signal teardown and the power observer, are driven by `SupervisorWriterAdmissionTests`) | The handback given to `LeaseAuthority` as its standing restorer. A lane writer kept by the composition and bridged through by `HelperFanRestorer` on `.leaseExpired`, after an envelope read at `.supervisor` (K6b); a check on the restores alone passed it. Storing the revocation's cause and replaying it on the TTL path stays green, correctly: the cause routes nothing |
| K7 | `ThermalCycleHandbackTripwireTests`, and the updated counts in `ThermalCycleLaneTripwireTests` | A lane view minted in `Lease/`. `~Copyable` dropped from a constraint. `borrowing` dropped (with `~Copyable`; alone, it does not compile) |
| K7′ | `ThermalCycleHandbackShapeTripwireTests` — who builds a handback, the two lane files' shape, `FanRestoring`'s one requirement, no unsafe spelling anywhere in the helper outside the two IOKit bridges, pinned per file | A second handback built inside the signal teardown's closure (CX1), or by § 6 over its own plane (R6). A writer extension in the handback's file returning a lane view, used at § 5's re-assert (L2b). A defaulted requirement handing back a closure over `self`, kept by the lease core (M17). A bitwise copy of the borrowed handback into an `UnsafeMutablePointer` (M14) |
| K7″ (round 2) | `SupervisorWriterAdmissionTests` | § 5's re-assert commanded through a lane view from the handback's file (L2b), or through a nested `LaneWriter` reached by a `typealias` (C1). A handback kept by the composition and restored through by the teardown `bringUp()` installs (A1), or by the power observer it installs (U3). § 3's lane writer kept by the composition and bridged through by either closure (U3b), or § 3's lane view kept and used for envelope and control-state reads on `.willSleep` (M3b: red for the envelope read; a control-state read alone is not told from § 3's own). § 5's hand-back of a fan whose lease lapsed, restored in the lane at `restoreAndForget` (U1) |
| K7‴ (round 2) | `ThermalCycleHandbackShapeTripwireTests` | A nested type in the handback, before its own `init` (C1); a `static` factory in it, or an instance factory calling `Self(…)` (G2) or an unapplied `Self.init` (G2b); a `typealias` of it, including one wrapped after its `=` (G1); an unsafe copy relocated into `Safety/` |
| — | CI's `Lending probes` step | A refused shape that compiles; a probe failing for another reason — a missing `borrowing`, an undefined type; the positive control failing; an expectation broadened to an alternation or shortened to a fragment, which no longer equals the message and fails |
| TBR | `ThermalCycleLaneOverlapTests.sectionThreesTakeBackRevokesARacedLeaseOneRequestAtATime` — a lease granted across the latch's engagement, revoked by the take-back through the handback, one request at a time | The revocation started as an `async let` beside the bridges |
| K8 | One local `xcodebuild` of the shipping helper target, the repository's first use of noncopyable generics | — |

The per-file counts move with it: the lane's word leaves `HelperFanRestorer.swift` for
`ThermalCycleHandback.swift`; the cause's leaves `ThermalEmergency.swift` (three) and
`HelperFanRestorer.swift` (one) for `LeaseAuthority.swift` (one).

### Alternatives considered

- **Routing by cause, as #439 first built it (rejected).** Its key is a value every teardown path
  carries through the widest actor in the helper, and it can be kept and replayed without being
  named.
- **A lane restorer the lease core holds at rest, reached by a § 3-only verb (rejected).** Nothing
  at compile time stops the next teardown path from reaching it.
- **§ 3 restoring outside the lease core, with a begin and a finish (rejected).** It splits
  `releasing` across two actors.
- **A non-escaping closure lent by § 3 (the fallback).** The same compile-time guarantee, without
  `FanRestoring`'s contract.
- **A noncopyable handback (rejected for now).** It blinds the reflection census.
- **A task-local flag (rejected).** An unstructured `Task` inherits task-locals.
- **Routing by cause, plus a sweep after each firing (rejected).** The sweep covers only the paths
  it names, so it is defence in depth at best.

### What b2 must implement

b2 brings the write plane's bodies to `e4/bring-up`, and with them the same properties on real
write turns. Listed here because a pull request's body is not where an obligation should live:

- **B1.** Each of the plane's write verbs — `commandTarget(_:)`, `restoreToAutomatic(_:)`,
  `engageManualControl(of:)` and `bridgeThenRestore(_:)` — takes its turn at the plane's own
  `admission` and ends it there (`takeTurn(at:)`, `endTurn(at:)`), and none of them takes an
  admission or a cause argument. § 3's bridge jobs and its handback's restore turns run in the
  lane; every other write at `.supervisor`. Mutations: a write verb's turn hard-wired to either
  admission; an admission parameter defaulted to `.supervisor` that a restorer passes
  `.thermalCycle`.
- **B2.** K6 again, on real write turns with the plane `.built`.
- **B3.** K3 and K4 again, on the write plane; § 5's notice comes before the restore turn is
  requested.
- **B4.** A firing with every restore refused, at N = 12 and N = 40, with a TTL expiry and a § 5
  revocation landing mid-firing at `.supervisor`: each lane turn granted after at most one other
  turn, inside the allowance, and no overlap report. Mutation: the standing-restorer mutation (K6's),
  which must report the overlap and exceed the allowance.
- **B5.** K5 on the write-capable composition: the channel and the ledger shared through every view,
  at rest and after a firing.
- **B6 [HW].** W7/D8 also time the handback's lane restore turn, and a refused one, against the
  86.98 ms break-even.

#439's W-list — likewise recorded only in that pull request's body — still applies: W1, every write
turn at its plane's admission (which B1 sharpens); W2, the bridge job as one `withWriteTurn` of the
command's and the restore's bodies, in at most five round trips; W3, the bridge's restore requested
before the job waits for its turn, and its order inside the turn; W4, a firing under sustained load
within the allowance (which B4 extends); W5, § 3 completing cycles during an engagement's poll and
under load; W6, the two-plane contract suite over the bridge verb, every command-half failure still
restoring; W7 [HW], D8's per-round-trip latency of a bridge job, a `.fan` restore and a refused one.
The sync that carries this amendment onto `e4/bring-up` must also scan a plane built with a write
channel at all four lane sites, the handback's included: `PlaneViewTests` scans a plane with none.
*(Done by that sync: `PlaneViewTests.everyLaneSiteHoldsThePlanesChannel` composes the graph over a
plane holding `FirmwareSMC` and holds each lane site to that channel, and to the plane, by
identity.)*

**Revisit if:** a toolchain accepts any of the refused shapes (fall back to the closure) — they were
observed on Swift 6.4, and CI's lending probes compile them on every run's toolchain, so a toolchain
upgrade that accepts one turns CI red; a second user of the lane is proposed; a composition edit
that hands the handback to a second holder survives review; the lease core gains a second verb that
lends a restorer; `FanRestoring` gains a requirement, or the helper an unsafe spelling; a second
holder of the handback of A1's class — the composition keeping a copy for a path of its own — is
proposed, at which point the optional structural fix is to have § 3 build its own handback from
what it is given, so the composition never holds one (not built: today the composition builds it
once and holds it nowhere); or the overlap report ever fires.

**No `AeolusXPCVersion` bump**: nothing crosses the boundary.

## Amendment (2026-10-31, [#465](https://github.com/blamechris/Aeolus/pull/465)) — the engaged step at rest counts nine, once per fan, and an open family is ruled by its reach, not its figure

**Status.** Accepted on architect review of #465, under ADR authority. It applies on `e4/bring-up`,
where ADR 0014's P1′ engaged turn is built; `main` has no `engagedStepRoundTrips` until E4 merges.
D, D_cycle, D_bringUp, G, the tick and the two-tick rule are unchanged. It re-runs G's lower side
for the engaged step, and on the branch it supersedes the #332 amendment's figures for the modelled
cases, the closed histories and the open families. Every figure here is printed, and the ones it
leans on asserted, by [`scripts/gate-wait-model/engaged_step.py`](../../scripts/gate-wait-model/engaged_step.py).

### Context

ADR 0014's P1′ amendment (decision 4) raises a fan engaged at rest to its floor in the turn that
reads back engaged. That turn is the longest a supervisor reader takes:
- eight round trips with `F<n>Tg`'s key info cached: the mode key's fresh info, the pre-state, the
  mode write, its read-back, the target's read, its fresh info, the floor's write and its read-back;
- nine when the info is not cached. The preparation step takes it, and so does every grant's
  control-state read, but each carries a failed read rather than throwing it, so the first engaged
  turn can find the key cold. `freshKeyInfo` replaces the cache entry, so the floor's read-back is
  never cold.

ADR 0014 asked for G to be re-run at N = 12. If it failed, the queue was to count at most one long
turn per fan with an engagement in progress. If that failed too, the floor was to be raised in a turn
of its own.

### Decision

- **`WatchdogLimits.engagedStepRoundTrips` is 9.** It counts the step that reads back `1`, whatever
  that step writes and whatever the cache holds. It raises in eight warm and nine cold, and holds in
  five warm and six cold. `readerTurnRoundTrips` is 9, and G's slot adds it. `writeTurnRoundTrips`
  stays 5, so D_cycle's allowance is unchanged: 632 round trips, 13.34 s. Each of § 3's lane turns
  waits for at most one turn in flight, and that turn is counted at 64 read round trips, 733.0 ms
  at the measured worst read. Under D_cycle's own model, § 3's reads at that 11.453 ms and its
  writes at W, the cold raise (seven reads and two writes) fits that count while 80.2 ms + 2W is at
  most 733.0 ms: up to a W of about **326 ms**. That is far above D_cycle's 86.98 ms break-even for
  § 3's own writes, so they still bind first, and both are above the about 20.5 ms at which G's
  modelled slot already breaks (What remains).
  *(Corrected on #465's delta review. This amendment first compared 64 × 11.453 / 9 = 81.4 ms,
  91.6 ms at eight, with 86.98 ms. That takes all nine round trips at one latency, which is another
  model: under it D_cycle itself breaks at about 14.1 ms, where 632 round trips fill the 8.9 s it
  leaves after the interval, the slop and D. The figure erred safe.)*
- **G's queue counts at most one engaged step per fan at nine, and every other reader at five**
  (`WatchdogLimits.readerTurns`). Taking every reader at the engaged step fails four of the
  histories this ADR counts closed: 874–892 round trips at eight. The one-per-fan count rests on ADR
  0014's examination gate, which admits one engagement per fan at a time; an engagement's steps are
  sequential, and only the step that reads back `1` is long. On `Mac16,5` (K = 34, F = 2) at N = 12:
  - the queue is 64 + 34 + (9·2 + 5·7) + 64·6 = **535**, against 527;
  - the modelled case is **829 round trips, 9.49 s**, and the slot **838, 9.60 s**;
  - G holds to N = 12 and not at 13 (932, 10.67 s);
  - the closed histories are 795–839 round trips (9.11–9.61 s), and the event model's worst is 619
    (7.09 s), all under G.
- **What a re-run of G must pass, stated once:**
  - the modelled cases and the slot, which `WatchdogLimitsTests` pins;
  - the histories this ADR counts closed;
  - the event model.

  The open families are counted and recorded at every change to a turn's length, and they do not
  gate. One has been over G since the #332 amendment. ADR 0014's "if it fails" means these
  criteria.
- **The open families move.**
  - A take-back with writes every cycle is **927 round trips, 10.62 s**. It is over G, as before.
  - A refused revocation every latched cycle is **867–877, 9.93–10.04 s**. Its upper member, after a
    firing and a take-back, now passes G as a wait.

  That member's slot passed G before the engaged step existed: 869 + 5 = 874 round trips, 10.01 s.
  The #332 amendment's "under G" described the wait alone.
- **What the family needs to recur.** Each lease is revoked once, because `revokeEveryLease`
  empties the table, and grants are refused while § 3 holds. A lease therefore reaches a latched
  cycle only from a grant that passed the latch check before the firing. Two more rules bound it:
  - a fan whose revocation is refused on every attempt lands in `restoreAbandoned`. The grant refuses
    such a fan after its last suspension point, and only § 7's read-back lifts the refusal;
  - so at most F fully refused revocations follow one firing. Counted at full cost, those histories
    are 819–863 round trips, with slots of 828–872 (9.48–9.99 s), all under G.

  The member over G needs five consecutive full-cost revocations after the firing and its take-back.
  Beyond the first F, each needs the firmware to refuse a restore twice and accept it on the third
  attempt, and each needs a separate grant that raced the latch. All of this was read from the code
  at `390da86`; no test holds it.
- **What passing G costs in that history.** Nothing ends the helper, and nothing writes away from
  automatic control.
  - The gate fault is logged, once per waiter.
  - In ADR 0014's examination gate, three slots of 10.15 s plus `stepWait` are 31.44 s. That is
    inside `examinationWait`'s 32 s, and it spends 0.44 s of the 1 s `examinationMargin`.
  - An `apply`'s per-fan time, 51.74 s, stays inside `applyPerFan`'s 52 s.

  The take-back family, open since the #332 amendment, is the one that can outlast § 5's wait:
  33.16 s. *(Its `apply` per-fan time, 54.60 s, is past `applyPerFan` as well, as it was at the
  #332 amendment's figures, 53.91 s.)*
- **The floor is not moved to a turn of its own** (ADR 0014's second fallback). It would leave every
  fan engaged at rest in manual at a target of 0 for up to a slot. That is the stopped-fan window the
  P1′ amendment closed. In exchange it would move this family's wait by 0.09 s, to 0.047 s under G
  (877 to 869 round trips, 10.044 s to 9.953 s), while leaving its slot at 10.01 s and the
  take-back family at 10.58 s.

### What remains

- **Write round trips are unmeasured** (ADR 0014's U8). Every figure here takes a write at the
  measured read maximum. G's modelled slot at N = 12 holds while a write round trip stays under
  about **20.5 ms**: about 20.4 ms before the engaged step, by this amendment's extension of the
  model with reads at 11.453 ms and the turn shapes of `SMCWriteTurns`. That is well below the 50 ms
  of the #332 amendment's revisit list and D_cycle's 86.98 ms. D8's per-write log lines are compared
  against it.
- **Cold key info in any other read** stays where the #332 amendment put it: inside the margin, once
  per key per process. A control-state read with three cold keys takes six round trips.
- **The fully refused bound is read, not tested.** A test that a revocation refused on every attempt
  leaves its fans refused at insertion, so that the next latched cycle's revocation issues no turn,
  would close that form of the family.
- **If an open family is shown to recur**, the structural remedy is in the lease core, not the
  plane: a latch generation readable without a suspension, checked in the grant's straight-line
  region, so that no grant that passed the latch check before a firing inserts a lease after it.
  That would take both families' leases away. It is not built.

### Tests, each with the mutation that must turn it red

| Test | Mutation that must turn it red |
|---|---|
| `WatchdogLimitsTests.theGateBoundIsDerivedAndConstant`, `theGateBoundHoldsForEveryCuratedSet` (829; 9.49 s; N = 13 at 932, 10.67 s) | `readerTurns` with no engaged step (821). Every reader at the engaged step. The lane omitted (535). Window (a) without its firing. `engagedStepRoundTrips` at 8 |
| `WatchdogLimitsTests.theGateBoundCoversAWholeTurn` (slot 838, 9.60 s) | `gateWaiterAlarm` at 9.5 s: the wait, 9.49 s, clears it and the slot does not. `readerTurnRoundTrips` without the engaged step |
| `SMCWritePlaneTests+ForceKey`'s C26 row, with `F0Tg`'s key info failing at preparation: the engaged turn at rest is nine, equal to `engagedStepRoundTrips`, and under load six; warm, eight and five | `engagedStepRoundTrips` at 8. The target read twice in `holdFloor` (ten). `survey` taking no target key info (the warm rows become nine and six) |

**Alternatives considered**
- *Every reader at the engaged step.* Four closed histories pass G.
- *The floor in a turn of its own, with abort 10* (ADR 0014's second fallback). It brings back the
  stopped-fan window, and it closes neither family's slot (see the Decision).
- *Raise G.* It is I8's constant, it lengthens `examinationWait` and `applyPerFan` and the client
  deadline copied from them, and it would fit the bound to a history no one has shown can occur.
- *Lower the design point to N = 11.* That trades a stated reach for a narrower one, and nothing
  bounds N (#332).
- *Keep eight, and make the step take the target's key info first and hand it to the write.* The
  turn would then be eight whatever the cache holds, which is the B1 ruling's principle. But it
  splits a body the command turn shares, in reviewed write-path code, to save 11 ms against 0.40 s
  of margin.
- *Refuse to engage a fan whose target key info is cold.* It turns a transient read into a lasting
  refusal, and it needs either new state or a view of `SMCCore`'s cache.

**Revisit if:**
- a worst write round trip above 20 ms is measured (D8, W7, B6);
- an open family is shown to recur: a lease reaching consecutive latched cycles, or a restore
  refused and then accepted within one attempt budget, in any run;
- the gate fault or § 5's outwaited `.fault` is logged at N ≤ 12;
- a change lengthens the engaged turn;
- `freshKeyInfo` stops replacing the cache entry, which makes the floor's read-back cold too and the
  turn ten;
- the engaged turn is restructured for another reason (take the key info first, and the bound
  returns to eight);
- a third open family appears, or one whose cost reaches past a fault line and § 5's margin.

**No `AeolusXPCVersion` bump**: nothing crosses the boundary.
