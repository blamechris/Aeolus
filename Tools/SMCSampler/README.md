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
   outcome of each key is reported in the summary's `warmup` field, so the claim can be
   checked against the capture.
2. Takes `--count` timed reads, **one key per call**, cycling through the key set in order
   (`F0Ac` alone by default; `--keys` replaces it). `--count` is the total number of timed
   reads, not the number of passes. They run **back to back**, with no sleep, unless
   `--interval=<seconds>` is given explicitly.
3. Writes one `read` line per read as it happens, then a `latencySummary` line. `Ctrl-C`
   (`SIGINT`, and `SIGTERM`/`SIGHUP`) ends the run cleanly and still writes the summary for
   the reads done so far, with `"interrupted":true`.

`--latency` without `--count` is refused at parse time: a run with no end would hold the SMC
in a tight loop until someone remembered it.

The timed region is the `provider.read(keys:)` call, so it includes a few microseconds of
Swift (two actor hops, a dictionary, the outcome mapping). The figure is an upper bound on
the round trip, never an underestimate, and the overhead is orders of magnitude below what
a wedge bound of seconds is set against.

Build in release, **once, before measuring**, and run the binaries directly from the
repository root. `swift run` would plan (and may relink) before it starts, and a build running
beside a measurement is the contention the measurement is not about. `swift run -c release
smc-sampler …` is the same program, for a machine where that does not matter:

```sh
swift build -c release --product smc-sampler --product fanctl
```

Each `read` line is about 175 bytes, so 100,000 reads is about 17 MB of NDJSON. On `Mac16,5`
a read takes a few hundred microseconds (a 20,000-read release run took 4.1 s), so
`--count=100000` is roughly twenty seconds.

### Condition 1 — idle

A quiet machine: nothing else running, display idle, no build in progress.

```sh
.build/release/smc-sampler --latency --count=100000 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-idle-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

Size `--count` for the tail you want to report: p99.99 is only meaningful from 10,000
successful reads, and the summary says so itself (`p9999Meaningful`). A short run
(`--count=2000`) is a sanity check, not a measurement.

### Condition 2 — contended with a `fanctl` walk

`fanctl sensors` walks the whole key table, and a walk takes 22–24.9 s on `Mac16,5`. Run the
latency capture in one terminal while walks repeat back to back in another, and size
`--count` so the capture outlasts several walks. 400,000 reads is about a minute and a half
at the idle rate, which is more than three walks; contention will only slow the reads, so the
capture lasts at least that long.

Terminal A:

```sh
.build/release/smc-sampler --latency --count=400000 \
  > ~/Obsidian/no-it-all/handoffs/Aeolus-296-latency-contended-$(date -u +%Y%m%dT%H%M%SZ).ndjson
```

Terminal B, started a few seconds after A, and stopped (`Ctrl-C`) after A has finished:

```sh
while true; do .build/release/fanctl sensors > /dev/null; done
```

The `slowest` entries carry `atContinuousNanoseconds`, so a slow read can be placed against
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
`Ctrl-C`. The process is suspended while the machine sleeps, so the evidence is in the stream
rather than in a long read:

- **Failing reads in a dark wake** are the `read` lines whose `status` is not `"ok"`, with the
  reason in `failureReason`. They are counted in the summary and kept out of its percentiles,
  but `slowest` and `maxAllReadsContinuousNanoseconds` include them, so a read that
  took seconds to fail cannot hide.
- **The first read after wake** is the read that follows the largest gap between consecutive
  `atContinuousNanoseconds` values. A read that was already in flight when the machine slept
  shows `continuousNanoseconds` far above `suspendingNanoseconds` — the second is the clock
  ADR 0012 I3 ages a call on.

### Reading a latency capture

```sh
jq -c 'select(.kind == "latencySummary")' capture.ndjson          # the summary
jq -c 'select(.kind == "read" and .status != "ok")' capture.ndjson # every failing read
```

**Percentiles are nearest-rank over successful reads only**, and the summary says how many
(`percentileSampleSize`). **Below 10,000 successful reads, p99.99 is the maximum under another
name**; `p9999Meaningful` is `false` and `p9999Note` says so. The same holds for p99.9 below
1,000 reads (`p999Meaningful`). A run that is `"interrupted":true` has fewer reads than it
asked for; read its `count`, not its `requestedCount`.

This mode measures H1 only. H2 (`kill -9` the helper during a walk) needs the helper and is
not something a read-only tool can answer.

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

- `"kind":"read"` — one per timed read. `index` (0-indexed), `key`, `status` (`"ok"`, the
  three failure words above, `"providerError"` if the provider itself threw, or
  `"noOutcome"` if it answered for no such key), `failureReason` (JSON `null` when `ok`), and
  — **different from `sample`'s fields of the same names** —
  `continuousNanoseconds`/`suspendingNanoseconds` are the *duration of this read* on each
  clock, while `atContinuousNanoseconds` is when the read was issued, as an offset from the
  `start` line.
- `"kind":"latencySummary"` — once, at the end, whatever ended the run. `requestedCount`,
  `count`, `interrupted`, `okCount`, `failureCount`, `percentileSampleSize`, then
  `min`/`p50`/`p99`/`p999`/`p9999`/`maxContinuousNanoseconds` (JSON `null` when there were no
  successful reads), `maxAllReadsContinuousNanoseconds`, the two `Meaningful` flags
  and `p9999Note`, the ten `slowest` reads (index, key, status, both durations, offset) taken
  from every read including failures, and `warmup`.

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
