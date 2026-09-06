# power-observer

A maintainer measurement tool. It is never built by `project.yml`, never shipped in
`Aeolus.app`, and never touches the SMC. It exists to answer one question
[docs/SAFETY.md](../../docs/SAFETY.md) row 14 leaves unmeasured:

> How many `willSleep`/`didWake` pairs does a real lid close deliver to a process holding
> an `IORegisterForSystemPower` port?

`Sources/AeolusHelper/Lifecycle/SystemPowerObserver.swift` only ever sees two of the
messages the root power domain can send, because that is all § 4 acts on. This tool sees
and counts every one, including the ones the helper silently drops — that gap is the
whole reason it exists as a second, narrower program rather than a debug flag on the
helper.

## Running it

It needs no root, no signing identity, and no installed helper —
`IORegisterForSystemPower` works for an ordinary user. Run it across one real lid close,
capturing to a durable path (not inside this worktree, which a teardown can reclaim):

```sh
swift run power-observer > ~/Obsidian/no-it-all/handoffs/Aeolus-209-power-observer-<UTC date>.ndjson
```

Close the lid, wait for it to wake back up on its own, then bring the lid back up and
press a key (or otherwise wake the machine) so you can return to the terminal. Stop the
tool with `Ctrl-C` (`SIGINT`) — it exits cleanly and appends a `stop` line with the final
per-message-type counts.

Immediately afterward, capture the system's own account of the same window:

```sh
pmset -g log | grep -E "Sleep|Wake"
```

Run both every time. Neither one alone answers the question this tool exists for.

## What each NDJSON line means

One JSON object per line, no line ever containing a literal newline:

- `"kind":"start"` — once, at launch. Hostname, `hw.model`, OS version, uid, pid, and
  whether `com.blamechris.Aeolus.Helper` was loaded (`launchctl print
  system/com.blamechris.Aeolus.Helper`'s exit status) at the moment this tool started.
  **Recorded, never acted on** — this tool does not change its behaviour based on whether
  the helper is also running. It matters for reading the result afterward: two processes
  registered for system power at once is unremarkable, and two sets of NDJSON lines
  mistaken for one is how a count gets doubled. If you are also trying to observe the
  helper's own behaviour across the same lid close, run the built helper binary under
  `sudo` separately (see row 14's note on why that needs no install) and keep the two
  captures in separate files.
- `"kind":"event"` — one per message `IORegisterForSystemPower` delivered. Carries the
  raw `messageType` as both decimal and hex, a name where one of the five documented
  `IORegisterForSystemPower` message types matches (`kIOMessageCanSystemSleep`,
  `kIOMessageSystemWillSleep`, `kIOMessageSystemWillNotSleep`,
  `kIOMessageSystemWillPowerOn`, `kIOMessageSystemHasPoweredOn`) or `"unknown"`
  otherwise, the `argument` token as a plain integer, a monotonic nanosecond stamp, a
  wall-clock UTC ISO-8601 stamp, and `ackLatencyMicroseconds` — the time from receipt to
  this tool's own acknowledgement, or JSON `null` for a message this tool does not
  acknowledge (every one except `kIOMessageCanSystemSleep` and
  `kIOMessageSystemWillSleep`).
- `"kind":"heartbeat"` — once a second, both clocks. If the heartbeats stop but the
  process is still in the process list, it is suspended rather than idle; if the whole
  file stops growing including heartbeats, the process is gone. This is what makes a
  missed delivery during a dark wake distinguishable from a process macOS never resumed.
- `"kind":"stop"` — once, on a clean `SIGINT`/`SIGTERM` exit. The final counts, keyed by
  the same names `event` lines use (`"unknown"` included).

## Reading the result

**Dark-wake versus full wake is never inferred from IOKit.** `kIOMessageSystemHasPoweredOn`
is delivered identically for both — that is Apple's documented behaviour, not a gap in
this tool — so which one happened comes from `pmset -g log` alone. Cross-reference by
wall-clock timestamp, not by trying to read it out of the NDJSON.

**The number that feeds [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s
assumption row** is the count of `kIOMessageSystemWillSleep`/`kIOMessageSystemHasPoweredOn`
*pairs* across the capture — not the raw event count, which also includes
`kIOMessageCanSystemSleep` (the idle-sleep question that precedes some but not all of
those pairs) and anything landing in `"unknown"`.

**Whether maintenance sleep delivers `kIOMessageSystemWillSleep` at all is unmeasured
before this tool runs**, and is exactly what running it across a real lid close settles.
`docs/SMC-RESEARCH.md`'s `pmset` capture recorded one clamshell sleep plus six
maintenance sleeps in a 1 h 29 min window with no process registered to receive any of
them — this tool is what turns that gap into a count.

**Record whether the helper was loaded during the run.** The `start` line's
`helperLoaded` field is exactly that record. Two registered processes delivering the
same sequence of messages is fine; two sets of lines from that mistaken for one process's
count is not, and is the specific mistake this note exists to prevent.
