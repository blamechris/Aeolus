# Testing

How the suite is run, and the one hazard that is specific to how it is run: tests that hold a
cooperative-pool thread on purpose ([#554](https://github.com/blamechris/Aeolus/issues/554)).

## How CI runs it

CI's `swift test --skip-build` runs every test target in **one process**: its log (run
40942348614, Apple Swift 6.3.3) has a single `Test run with 3393 tests in 510 suites` line per
configuration. Swift Testing runs the tests in parallel, and every `async` test, and every
synchronous one, runs on the cooperative pool: one thread per core, so **three on a hosted macOS
runner**. Nothing ends a thread that is blocked in a synchronous call, and nothing grows the pool
to make up for it.

That is not what a plain `swift test` does on every toolchain. On Apple Swift 6.4, the default
build system ran each target in its own process and printed nine `Test run with` lines. The
one-process run is `--build-system native`, which that toolchain prints a deprecation warning for
("will be removed in a future release"). When it goes, the one-process run needs another route.

A suite's `.timeLimit` cancels a test's task. It cannot end a thread parked in a
`DispatchSemaphore.wait()`, so a blocked pool thread outlives the limit, and a process whose pool
is all blocked runs nothing that would release them. It sits at 0% CPU until something outside
kills it.

## The rule

A test may hold a pool thread, because the product it tests does (a restore stuck in a
synchronous IOKit call is the case this repository exists to survive). It may not hold one on
a release that **needs** a pool thread, unless it is the only test that does and it says so.

- **Release a held thread from a `Thread` of your own.** The driver of the held window, its
  failsafe, and whatever signals the semaphore are dedicated `Thread`s. The `async` test then
  only suspends (on a continuation) and holds no thread while it does.
- **Give every hold a ceiling.** `signalled(_:within:)` (`SliceCountedWait`, whose budget a
  stalled runner cannot spend), or a timed wait. A block that is never released must end, so
  that the process can. For a hold the pool has to release, put the ceiling above the suite's
  `.timeLimit`, so that a slow run never trips it: the time limit ends the test when the pool has
  a free thread, and the ceiling ends the process when it has none. A hold a `Thread` releases
  should fail safe sooner: nothing it waits for needs the pool, so it has no slow pool to
  outlast, and the 30, 10, 5 and 3 s failsafes in the tables below are the better design.
- **Put the release in a `defer`** when it is synchronous, so a test that fails before its own
  release leaves nothing parked.
- **Poll with `Task.sleep`**, never by waiting on a semaphore that a pool task signals.

## Every test that holds a pool thread

Found by searching `Tests` for `DispatchSemaphore`, `NSCondition`, `Thread.sleep`, `usleep`,
`Process.waitUntilExit`, `DispatchQueue.sync`, `NSLock` held across a wait, and spins; every hit
was read. What is *not* here suspends, which gives its thread back: `AsyncSignal`, `Task.sleep`,
`withCheckedContinuation`, actor hops.

**Needs the pool to be released (the hazard):**

| Test | Holds | Released by | Bound |
|---|---|---|---|
| `SystemPowerTests.theBudgetSurvivesARestoreThatBlocksItsThread` | the pool thread running the keystone restore: `ThreadBlockingRestorePlane`'s `DispatchSemaphore` | `plane.release()`, from the test's own task, once the budget's task (also a pool task) has acknowledged; also in a `defer` | 90 s ceiling, above the suite's 60 s time limit: with a free pool thread the time limit ends the test and the `defer` releases the plane; with none, the block opens at 90 s with an issue and the process ends. Needs a pool of two or more. |

**Held until a `Thread` or a timeout releases it (cannot exhaust a pool):**

| Test | Holds | Released by |
|---|---|---|
| `SMCRoundTripMonitorTests.theStampIsReadableWhileTheConnectionIsOccupied` | the pool thread inside `SMCConnection.occupyForTesting`, parked on a `DispatchSemaphore` | the driver `Thread`'s `defer`, after a 0.25 s window; else a 30 s `signalled(_:within:)` wait |
| `HelperWatchdogCompositionTests.theWatchdogNeverEntersTheConnectionActor` | the same, through the same seam | the driver `Thread`'s `defer`, after two synchronous ticks; else a 30 s wall-clock `wait(timeout:)` |
| `SMCRoundTripMonitorTests` (five synchronous tests: the bracket, the sequence, the lock, the clearing, the suspending clock) | the test's own pool thread, in `signalled(_:within:)` / `observeInFlight` / `ParkedRoundTrip.waitUntilParked`, up to 10 s (3 s for a read) | a dedicated `Thread` signals the semaphore |
| `SMCRoundTripMonitorTests.anAgeIsNeverNegativeUnderContention` | the test's own pool thread, reading the monitor in a loop, then a `DispatchSemaphore` | a writer `Thread` ends the loop and signals; the wait is 10 s |
| `ThreadBlockingCeilingTests.threadBlockingRestorePlaneGivesUp` | the pool thread running a blocked restore, for the 1 s ceiling it is given | that ceiling |
| `SliceCountedWaitTests` (four) | the test's own pool thread, in `Thread.sleep` (at most 0.3 s) and semaphore waits | their own timeouts; one is signalled by a `Thread` after 0.1 s |
| `IntegrationTests` signed-fixture tests (`AdHocSignedFixtures.codesign`) | the test's own pool thread, in `Process.waitUntilExit()` on `/usr/bin/codesign` | `codesign` exiting |

**Not a pool thread (listed so nobody searches again):**

| Where | Holds | Released by |
|---|---|---|
| `WedgedRoundTrip` (`WatchdogDoubles`), `ParkedRoundTrip` (`RoundTripTestSupport`) | a `Thread` the double starts | the test (`finish()` in a `defer` for `ParkedRoundTrip`); `WedgedRoundTrip` also has a 120 s failsafe |
| `ScriptedProgressClock` (`LivenessWatchdogClockTests`) | the `Thread` the **test** starts (`aLateCompletionCannotPassAPhaseChange`) to call `recordCompletion()`: the clock parks whichever caller reaches its second read | the test's `clock.release()`; else a 30 s `signalled` wait |
| `RoundBarrier` (`WatchdogEndingTests`) | two `Thread`s the test starts, each spinning in `sched_yield()` until both have arrived: a spin, not a wait | both arriving; else it gives up after 20 s |
| `HealthSignalThreadRaceTests`, `LeaseDriverPublisherThreadRaceTests` (`NSCondition`) | `Thread`s the burst starts, which wait on each other | the publisher thread |
| `QuitOffTheMainActorTests` (three) | the **main** thread, up to 5 s (2 s in one): the main actor is held on purpose | in one, a detached pool task signals the semaphore, so it needs a free pool thread and holds none; in another a `Thread` queues the block; the third needs nothing |

### The bound

Only the first table can wedge, and it has **one** row, so at most one pool thread is ever held on
a release the pool has to deliver. Every other hold ends on its own, without a pool thread, within
the bound in its row. Take a pool of `N` threads:

- `N >= 2`: at worst `N - 1` threads are held by tests in the second table, each freed by a `Thread`
  or a timeout. The row in the first table gets a thread as soon as one is freed, so nothing waits
  forever and the longest wait is the longest hold in the second table. `N = 3` is CI.
- `N = 1`: the first table's test cannot run. Its claim is that the sleep budget is delivered while
  a restore holds a thread, so something else has to be left to deliver it. Unskipped, it blocks
  until its 90 s ceiling opens the block, then fails (the run measured for #554 ended at 103 s,
  with the time limit recorded after the ceiling, not before); skip it by name (below).

The first table's test cannot move onto a dedicated `Thread` and keep its claim. A restore that parks
a thread of its own, while its caller suspends, is `WedgedRestorePlane`, which the doc on
`ThreadBlockingRestorePlane` calls the weaker model. The bound is the answer for that test; a new
row in the first table is a decision to make in review, with the bound redone.

## Running the whole suite on a pool of one

```bash
swift build --build-tests --build-system native
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 gtimeout -k 30 1200 swift test --skip-build --build-system native \
  --skip HelperHardwareTests --skip HelperHardwareSightingTests --skip WatchdogHardwareTests \
  --skip SMCSensorProviderTests --skip SMCConnectionTests --skip HardwareSmokeTests \
  --skip theBudgetSurvivesARestoreThatBlocksItsThread
```

`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` makes the cooperative pool one thread wide. The hardware
suites are skipped because they need an SMC and a quiet machine. The last `--skip` is the only
test that cannot run on a pool of one, for the reason in "The bound". The run should complete in
about a minute with no failure. Anything that wedges it, or needs a second thread to pass, is a
new row for the first table, or a bug in the test.

`--build-system native` is deprecated on this toolchain (Apple Swift 6.4 prints "has been
deprecated and will be removed in a future release"), and it is what makes this one process:
without it, `swift test` on that toolchain runs each target in its own process, which is not the
run CI does, and a pool of one then applies to each target separately.

`timeout` does not exist on macOS; `gtimeout` is from `brew install coreutils`.
