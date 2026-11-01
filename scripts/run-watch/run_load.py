#!/usr/bin/env python3
"""The run-1 load driver: a CPU load that bounds itself and kills only its own children.

Run 1's coordinator can be lost mid-hold (a quota wall, a compaction, a crash), and a load that
only the coordinator can stop is a load nobody stops. This is P1's sixteen-way busy loop
(`sh -c 'while :; do :; done'`) in one script that stops itself, traps INT, TERM and HUP, and
kills nothing but the workers it started, each by its own PID.

    python3 -I run_load.py --mode 1b --dir ~/aeolus-captures/run1
    python3 -I run_load.py --mode 1d --dir ~/aeolus-captures/run1

1b   starts at once, and stops itself 600 s later: P1's measured exposure, which covers the
     engagement (about 56 s), the hold, the 120 s observation and 1b'.
1d   is armed BEFORE `fanctl set`. It reads `started` from `set`'s --json file (set-1d.ndjson),
     starts once fan 0 reads as held (raw mode 1) with its target on `started`'s commanded RPM
     (5,777 unless `started` says otherwise) for 10 s on every sample (that moment is t_L), never
     starts later than 30 s after `started`, and starts nothing if `set` has already failed or
     ended (it writes a note and exits instead). It stops itself 20 s after fan 1's target
     leaves 0, or 80 s after it started, or when `set` fails or ends.

It writes `CTX load-start step=<1b|1d>` to phases.log BEFORE it forks, and `CTX load-stop` once
every worker is gone, in the watcher's grammar and stamped as the runbook stamps (`%.3f` epoch
seconds). It writes only its own files: load.pid (its PID), busy-<step>.pids (the workers', one
per line, written as each starts), load-<step>.log, and those two CTX lines. It opens no SMC
connection, starts nothing but the workers, and runs no fanctl, sudo or launchctl.

The owner's stop is `kill -TERM $(cat <dir>/load.pid)`: it stops the workers, writes
`CTX load-stop`, and exits. It never kills by pattern. If the workers are killed from outside
instead (`kill $(cat busy-<step>.pids)`), the driver sees that every one has gone, within a poll,
and stops the same way. Each worker also bounds itself, with an `alarm` a little past the mode's
bound, so that workers a SIGKILLed driver left behind end by themselves.

    python3 -I run_load.py --check-set <dir>/set-1a.ndjson

reads a `fanctl set --json` file as 1d would, prints the `started` event's time and fan 0's
target (and where the target came from), and exits 0 if it found a usable `started`, else 3. It
forks nothing and writes nothing.

Python 3 standard library only (3.9 or later). It does not import the watcher: it is pinned and
run from its own directory, and the tests hold its reading of the sampler's records, and its CTX
lines, to the watcher's.
"""

from __future__ import annotations

import argparse
import calendar
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from collections import namedtuple

# --------------------------------------------------------------------------------------------
# What the run-1 amendment fixes (items 8 and 12, the fixes' section C, critic S2)
# --------------------------------------------------------------------------------------------

P1_LOOP = ("/bin/sh", "-c", "while :; do :; done")  # P1's sixteen-way load, one core each
PERL = "/usr/bin/perl"
ALARM_MARGIN_SECONDS = 10  # a worker's own alarm is its mode's bound, rounded up, plus this
DEFAULT_WORKERS = 16
MAX_WORKERS = 32
BOUNDS = {"1b": 600.0, "1d": 80.0}  # the longest each mode runs, from the load's start
TARGET_RPM = 5777.0  # 1d: F0Tg must read this (the hold at 100 % commands F0Mx) ...
TARGET_TOLERANCE_RPM = 1.0  # ... within this, as the watcher reads a held target ...
HELD_MODE = 1.0  # ... with F0Md raw 1, which is what an engaged fan reads (ADR 0014, abort 3) ...
DWELL_SECONDS = 10.0  # ... on every sample for this long; that moment is t_L
START_WINDOW_SECONDS = 30.0  # 1d never starts later than this after `started`
TAIL_SECONDS = 20.0  # 1d stops this long after F1Tg leaves 0
ARM_TIMEOUT_SECONDS = 300.0  # 1d gives up if `started` has not come by then (no load)
ARM_TIMEOUT_RANGE = (1.0, 3600.0)  # what --arm-timeout may be
TARGET_RPM_RANGE = (500.0, 12000.0)  # what --target-rpm may be: a fan's speed, never 0
CLOSING_EVENTS = ("failed", "ended")  # `fanctl set --json`: the one closing event of a hold
SAMPLE_GAP_SECONDS = 2.0  # a gap in the fan record this long restarts the dwell
STALE_STARTED_SECONDS = 1.5  # a `started` stamped before the arming (to a second) is an old one
STOP_GRACE_SECONDS = 2.0  # SIGTERM, then this long, then SIGKILL, then this long again
PID_FILE_WAIT_SECONDS = 1.0  # a load.pid that names nothing is waited for this long
POLL_SECONDS = 0.05

EXIT_OK, EXIT_ERROR, EXIT_REFUSED, EXIT_NOT_STARTED, EXIT_SURVIVOR = 0, 1, 2, 3, 4

_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$")

FanSample = namedtuple("FanSample", "t v")
SetEvent = namedtuple("SetEvent", "event t target", defaults=(None,))


# --------------------------------------------------------------------------------------------
# Reading the records (pure)
# --------------------------------------------------------------------------------------------


def parse_iso_utc(text):
    """`2026-10-31T01:17:19.037Z` (or without the fraction, as `fanctl set --json` writes it) as
    epoch seconds, or None."""
    m = _ISO_RE.match(text) if isinstance(text, str) else None
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups()[:6])
    fraction = float("0." + m.group(7)) if m.group(7) else 0.0
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)) + fraction


def _record(raw):
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    raw = raw.strip()
    if not raw.startswith("{"):
        return None
    try:
        record = json.loads(raw)
    except ValueError:
        return None
    return record if isinstance(record, dict) else None


def parse_fan_sample(raw):
    """A `sample` line of the fan sampler's ndjson as a FanSample (its `wallClockUTC` and the
    `ok` readings by key), or None for the start line, a heartbeat, the stop line and junk. The
    same reading the watcher makes of the same line."""
    record = _record(raw)
    if record is None or record.get("kind") != "sample":
        return None
    t = parse_iso_utc(record.get("wallClockUTC"))
    readings = record.get("readings")
    if t is None or not isinstance(readings, list):
        return None
    values = {}
    for reading in readings:
        if not isinstance(reading, dict) or reading.get("status") != "ok":
            continue
        value = reading.get("value")
        if isinstance(reading.get("key"), str) and isinstance(value, (int, float)) and not (
                isinstance(value, bool)):
            values[reading["key"]] = float(value)
    return FanSample(t, values)


def held_on_target(sample, target):
    """Whether fan 0 reads as held and commanded: raw mode 1 and F0Tg on `target`. A held fan
    reads mode 1 (the engagement writes `F0Md = 0x1`, and ADR 0014's abort 3 allows 1 only during
    a hold). A fan whose hold has been released but whose target Apple has not yet rewritten reads
    the target with another mode, and is not held."""
    mode, tg = sample.v.get("F0Md"), sample.v.get("F0Tg")
    return mode == HELD_MODE and tg is not None and abs(tg - target) <= TARGET_TOLERANCE_RPM


def _commanded_rpm(record):
    """Fan 0's `commandedRPM` in an event's `fans` (docs/CLI.md: `commandedRPM` is the target that
    was sent), or None: absent, not a number, not finite, or not above 0. A hold's target is never
    0, so a 0 here is a record that cannot be read as one."""
    fans = record.get("fans")
    if not isinstance(fans, list):
        return None
    for fan in fans:
        index = fan.get("index") if isinstance(fan, dict) else None
        if isinstance(index, int) and not isinstance(index, bool) and index == 0:
            value = fan.get("commandedRPM")
            if isinstance(value, (int, float)) and not isinstance(value, bool) and (
                    math.isfinite(value) and value > 0):
                return float(value)
    return None


def parse_set_event(raw):
    """An event line of `fanctl set --json` (`started`, `holding`, `ended`, `failed`) as a
    SetEvent of its name, its `at` and fan 0's commanded RPM, or None. `at` is the time the line
    was written. The RPM is None where the line has none (`ended`, `failed`), or an unusable one."""
    record = _record(raw)
    if record is None or not isinstance(record.get("event"), str):
        return None
    t = parse_iso_utc(record.get("at"))
    return SetEvent(record["event"], t, _commanded_rpm(record)) if t is not None else None


def worker_argv_for(bound_seconds, loop=P1_LOOP):
    """A worker's command: `loop` (P1's busy loop) started by perl, after `alarm`. A pending alarm
    survives `exec`, so the loop is P1's exactly and the worker still ends by itself, when its
    SIGALRM comes, if nothing has stopped it first: the driver SIGKILLed, say, which no handler
    can answer. The alarm is the mode's bound, rounded up, plus ALARM_MARGIN_SECONDS."""
    for argument in loop:
        if any(ch in argument for ch in '"$@\\\n'):
            raise ValueError("a worker argument perl would read as more than text: %r" % (argument,))
    seconds = int(math.ceil(bound_seconds)) + ALARM_MARGIN_SECONDS
    return (PERL, "-e", "alarm %d; exec %s" % (seconds, ", ".join('"%s"' % a for a in loop)))


def ctx_line(wall, body):
    """One line of phases.log, stamped as the runbook's `perl -MTime::HiRes=time -e 'printf
    "%.3f", time'` stamps it."""
    return "%.3f CTX %s\n" % (wall, body)


class Follow:
    """The whole lines appended to a file, read-only. With `from_end` a file that exists now is
    read from its end, so a driver armed hours into a capture does not read the hours; a file
    that is replaced or truncated afterwards (a `tee` starting again) is read from its start."""

    CHUNK = 1 << 20

    def __init__(self, path, from_end=False):
        self.path, self.handle, self.inode, self.pending = path, None, None, b""
        try:
            self.skip = os.path.getsize(path) if from_end else 0
        except OSError:
            self.skip = 0

    def read_new(self):
        try:
            status = os.stat(self.path)
        except OSError:
            return []
        if self.handle is not None and (
                status.st_ino != self.inode or status.st_size < self.handle.tell()):
            self.close()
            self.skip = 0
        if self.handle is None:
            try:
                self.handle = open(self.path, "rb")
            except OSError:
                return []
            self.inode = os.fstat(self.handle.fileno()).st_ino
            self.handle.seek(min(self.skip, status.st_size))
        data = self.pending + self.handle.read(self.CHUNK)
        *lines, self.pending = data.split(b"\n")
        return lines

    def close(self):
        if self.handle is not None:
            self.handle.close()
        self.handle, self.pending = None, b""


class Whole:
    """A small file, read whole each time it changes. `fanctl set --json`'s output is a `tee`
    target, so a second attempt truncates the very file the first one wrote: following it by an
    offset could resume in the middle of the new content."""

    def __init__(self, path):
        self.path, self.signature = path, None

    def read_new(self):
        """The file's lines, if it has changed since the last call, else none."""
        try:
            status = os.stat(self.path)
            signature = (status.st_ino, status.st_size, status.st_mtime_ns)
            if signature == self.signature:
                return []
            with open(self.path, "rb") as handle:
                data = handle.read()
        except OSError:
            return []
        self.signature = signature
        return data.split(b"\n")

    def close(self):
        pass


class Clock:
    """Time, and the means to wait. Bounds are judged on both clocks and the later one wins:
    the monotonic clock stands still while the Mac sleeps, and the wall clock can be set back."""

    def wall(self):
        return time.time()

    def mono(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


class SetReader:
    """1d's reading of `fanctl set --json`'s file: this arming's events, no others. It keeps the
    first `started` (with the moment this arming first saw it) and the first closing event
    (`failed` or `ended`) that follows or precedes it. An event stamped before the arming is an
    earlier attempt's, and is not read."""

    def __init__(self, path, armed_wall, clock):
        self.whole, self.armed_wall, self.clock = Whole(path), armed_wall, clock
        self.started = None  # the SetEvent
        self.started_at = None  # min(its `at`, the wall time this arming first saw it)
        self.closing = None  # the first failed or ended SetEvent
        self.closing_after_started = False

    def poll(self):
        """Read what the file has gained. Returns True if `started` was found by this call."""
        found = False
        for raw in self.whole.read_new():
            event = parse_set_event(raw)
            if event is None or event.t < self.armed_wall - STALE_STARTED_SECONDS:
                continue  # not an event, or one from before this arming
            if event.event == "started" and self.started is None:
                # `at` is the CLI's own clock, to the second; a `started` that says it is from the
                # future (a bad clock, a bad line) must not extend the window it opens
                self.started, found = event, True
                self.started_at = min(event.t, self.clock.wall())
            elif event.event in CLOSING_EVENTS and self.closing is None:
                self.closing, self.closing_after_started = event, self.started is not None
        return found

    def close(self):
        self.whole.close()


def read_set_file(path):
    """A `set --json` file as 1d would read it, whole and read-only: (the first `started` event,
    the first closing event after it), either may be None; or raises OSError if it cannot be
    read."""
    with open(path, "rb") as handle:
        data = handle.read()
    started = closing = None
    for raw in data.split(b"\n"):
        event = parse_set_event(raw)
        if event is None:
            continue
        if event.event == "started" and started is None:
            started = event
        elif event.event in CLOSING_EVENTS and started is not None and closing is None:
            closing = event
    return started, closing


Config = namedtuple(
    "Config", "mode directory workers max_seconds arm_timeout target_rpm fans phases set_json")


def _finite(value):
    """Whether `value` is a number that is neither `nan` nor infinite. `nan` is below nothing and
    above nothing, so a test written as "refuse what is outside the range" lets it through."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _within(name, value, low, high):
    """`value` as a float, if it is finite and in [low, high]; else a ValueError naming the flag."""
    if not _finite(value) or value < low or value > high:
        raise ValueError("%s must be a number from %g to %g, not %r" % (name, low, high, value))
    return float(value)


def make_config(mode, directory, workers=DEFAULT_WORKERS, max_seconds=None,
                arm_timeout=ARM_TIMEOUT_SECONDS, target_rpm=TARGET_RPM, fans=None, phases=None,
                set_json=None):
    """The driver's settings. A bound can only be shortened: `max_seconds` above the mode's own is
    refused, as a ceiling that can be raised is not a ceiling. Every number is finite and in a
    range a person could mean; the rest is refused (the command line exits 2)."""
    if mode not in BOUNDS:
        raise ValueError("mode must be 1b or 1d, not %r" % (mode,))
    if not 1 <= workers <= MAX_WORKERS:
        raise ValueError("workers must be 1 to %d, not %r" % (MAX_WORKERS, workers))
    bound = BOUNDS[mode]
    if max_seconds is not None and (not _finite(max_seconds) or max_seconds <= 0 or max_seconds > bound):
        raise ValueError("--max-seconds can only shorten %s's %g s, not %r" % (mode, bound, max_seconds))
    arm_timeout = _within("--arm-timeout", arm_timeout, *ARM_TIMEOUT_RANGE)
    target_rpm = _within("--target-rpm", target_rpm, *TARGET_RPM_RANGE)
    return Config(
        mode, directory, workers, bound if max_seconds is None else float(max_seconds),
        arm_timeout, target_rpm,
        fans or os.path.join(directory, "fans-10hz.ndjson"),
        phases or os.path.join(directory, "phases.log"),
        set_json or os.path.join(directory, "set-%s.ndjson" % mode))


# --------------------------------------------------------------------------------------------
# The driver
# --------------------------------------------------------------------------------------------


class Refused(Exception):
    """The driver will not start: nothing was written to phases.log and nothing was forked."""


class Driver:
    def __init__(self, config, worker_argv=None, clock=None, spawn=subprocess.Popen, echo=None,
                 worker_loop=P1_LOOP):
        """`worker_argv`, `clock`, `spawn` and `worker_loop` are the tests' seams. Without a
        `worker_argv`, each worker is `worker_loop` under an alarm of this mode's bound."""
        self.config = config
        self.worker_argv = tuple(worker_argv) if worker_argv else worker_argv_for(
            config.max_seconds, worker_loop)
        self.clock = clock or Clock()
        self.spawn = spawn
        self.echo = echo or (lambda text: None)
        self.workers = []
        self.load_started = False
        self.stop_signal = None  # the name of the signal that asked for a stop
        self.wall0 = self.mono0 = None  # when the load started, on each clock
        self.pid_path = os.path.join(config.directory, "load.pid")
        self.workers_path = os.path.join(config.directory, "busy-%s.pids" % config.mode)
        self.log_path = os.path.join(config.directory, "load-%s.log" % config.mode)
        self.owns_pid_file = False
        self.workers_file = None

    # ------------------------------------------------------------------ files

    def log(self, text):
        line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.clock.wall())), text)
        with open(self.log_path, "a", encoding="utf-8") as handle:
            handle.write(line)
        self.echo(line)

    def ctx(self, body):
        """One CTX line, appended whole (O_APPEND, one write) so it cannot interleave with the
        coordinator's own `echo` into the same file. Returns its stamp."""
        wall = self.clock.wall()
        with open(self.config.phases, "a", encoding="utf-8") as handle:
            handle.write(ctx_line(wall, body))
        return wall

    def claim_pid_file(self):
        """load.pid holds this process's PID for the owner's `kill -TERM $(cat load.pid)`. One
        driver at a time. The file is made with O_CREAT|O_EXCL, so of two drivers that start at
        once only one makes it. One that is already there is replaced only after the process it
        names has been found dead; a file that names no process (empty, as the winner of a race
        leaves it for an instant, or not a PID) is not replaced, because nothing says it is stale."""
        for _ in range(2):
            try:
                fd = os.open(self.pid_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            except FileExistsError:
                holder = self.holder_of_pid_file()
                if holder is None:
                    raise Refused("%s exists and names no process: it may be another driver's, "
                                  "just started; remove it if it is not" % self.pid_path)
                if self.alive(holder):
                    raise Refused("%s names a running process (pid %d): one load driver at a time; "
                                  "stop it, or remove the file if that pid is not a driver"
                                  % (self.pid_path, holder))
                os.unlink(self.pid_path)  # a dead driver's
                continue
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write("%d\n" % os.getpid())
            self.owns_pid_file = True
            return
        raise Refused("could not claim %s" % self.pid_path)

    def holder_of_pid_file(self):
        """The PID in load.pid, giving a driver that has just made the file a moment to write it."""
        deadline = self.clock.mono() + PID_FILE_WAIT_SECONDS
        while True:
            holder = self.read_pid(self.pid_path)
            if holder is not None or self.clock.mono() >= deadline:
                return holder
            self.clock.sleep(POLL_SECONDS)

    @staticmethod
    def read_pid(path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return int(handle.read().split()[0])
        except (OSError, ValueError, IndexError):
            return None

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)  # signal 0 delivers nothing: it only asks whether the pid exists
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def release_pid_file(self):
        if self.owns_pid_file and self.read_pid(self.pid_path) == os.getpid():
            os.unlink(self.pid_path)
        self.owns_pid_file = False

    def check_writable(self):
        """Before arming or forking: the directory exists and phases.log can take a CTX line."""
        if not os.path.isdir(self.config.directory):
            raise Refused("%s is not a directory" % self.config.directory)
        if os.path.isdir(self.config.phases) or not os.access(self.config.directory, os.W_OK) or (
                os.path.exists(self.config.phases) and not os.access(self.config.phases, os.W_OK)):
            raise Refused("%s cannot take a CTX line" % self.config.phases)

    # ------------------------------------------------------------------ signals

    def request_stop(self, name):
        """The signal handlers' whole body: note it. The loop acts on it within one poll."""
        if self.stop_signal is None:
            self.stop_signal = name

    def install_signals(self):
        for number, name in ((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP")):
            signal.signal(number, lambda *_args, name=name: self.request_stop(name))

    # ------------------------------------------------------------------ the load

    def elapsed(self):
        """Seconds since the load started, on whichever clock says longer."""
        return max(self.clock.wall() - self.wall0, self.clock.mono() - self.mono0)

    def start_load(self):
        """CTX load-start first, then the workers, each PID recorded as its worker starts."""
        wall = self.ctx("load-start step=%s" % self.config.mode)
        self.load_started = True  # from here a load-stop is owed, whatever happens next
        self.wall0, self.mono0 = self.clock.wall(), self.clock.mono()
        self.log("load-start step=%s: %d worker(s), %s" % (
            self.config.mode, self.config.workers, " ".join(self.worker_argv)))
        with open(self.workers_path, "w", encoding="utf-8", buffering=1) as pids:
            for _ in range(self.config.workers):
                worker = self.spawn(
                    self.worker_argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
                self.workers.append(worker)
                pids.write("%d\n" % worker.pid)
        self.log("workers: %s" % " ".join(str(w.pid) for w in self.workers))
        return wall

    def stop_load(self):
        """SIGTERM each worker (by its own Popen, so by its own PID, and never after it has been
        reaped), wait, SIGKILL any that remain, wait. `CTX load-stop` is written only when every
        worker is gone: until then the load has not stopped. Returns the PIDs still running."""
        if not self.load_started:
            return []
        for worker in self.workers:
            if worker.poll() is None:
                worker.terminate()
        self.wait_for_workers()
        for worker in self.workers:
            if worker.poll() is None:
                self.log("pid %d ignored SIGTERM: SIGKILL" % worker.pid)
                worker.kill()
        self.wait_for_workers()
        alive = [w.pid for w in self.workers if w.poll() is None]
        if alive:
            self.log("STILL RUNNING after SIGKILL: %s. No CTX load-stop was written." % alive)
            return alive
        self.ctx("load-stop")
        self.log("load-stop: every worker is gone")
        self.load_started = False
        return []

    def wait_for_workers(self):
        deadline = self.clock.mono() + STOP_GRACE_SECONDS
        while any(w.poll() is None for w in self.workers) and self.clock.mono() < deadline:
            self.clock.sleep(0.02)

    # ------------------------------------------------------------------ the modes

    def run(self):
        """Returns the exit code. Whatever happens after load-start, the workers are stopped."""
        code = EXIT_OK
        try:
            self.check_writable()
            self.claim_pid_file()
            try:
                code = self.run_1b() if self.config.mode == "1b" else self.run_1d()
            finally:
                survivors = self.stop_load()
                if survivors:
                    code = EXIT_SURVIVOR
        except Refused as why:
            self.echo("refused: %s\n" % why)
            return EXIT_REFUSED
        finally:
            self.release_pid_file()
        return code

    def running(self):
        """Whether the load goes on: not asked to stop, inside its bound, and with a worker left.
        Every worker is polled each time, so one killed from outside (the runbook's L2 by PID) is
        reaped at once and not left <defunct>; when all of them are gone there is no load, and
        the driver says so (`CTX load-stop`) instead of waiting out the bound."""
        if self.stop_signal is not None:
            self.log("stop requested by SIG%s" % self.stop_signal)
            return False
        if self.elapsed() >= self.config.max_seconds:
            self.log("reached its bound of %g s" % self.config.max_seconds)
            return False
        codes = [worker.poll() for worker in self.workers]
        if codes and all(code is not None for code in codes):
            self.log("every worker has exited (return codes %s): no load is left, stopping" % (
                " ".join(str(code) for code in sorted(set(codes)))))
            return False
        return True

    def run_1b(self):
        self.start_load()
        while self.running():
            self.clock.sleep(POLL_SECONDS)
        return EXIT_OK

    def settle_target(self, started):
        """Fan 0's target for the dwell: what `started` says it commanded (docs/CLI.md:
        `fans[0].commandedRPM` is the target that was sent), else --target-rpm. The source is
        logged, and so is a disagreement; `started`'s is used, because it is what was sent."""
        flag = self.config.target_rpm
        if started.target is None:
            self.log("target %g RPM, from --target-rpm: `started` carries no usable "
                     "fans[0].commandedRPM" % flag)
            return flag
        if started.target != flag:
            self.log("target %g RPM, from `started` (fans[0].commandedRPM); --target-rpm says %g "
                     "and differs: `started`'s is used" % (started.target, flag))
        else:
            self.log("target %g RPM, from `started` (fans[0].commandedRPM); --target-rpm agrees"
                     % started.target)
        return started.target

    def run_1d(self):
        config = self.config
        armed_wall, armed_mono = self.clock.wall(), self.clock.mono()
        fans, sets = Follow(config.fans, from_end=True), SetReader(
            config.set_json, armed_wall, self.clock)
        started = target = None  # when `started` came (see SetReader), and fan 0's target
        run_since = last_t = None  # fan 0 held on its target: since which sample, and the last sample
        self.log("armed: waiting for `started` in %s, then F0Md %g and F0Tg on the target "
                 "(%g unless `started` names another) on every sample for %g s" % (
                     config.set_json, HELD_MODE, config.target_rpm, DWELL_SECONDS))
        try:
            while True:
                if self.stop_signal is not None:
                    self.log("stop requested by SIG%s before the load started: no load" % self.stop_signal)
                    return EXIT_OK
                now = self.clock.wall()
                if max(now - armed_wall, self.clock.mono() - armed_mono) >= config.arm_timeout:
                    self.log("NOT STARTED: no `started` event within %g s of arming" % config.arm_timeout)
                    return EXIT_NOT_STARTED
                if sets.poll():
                    started, target = sets.started_at, self.settle_target(sets.started)
                    self.log("started at %.3f%s: the load must start by %.3f" % (
                        started, "" if started == sets.started.t else (
                            " (its `at` says %.3f, later than this arming first saw it)" % sets.started.t),
                        started + START_WINDOW_SECONDS))
                if sets.closing is not None:  # the hold is over, or never was: no load on it
                    if sets.started is None:
                        self.log("NOT STARTED: `set` ended before `started` (%s)" % sets.closing.event)
                    else:
                        self.log("NOT STARTED: `set` ended (%s) %.1f s after `started`, before the "
                                 "load started: the hold is over" % (
                                     sets.closing.event, sets.closing.t - sets.started.t))
                    return EXIT_NOT_STARTED
                for raw in fans.read_new():
                    sample = parse_fan_sample(raw)
                    if sample is None:
                        continue
                    if last_t is not None and sample.t - last_t > SAMPLE_GAP_SECONDS:
                        run_since = None  # nobody recorded the gap
                    last_t = sample.t
                    if target is None or not held_on_target(sample, target):
                        run_since = None
                    elif run_since is None:
                        run_since = sample.t
                # fan 0 has read as held for 10 s, in a record that is still being written
                due = (run_since is not None and last_t - run_since >= DWELL_SECONDS
                       and now - last_t <= SAMPLE_GAP_SECONDS)
                if started is not None and due and now <= started + START_WINDOW_SECONDS:
                    break
                if started is not None and now > started + START_WINDOW_SECONDS:
                    self.log("NOT STARTED: %.1f s after `started`, past its %g s window; fan 0 had "
                             "%sread as held (F0Md %g, F0Tg %g) for %g s" % (
                                 now - started, START_WINDOW_SECONDS, "" if due else "not ",
                                 HELD_MODE, target, DWELL_SECONDS))
                    return EXIT_NOT_STARTED
                self.clock.sleep(POLL_SECONDS)
            t_l = self.start_load()
            return self.run_1d_load(fans, t_l, sets)
        finally:
            fans.close()
            sets.close()

    def run_1d_load(self, fans, t_l, sets=None):
        """The load runs until 20 s after F1Tg leaves 0, or its bound, or the hold ends. F1Tg
        'leaves 0' at the first sample stamped at or after t_L that reads above 0, as the watcher
        reads it. `set` reporting `failed` or `ended` means the hold is over (the owner's reset
        after an abort, or a loss of control): nothing the load was for is left, so it stops."""
        left = None
        while True:
            if sets is not None:
                sets.poll()
                if sets.closing is not None:
                    self.log("`set` ended (%s) %.1f s into the load: the hold is over, stopping" % (
                        sets.closing.event, self.elapsed()))
                    return EXIT_OK
            if left is None:
                for raw in fans.read_new():
                    sample = parse_fan_sample(raw)
                    if sample is not None and sample.t >= t_l and sample.v.get("F1Tg", 0.0) > 0:
                        left = sample.t
                        self.log("F1Tg left 0 at %.3f (%.1f s after t_L): stopping %g s later" % (
                            left, left - t_l, TAIL_SECONDS))
                        break
            if left is not None and self.clock.wall() >= left + TAIL_SECONDS:
                self.log("%g s after F1Tg left 0" % TAIL_SECONDS)
                return EXIT_OK
            if not self.running():
                return EXIT_OK
            self.clock.sleep(POLL_SECONDS)


# --------------------------------------------------------------------------------------------
# The command line
# --------------------------------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(
        prog="run_load.py", description="The run-1 CPU load: bounds itself, kills only its own "
        "workers. The owner's stop is: kill -TERM $(cat <dir>/load.pid)")
    p.add_argument("--mode", choices=sorted(BOUNDS),
                   help="1b: start now, stop at 600 s. 1d: armed before `set`; see the module text")
    p.add_argument("--dir", help="the capture directory (phases.log, the PID files, the log)")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                   help="busy-loop workers (default %d, at most %d)" % (DEFAULT_WORKERS, MAX_WORKERS))
    p.add_argument("--max-seconds", type=float,
                   help="stop sooner than the mode's own bound (600 s for 1b, 80 s for 1d); it "
                        "cannot lengthen it")
    p.add_argument("--arm-timeout", type=float, default=ARM_TIMEOUT_SECONDS,
                   help="1d: give up, with no load, if `started` has not come by then (%g to %g s)"
                   % ARM_TIMEOUT_RANGE)
    p.add_argument("--target-rpm", type=float, default=TARGET_RPM,
                   help="1d: the F0Tg to wait for if `started` names none (default 5777, F0Mx; "
                        "%g to %g)" % TARGET_RPM_RANGE)
    p.add_argument("--fans", help="the fan sampler's ndjson (default DIR/fans-10hz.ndjson)")
    p.add_argument("--phases", help="phases.log (default DIR/phases.log)")
    p.add_argument("--set-json", help="1d: `fanctl set --json`'s output (default DIR/set-1d.ndjson)")
    p.add_argument("--check-set", metavar="FILE",
                   help="read FILE (a `fanctl set --json` output, such as set-1a.ndjson) as 1d "
                        "would, print `started`'s time and fan 0's target and where the target "
                        "came from, and exit 0 if there is a usable `started`, else 3. Starts "
                        "nothing and writes nothing; takes no flag but --target-rpm")
    return p


def check_set(path, target_rpm, echo):
    """`--check-set`: what 1d would make of this file, and nothing else. Read-only, no fork."""
    try:
        started, closing = read_set_file(path)
    except OSError as why:
        echo("check-set: cannot read %s: %s\n" % (path, why))
        return EXIT_NOT_STARTED
    if started is None:
        echo("check-set: no `started` event in %s: 1d would not start a load from this file\n" % path)
        return EXIT_NOT_STARTED
    echo("check-set: %s\n" % path)
    echo("check-set: started at %s (epoch %.3f)\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started.t)), started.t))
    if started.target is None:
        echo("check-set: fan 0 target %g RPM, source: --target-rpm (`started` carries no usable "
             "fans[0].commandedRPM, which is what 1d reads first)\n" % target_rpm)
    else:
        echo("check-set: fan 0 target %g RPM, source: started.fans[0].commandedRPM\n" % started.target)
        if started.target != target_rpm:
            echo("check-set: --target-rpm is %g and differs; 1d uses `started`'s\n" % target_rpm)
    if closing is not None:
        echo("check-set: then %s at %s\n" % (
            closing.event, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(closing.t))))
    return EXIT_OK


def main(argv=None, worker_argv=None, clock=None, spawn=subprocess.Popen,
         install_signals=True, worker_loop=P1_LOOP):
    """`worker_argv`, `worker_loop`, `clock` and `spawn` are the tests' seams; the command line
    has no flag for them. The workers it starts are the one thing this program may start."""
    parser = build_parser()
    args = parser.parse_args(argv)

    def echo(text):
        try:
            sys.stdout.write(text)
            sys.stdout.flush()
        except OSError:
            pass  # a closed terminal must not stop a load that is bounded and logged

    if args.check_set is not None:
        given = [flag for flag, value, default in (
            ("--mode", args.mode, None), ("--dir", args.dir, None),
            ("--workers", args.workers, DEFAULT_WORKERS), ("--max-seconds", args.max_seconds, None),
            ("--arm-timeout", args.arm_timeout, ARM_TIMEOUT_SECONDS), ("--fans", args.fans, None),
            ("--phases", args.phases, None), ("--set-json", args.set_json, None))
            if value != default]
        if given:
            parser.error("--check-set only reads a file and takes no %s" % ", ".join(given))
        try:
            target_rpm = _within("--target-rpm", args.target_rpm, *TARGET_RPM_RANGE)
        except ValueError as why:
            parser.error(str(why))
        return check_set(args.check_set, target_rpm, echo)
    if args.mode is None or args.dir is None:
        parser.error("--mode and --dir are required (or --check-set FILE)")
    try:
        config = make_config(
            args.mode, os.path.abspath(args.dir), args.workers, args.max_seconds,
            args.arm_timeout, args.target_rpm, args.fans, args.phases, args.set_json)
    except ValueError as why:
        parser.error(str(why))

    driver = Driver(config, worker_argv, clock, spawn, echo, worker_loop)
    if install_signals:
        driver.install_signals()
    return driver.run()


if __name__ == "__main__":
    sys.exit(main())
