# run-watch: the run-1 watcher

A read-only operator's instrument for the first supervised fan write. It reads the run's capture
files and the helper's log stream, evaluates the abort rules of the run-1 amendment to
[ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) (aborts 1 to 12, plus the fault and
no-context rules), and **tells the operator aloud**. The operator acts on what it says.

It is not a safety mechanism, and nothing in the helper depends on it. If it misses an abort, the
operator, the helper's own mechanisms, the hold's length and § 3's ceiling remain. If it alerts
falsely, that costs a session.

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
| `CTX armed` (optionally `pid=<n>`) | after start 0 passes | records the helper's PID (from the line, else the first `pgrep`). A PID change or a second preparation-step line afterwards is rule 7 |
| `CTX step=<1a\|1b\|1b'\|1c\|1d> target=<rpm\|none> GO` | before the owner's `set` (1a, 1c, 1d), at GO (1b), or before the reset (1b') | opens the step; computes **B** (the mean of the hottest over the 10 s before the stamp) and logs it. `target=` must be a plain number of RPM above 0, or `none`: anything else (`5,777`, `5777rpm`, `nan`, `0`) is a spoken **BAD CONTEXT**, because rule 9 and the held-fan clause of rule 2 would otherwise be off without a word. So is a step line with no `target=` field at all (`step=1b GO`, or a misspelt `targt=5777`); only `step=none` needs none. A later valid step line ends it |
| `CTX load-start step=<1b\|1d>` | the first command of L1 | opens the **load window**: the 74 C limit begins, and B + 10 stops applying. For `1d` it also arms rule 11, with t_L at this stamp |
| `CTX load-stop` | the first command of L2 | disarms rule 11. The load window does **not** end here: the machine leaves a load heat-soaked, and 1d's hold outlasts its load |
| `CTX step=none` | after V passes | closes the step. The first one after `load-stop` also ends the load window (1b's own `step=none` comes while the load still runs, and does not) |
| `CTX test-alert` | run day, once | raises a test alert, spoken once |
| `CTX end` | after the last post-hold check passes, before the `main` reinstall | outside a hold, a helper PID change (or a second preparation-step line) is a note, not an alert, because the reinstall replaces the helper by design. It also lets a sampler's own `stop` line end that sampler's source for rule 12, with no hold active (see *Stopping it*). It stands no check down by itself: in a hold every abort stays armed |

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
| **Blind, no go** | 12 | The same, with no hold. Make no forward write until the record is whole again. No `CTX` line stands this rule down: a sampler's source ends only with that sampler's own `stop` line, and only if `CTX end` has been written and no hold is active. A stop line anywhere else is a `WARN` in `watch.log`, and the gap is heard as abort 12 (in a hold) or blind, no go |
| **Helper fault** | - | A helper line of `messageType` `Fault`, at every stage of the run, `CTX end` included (a refused exit restore is the one that matters most at the end). The coordinator reads the line |
| **Bad context** | - | A `CTX` line whose `target=` is not a number of RPM above 0, or a step line (other than `step=none`) with no `target=` field |
| **No context** | - | `F0Md` reads 1 and no `CTX` step is open: the coordinator has not written one |
| **Unparsed write** | 5 | A `Wrote` line whose duration cannot be read, so abort 5 cannot be judged |
| **Watcher error** | - | A check raised an exception. The alert names the check. That check is not evaluated; the others still are. The traceback is in `watch.log` as one `ERROR` line (and again every thousandth time), not one per sample |
| **Test alert** | - | `CTX test-alert` |

Every 5 s a `STATUS` line records the step, the hold, the seven fan values, the hottest, the
thresholds in force, the time since engage and since t_L, the pressure level, and any alert states.

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

(The PID files are the ones the runbook's recorders step writes.)

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
python3 -I -m unittest          # the unit tests; no captures needed
python3 -I dryrun.py ~/aeolus-captures/P1 --work <scratch> --mutations <scratch>/mut [d1 d2 d3 d4 unit]
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

P1's captures are read and never copied. Mutated copies are written under `--mutations`, which
must be outside the working tree, and only one sweep may run at a time.

## Thresholds are `Mac16,5` on macOS 27.2

Every number here is from the run-1 amendment and is set for that machine and OS. Abort 2's 10 s
allowance for the held fan, and abort 12's 2 s and 5 s, are set without data from a write; row 9's
step response and the samplers' achieved rates re-derive them before run 2. A start record naming
another `hwModel` is a warning.
