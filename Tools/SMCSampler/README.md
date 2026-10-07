# smc-sampler

A maintainer measurement tool. It is never built by `project.yml`, never shipped in
`Aeolus.app`, and never writes to the SMC. It exists to unblock #210's rows 12 and 13 — see
#248 — by giving those captures an instrument that neither `fanctl watch` (fan keys only)
nor `fanctl sensors` (full enumeration, too slow and too invasive for a per-tick read across
a dark wake) can be.

Unlike [`Tools/PowerObserver`](../PowerObserver/README.md), which depends on nothing but
Foundation and IOKit specifically so it cannot become a second route to the SMC, this tool
depends on `SMCCore` and `FanKit` **on purpose**: its whole job is targeted
`SensorProvider.read(keys:)` subset reads, the same call `fanctl watch` and
`SMCFanEnumeration` already use. What it never does, and what
[`Tests/SMCSamplerTests/ToolsSeamTests.swift`](../../Tests/SMCSamplerTests/ToolsSeamTests.swift)
checks against the source rather than trusting anyone's memory of it, is depend on
`AeolusHelper` or name the SMC write seam (`@_spi(FanWrite)`, `SMCConnection.write`).

## What it samples

By default: this machine's critical sensor set (a read-only mirror of
[`CriticalSensorSet`](../../Sources/AeolusHelper/Safety/CriticalSensorSet.swift), resolved
the same way — by `HardwareIdentity.modelIdentifier`, never `uname -m` — and empty for a
machine nobody has measured) plus every enumerated fan's `Ac`/`Mn`/`Mx` keys, discovered
once at startup via `SMCFanEnumeration.enumerate(provider:)`. Pass `--keys` to sample a
different set instead:

```sh
swift run smc-sampler --keys=TPD0,TPD1,F0Ac > capture.ndjson
```

`--keys` takes a comma-separated list and is validated against `SMCKey`'s four-ASCII-
character rule at parse time — a typo is reported immediately, not discovered as
`"status":"unknownKey"` on every tick of an unattended capture.

## Running it

It needs no root, no signing identity, and no installed helper — every read goes straight
through `SMCSensorProvider`, the same as `fanctl`'s own read commands. Run it across one
real lid close, capturing to a durable path (not inside this worktree, which a teardown can
reclaim):

```sh
swift run smc-sampler --interval=1 > ~/Obsidian/no-it-all/handoffs/Aeolus-210-smc-sampler-<UTC date>.ndjson
```

Close the lid, wait for it to wake back up on its own, then bring the lid back up and press
a key so you can return to the terminal. Stop the tool with `Ctrl-C` (`SIGINT`) — it exits
cleanly and appends a `stop` line with the final tick count and both clocks. `SIGTERM` and
`SIGHUP` exit the same way, so a dropped terminal during a long attended capture does not
end the run with no `stop` line.

Flags:

- `--interval=<seconds>` — seconds between ticks. Default `1`.
- `--count=<n>` — stop after `n` ticks. Default: run until stopped.
- `--keys=<K1,K2,...>` — sample exactly these keys instead of the default set.
- `--latency` — time each read instead of sampling on a schedule; see
  [Latency mode (#296)](#latency-mode-296) below. Requires `--count`.

Immediately afterward, capture the system's own account of the same window:

```sh
pmset -g log | grep -E "Sleep|Wake"
```

Run both every time, the same discipline `Tools/PowerObserver/README.md` asks for its own
capture: neither one alone answers the question either tool exists for.

## Latency mode (#296)

The ordinary mode records *when* each tick happened. `--latency` records *how long each
read took*, because ADR 0012's wedge bound **D** has to come from the measured maximum and
tail of one SMC round trip (hypothesis H1 in
[ADR 0012](../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)), and
nothing else here measures that. It is the same read-only instrument: the reads go through
the same `SMCSensorProvider` as every other mode, and nothing in it can write.

What a latency run does:

1. Reads each key of the `--keys` set once, **untimed and unrecorded**, so its metadata is
   cached. After that, one `read(keys: [key])` is exactly one `READ_BYTES` call — one
   `IOConnectCallStructMethod` — because metadata is cached and values never are. That is
   what makes "time one read" the same measurement as "time one round trip". The warm-up
   outcome of each key, with its failure reason if it had one, is reported in the summary's
   `warmup` field, so the claim can be checked against the capture: a `readFailed` warm-up
   whose reason is a `READ_KEYINFO` error leaves the metadata uncached, and every timed
   read of that key is then itself a `READ_KEYINFO` trip.
2. Takes `--count` timed reads, **one key per call**, cycling through the key set in order
   (`F0Ac` alone by default; `--keys` replaces it). `--count` is the total number of timed
   reads, not the number of passes. They run **back to back**, with no sleep, unless
   `--interval=<seconds>` is given explicitly.
3. Writes one `read` line per read, then a `latencySummary` line. `Ctrl-C` (`SIGINT`, and
   `SIGTERM`/`SIGHUP`) ends the run cleanly and still writes the summary for the reads done
   so far, with `"interrupted":true`.

`--latency` without `--count` is refused at parse time: a run with no end would hold the SMC
in a tight loop until someone remembered it.

**What is timed.** The span is the `provider.read(keys:)` call and nothing else: the line is
written *after* the end stamp, synchronously and under a lock the heartbeat shares, so it
inflates no figure — but it means "back to back" has a gap of tens of microseconds between
reads, and the loop is not literally hammering the SMC. The span does contain the Swift
around the round trip (two actor hops, a dictionary, the outcome mapping) and whatever it
takes to wake the task when the call returns. That cost is **not measured**, and it need not
be small: a review run saw the median roughly double between a back-to-back and a paced run
(below), which looks like wake-up latency. So every figure is an upper bound on the round
trip and never an underestimate — the direction a wedge bound can safely err in — but it is
not the round trip itself.

**A read still in flight when the process is killed** (`SIGKILL`) **or wedged leaves no line
at all**, because a line is written only after the call returns. Under `SIGINT` the in-flight
read finishes and is recorded. For a kill or a true wedge the evidence is `heartbeat` lines
that go on with no further `read` lines.

Build in release, **once, before measuring**, and run the binaries directly from the
repository root. `swift run` would plan (and may relink) before it starts, and a build running
beside a measurement is the contention the measurement is not about. `swift run -c release
smc-sampler …` is the same program, for a machine where that does not matter. Two commands,
because `swift build --product` takes one product:

```sh
swift build -c release --product smc-sampler
swift build -c release --product fanctl
```

Each `read` line is about 175 bytes, so 100,000 reads is about 17 MB of NDJSON. On `Mac16,5`
a back-to-back read takes a few hundred microseconds (a 20,000-read release run took 4.1 s),
so `--count=100000` is roughly twenty seconds.

### Which clock sets D

**The suspending one.** ADR 0012 I3 ages a call on `SuspendingClock`, so a read that was in
flight when the lid closed is not a wedge, and the sleep it spanned must not count against D.
Every read line carries both durations and the summary carries both sets of figures:

- `…SuspendingNanoseconds` — what D is compared against. Use `maxSuspendingNanoseconds`,
  `p9999SuspendingNanoseconds`, `maxAllReadsSuspendingNanoseconds` (the max over reads of
  *every* status, failures included) and `slowestBySuspending`.
- `…ContinuousNanoseconds` — what a stopwatch would read. Its job here is to find the reads
  that spanned a sleep: one whose continuous duration is far above its suspending one slept
  mid-read. Its maximum is *the whole sleep* whenever a lid close caught a read in flight, so
  it is not a latency figure for that run, and a dozen such reads will own `slowestByContinuous`.

### Condition 1 — idle, paced (this is the idle row)

The helper does not read in a hot loop; it reads at a low cadence, from a cold CPU and a cold
cooperative-pool thread, and reads after an idle gap are slower. A review run on `Mac16,5`
(load average about 4, so not a clean idle, and small counts) saw `--interval=0.05 --count=300`
give p50 400 µs, p99 2.3 ms, max 4.1 ms, against p50 201 µs and max 978 µs back to back. The
idle row of the #296 table is therefore the paced run. A quiet machine: nothing else running,
display idle, no build in progress. `--count=12000` at 50 ms is about ten minutes and is
enough for p99.99 to mean something (it needs 10,000 completed reads).

```sh
.build/release/smc-sampler --latency --count=12000 --interval=0.05 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-idle-paced-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

### Condition 1b — idle, back to back (a separate row)

The same machine with no gap between reads: the hot-loop case, which is also what the contended
run below is made of. Keep it as its own row; do not merge it into the paced one.

```sh
.build/release/smc-sampler --latency --count=100000 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-idle-b2b-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

Size `--count` for the tail you want to report: p99.99 is only meaningful from 10,000
completed reads, and the summary says so itself (`p9999Meaningful`). A short run
(`--count=2000`) is a sanity check, not a measurement.

### Condition 2 — contended with a `fanctl` walk

`fanctl sensors` walks the whole key table, and a walk takes 22–24.9 s on `Mac16,5`. Run the
latency capture in one terminal while walks repeat back to back in another, and size
`--count` so the capture outlasts several walks. 400,000 reads is about a minute and a half
at the back-to-back rate, which is more than three walks; contention will only slow the
reads, so the capture lasts at least that long.

Terminal A:

```sh
.build/release/smc-sampler --latency --count=400000 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-contended-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

Terminal B, started a few seconds after A, and stopped (`Ctrl-C`) after A has finished:

```sh
while true; do .build/release/fanctl sensors > /dev/null; done
```

The slowest entries carry `atContinuousNanoseconds`, so a slow read can be placed against
the walks. Note the wall-clock time terminal B starts: the `heartbeat` lines carry
`wallClockUTC` and `continuousNanoseconds` once a second, which converts that time into an
offset on the same scale as `atContinuousNanoseconds`.

### Conditions 3 and 4 — dark-wake failing reads, and the first read after wake

These need **one attended lid close**: the process has to be alive and reading across a real
sleep and a real dark wake, and nothing here can cause one. Pace the reads so the file stays
a sensible size across a several-minute capture, and run `pmset` afterward, exactly as for the
ordinary mode:

```sh
.build/release/smc-sampler --latency --count=12000 --interval=0.05 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-wake-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

Close the lid, wait for the machine to wake on its own, then open it and stop the tool with
`Ctrl-C`. The process is suspended while the machine sleeps, and one lid close produces
several sleeps and wakes (seven were observed in #68), so look for all of them:

- **Reads that spanned a sleep** — in flight when the machine slept — have a continuous
  duration far above their suspending one:

  ```sh
  jq -c 'select(.kind == "read" and (.continuousNanoseconds - .suspendingNanoseconds) > 1000000000)' capture.ndjson
  ```

- **Each read after a wake** is a read that follows a gap far above the interval, between
  the end of the previous read and its own start (a sleep that falls between two reads leaves
  exactly this and no straddler):

  ```sh
  jq -c 'select(.kind == "read")' capture.ndjson | jq -s -c '
    [range(1; length) as $i | .[$i - 1] as $p | .[$i] as $r
     | select(($r.atContinuousNanoseconds - ($p.atContinuousNanoseconds + $p.continuousNanoseconds)) > 1000000000)
     | $r]'
  ```

- **Failing reads in a dark wake** are the `read` lines whose `status` is not `"ok"` and not
  `"notDecodable"`, with the reason in `failureReason` (`jq -c 'select(.kind == "read" and .status != "ok" and .status != "notDecodable")'`).
  A failing read is counted in the summary and kept out of its percentiles, but it is in
  `maxAllReadsSuspendingNanoseconds` and, unless ten reads were slower, in
  `slowestBySuspending`. Every read is on its own line whatever the summary says.

### Reading a latency capture

```sh
jq -c 'select(.kind == "latencySummary")' capture.ndjson          # the summary
```

**Percentiles are nearest-rank over completed round trips**, and the summary says how many
(`percentileSampleSize`). A completed round trip is a read whose status is `ok`, or
`notDecodable`: the `READ_BYTES` returned and its value is not a number (a string or flag
key), which is still a latency sample, so a `--keys` set that mixes numeric and non-numeric
keys measures all of them. `notDecodable` keeps its status on the read line and is counted
in `failureCount`. `readFailed`, `unknownKey`, `providerError` and `noOutcome` reads are
counted but not percentiled: the status does not say whether a round trip was made.
**Below 10,000 completed reads, p99.99 is the maximum under another name**; `p9999Meaningful`
is `false` and `p9999Note` says so. The same holds for p99.9 below 1,000 reads
(`p999Meaningful`). A run that is `"interrupted":true` has fewer reads than it asked for;
read its `count`, not its `requestedCount`.

This mode measures reads only. ADR 0012's D bounds every stamped round trip, so a write
selector's latency will need measuring when E4 can issue one; that belongs with H3. H2
(`kill -9` the helper during a walk) needs the helper and is not something a read-only tool
can answer.

## What each NDJSON line means

One JSON object per line, no line ever containing a literal newline:

- `"kind":"start"` — once, at launch. Hostname, `hw.model`, OS version, uid, pid, the
  resolved `--interval`, and — the field that makes a capture reproducible and auditable —
  the exact `keys` this run is sampling and a `keySource` string naming where that list came
  from (`"default(model:...,fans:...)"` or `"custom"`). A capture is only as trustworthy as
  its own record of what it asked for. `fanEnumerationFailed` and
  `fanEnumerationFailureReason` record whether fan discovery itself failed before the key
  list above was resolved: `keySource`'s own `fans:0` looks identical whether this machine
  genuinely has no fans or enumeration failed transiently, and this tool's own invocation
  above (`> capture.ndjson`) captures stdout only — the stderr line this failure also
  produces never reaches the file. Check this field, not `fans:0` alone, before reading a
  capture as evidence a machine has no fans.
- `"kind":"sample"` — one per tick. `tick` (0-indexed), `wallClockUTC`, and **both**
  monotonic clocks: `continuousNanoseconds`/`continuousDeltaNanoseconds` from
  `ContinuousClock` (documented to keep advancing across sleep) and
  `suspendingNanoseconds`/`suspendingDeltaNanoseconds` from `SuspendingClock` (documented not
  to). Both nanosecond counts are elapsed time since the `start` line; both deltas are the
  change since the previous tick, and are JSON `null` on tick 0, where there is no previous
  tick. `readings` is one object per sampled key: `key`, `status`
  (`"ok"`/`"unknownKey"`/`"readFailed"`/`"notDecodable"` — the same four words
  `SensorReadFailure` uses), `value` and `kind` on success, `failureReason` on failure. A
  rejected reading is never a fabricated `0` or a dropped key: every requested key appears in
  every tick's `readings`, whatever happened to it.
- `"kind":"heartbeat"` — once a second, both clocks, independent of `--interval`. If the
  heartbeats stop but the process is still in the process list, it is suspended rather than
  idle; if a `sample` tick is missing while the surrounding heartbeats are present, the
  *read* stalled, not the process.
- `"kind":"stop"` — once, on a clean `SIGINT`/`SIGTERM`/`SIGHUP` exit or on reaching
  `--count` ticks. The total tick count and both final clocks. Under `--latency`,
  `totalTicks` is the number of timed reads.

Under `--latency` the `start` line has `keySource` `"latency-default"` (or `"custom"`) and
`intervalSeconds` `0` unless `--interval` was given, and `sample` lines are replaced by:

- `"kind":"read"` — one per timed read, written after the read returns (so a read still in
  flight when the process is killed has no line). `index` (0-indexed), `key`, `status`
  (`"ok"`, the three failure words above, `"providerError"` if the provider itself threw, or
  `"noOutcome"` if it answered for no such key), `failureReason` (JSON `null` when `ok`), and
  — **different from `sample`'s fields of the same names** —
  `continuousNanoseconds`/`suspendingNanoseconds` are the *duration of this read* on each
  clock, while `atContinuousNanoseconds` is when the read was issued, as an offset from the
  `start` line.
- `"kind":"latencySummary"` — once, at the end, whatever ended the run. `requestedCount`,
  `count`, `interrupted`, `okCount` (status `ok`), `failureCount` (every other status,
  `notDecodable` included), `percentileSampleSize` (completed round trips), then
  `min`/`p50`/`p99`/`p999`/`p9999`/`max` with `Continuous` or `Suspending` before
  `Nanoseconds` (twelve fields; JSON `null` when there were no completed reads),
  `maxAllReadsContinuousNanoseconds` and `maxAllReadsSuspendingNanoseconds` (over reads of
  every status), the two `Meaningful` flags and `p9999Note`, `slowestBySuspending` and
  `slowestByContinuous` (the ten longest reads on each clock — index, key, status, both
  durations, offset — taken from every read including failures), and `warmup` (key, status,
  `failureReason`). See [Which clock sets D](#which-clock-sets-d).

## Reading the result

**A `continuousDelta` far larger than the matching `suspendingDelta` on the same tick is a
sleep `SuspendingClock` missed and `ContinuousClock` did not.** (The wall clock — `Date`,
via `wallClockUTC` — advances across a sleep exactly as `ContinuousClock` does, and reading
a large `wallClockUTC` gap on that tick as a problem rather than the expected reading is a
mistake; `SuspendingClock` is the one clock this comparison is about.) That comparison is
the whole reason this tool samples both — see
[ADR 0007](../../docs/ADR/0007-safety-composition.md)'s assumption table and #210's
own description of why a capture carrying only one clock cannot distinguish "this clock
advanced" from "this clock is the other family."

**A missing or frozen critical-sensor value during a dark wake is the finding #210 exists to
make, not evidence this tool is broken.** Compare the dark-wake readings against the
pre-sleep baseline and, where `docs/SMC-RESEARCH.md` already has one, the
`IOHIDEventSystemClient` reading for the same sensor. Two independent paths disagreeing
during a dark wake **is** the result, either way.

**This tool's default key set is a read-only mirror of `CriticalSensorSet`, not the safety
subsystem's own copy.** A drift between the two would be a maintenance bug in this tool, not
a safety bug in the helper — nothing this tool reads or prints ever feeds back into any
safety decision. If a maintainer widens `CriticalSensorSet` for a new machine, update
`MeasurementKeySet.criticalKeys(forModel:)` in
[`SMCSamplerCore.swift`](SMCSamplerCore.swift) to match, or pass `--keys` for that run
instead.
