# run-watch: the run-1 watcher, its load driver and its record restart

A read-only operator's instrument for the first supervised fan write. It reads the run's capture
files and the helper's log stream, evaluates the abort rules of the run-1 amendment to
[ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) (aborts 1 to 12, plus the fault and
no-context rules), and **tells the operator aloud**. The operator acts on what it says.

It is not a safety mechanism, and nothing in the helper depends on it. If it misses an abort, the
operator, the helper's own mechanisms, the hold's length and § 3's ceiling remain. If it alerts
falsely, that costs a session.

This directory also holds the other two operator tools for run 1: [`run_load.py`](#the-load-driver-run_loadpy),
the CPU load that bounds itself, and [`restart-record.sh`](#the-record-restart-restart-recordsh), which
starts the record again after a power cycle. Neither is the watcher, neither is part of its
confinement below, and neither can write to a fan.

## What it never does

- It opens no SMC connection and sends no XPC message. It is not a client of the helper.
- It runs no `fanctl`, `sudo`, `launchctl` or `kill`. The only programs it starts are
  `pgrep -x AeolusHelper`, `notifyutil -g com.apple.system.thermalpressurelevel`,
  `pmset -g therm`, `say` and `afplay`, by absolute path, through one function that refuses
  anything else (`_spawn`, with its list in `COMMANDS`).
- It writes only `watch.log`, `watch.hb` and `ALERT`, in the output directory. Every input is
  opened read-only. A replay refuses to write into the capture directory at all.
- It is Python 3 standard library only (3.9 or later), run as `python3 -I`.

## Inputs

All in the capture directory (`~/aeolus-captures/run1/` on run day):

| File | From | Used for |
|---|---|---|
| `fans-10hz.ndjson` | `smc-sampler`, 10 Hz | `sample` lines: `F0Md F1Md Ftst F0Tg F1Tg F0Ac F1Ac`, stamped `wallClockUTC` |
| `package-1hz.ndjson` | `smc-sampler`, 1 Hz | the curated temperature keys (the highest that read is "hottest"), and `F<n>Mn` |
| `helper-log.ndjson` | `log stream --style ndjson --level debug` | `timestamp`, `messageType`, `eventMessage`. Non-JSON lines (the `Filtering...` header) are skipped. A line whose `processImagePath` is not `AeolusHelper` is ignored with one warning (F1: test processes log under the helper's subsystem) |
| `phases.log` | the coordinator | the `CTX` lines below. Any other line is ignored |
| `logstream.pid` | the coordinator | whether the log stream is still running |
| `pgrep`, `notifyutil` every 1 s; `pmset -g therm` every 5 s | the OS | the helper's PID, the thermal pressure level |

All four files are read from their first line, so a watcher started late, or restarted,
rebuilds its state (hold, step, engage time, B) from what is already there. During that catch-up
it says nothing; whatever still holds afterwards is then announced at once.

## Starting it

The coordinator starts it from a foreground call, **after the recorders and before the census**:

```sh
D=~/aeolus-captures/run1
cd <worktree>/scripts/run-watch
nohup python3 -I run_watch.py --dir "$D" >> "$D/watch.log" 2>&1 &
echo $! > "$D/watch.pid"
nohup sh watcher-down.sh "$D" > /dev/null 2>&1 &
echo $! > "$D/watcher-down.pid"
```

`>> watch.log` puts a crash traceback in the file the operator is tailing. The watcher opens the
same file for append, so the two interleave without clobbering. In a fourth terminal:

```sh
tail -f ~/aeolus-captures/run1/watch.log
```

`watcher-down.sh` is the five-line companion: it speaks "watcher down" whenever `watch.hb` is more
than 10 s old or missing, so a watcher that died, was stopped or hung is heard. The watcher
rewrites `watch.hb` every second.

Flags worth knowing: `--out DIR` (live defaults to `--dir`), `--fans`, `--package`,
`--helper-log`, `--phases` and `--logstream-pid` to name files that are not at their default
names, and `--mute` to log and say nothing. **`--mute` is for rehearsal only**: every status line
then ends in `MUTED`, and run day's test alert (below) would not be heard.

## What the coordinator writes to `phases.log`

One `echo` per line, stamped with `$(perl -MTime::HiRes=time -e 'printf "%.3f", time')`, then
`CTX`, then:

| Line | Written | The watcher does |
|---|---|---|
| `CTX t0-freeze` | at PR-9, right after the quiescence window (PR-8) has passed and before the install | freezes **T0** (the gates, below) at the median of the window that has just ended, so that the baseline is a pre-run one. The first of this line and `CTX armed` freezes it; the other changes nothing. It is not an alert and not an unknown line |
| `CTX armed` (optionally `pid=<n>`) | after start 0 passes | records the helper's PID (from the line, else the first `pgrep`). A PID change or a second preparation-step line afterwards is rule 7. It also freezes T0, if no `t0-freeze` came first, and starts the at-rest clock |
| `CTX step=<1a\|1b\|1b'\|1c\|1d> target=<rpm\|none> GO` | before the owner's `set` (1a, 1c, 1d), at GO (1b), or before the reset (1b') | opens the step; computes **B** (the mean of the hottest over the 10 s before the stamp) and logs it. `target=` must be a plain number of RPM above 0, or `none`: anything else (`5,777`, `5777rpm`, `nan`, `0`) is a spoken **BAD CONTEXT**, because rule 9 and the held-fan clause of rule 2 would otherwise be off without a word. So is a step line with no `target=` field at all (`step=1b GO`, or a misspelt `targt=5777`); only `step=none` needs none. A later valid step line ends it |
| `CTX load-start step=<1b\|1d>` | the first command of L1 | opens the **load window**: the 74 C limit begins, and B + 10 stops applying. For `1d` it also arms rule 11, with t_L at this stamp |
| `CTX load-stop` | the first command of L2 | disarms rule 11. The load window does **not** end here: the machine leaves a load heat-soaked, and 1d's hold outlasts its load |
| `CTX step=none` | after V passes | closes the step. The first one after `load-stop` also ends the load window (1b's own `step=none` comes while the load still runs, and does not) |
| `CTX test-alert` | run day, once | raises a test alert, spoken once |
| `CTX end` | after the last post-hold check passes, before the `main` reinstall | outside a hold, a helper PID change (or a second preparation-step line) is a note, not an alert, because the reinstall replaces the helper by design. It also lets a sampler's own `stop` line end that sampler's source for rule 12, with no hold active (see *Stopping it*), and it **stops the at-rest clock** (below). It stands no check down by itself: in a hold every abort stays armed |

## What the alerts mean

On entering an alert state the watcher says its name aloud, plays `Sosumi`, writes a line to
`watch.log`, and touches `ALERT`. Both repeat every 15 s while the state holds. A state that
holds because a value is wrong (rules 1, 2, 6, 9, 10, 11, 12 and the mode checks) ends when the
value is right again, and the log says `CLEAR`. A state that holds because of something that
happened (a log line, a changed value) is repeated for two minutes.

**The watcher never acts.** Per D8 as the run-1 amendment restates it, the maintainer runs
`fanctl reset --all` at once on an abort, **except abort 4**, which is verified first (item 6).
Any abort called ends the session's forward writes (item 7).

| It says | Rule | Means |
|---|---|---|
| **Abort 1** | 1 | The hottest curated key is over 85 C at any time; or over 74 C in a load window (from `load-start` to the first `step=none` after `load-stop`); or over B + 10 C from a GO to `step=none`, in a step that no load window covers. A baseline taken at rest never applies again after a load in the same step |
| **Abort 2** | 2 | A fan has been under 0.8 of its target for 10 s. An automatic fan (fan 1 always; fan 0 when no hold is active) against its `F<n>Tg` while that is above 0. The held fan 0 against the `CTX` target, counted from 10 s after `F0Tg` first reads it |
| **Abort 3** | 3 | Something changed that nothing explains: `Ftst` changed with no `Wrote Ftst` within [-2 s, +0.5 s]; `F1Md` outside {0, 3}; `F0Md` outside {0, 3} for 2 s with no `Wrote F0Md` of that value near it; or, during a hold, `F0Tg` moved more than 1 RPM or `F0Md` left 1 with no `Wrote` of that key near it. `F0Md` = 1 during a hold is exempt and is not counted, so the 2 s starts when the hold ends: a restore that did not take is heard 2 s after it, however long the hold was, and a readback that lags it by under 2 s is not an alert (live too: a sample stamped before the restore line is in the hold even when it is read after the line). Each sample is explained only by a write in its own window [-2 s, +0.5 s], judged 2 s after the sample on log stamps: an old write cannot explain a later reading, and `Wrote F0Md = 0x0` does not explain a reading of 1 |
| **Abort 4, verify** | 4 | An engagement was refused, the line says the restore landed, and the first sample after it agrees (`Ftst` 0, both modes in {0, 3}). **Verify; do not reset** (the undo has already run, and a reset on top of it is an unlabelled U5b test) |
| **Abort 4, reset** | 4 | Anything else about a refused engagement: the hand-back was refused, `Could not undo the engagement`, the first sample disagrees, or 10 s passed with no verdict. **Reset** |
| **Abort 5** | 5 | A `Wrote` call took 1 s or more. (Durations are read as floats: `5.3083e-05` is 53 microseconds.) Notes in the log, not alerts: a write at 20 ms or more, and at 50 ms or more ("forward writes end after this hold") |
| **Abort 6** | 6 | `com.apple.system.thermalpressurelevel` is not 0. A changed `pmset -g therm` is a note |
| **Abort 7** | 7 | During a hold, the helper's PID changed or vanished, or a second preparation-step line appeared. Armed whatever `CTX` says |
| **Helper restarted** | 7 | The same, with no hold active. After `CTX end` it is a note instead (the `main` reinstall replaces the helper) |
| **Abort 8** | 8 | No verified restore 5 min after engage (a warning at 4 min). A verified restore is a `Wrote F0Md = 0x0` followed by 10 s of samples with `Ftst` 0 and both modes in {0, 3} |
| **Abort 9** | 9 | During a hold, `F1Tg` is above 0.9 of the `CTX` target: Apple is demanding more than the hold gives |
| **Abort 10** | 10 | `F0Md` is 1 and `F0Tg` is below `F0Mn` for more than 1 s (`F0Mn` from the package file; 1,350 until read) |
| **Abort 11, time** | 11 | 60 s after `load-start step=1d`, `F1Tg` still reads 0 (a warning at 45 s) |
| **Abort 11, temperature** | 11 | After `load-start step=1d`, `F1Tg` still reads 0 and the hottest is 50 C or more. When `F1Tg` first leaves 0 the watcher logs how long it took and the hottest, and disarms |
| **Abort 12** | 12 | During a hold the record has gone blind: no fan sample for 2 s, no package sample for 5 s, or the log stream's process is gone |
| **Blind, no go** | 12 | The same, with no hold. Make no forward write until the record is whole again. No `CTX` line stands this rule down: a sampler's source ends only with that sampler's own `stop` line, and only if `CTX end` has been written and no hold is active. A hold that begins afterwards re-arms every source, so a record that is dead when a hold starts is abort 12 at once. A stop line anywhere else is a `WARN` in `watch.log`, and a live watcher hears the gap as abort 12 (in a hold) or blind, no go. A `--replay` ends every file at its last sample and raises nothing for it, and its warning says so |
| **Helper fault** | - | A helper line of `messageType` `Fault`, at every stage of the run, `CTX end` included (a refused exit restore is the one that matters most at the end). The coordinator reads the line |
| **Bad context** | - | A `CTX` line whose `target=` is not a number of RPM above 0, or a step line (other than `step=none`) with no `target=` field |
| **No context** | - | `F0Md` reads 1 and no `CTX` step is open: the coordinator has not written one |
| **Unparsed write** | 5 | A `Wrote` line whose duration cannot be read, so abort 5 cannot be judged |
| **Watcher error** | - | A check raised an exception. The alert names the check. That check is not evaluated; the others still are. The traceback is in `watch.log` as one `ERROR` line (and again every thousandth time), not one per sample |
| **Test alert** | - | `CTX test-alert` |

Every 5 s a `STATUS` line records the step, the hold, the seven fan values, the hottest, the
thresholds in force, the time since engage and since t_L, the pressure level, the gates' present
state (`gates[...]`, below), and any alert states.

## Derived-gate notes (`GATE` lines)

The runbook's gates that are a matter of arithmetic are evaluated here, once, so that nobody does
them by hand (the fixes' section C, critic S5): **"at rest"**, **T0**, **1b's engaged condition**,
**1d's entry** and the **30-minute at-rest clock**. They are **advice, never spoken**: a `GATE`
line is not an alert, is not counted as a note or a warning, sets no `ALERT` file, and a bug in
one is an `ERROR` line and nothing said. A gate's line is written when its state changes, so **the
newest line for a gate is its present state**, as long as that gate's check is running. The
`STATUS` line every 5 s carries the present state of all five, evaluated each time:

```
gates[at-rest=YES t0=40.00(frozen) engaged=NO rest-clock=met 1d-entry=YES]
```

`at-rest` and `1d-entry` are `YES`, or `NO:<why>`; `t0` is `none`, `40.00(provisional)`,
`40.00(frozen)` or `none(frozen)`; `engaged` is `NO`, `rising`, `YES` or `stale`; `rest-clock` is
`-`, `ticking`, `met`, `expired` or `stopped` (with `(1d-entry)` after it for the clock that waits
for 1d). **A gate whose check raised on its last evaluation reads `ERROR`**, and so does every
gate that check feeds (a bug in the check that writes `at-rest` means the last `at-rest=YES` line
is no longer the truth). `ERROR` clears when the check runs again. Read the `STATUS` line, not
only the last `GATE` line, when the coordinator's decision rests on one.

Every line is `<time> GATE <name>=<value> <key>=<value> ...`, with no other text, so that
`grep` and `awk` can read it. The runbook greps for the name:

```sh
grep ' GATE at-rest=' ~/aeolus-captures/run1/watch.log | tail -n 1
grep ' GATE t0='      ~/aeolus-captures/run1/watch.log | tail -n 1
grep ' GATE engaged=' ~/aeolus-captures/run1/watch.log | tail -n 1
grep ' GATE rest-clock=' ~/aeolus-captures/run1/watch.log | tail -n 1
grep ' GATE 1d-entry=' ~/aeolus-captures/run1/watch.log | tail -n 1
grep ' STATUS ' ~/aeolus-captures/run1/watch.log | tail -n 1     # the gates[...] of all five, now
```

| Line | Means |
|---|---|
| `at-rest=YES held=61.2s hottest=36.40 limit=38.88 t0=35.88` | Both fans read raw `3` with a target of `0`, and `Ftst` reads `0`, for at least 60 s (item 8: a span of 59.5 s counts, as the fans' stamps are 0.1 s apart), and the hottest curated is at most T0 + 3 C. The fan samples are the newest, and the package sample is under 3 s older |
| `at-rest=NO why=<w> held=.. hottest=.. limit=.. t0=.. F0Md=.. F1Md=.. Ftst=.. F0Tg=.. F1Tg=..` | Not at rest. `<w>` is the first clause that fails, in this order: `stale` (no fan sample for 2 s), `step-open` (a `CTX` step is open, or a hold is active: it is an entry gate), `fans` (a sample is not at rest: the five values are on the line), `short` (at rest, but under 60 s), `t0` (no T0 yet), `package` (the package record is behind the fans' by 3 s), `warm` (the hottest is over the limit). A mode of `0` is Apple's, but it is not rest |
| `t0=35.88 n=118 span=119.9s ok=YES limit=50 state=provisional window=<from>/<to>` | The median of the hottest curated over the newest complete quiescence window: 120 s (a span of 119.5 s) in which `Ftst` is `0`, both modes are in `{0, 3}`, and no fan reads `3` with a target above `0` (D9: the five keys `F0Md F1Md Ftst F0Tg F1Tg`; the runbook's `quiescence.jq` also refuses a window in which `F0Ac` or `F1Ac` did not read), with at least 100 package samples. `ok=YES` is T0 below 50 C. A gap of over 2 s in the fan record ends a window. It **follows the machine, and is written once a minute, until the first `CTX t0-freeze` or `CTX armed`** (a `CTX step=` line is the backstop); then it is **frozen** (`state=frozen by=CTX_t0-freeze`, written once) and the run keeps it. The freeze works T0 out from the window that ends at the newest sample, then; it is not the last provisional figure. Quote the frozen line |
| `t0=unavailable ok=NO limit=50 state=frozen by=CTX_armed why=window n=0 need=100` | T0 froze with **no usable window**, and stays unavailable for the whole run: `why=window` (no complete 120 s of quiet ends at the newest fan sample), `why=package` (the package record is behind it) or `why=short` (fewer than 100 package samples). **"At rest" then stays NO** (`why=t0`) and no later window repairs it: a baseline taken after the run began is not a pre-run one. The coordinator re-freezes nothing; the session writes nothing forward (item 8) |
| `t0=unavailable n=90 need=100 window=<from>/<to>` | Before the freeze: a complete window with too few package samples. T0 stays what it was, and the next window is tried |
| `engaged=rising held=4.1s thr=1650 F0Tg=1700 F0Mn=1350` | 1b's engaged condition has begun: `F0Tg` is at least `F0Mn` + 300 RPM (`F0Mn` is the one the package file reports, 1,350 until read). `YES` at 30 s; `NO` when it falls below; `stale` when the fan record has stopped. Nothing is written until it first rises. On P1's sixteen-way load it says `YES` 56 s in, the ADR's figure |
| `1d-entry=YES at-rest=YES hottest=38.20 key=TPD3 limit=41` | 1d's entry (item 12): "at rest" **and** the hottest curated at most 41 C (41.00 passes, 41.01 does not). `hottest` is the highest curated reading, in C, and `key` is the raw SMC key that read it |
| `1d-entry=NO why=<w> hottest=.. key=.. limit=41` | `<w>` is `at-rest` (not at rest; `at-rest-why=<why>` is that gate's reason at the moment, and the `at-rest=` line has the facts), `warm` (at rest, but over 41 C: 1d waits for a cooler session) or `package` (no package reading). It is written when `<w>` changes, so its `hottest` is the figure at that change; the `STATUS` line says `1d-entry=NO:warm` every 5 s |
| `rest-clock=START limit=1800s from=CTX_armed` | The 30-minute clock for the at-rest gate to hold starts at `CTX armed` (the entry to 1a), and at each `CTX step=none` that closes a step other than 1b's (`from=CTX_step=none_after_step_1a`; 1b's load goes on under 1b', so its cool-down is 1b''s). **The one after 1c waits for `1d-entry`**, not for "at rest" alone (`from=CTX_step=none_after_step_1c for=1d-entry`; every line of that clock ends `for=1d-entry`): the wait for 41 C is inside the 30 minutes (gap decision `41-wait`) |
| `rest-clock=TICKING elapsed=120s left=1680s at-rest=NO why=<w>` | Once a minute while the gate has not held, with the clause that fails (`1d-entry=NO why=<w>` for the clock after 1c) |
| `rest-clock=MET elapsed=114s limit=1800s` | The gate held in time. The clock stops, and **MET is a fact about the past**: if "at rest" (or `1d-entry`) is lost again afterwards, the clock does not start again (there is no second clock) and does not expire. The gate's own line and `STATUS` value say what holds now; the entry is read at GO, and the watcher does not decide what a lost gate means for the step |
| `rest-clock=EXPIRED elapsed=1800s limit=1800s action=no-forward-writes` | It did not hold in 30 minutes: the session writes nothing forward (item 8) |
| `rest-clock=ABANDONED elapsed=412s was=ticking step=1a` | A step opened while the clock was still ticking, or after it had expired: the step ran on a gate that never held |
| `rest-clock=STOPPED elapsed=412s was=ticking by=CTX_end` | `CTX end` came while the clock was still ticking: the run is over and nothing is waiting for a gate, so it neither expires nor starts again (no clock starts after `CTX end`). A clock that had met or expired says nothing at `CTX end` |

These are `Mac16,5` figures like the rest, and the gates read the files the rules read. A replay
writes the same lines (stamped by the capture), which is how they are tested against P1.

## The load driver (`run_load.py`)

P1's sixteen-way busy loop (`sh -c 'while :; do :; done'`, one per worker), in one script that
**bounds itself, traps INT, TERM and HUP, and kills only its own workers, each by its own PID**. The
coordinator can be lost mid-hold; a load only the coordinator can stop is a load nobody stops
(the fixes' section C, critic S2). Python 3 standard library only, run as `python3 -I`, from its
pinned directory (`~/aeolus-captures/bin/run-load-<sha>/`, a copy of this directory).

```sh
D=~/aeolus-captures/run1
nohup /opt/homebrew/bin/python3 -I <dir>/run_load.py --mode 1b --dir "$D" >> "$D/load-1b.out" 2>&1 &
nohup /opt/homebrew/bin/python3 -I <dir>/run_load.py --mode 1d --dir "$D" >> "$D/load-1d.out" 2>&1 &   # armed BEFORE `set`
/opt/homebrew/bin/python3 -I <dir>/run_load.py --check-set "$D/set-1a.ndjson"                          # before 1d: read-only
```

| Mode | It does |
|---|---|
| `--mode 1b` | Starts **at once**, and stops itself **600 s** after the workers start: P1's measured exposure, which covers the engagement (about 56 s), the hold, the 120 s observation and 1b' |
| `--mode 1d` | Is **armed before `fanctl set`**, and does nothing until it has read `started` from `set`'s `--json` file (`DIR/set-1d.ndjson`, the runbook's `tee` target) **and** fan 0 has read as **held** for 10 s on every sample: raw `F0Md` **1** (what an engagement writes, and what ADR 0014's abort 3 allows only during a hold) **and** `F0Tg` within 1 RPM of the target; that moment is **t_L**. A target that is on its number with any other mode is Apple's, or a released hold's, and is not a hold. It **never starts later than `started` + 30 s**: if the 10 s is not in by then it starts nothing, writes a note to `load-1d.log` and exits 3. It stops itself **20 s after `F1Tg` leaves 0** (the first sample at or after t_L reading above 0, as the watcher reads it), or **80 s** after it started, or **as soon as `set` reports `failed` or `ended`** (the hold is over: the owner's reset after an abort, or a loss of control). If `started` has not come within 5 minutes of arming there is no load and exit 3 |

- **No load on a hold that is over.** A `failed` or `ended` event from `set`, at any time before the load starts (before or after `started`), is "NOT STARTED": exit 3, nothing forked, a note in `load-1d.log` naming the event. This is the case where the owner's reset follows an alert in the first seconds: `set` prints `failed`, the mode returns to Apple's, and Apple may not rewrite the target for a while, so a target alone would still read as on its number.
- **The target** is what `started` says it commanded: `fans[0].commandedRPM` (docs/CLI.md; the entry whose `index` is 0), 5,777 on this Mac at 100 %. If `started` carries none, `--target-rpm` (default 5777) is used. The log says which, and says so when the two differ (`started`'s is used: it is what was sent). `--target-rpm` is for a `started` with no usable number.
- **`started`'s time** is the earlier of its `at` and the moment the driver first saw the line, so a line dated in the future cannot stretch the 30 s window.
- **Every number is checked** (exit 2 on a bad one): `--target-rpm` 500 to 12000, `--arm-timeout` 1 to 3600 s, `--max-seconds` above 0 and at most the mode's own bound, `--workers` 1 to 32; `nan`, `inf` and the rest are refused.
- **Before 1d, read the shape.** `run_load.py --check-set <set-1a.ndjson>` reads a `set --json` file as 1d would (the first `started`), prints its time and fan 0's target with where the target came from, and exits **0** if there is a usable `started`, **3** if there is not. It forks nothing, writes nothing, and takes no flag but `--target-rpm`. The driver's reader was written from docs/CLI.md's example; the first real `started` line is 1a's.
- **The owner's stop (L2): `kill -TERM $(cat ~/aeolus-captures/run1/load.pid)`.** `load.pid` is the driver's own PID, written when it starts (armed or running) and removed when it ends. TERM, INT or HUP stops the workers (SIGTERM, then SIGKILL after 2 s for any that ignore it), writes `CTX load-stop` **once every worker is gone**, and exits 0. It works armed too: the load never starts, and `busy-1d.pids` does not exist yet, so `load.pid` is the only stop an armed 1d has.
- **Killing the workers by PID** (`kill $(cat busy-<step>.pids)`, L2's other form) works too, **if it kills all of them**: the driver polls every worker each 50 ms, reaps the dead (none is left `<defunct>` for L3 to list), and when every one has gone it logs that, writes `CTX load-stop` and exits 0, removing `load.pid`. Some of them killed leaves the driver and the rest running to the bound. The driver writes `CTX load-stop` itself, within a poll of the last worker going: look in `phases.log` before writing one by hand, or the record has two.
- **The files it writes, and no others:** `load.pid`; `busy-1b.pids` or `busy-1d.pids` (the workers' PIDs, one per line, each written as its worker starts, kept after the run for L3: `ps -o pid=,command= -p $(tr '\n' ',' < busy-1b.pids | sed 's/,$//')`); `load-<step>.log`; and its two `CTX` lines in `phases.log`.
- **The `CTX` lines**, in the watcher's grammar, stamped as the runbook stamps (`%.3f` epoch seconds): `CTX load-start step=<1b|1d>` **before it forks anything** (if `phases.log` cannot take it, nothing is forked), and `CTX load-stop` after the workers are gone. If a worker survives SIGKILL it says so in the log, writes no `load-stop`, and exits 4: the load has not stopped, and L3 says which.
- **One driver at a time.** `load.pid` is made with `O_CREAT|O_EXCL`, so of two drivers started at once one wins. If it names a running process (a PID the driver may not signal counts as running) the driver refuses (exit 2) and touches nothing. A file naming a **dead** process is replaced. A file that names **no** process (empty: a driver that has just made it and not yet written; or not a PID) is waited for for a second and then refused, never replaced, because nothing says it is stale: remove it by hand if it is.
- **Each worker bounds itself.** A worker is `/usr/bin/perl -e 'alarm N; exec "/bin/sh", "-c", "while :; do :; done"'`, where N is the mode's bound (`--max-seconds` if shorter), rounded up, **plus 10 s** (610 for 1b, 90 for 1d). A pending alarm survives `exec`, so the loop is P1's exactly (`ps` shows `/bin/sh -c while :; do :; done`), and the process ends by itself on SIGALRM. **If the driver is killed with SIGKILL, which nothing can trap, its workers now end by themselves** at N seconds after they started, and not never; `load.pid` is left, naming a dead process, which the next driver replaces and **the owner must not signal** if the number could be another process's by then.
- **Bounds only shorten.** `--max-seconds` can lower a mode's bound (a rehearsal), never raise it. `--workers` is 1 to 32, default 16.
- **Exit codes:** 0 ended (its bound, asked to stop, the hold over, or every worker gone); 2 refused to start (or a bad flag); 3 1d did not start (nothing was forked), or `--check-set` found no usable `started`; 4 a worker survived SIGKILL; 1 an unexpected error (the workers are stopped first, whatever it was).
- **What it does not do:** it opens no SMC connection, runs no `fanctl`, `sudo` or `launchctl`, and starts nothing but its workers. It does not kill by pattern.
- **Both clocks.** A bound is judged on the wall clock and the monotonic clock, and the later wins: the monotonic clock stands still while the Mac sleeps, and the wall clock can be set back.

Tests: `test_run_load.py` (fake clock, fake workers; the driver as a real process with `/bin/sleep` for workers, to see the signals work, a bystander left alone, workers killed by PID reaped, and the workers of a SIGKILLed driver end by their own alarm; real workers that ignore SIGTERM, so the SIGKILL path runs), run with the other unit tests. **`smoke_run_load.py` is the one real load**, two busy loops for two seconds (it also checks that each worker is P1's loop once perl has exec'd it), and runs on request: `python3 -I -m unittest discover -s . -p smoke_run_load.py`.

## The record restart (`restart-record.sh`)

After the ladder's power cycle (item 13) every recorder, the watcher and the coordinator's session
are gone, and the check is read against a record. The coordinator restarts it when the owner
reopens its session; **if the coordinator is lost, the owner runs this, staged in `~/aeolus-captures/bin/`
and tested before run day**:

```sh
~/aeolus-captures/bin/restart-record.sh --watcher-sha <sha>
```

It makes `~/aeolus-captures/run1-<n>/` (`n` is the smallest free number, from 1; `mkdir` is atomic, and an existing directory is never written into) and starts into it, in order, with the runbook's own commands (PR-3, PR-5) and pinned paths: both samplers (`smc-sampler-5b0d191`, **checked against the pinned sha256 first**), the log stream (`process == "AeolusHelper"`), the record-only poll loop, the watcher (`/opt/homebrew/bin/python3 -I ~/aeolus-captures/bin/run-watch-<sha>/scripts/run-watch/run_watch.py`) and its companion. It writes the same `.pid` files (`fans-10hz`, `package-1hz`, `logstream`, `poll`, `watch`, `watcher-down`), prints the directory and the six PIDs, waits a second, and says which of them is not running (exit 1).

It then **prints, and runs none of, the commands the owner pastes next**, with the real `run1-<n>` path in each: `tail -f` on the new `watch.log` (T4); the `log show` capture ADR item 13 requires (the helper's own start in this boot, which the power cycle ran before any recorder could, with the helper's process filter, `--last boot`, into `run1-<n>/helper-log-show.txt`); E-6's check on the new fans file (`quiescence.jq` with `win` 10; pass is `"violations":0`); and E-10's four stop commands for this directory, in order. It ends with a note that **`run1/`'s PID files (and any earlier `run1-<m>/`'s) are from the previous boot and are never to be signalled**: their numbers may now belong to the owner's Terminal, the coordinator, or this record's own watcher.

**`CTX end` is the first line of the new `phases.log`**, stamped as the runbook stamps it, followed by a plain note that says why. If that line cannot be written the script **refuses** (exit 2, "could not write CTX end", the new directory removed) before any recorder starts: a record without it would hear its own teardown as blind. A restart happens only after the forward writes have ended (items 10 and 13), so the new watcher starts in the teardown state: outside a hold a helper restart is a note, and a sampler's own stop line ends its source for rule 12, so that this record's own E-10 teardown is not heard as blind (#652's review, S2). Without it the second record's teardown would be `BLIND — NO GO`.

Everything is checked before anything is made or started, and a failed check (exit 2) leaves nothing behind: the pinned sampler, its hash, the pinned watcher and companion, the interpreter, the captures directory. A sampler already running is a warning, not a refusal (this is not the restart after a power cycle, and you are about to have two records). It writes only into the new directory, signals nothing (`kill -0` only asks whether a PID it started is still there), and runs no `fanctl`, `sudo` or `launchctl`. Stop the second record as the first: `kill -INT` the samplers, then the companion, the watcher, the log stream and the poll, each by PID from that directory (the runbook's E-10).

Tests: `test_restart_record.py`, with stub binaries in place of the sampler, `log`, the interpreter, `pgrep`, and the watcher's companion (no real recorder, and no real `say`, starts). The record-only poll loop is the one thing a stub does not replace; in the test copy it is bounded to about 20 s, so that a test that loses its PID leaves a loop that ends by itself. The order (`CTX end` before the first process is started) is also checked statically, on the script read as the shell reads it (comments gone, whitespace collapsed, quotes set aside), because the dynamic check reads the file from a stub started a few milliseconds later and cannot tell.

## Stopping it

Everything is stopped **by PID**, at the end, **after the reinstall of the `main` helper**, and
only **after `CTX end`** has been written, in this order, so that no teardown step is heard as
blind:

1. `kill -INT` both samplers. Each writes its own `stop` line, and, with `CTX end` written and no
   hold active, that line ends rule 12's wait for its source. Nothing else does: `CTX end` alone
   does not.
2. The watcher-down loop, or it will say "watcher down" when the watcher goes.
3. The watcher.
4. The log stream and the poll.

```sh
D=~/aeolus-captures/run1
kill -INT "$(cat "$D/fans-10hz.pid")" "$(cat "$D/package-1hz.pid")"
kill "$(cat "$D/watcher-down.pid")"
kill "$(cat "$D/watch.pid")"
kill "$(cat "$D/logstream.pid")" "$(cat "$D/poll.pid")"
```

(The PID files are the ones the runbook's recorders step writes. After a power cycle, those in `run1/` are from the previous boot: signal the new record's, in `run1-<n>/`, and never `run1/`'s.)

**The samplers are stopped only after `CTX end`, never before it and never in a hold, because of
rule 12.** A sampler that stops while the run is on, or while a hold is active, has left the record
blind, and rule 12 must go on saying so: abort 12 in a hold, blind (no go) outside one. A stop
line that arrives before `CTX end`, or in a hold, is therefore a `WARN` in `watch.log` and ends
nothing. A `kill -INT` run early, or a pattern `pkill`, is exactly that, and a hold that runs on
with its sampler gone must not be quiet.

`SIGTERM` and `SIGINT` both end the watcher cleanly; its last log line is `watcher stopped`.

## Run day (D5)

1. Arm the watcher before the census. It raises zero alerts through the 120 s quiescence window.
2. Write `CTX test-alert` (stamped, as above). The owner says he heard it.
3. `kill -STOP` the watcher's PID: "watcher down" is heard within about 13 s. Then `kill -CONT`.

## Replay, the tests, and the dry run

`--replay` reads the files once, clocks itself by their own stamps, says nothing, and needs
`--out` somewhere other than the capture directory. `--replay-polls FILE` stands in for the OS
polls (ndjson lines such as `{"t": 1761870020.0, "kind": "pressure", "level": 1}`,
`{"kind": "pgrep", "pids": [101]}`, `{"kind": "pmset", "text": "..."}`,
`{"kind": "logstream", "alive": false}`).

```sh
cd scripts/run-watch
python3 -I -m unittest          # the unit tests of all three tools; no captures needed
python3 -I dryrun.py ~/aeolus-captures/P1 --work <scratch> --mutations <scratch>/mut [d1 d2 d3 d4 unit tools]
python3 -I -m unittest discover -s . -p smoke_run_load.py    # the one real load: two busy loops, two seconds, on request
```

The unit tests use the synthetic fixture in `fixtures/synthetic/` (regenerated by
`python3 -I synth.py <dir>`, and checked byte for byte against the committed copy). The tests that
compare record shapes with P1's skip when P1's captures are absent.

`dryrun.py` is the watcher's pre-run evidence (D1 to D4 of the run-1 gap rulings, section 3):

- **d1** replays P1 as captured: no alert.
- **d2** replays P1 with synthetic `CTX` lines: no abort 11 (`F1Tg` leaves 0 and the check
  disarms), no abort 9 at 1b's GO; plus a synthetic accepted engage so rule 9 is live, and two
  targets either side of the line to show it fires when it should. **d2e** replays 1d in the
  runbook's order (GO at rest, the load, `load-stop` at t_L + 34 s and at t_L + 60 s, `step=none`
  at t_L + 130 s): no alert; B about 35.5 C; `F1Tg` leaves 0 at about 14 s; an injected 74.1 C at
  t_L + 90 s raises abort 1; and a watcher whose window ends at `load-stop` goes red.
- **d3** injects one violation at a time into copies of P1 windows and requires each to raise its
  own alert, within its latency, and no other.
- **d4** runs each injection against a copy of the watcher with that rule's check emptied. It must
  stay silent, and a control injection must still fire on the same copy.
- **unit** runs the unit tests against the same mutated copies; every one must go red.
- **tools** does the same for the load driver and the record restart: each guard is edited out of a
  private copy, and its tests must go red. (The watcher's mutants never copy those tools, and
  their tests, so the real load of the smoke test is never started by a sweep.)

P1's captures are read and never copied. Mutated copies are written under `--mutations`, which
must be outside the working tree, and only one sweep may run at a time.

## Thresholds are `Mac16,5` on macOS 27.2

Every number here is from the run-1 amendment and is set for that machine and OS. Abort 2's 10 s
allowance for the held fan, and abort 12's 2 s and 5 s, are set without data from a write; row 9's
step response and the samplers' achieved rates re-derive them before run 2. A start record naming
another `hwModel` is a warning.
