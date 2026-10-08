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
restores automatic control. The restart relies on `KeepAlive = { SuccessfulExit = false }`,
which lands in the order ADR 0007 sets. Nothing in the process abandons a round trip,
times one out, or reopens the connection.

Detection runs on a timer on a dispatch queue the watchdog owns. It reads round-trip stamps
(sequence, key, selector, and a start time on the suspending clock), published under a
lock, without an actor hop.

- D is a constant, set from a measured per-round-trip maximum.
- No message or configuration can disarm D or lengthen it.
- The watchdog is armed before reconciliation's first read and stays armed through
  teardown.
- It lands before E3, and is a precondition of any lease grant on a build that has a write
  path.

### Invariants

*I1, I4 and I5 are amended: read them with the 2026-10-08 amendment at the end of this document.*

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
   through the orderly teardown.
7. **I7.** Nothing is abandoned in-process. Nothing resumes the caller of a round trip that
   has not returned. Nothing closes or opens the connection while a round trip is stamped
   in flight.
8. **I8.** D is a constant. No XPC message and no configuration can disarm it or lengthen
   it.

### Tests, each with the mutation that must turn it red

| Test | Mutation that must turn it red |
|---|---|
| `aWedgedRoundTripEndsTheProcessNonZero` | Delete the `terminate` call. Separately, map `.blind` to exit code 0. |
| `continuousShortRoundTripsNeverTrip` | Drop the same-sequence check. |
| `aRoundTripSpanningSleepIsNotAWedge` (the comparer mints the instant) | Swap in `ContinuousClock`. |
| `theWatchdogNeverEntersTheConnectionActor` (the actor is really blocked on a semaphore, not a mock that only suspends) | Read the stamp through an actor hop. |
| `theStampBracketsTheIOKitCall` | Take the stamp after the call. |
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
argument fails with it, and the table says what to revisit. A false positive puts the fans back to automatic, which is the safe direction.
The recovery it triggers already exists and is tested.

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
- **A recurring wedge produces a restart loop of a root daemon.** Each pass restores
  automatic control. This is accepted because every iteration ends in the safe state.
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
| Per-round-trip latency stays at least 100× below D, under contention and in dark wake | To be measured on `Mac16,5` (H1). **Partly measured, 2026-10-07, on macOS 27.0.1:** idle, and contended by one and by three concurrent `fanctl` walkers, reads only. The worst round trip was 11.45 ms, so 100× is 1.15 s and the expected D of about 5 s is about 437× that maximum. **Not yet measured:** dark wake and the first read after wake. D is not set. | Raise D, or false positives will cost users their manual control. |

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
  of the four conditions, not a value for D, and D is not set here.** Every figure is an
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
- **Not measurable here:** whether a wedge is confined to one handle or covers the whole
  driver, and whether the kernel wait can be interrupted.

Every observation cited is from `Mac16,5`. Those made before 2026-10-07 were on macOS 26
(26.6.2 where the OS is recorded; it is not recorded for every early figure, such as the
24.9 s walk); #296's measurements (H1) are on macOS 27.0.1 (26A434). Intel and M1/M2 are
`untested`.

## Amendment (2026-10-08, [#329](https://github.com/blamechris/Aeolus/issues/329)) — accepted, the constants, and four corrections

**Status.** Accepted. Two things were decided on 2026-10-08, and they are different decisions.
The **ordering** — the watchdog lands before E3 and before any lease grant on a build with a
write path, the supervised E4 experiment ([#9](https://github.com/blamechris/Aeolus/issues/9))
included — was the owner's, recorded on
[#293](https://github.com/blamechris/Aeolus/issues/293). This **amendment**, and the split of the
work into three pull requests (the stamp, the watchdog, the #135 gate trigger), was decided on
architect review. D stays provisional: it is confirmed for reads only, and not for write selectors
or for dark wake. It is revisited when [#296](https://github.com/blamechris/Aeolus/issues/296)'s
conditions 3 and 4 are measured and when the first supervised E4 write has recorded its own
per-round-trip latency. A persistent wedge becomes a throttled restart loop in which every pass
ends in reconciliation; that consequence is accepted above and is unchanged.

### The constants

| Constant | Value | Bounds | Derivation |
|---|---|---|---|
| **D** | 5 s (provisional) | One stamped round trip. | About 437× the worst of 912,000 measured reads (11.45 ms; the four conditions in H1, [#296](https://github.com/blamechris/Aeolus/issues/296)). Reads only. |
| **D_cycle** | 2·D = 10 s | No completed § 3 cycle, while armed. | See below. |
| **D_bringUp** | `ReconciliationLimits.budget` + D_cycle = 15 s | Arming to `ThermalSupervisor.start()`. | The reconciliation budget (5 s) plus one cycle's allowance. |
| **G** | D = 5 s | One parked gate waiter, for [#135](https://github.com/blamechris/Aeolus/issues/135)'s `.fault`. | Set equal to D, per parked waiter. |
| **Tick** | 1 s | The watchdog's timer, a `.strict` `DispatchSourceTimer`. | A verdict needs two over-bound ticks, so it lands at most two ticks after the bound is crossed. |

**A verdict needs two consecutive over-bound ticks on the same sequence** (the same round-trip
sequence number, or the same cycle-completion count). I3 already required the same in-flight
sequence on two ticks; the progress trigger is held to the same rule on its cycle-completion
count. One over-bound observation is not a verdict.

**Why D_cycle is 10 s and not smaller.** The § 3 cycle runs, then sleeps one second
(`ThermalSupervisor.defaultInterval`) measured from the cycle's end, so the gap between two
completed cycles is that second, plus timer slop (up to 100 ms of background coalescing has been
observed), plus the next cycle. D_cycle must exceed the interval, plus D, plus the rest of a cycle's
round trips at the measured worst: 1 s + 0.1 s + 5 s + (256 × 11.45 ms ≈ 2.93 s) = 9.03 s, so 10 s.
Set lower, a legal slow round trip would trip the cycle trigger before it tripped its own, and
D_cycle would silently become the per-round-trip bound.

### Corrections to the Decision

1. **I1 extends to `IOServiceOpen` and `IOServiceClose`.** `SMCConnection.open()` and `close()`
   are stamped as `.open` and `.close`, because `ConnectionHealth.reconnect()` runs them and either
   can block in the kernel exactly as a read can. Two IOKit calls remain unstamped, on purpose: the
   `deinit` (nothing holds a reference to read a stamp from) and the static
   `SMCConnection.isHardwareAvailable()` (a service lookup, not a round trip on the connection);
   a hang in the latter is caught by D_cycle, not by D.
2. **I4's progress trigger is armed from bring-up, not only while the supervisors run.** As
   written, the trigger was armed only after § 3 started, so a bring-up that stalled anywhere other
   than inside a stamped round trip, or that returned without ever starting the supervisor, was
   watched by nothing. It is armed with the watchdog, bounded by D_bringUp until
   `ThermalSupervisor.start()` and by D_cycle from then until `stop()`: § 3's `start()` and
   `stop()` switch its phase. A stopped supervisor is not a stall.
3. **I5's first-terminate-wins guard wraps the seam in `ProcessTermination`, shared with the
   SIGTERM teardown, and never consults `hasBegun`.** A lock-guarded `ProcessTermination` sits in
   front of `TeardownExit.process`, and both `SignalTeardown` and the watchdog end the process
   through it. It must not ask whether the teardown has begun: a teardown that has begun and
   wedged is the case I6 keeps the watchdog armed for. The exit-count tripwire stays at one site,
   and its pattern extends to `_exit(`.
4. **The gate trigger's `.fault` is suppressed while a stamped round trip is older than one tick.**
   A waiter parked behind a round trip that is itself overdue is explained by that stamp, and the
   per-round-trip verdict is the alarm; a second `.fault` for the same cause would only duplicate it.
   The gate trigger still raises `.fault` only and never ends the process.

### Two clock families in the helper

The helper now measures time on two different clocks, deliberately. Leases run on
`MonotonicClock`, which is backed by `ContinuousClock`: a lease must keep running while the machine
sleeps, so that it expires. The watchdog runs on `SuspendingClock`, through
`SMCRoundTripMonitor`: a round trip in flight across a sleep must **not** age (I3). **Unifying them
is not a tidy-up.** Moving the watchdog onto the continuous clock reintroduces the sleep false
positive, and moving leases onto the suspending clock stops them expiring across a sleep. The
monitor's clock is one `typealias` (`SMCRoundTripMonitor.MeasuringClock`), and a test asserts the
type rather than a clock it built.

### Tests added or sharpened by the stamp (PR A)

| Test | Mutation that must turn it red |
|---|---|
| `theStampBracketsTheIOKitCall` (stamped inside the body; cleared on return and on throw; sequence strictly increasing) | Take the stamp after the body. Separately, clear outside the `defer`. |
| `theLockIsNotHeldAcrossTheCall` (a reader is not blocked while the body is parked) | Run the body inside `withLock`. |
| The tripwire, tightened: exactly one `IOConnectCallStructMethod` under `Sources/` and `Tools/`, and it is inside `roundTrips.bracket(.call(…))`; `IOServiceOpen` and `IOServiceClose` in `SMCConnection` likewise, `deinit` excepted. Source normalised before matching. | Add a second call site. Separately, hoist the call out of the bracket. |
| `aRoundTripSpanningSleepIsNotAWedge`, the half CI can run (`Instant == SuspendingClock.Instant`; the age comes from the monitor's own clock, when it is asked) | Swap in `ContinuousClock`. Separately, compute the age when the stamp is taken. |

The watchdog's own tests, and the gate trigger's, are listed on
[#329](https://github.com/blamechris/Aeolus/issues/329) and carry their mutations in the pull
requests that add them. The hardware half of `aRoundTripSpanningSleepIsNotAWedge` (a real lid close
with a round trip in flight) has not been observed; it is H1 conditions 3 and 4.
