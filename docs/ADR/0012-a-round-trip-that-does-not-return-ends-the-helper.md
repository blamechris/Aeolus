# ADR 0012 — A round trip that does not return ends the helper

- **Status:** Proposed
- **Date:** 2026-09-20
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

Process death is the only abandonment that is **ordered**. A task cannot finish exiting
while one of its threads is inside the kernel, and launchd starts no successor until it
has. So whatever the wedged call does happens before the next reconciliation reads the
mode keys. A false positive puts the fans back to automatic, which is the safe direction.
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
| Per-round-trip latency stays at least 100× below D, under contention and in dark wake | To be measured on `Mac16,5` (H1) | Raise D, or false positives will cost users their manual control. |

## To measure on Mac16,5 before relying on this (hypotheses, not facts)

- **H1 (sets D).** Per-round-trip maximum and p99.99 latency in four conditions: idle,
  during a contended `fanctl` walk, during failing dark-wake reads, and on the first read
  after wake. The expected D is about 5 s.
- **H2.** `kill -9` the helper during a walk. It should die promptly, and the successor
  should start only after the old process is reaped.
- **H3 (E4).** After the writer is killed, `F<n>Md` and `Ftst` stay manual.
- **H4.** How quickly launchd restarts a non-zero exit after a long uptime.
- **H5.** Whether launchd's SIGKILL follows `ExitTimeOut` when the teardown is parked.
- **Not measurable here:** whether a wedge is confined to one handle or covers the whole
  driver, and whether the kernel wait can be interrupted.

Every observation cited is from `Mac16,5` on macOS 26.6.2. Intel and M1/M2 are `untested`.
