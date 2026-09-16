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

Immediately afterward, capture the system's own account of the same window:

```sh
pmset -g log | grep -E "Sleep|Wake"
```

Run both every time, the same discipline `Tools/PowerObserver/README.md` asks for its own
capture: neither one alone answers the question either tool exists for.

## What each NDJSON line means

One JSON object per line, no line ever containing a literal newline:

- `"kind":"start"` — once, at launch. Hostname, `hw.model`, OS version, uid, pid, the
  resolved `--interval`, and — the field that makes a capture reproducible and auditable —
  the exact `keys` this run is sampling and a `keySource` string naming where that list came
  from (`"default(model:...,fans:...)"` or `"custom"`). A capture is only as trustworthy as
  its own record of what it asked for.
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
  `--count` ticks. The total tick count and both final clocks.

## Reading the result

**A `continuousDelta` far larger than the matching `suspendingDelta` on the same tick is a
sleep the wall clock and `SuspendingClock` both missed and `ContinuousClock` did not.** That
comparison is the whole reason this tool samples both — see
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
