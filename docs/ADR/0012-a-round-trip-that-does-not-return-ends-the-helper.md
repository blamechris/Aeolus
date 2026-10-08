# ADR 0012 — A round trip that does not return ends the helper

- **Status:** Accepted (2026-10-08) — D provisional pending [#296](https://github.com/blamechris/Aeolus/issues/296) conditions 3–4 and E4's write-selector measurement
- **Date:** 2026-09-20 (amended 2026-10-08, see the last section)
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
restores automatic control **if its first read returns**; the amendment's "What the ending buys,
and what it does not" says where that stops being true. The restart relies on
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
automatic once its first read returns, which is the safe direction. The recovery it triggers
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
  a recovery.** Each new process's first reconciliation read hangs in the same driver, so the
  bring-up trigger ends it after D_bringUp, launchd throttles the next start, and **nothing
  restores a fan until the driver answers.** This ADR does not claim that every iteration ends
  in the safe state. What it accepts is that no pass of the loop writes anything: each ends at
  its first read, and a fan the driver will not answer for is left as it is.
- **A restart is not guaranteed.** Where launchd is itself removing or stopping the job — a
  bootout, `SMAppService.unregister()`, a shutdown — exit code 2 is not followed by a start,
  and nothing restores the fans.
- **The orderly teardown is bounded by D.** Only the round-trip trigger stays armed through
  it (stopping § 3 ends the cycle trigger: a stopped supervisor is not a stall), so a teardown
  restore in which any single round trip takes longer than D is cut off mid-restore. D is
  confirmed for reads only; see H6.
- **Exit codes:** `TeardownOutcome` gains a non-zero case. The exit-count tripwire stays at
  one.
- **#135:** its observer is the `.fault` from the gate-level trigger.
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
this paragraph said every pass ended in reconciliation. It does not: each pass is ended at its
first read.)

### The constants

| Constant | Value | Bounds | Derivation |
|---|---|---|---|
| **D** | 5 s (provisional, reads only) | One stamped round trip. | About 437× the worst of 912,000 measured reads (11.45 ms; the four conditions in H1, [#296](https://github.com/blamechris/Aeolus/issues/296)). |
| **D_cycle** | 3·D = 15 s | No completed § 3 cycle, while armed. | At least the interval (1 s), plus timer slop (0.1 s), plus D, plus the allowance at the design point of 12 outstanding supervisor reads (576 round trips × 11.453 ms = 6.60 s): 12.70 s. See below. |
| **D_bringUp** | `ReconciliationLimits.budget` + 2·D = 15 s | Arming to `ThermalSupervisor.start()`. | The reconciliation budget (5 s) plus 2·D. Independent of the outstanding-read count: no client can reach the helper before `listener.resume()`. |
| **G** | 2·D = 10 s, per parked waiter | [#135](https://github.com/blamechris/Aeolus/issues/135)'s gate-waiter `.fault`. | Must exceed the wait at the design point (the allowance without § 3's own read and the cycle's writes: 512 round trips × 11.453 ms = 5.86 s) and stay below D_cycle − interval − 2 ticks (12 s). Suppressed while a stamp is older than one tick. |
| **Tick** | 1 s | The watchdog's timer, a `.strict` `DispatchSourceTimer`. | A verdict needs two over-bound ticks, so it lands at most two ticks after the bound is crossed. |

**A verdict needs two consecutive over-bound ticks on the same sequence** (the same round-trip
sequence number, or the same cycle-completion count). I3 already required the same in-flight
sequence on two ticks; the progress trigger is held to the same rule on its cycle-completion
count. One over-bound observation is not a verdict.

### Outstanding reads, and why D_cycle is 15 s

How long a § 3 cycle can legitimately take is **not a constant**. It depends on *N*, the number of
supervisor-priority reads outstanding at once, and nothing in the helper bounds N. Besides the
fixed readers (§ 3's cycle, § 5's cycle, the grant path's curated read, which is single-flight,
and a reconnect's exclusive turn) there is one mode read per connection with an `acquireLease` in
flight and one per in-flight `restoreAllToAutomatic`, and nothing caps connections or those
messages ([#332](https://github.com/blamechris/Aeolus/issues/332)). Today's build is N = 3: the
write path is not built, so `acquireLease` refuses before it reads. The client-driven terms
arrive with E3.

D_cycle is therefore sized for a stated **design point of N = 12**. The scheduler admits
supervisor reads first-come first-served, in turns of at most `maxKeysPerTurn` (64) keys, and
forces a snapshot turn after every `maxConsecutiveOvertakes` (2) of them, so the allowance a
cycle has to survive, in round trips, is

> 64 + 34 + 3·(N − 2) + 64·(⌊(N − 1)/2⌋ + 1) + 34 + 30

term by term: **64**, the turn already in flight; **34**, the grant path's curated critical read
(single-flight); **3·(N − 2)**, the other outstanding readers' mode reads (`readControlState`,
three keys each); **64·(⌊(N − 1)/2⌋ + 1)**, the snapshot turns the overtake quota forces; **34**,
§ 3's own read; **30**, a firing cycle's writes and read-backs on two fans. Every round trip is taken at the
measured worst, as everywhere in this ADR.
At N = 12 that is 576 round trips, and at the measured worst of 11.453 ms each, 6.60 s. Adding the
interval, the slop and D gives **12.70 s**, which 15 s clears. At N = 16 the allowance is 716
round trips (8.20 s) and the requirement 14.30 s; at N = 17 it is 783 (8.97 s) and 15.07 s. **15 s
holds for N ≤ 16.**

**Above the design point, the cycle trigger firing is the correct outcome**: the helper ends and
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
  automatic control **if its first read returns**.
- A wedge that outlives the restart hangs that first read. The bring-up trigger ends the new
  process at D_bringUp, launchd throttles the loop, and nothing restores a fan until the driver
  answers.
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
requests that add them. The hardware half of `aRoundTripSpanningSleepIsNotAWedge` (a real lid close
with a round trip in flight) has not been observed; it is H1 conditions 3 and 4.
