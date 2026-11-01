#!/usr/bin/env python3
"""The run-1 watcher: a read-only operator's instrument.

It reads the run's capture files and the helper's log stream, evaluates the abort rules of the
run-1 gap rulings (section 3), and alerts the operator aloud. It is not a safety mechanism and
nothing in the helper depends on it.

What it never does
    * open an SMC connection or send an XPC message;
    * run fanctl, sudo, launchctl or kill;
    * write anywhere but its own watch.log, watch.hb and ALERT in the output directory.

The only programs it starts are the five in COMMANDS, by absolute path, through `_spawn`, which
refuses anything else. Everything it reads it opens read-only.

Run as `python3 -I run_watch.py --dir <capture dir>`. See README.md.
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
import traceback
from collections import deque, namedtuple

# --------------------------------------------------------------------------------------------
# Thresholds (the run-1 amendment, items 3, 5 and 8). Mac16,5 on macOS 27.2, run 1 only.
# --------------------------------------------------------------------------------------------

TEMP_ABSOLUTE = 85.0  # rule 1, at any time
TEMP_LOADED = 74.0  # rule 1, between load-start and load-stop
TEMP_RISE = 10.0  # rule 1, above B from a GO to step=none with no load
B_WINDOW = 10.0  # B is the mean of the hottest over this many seconds before the GO

ACTUAL_FRACTION = 0.8  # rule 2: Ac below this fraction of Tg
RULE2_SECONDS = 10.0  # rule 2: continuously for this long
HELD_SPINUP_SECONDS = 10.0  # rule 2: the held fan is counted from this long after Tg reads target
TARGET_TOLERANCE_RPM = 1.0  # rule 2: "within 1 RPM"

EXPLAIN_BEFORE = 2.0  # rule 3: a Wrote line this long before the sample explains it
EXPLAIN_AFTER = 0.5  # rule 3: or this long after
JUDGE_AFTER = 2.0  # rule 3: explanations are judged this long after the sample
MODE_SECONDS = 2.0  # rule 3: F0Md outside {0, 3} for this long
TARGET_MOVE_RPM = 1.0  # rule 3: F0Tg moving more than this during a hold

VERIFY_ESCALATE_SECONDS = 10.0  # rule 4: no VERIFY verdict by then is RESET

WRITE_ABORT_SECONDS = 1.0  # rule 5
WRITE_NOTE_50MS = 0.050
WRITE_NOTE_20MS = 0.020

RESTORE_WARN_SECONDS = 240.0  # rule 8
RESTORE_ABORT_SECONDS = 300.0
RESTORE_VERIFY_SECONDS = 10.0

F1_FOLLOW_FRACTION = 0.9  # rule 9: F1Tg above this fraction of the CTX target
FLOOR_SECONDS = 1.0  # rule 10: F0Md = 1 with F0Tg below F0Mn for more than this
DEFAULT_F0MN = 1350.0  # until the package file has been read

R11_WARN_SECONDS = 45.0  # rule 11
R11_TIME_SECONDS = 60.0
R11_TEMPERATURE = 50.0

FAN_STALE_SECONDS = 2.0  # rule 12
PACKAGE_STALE_SECONDS = 5.0

# Derived gates (the run-1 amendment, items 8 and 12; the fixes' section C, critic S5). The facts
# the runbook reads are evaluated here, once, instead of by hand. They are logged as GATE lines
# and never spoken.
GATE_REST_SECONDS = 60.0  # "at rest" must have held this long ...
GATE_REST_MARGIN = 3.0  # ... with the hottest curated at most T0 + this
GATE_QUIESCENCE_SECONDS = 120.0  # D9's quiescence window; T0 is the median over it
GATE_SPAN_TOLERANCE = 0.5  # a window of L s is complete at a span of L - 0.5 s (10 Hz stamps)
GATE_MAX_GAP = FAN_STALE_SECONDS  # a gap in the fan record this long ends a run: nobody saw it
GATE_PACKAGE_FRESH = 3.0  # the package sample a gate reads is under this much older than the fans'
GATE_T0_LIMIT = 50.0  # T0 must be below this
GATE_T0_MIN_SAMPLES = 100  # package samples in T0's window
GATE_ENGAGED_ABOVE_F0MN = 300.0  # 1b's engaged condition: F0Tg at least F0Mn + this ...
GATE_ENGAGED_SECONDS = 30.0  # ... for this long
GATE_CLOCK_SECONDS = 1800.0  # the at-rest clock: 30 minutes
GATE_EVERY_SECONDS = 60.0  # a provisional T0 and a ticking clock are logged this often
GATE_FAN_KEYS = ("F0Md", "F1Md", "Ftst", "F0Tg", "F1Tg")

REPEAT_SECONDS = 15.0  # an alert state repeats aloud this often while it holds
LATCH_SECONDS = 120.0  # an event alert (a log line, a changed value) holds this long
STATUS_SECONDS = 5.0
HISTORY_SECONDS = 90.0
LOOP_SECONDS = 0.05  # the live loop's period, and the replay's tick

HELPER_PROCESS = "AeolusHelper"
SAFE_MODES = (0, 3)

# --------------------------------------------------------------------------------------------
# What the process may start, and what it may write.
# --------------------------------------------------------------------------------------------

COMMANDS = {
    "pgrep": ("/usr/bin/pgrep", "-x", HELPER_PROCESS),
    "notifyutil": ("/usr/bin/notifyutil", "-g", "com.apple.system.thermalpressurelevel"),
    "pmset": ("/usr/bin/pmset", "-g", "therm"),
}
SAY = "/usr/bin/say"
AFPLAY = "/usr/bin/afplay"
ALERT_SOUND = "/System/Library/Sounds/Sosumi.aiff"
SAY_SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .,]*$")
OWN_FILES = ("watch.log", "watch.hb", "ALERT")


def _allowed(argv):
    argv = tuple(argv)
    if any(argv == spec for spec in COMMANDS.values()) or argv == (AFPLAY, ALERT_SOUND):
        return True
    return len(argv) == 2 and argv[0] == SAY and bool(SAY_SAFE.match(argv[1]))


def _spawn(argv, capture=False, timeout=None):
    """The one place a program starts. Anything not on the list is refused."""
    argv = tuple(argv)
    if not _allowed(argv):
        raise PermissionError("refusing to start %r" % (argv,))
    if capture:
        return subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    return subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --------------------------------------------------------------------------------------------
# Parsing. Everything here is pure.
# --------------------------------------------------------------------------------------------

FanSample = namedtuple("FanSample", "t v")
PackageSample = namedtuple("PackageSample", "t hottest f")
LogLine = namedtuple("LogLine", "t level msg foreign")
CtxLine = namedtuple("CtxLine", "t kind step target pid raw bad_target", defaults=(None,))
MISSING_TARGET = "(no target= field)"  # the bad_target of a step line that has no target at all

_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$")
_LOG_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?([+-])(\d{2}):?(\d{2})$")
_CTX_RE = re.compile(
    r"^\s*(?:(?P<stamp>\d{9,}(?:\.\d+)?|\d{4}-\d{2}-\d{2}T[0-9:.]+Z)\s+)?CTX\s+(?P<body>\S.*?)\s*$")
_WROTE_RE = re.compile(
    r"^Wrote (?P<key>\S+) = (?P<bytes>.*?): answered (?P<answer>.*), in (?P<dur>\S+) seconds\.$",
    re.S)
_DURATION_RE = re.compile(r"^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$")
_RPM_RE = re.compile(r"^\d+(?:\.\d+)?\Z")
_REFUSED_RE = re.compile(r"^The engagement of fan \d+ was refused after \d+ attempt\(s\): ")
_TEMPERATURE_KEY = re.compile(r"^T[A-Za-z0-9]{3}$")


def _epoch(fields, fraction, offset=0):
    y, mo, d, h, mi, s = (int(x) for x in fields)
    base = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))
    return base + (float("0." + fraction) if fraction else 0.0) - offset


def parse_iso_utc(text):
    """`2026-10-31T01:17:19.037Z` -> epoch seconds, or None."""
    m = _ISO_RE.match(text) if isinstance(text, str) else None
    return _epoch(m.groups()[:6], m.group(7)) if m else None


def parse_log_timestamp(text):
    """`2026-10-28 15:20:10.311558-0700` -> epoch seconds, or None."""
    m = _LOG_TS_RE.match(text) if isinstance(text, str) else None
    if not m:
        return None
    sign = -1 if m.group(8) == "-" else 1
    offset = sign * (int(m.group(9)) * 3600 + int(m.group(10)) * 60)
    return _epoch(m.groups()[:6], m.group(7), offset)


def parse_duration_seconds(text):
    """The text of a Swift `Duration` as seconds: `5.3083e-05` is 53 microseconds (F2).

    It takes exponents, and refuses what is not a plain non-negative finite decimal, so a value
    that cannot be compared (`nan`) is reported as unparsed rather than read as small."""
    if not isinstance(text, str) or not _DURATION_RE.match(text):
        return None
    value = float(text)
    return value if math.isfinite(value) else None


def _byte(data):
    """The value of a one-byte write's data text (`0x1`), or None for anything else."""
    m = re.fullmatch(r"0x([0-9a-fA-F]{1,2})", data.strip()) if isinstance(data, str) else None
    return int(m.group(1), 16) if m else None


def parse_wrote(msg):
    """(key, bytes, answer, duration text) of a `Wrote` line, or None if it does not parse."""
    m = _WROTE_RE.match(msg)
    return (m.group("key"), m.group("bytes"), m.group("answer"), m.group("dur")) if m else None


def parse_rpm(text):
    """A CTX target as RPM: a plain decimal above 0, or None. `5,777`, `5777rpm`, `nan`, `inf`,
    `1e3`, `-5` and `0` are all refused, never read as something else."""
    if not isinstance(text, str) or not _RPM_RE.match(text):
        return None
    value = float(text)
    return value if math.isfinite(value) and value > 0 else None


def _number(reading):
    if not isinstance(reading, dict) or reading.get("status") != "ok":
        return None
    value = reading.get("value")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


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


def parse_fan_line(raw):
    """A `sample` line of the fan file as a FanSample, or None (start, heartbeat, stop, junk)."""
    record = _record(raw)
    if record is None or record.get("kind") != "sample":
        return None
    t = parse_iso_utc(record.get("wallClockUTC"))
    readings = record.get("readings")
    if t is None or not isinstance(readings, list):
        return None
    values = {}
    for reading in readings:
        if isinstance(reading, dict) and isinstance(reading.get("key"), str):
            number = _number(reading)
            if number is not None:
                values[reading["key"]] = number
    return FanSample(t, values)


def is_stop_line(raw):
    """Whether a line is a sampler's own `stop` line, the last of its file. The sampler writes it
    on a clean exit (a signal, or `--count` reached) with the keys of `SamplerStopRecord`:
    `kind`, `totalTicks`, `finalContinuousNanoseconds` and `finalSuspendingNanoseconds`. It has no
    wall-clock stamp, so the caller dates it by the file's last sample: up to one sampling interval
    before it was written, which orders it correctly against every other stream except a line
    written within that interval of it."""
    record = _record(raw)
    return record is not None and record.get("kind") == "stop"


def parse_package_line(raw):
    """A `sample` line of the package file. `hottest` is the highest temperature key that read;
    `f` holds the F<n> keys (F0Mn is the one used)."""
    record = _record(raw)
    if record is None or record.get("kind") != "sample":
        return None
    t = parse_iso_utc(record.get("wallClockUTC"))
    readings = record.get("readings")
    if t is None or not isinstance(readings, list):
        return None
    hottest, fans = None, {}
    for reading in readings:
        key = reading.get("key") if isinstance(reading, dict) else None
        number = _number(reading)
        if number is None or not isinstance(key, str):
            continue
        if _TEMPERATURE_KEY.match(key):
            hottest = number if hottest is None else max(hottest, number)
        elif key.startswith("F"):
            fans[key] = number
    return PackageSample(t, hottest, fans)


def parse_log_line(raw):
    """One line of `log stream --style ndjson`, or None for the header and anything else."""
    record = _record(raw)
    if record is None or not isinstance(record.get("eventMessage"), str):
        return None
    t = parse_log_timestamp(record.get("timestamp"))
    if t is None:
        return None
    image = record.get("processImagePath")
    foreign = isinstance(image, str) and image.rsplit("/", 1)[-1] != HELPER_PROCESS
    return LogLine(t, str(record.get("messageType", "")), record["eventMessage"], foreign)


def parse_ctx_line(raw, arrival=None):
    """A `CTX` line of phases.log, or None for any other line. The stamp is the epoch seconds
    the coordinator wrote, or an ISO UTC time; a line with neither takes `arrival`."""
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    m = _CTX_RE.match(raw)
    if not m:
        return None
    stamp = m.group("stamp")
    if stamp is None:
        t = arrival
    elif stamp[0].isdigit() and "T" not in stamp:
        t = float(stamp)
    else:
        t = parse_iso_utc(stamp)
    tokens = m.group("body").replace("′", "'").split()
    fields = {}
    for token in tokens:
        if "=" in token:
            name, _, value = token.partition("=")
            fields[name] = value
    kind, step, target, pid, bad_target = tokens[0], fields.get("step"), None, None, None
    if kind.startswith("step="):
        kind = "step"
    if "target" in fields:
        if fields["target"] != "none":
            target = parse_rpm(fields["target"])
            if target is None:
                bad_target = fields["target"]
    elif kind == "step" and step != "none":  # `step=1b GO`, or a misspelt `targt=5777`
        bad_target = MISSING_TARGET
    if fields.get("pid", "").isdigit():
        pid = int(fields["pid"])
    return CtxLine(t, kind, step, target, pid, m.group("body"), bad_target)


# --------------------------------------------------------------------------------------------
# Output: the only files this process writes.
# --------------------------------------------------------------------------------------------


def one_line(text):
    """A record is one line: whatever a log message carries, it cannot split watch.log."""
    return " ".join(str(text).splitlines())


def format_time(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + (".%03dZ" % int((t % 1) * 1000))


class Output:
    """watch.log, watch.hb and ALERT in one directory, and nothing else."""

    def __init__(self, directory):
        self.directory = directory
        self.log_file = None
        self.alert_file = None

    def _path(self, name):
        assert name in OWN_FILES
        return os.path.join(self.directory, name)

    def line(self, t, level, text):
        if self.log_file is None:
            self.log_file = open(self._path("watch.log"), "a", encoding="utf-8", buffering=1)
        self.log_file.write("%s %s %s\n" % (format_time(t), level, one_line(text)))

    def alert(self, t, text):
        if self.alert_file is None:
            self.alert_file = open(self._path("ALERT"), "a", encoding="utf-8", buffering=1)
        self.alert_file.write("%s %s\n" % (format_time(t), one_line(text)))

    def heartbeat(self, wall):
        with open(self._path("watch.hb"), "w", encoding="utf-8") as handle:
            handle.write("%.3f\n" % wall)

    def close(self):
        for handle in (self.log_file, self.alert_file):
            if handle is not None:
                handle.close()


class MemoryOutput:
    """The same interface with no files, for tests."""

    def __init__(self):
        self.lines, self.alerts, self.beats = [], [], []

    def line(self, t, level, text):
        self.lines.append((t, level, text))

    def alert(self, t, text):
        self.alerts.append((t, text))

    def heartbeat(self, wall):
        self.beats.append(wall)

    def close(self):
        pass


# --------------------------------------------------------------------------------------------
# The rules.
# --------------------------------------------------------------------------------------------

Raised = namedtuple("Raised", "t id title detail")


class _Alert:
    __slots__ = ("title", "kind", "active", "next_speak", "latch_until")

    def __init__(self, title, kind):
        self.title, self.kind = title, kind
        self.active, self.next_speak, self.latch_until = False, 0.0, 0.0


def _voice(title):
    return re.sub(r"\s*—\s*", ". ", title).lower()


class Watcher:
    """The rules, as a function of the events fed to it. It has no clock of its own: `now` is
    the latest time any event or `advance` has carried, so a replay and a live run take the
    same path. Every `check_*` method is one rule's check, and removing a method's body
    removes that check and nothing else (the dry run's D4 does exactly that).

    With `guard` (the live loop) a check that raises is heard once as "watcher error" and the
    checks after it still run; without it (a replay, the tests) it raises, so a bug is seen."""

    def __init__(self, out, speak=False, guard=False):
        self.out = out
        self.speak = speak
        self.guard = guard
        self.error_counts = {}
        self.say_queue = []
        self.muted = False
        self.now = None
        self.t_start = None
        self.alerts = {}
        self.raised = []
        self.counts = {"NOTE": 0, "WARN": 0}
        self.ended_sources = set()
        self.pending = []
        self.next_status = None
        # fans
        self.fan = None
        self.fan_prev = None
        self.fan_last_t = None
        self.fan_hist = deque()
        self.fan_samples = 0
        # package
        self.hottest = None
        self.pkg_last_t = None
        self.pkg_hist = deque()
        self.f0mn = DEFAULT_F0MN
        self.package_samples = 0
        # context
        self.step = None
        self.target = None
        self.step_t = None
        self.load_active = False  # the load is running: load-start to load-stop
        self.load_window = False  # 74 C applies: load-start to the first step=none after load-stop
        self.load_stopped = False  # load-stop has come, and the window ends at the next step=none
        self.bad_target = None  # the text of an unreadable CTX target, until a valid step line
        self.t_L = None
        self.b = None
        self.b_due = None
        self.armed = False
        self.armed_t = None
        self.armed_pids = None
        self.ended = False
        self.last_pgrep = None
        self.pressure = None
        self.pmset_first = None
        self.logstream_alive = None
        # derived from the helper's log
        self.hold_active = False
        self.hold_since = None
        self.hold_end_t = None  # the stamp of the restore that last ended a hold
        self.engage_t = None
        self.restore_t = None
        self.clean_since = None
        self.r8_warned = False
        self.writes = deque()
        self.foreign_warned = False
        # per-rule run state
        self.r2_since = {0: None, 1: None}
        self.tg_hit_t = None
        self.r2_held_since = None
        self.f0_unjudged = deque()  # (t, mode) of out-of-set samples not yet old enough to judge
        self.r4_pending = []
        self.r10_since = None
        self.r11 = None
        # derived gates: logged, never spoken
        self.gate_keys = {}  # per gate, the state its last line described
        self.quiet_since = None  # first sample of the fans' newest run of D9 quiescence
        self.rest_since = None  # ... of their newest run of "at rest"
        self.engaged_since = None  # ... of their newest run of F0Tg >= F0Mn + 300
        self.pkg_log = deque()  # (t, hottest) over the last 130 s: T0's window
        self.t0 = None
        self.t0_n = 0
        self.t0_window = None
        self.t0_dirty = False  # a package sample has arrived since T0 was last worked out
        self.t0_frozen = False
        self.t0_frozen_by = None
        self.t0_freeze_pending = None  # why T0 freezes at the first window after it, if it must
        self.rest_yes = False
        self.clock_start = None  # the at-rest clock: when it started (event time) ...
        self.clock_why = None  # ... and why
        self.clock_state = None  # None, "ticking", "met" or "expired"

    # ---------------------------------------------------------------- bookkeeping

    def start(self, t):
        self.now = t if self.now is None else max(self.now, t)
        if self.t_start is None:
            self.t_start = t
        if self.next_status is None:
            self.next_status = t + STATUS_SECONDS

    def _bump(self, t):
        if self.now is None or t > self.now:
            self.now = t
        if self.t_start is None:
            self.start(t)

    def _stamp(self):
        return self.now if self.now is not None else time.time()

    def note(self, text, level="NOTE"):
        self.counts[level] = self.counts.get(level, 0) + 1
        self.out.line(self._stamp(), level, text)

    def info(self, text):
        self.out.line(self._stamp(), "INFO", text)

    def _enter(self, aid, title, detail, kind, latch=LATCH_SECONDS):
        state = self.alerts.get(aid)
        if state is None:
            state = self.alerts[aid] = _Alert(title, kind)
        state.title, state.kind, state.active = title, kind, True
        state.latch_until = self.now + latch
        state.next_speak = self.now + REPEAT_SECONDS
        self.raised.append(Raised(self.now, aid, title, detail))
        text = "%s: %s" % (title, detail)
        self.out.line(self.now, "ALERT", text)
        self.out.alert(self.now, text)
        if self.speak:
            self.say_queue.append(_voice(title))

    def event(self, aid, title, detail, latch=LATCH_SECONDS):
        """An alert for something that happened. It holds, and repeats, for `latch` seconds."""
        self._enter(aid, title, detail, "event", latch)

    def level(self, aid, title, condition, detail=""):
        """An alert for something that is true. It holds as long as `condition` does."""
        state = self.alerts.get(aid)
        active = state is not None and state.active
        if condition:
            if active and state.title != title:
                self._clear(aid)
                active = False
            if not active:
                self._enter(aid, title, detail, "level")
        elif active and state.kind == "level":
            self._clear(aid)

    def _clear(self, aid):
        state = self.alerts[aid]
        state.active = False
        self.out.line(self.now, "CLEAR", "%s no longer holds" % state.title)

    def internal_error(self, error, where="the live loop"):
        """A rule raised. The live loop goes on, and the operator is told once per episode: a
        watcher that dies is only heard by the companion ten seconds later. A bug that raises on
        every sample would write ten traceback lines a second into the file the operator is
        reading, so a traceback is written for its first occurrence and every thousandth."""
        key = (where, type(error).__name__, str(error)[:200])
        count = self.error_counts[key] = self.error_counts.get(key, 0) + 1
        if count == 1 or count % 1000 == 0:
            trace = " | ".join(traceback.format_exc().strip().splitlines()[-4:])
            self.out.line(self._stamp(), "ERROR", "%s (%s, occurrence %d)" % (trace, where, count))
        state = self.alerts.get("x-internal")
        if state is None or not state.active:
            self.event(
                "x-internal", "WATCHER ERROR",
                "%s raised %s: %s; the other checks still run" % (where, type(error).__name__, error))

    def _guard(self, check, *args):
        """Run one check. Live, a check that raises is heard and the next one still runs: one
        persistent bug must not silence rules 3, 4, 9 and 10 as well."""
        if not self.guard:
            check(*args)
            return
        try:
            check(*args)
        except Exception as error:  # noqa: BLE001  a bug in a rule must be heard, not fatal
            self.internal_error(error, getattr(check, "__name__", "a check"))

    def active_alerts(self):
        return sorted(s.title for s in self.alerts.values() if s.active)

    def take_speech(self):
        queue, self.say_queue = self.say_queue, []
        return queue

    def go_live(self, now):
        """The history is read. Anything that still holds begins to repeat aloud at once."""
        self.speak = True
        self._bump(now)
        for state in self.alerts.values():
            if state.active:
                state.next_speak = self.now

    def source_ended(self, name):
        """Replay only: a file that has been read to its end is not a stalled recorder."""
        self.ended_sources.add(name)

    # ---------------------------------------------------------------- events: the fan file

    def on_fan(self, sample):
        self._bump(sample.t)
        self.fan_prev, self.fan = self.fan, sample
        self.fan_last_t = sample.t
        self.fan_samples += 1
        self.fan_hist.append(sample)
        self._trim(self.fan_hist, sample.t)
        self.ended_sources.discard("fans")  # a sampler that has started again is no longer over
        guard = self._guard
        self._gate_guard(self.check_gate_runs, sample)
        guard(self._track_restore)
        guard(self._track_r11_release, sample)
        guard(self.check_r2_automatic, sample)
        guard(self.check_r2_held, sample)
        guard(self.check_r3_ftst, sample)
        guard(self.check_r3_f1_mode, sample)
        guard(self.check_r3_f0_mode, sample)
        guard(self.check_r3_hold, sample)
        guard(self.check_r4_verdict, sample)
        guard(self.check_r9_f1_follows, sample)
        guard(self.check_r10_floor, sample)
        guard(self.check_x_no_context, sample)
        guard(self.check_r11_time)
        guard(self._judge_f0_modes)
        guard(self._judge_pending)

    def check_r2_automatic(self, s):
        """Rule 2: an automatic fan whose actual speed stays under 0.8 of its target."""
        for n in (0, 1):
            if n == 0 and self.hold_active:
                self.r2_since[0] = None
                self.level("r2-f0", "ABORT 2", False)
                continue
            tg, ac = s.v.get("F%dTg" % n), s.v.get("F%dAc" % n)
            low = tg is not None and ac is not None and tg > 0 and ac < ACTUAL_FRACTION * tg
            if not low:
                self.r2_since[n] = None
            elif self.r2_since[n] is None:
                self.r2_since[n] = s.t
            since = self.r2_since[n]
            self.level(
                "r2-f%d" % n, "ABORT 2", since is not None and s.t - since >= RULE2_SECONDS,
                "fan %d F%dAc %s is under 0.8 x F%dTg %s since %s" % (
                    n, n, ac, n, tg, format_time(since or s.t)))

    def check_r2_held(self, s):
        """Rule 2, the held fan: counted from 10 s after F0Tg first reads the CTX target."""
        target = self.target
        tg, ac = s.v.get("F0Tg"), s.v.get("F0Ac")
        if not self.hold_active or target is None or tg is None or ac is None:
            self.r2_held_since = None
            self.level("r2-held", "ABORT 2", False)
            return
        if self.tg_hit_t is None and abs(tg - target) <= TARGET_TOLERANCE_RPM:
            self.tg_hit_t = s.t
        counted = self.tg_hit_t is not None and s.t >= self.tg_hit_t + HELD_SPINUP_SECONDS
        if not (counted and ac < ACTUAL_FRACTION * target):
            self.r2_held_since = None
        elif self.r2_held_since is None:
            self.r2_held_since = s.t
        since = self.r2_held_since
        self.level(
            "r2-held", "ABORT 2", since is not None and s.t - since >= RULE2_SECONDS,
            "held fan 0: F0Ac %s is under 0.8 x the target %s since %s" % (
                ac, target, format_time(since or s.t)))

    def check_r3_ftst(self, s):
        """Rule 3: Ftst changed with no `Wrote Ftst` near it (judged 2 s later)."""
        prev = self.fan_prev.v.get("Ftst") if self.fan_prev else None
        cur = s.v.get("Ftst")
        if prev is not None and cur is not None and cur != prev:
            self.pending.append((s.t + JUDGE_AFTER, "ftst", s.t, "Ftst", prev, cur))

    def check_r3_f1_mode(self, s):
        """Rule 3: any F1Md outside {0, 3}. Nothing in run 1 writes fan 1's mode."""
        mode = s.v.get("F1Md")
        bad = mode is not None and mode not in SAFE_MODES
        self.level("r3-f1md", "ABORT 3", bad, "F1Md reads %s, outside {0, 3}" % mode)

    def check_r3_f0_mode(self, s):
        """Rule 3: F0Md outside {0, 3} for 2 s with no explaining line.

        `F0Md = 1` in a hold is the hold, and is exempt: it does not count towards the 2 s, so
        the clock starts when the hold ends, not when it began. A restore that did not take is
        therefore heard 2 s after the restore, whether the hold lasted 30 s or 120. A readback
        that lags the restore's stamp is absorbed by the same 2 s, so there is no separate grace.
        A sample stamped before the restore line is in the hold even when it is read after the
        line, as the sample just before the restore usually is live; otherwise it would start the
        2 s early and the tolerance would be about 1.9 s. Each out-of-set sample waits to be
        judged (`_judge_f0_modes`)."""
        mode = s.v.get("F0Md")
        held = self.hold_active or (self.hold_end_t is not None and s.t < self.hold_end_t)
        if mode is None or mode in SAFE_MODES or (mode == 1 and held):
            self.f0_unjudged.clear()
            self.level("r3-f0md", "ABORT 3", False)
            return
        self.f0_unjudged.append((s.t, mode))

    def _judge_f0_modes(self):
        """Judge each out-of-set F0Md sample once it is 2 s old, if the mode has stayed out of the
        set the whole time (a sample that returns to the set clears the queue). The explanation is
        a `Wrote F0Md` of the value read, in that sample's own window [t - 2 s, t + 0.5 s]: an old
        write cannot explain a later reading, and a write of 0x0 does not explain a reading of 1."""
        delay = max(MODE_SECONDS, JUDGE_AFTER)
        while self.f0_unjudged and self.f0_unjudged[0][0] + delay <= self.now:
            t, mode = self.f0_unjudged.popleft()
            explained = self._wrote_value("F0Md", mode, t - EXPLAIN_BEFORE, t + EXPLAIN_AFTER)
            self.level(
                "r3-f0md", "ABORT 3", not explained,
                "F0Md read %g at %s and has stayed outside {0, 3} for %.0f s, with no `Wrote F0Md = "
                "0x%x` in [-2 s, +0.5 s] of that sample" % (mode, format_time(t), delay, int(mode)))

    def check_r3_hold(self, s):
        """Rule 3, during a hold: F0Tg moved more than 1 RPM, or F0Md left 1, with no `Wrote`
        of that key near it (judged 2 s later)."""
        if not self.hold_active or self.fan_prev is None:
            return
        tg, prev_tg = s.v.get("F0Tg"), self.fan_prev.v.get("F0Tg")
        if tg is not None and prev_tg is not None and abs(tg - prev_tg) > TARGET_MOVE_RPM:
            self.pending.append((s.t + JUDGE_AFTER, "hold", s.t, "F0Tg", prev_tg, tg))
        md, prev_md = s.v.get("F0Md"), self.fan_prev.v.get("F0Md")
        if prev_md == 1 and md is not None and md != 1:
            self.pending.append((s.t + JUDGE_AFTER, "hold", s.t, "F0Md", prev_md, md))

    def check_r4_verdict(self, s):
        """Rule 4: the first sample after a landed undo decides VERIFY or RESET."""
        still = []
        for line_t, text in self.r4_pending:
            if s.t >= line_t:
                self._r4_decide(s, text)
            else:
                still.append((line_t, text))
        self.r4_pending = still

    def check_r9_f1_follows(self, s):
        """Rule 9: during a hold, fan 1's target is above 0.9 of the held fan's CTX target."""
        f1, target = s.v.get("F1Tg"), self.target
        over = (
            self.hold_active and target is not None and f1 is not None
            and f1 > F1_FOLLOW_FRACTION * target)
        self.level(
            "r9", "ABORT 9", over,
            "F1Tg %s is above 0.9 x the target %s: Apple is demanding more than the hold" % (
                f1, target))

    def check_r10_floor(self, s):
        """Rule 10: F0Md = 1 with F0Tg below F0Mn for more than 1 s."""
        md, tg = s.v.get("F0Md"), s.v.get("F0Tg")
        if md == 1 and tg is not None and tg < self.f0mn:
            if self.r10_since is None:
                self.r10_since = s.t
        else:
            self.r10_since = None
        since = self.r10_since
        self.level(
            "r10", "ABORT 10", since is not None and s.t - since > FLOOR_SECONDS,
            "F0Md = 1 with F0Tg %s below F0Mn %s since %s" % (tg, self.f0mn, format_time(since or s.t)))

    def check_x_no_context(self, s):
        """F0Md = 1 with no open CTX step."""
        self.level(
            "x-no-context", "NO CONTEXT", s.v.get("F0Md") == 1 and self.step is None,
            "F0Md reads 1 and no CTX step is open: the coordinator has not written one")

    # ---------------------------------------------------------------- events: the package file

    def on_package(self, p):
        self._bump(p.t)
        self.pkg_last_t = p.t
        self.package_samples += 1
        self.ended_sources.discard("package")
        if p.hottest is not None:
            self.hottest = p.hottest
            self.pkg_hist.append((p.t, p.hottest))
            self._trim(self.pkg_hist, p.t, key=lambda item: item[0])
            self.pkg_log.append((p.t, p.hottest))
            self._trim(
                self.pkg_log, p.t, key=lambda item: item[0], span=GATE_QUIESCENCE_SECONDS + 10.0)
            self.t0_dirty = True
        mn = p.f.get("F0Mn")
        if mn is not None and mn > 0:
            self.f0mn = mn
        self._guard(self._resolve_b)
        if p.hottest is not None:
            self._guard(self.check_r1_absolute, p.hottest)
            self._guard(self.check_r1_loaded, p.hottest)
            self._guard(self.check_r1_rise, p.hottest)
            self._guard(self.check_r11_temperature, p.hottest)

    def check_r1_absolute(self, hottest):
        self.level(
            "r1-absolute", "ABORT 1", hottest > TEMP_ABSOLUTE,
            "hottest curated %.1f C is above %.0f C" % (hottest, TEMP_ABSOLUTE))

    def check_r1_loaded(self, hottest):
        """74 C holds in a load window: from load-start to the first step=none after load-stop.
        The machine leaves a load heat-soaked, so the window outlasts the load itself."""
        self.level(
            "r1-loaded", "ABORT 1", self.load_window and hottest > TEMP_LOADED,
            "hottest curated %.1f C is above %.0f C in a load window" % (hottest, TEMP_LOADED))

    def check_r1_rise(self, hottest):
        """B + 10 holds only in a step that no load window covers: a baseline taken at rest never
        applies again after a load in the same step."""
        limit = None if self.b is None else self.b + TEMP_RISE
        rising = (
            self.step is not None and not self.load_window and limit is not None
            and hottest > limit)
        self.level(
            "r1-rise", "ABORT 1", rising,
            "hottest curated %.1f C is above B + 10 = %s C" % (
                hottest, "%.1f" % limit if limit is not None else "?"))

    def check_r11_temperature(self, hottest):
        armed = self.r11 is not None and self._f1_reads_zero()
        self.level(
            "r11-temperature", "ABORT 11 TEMPERATURE", armed and hottest >= R11_TEMPERATURE,
            "F1Tg still reads 0 and the hottest curated is %.1f C (>= %.0f C)" % (
                hottest, R11_TEMPERATURE))

    # ---------------------------------------------------------------- events: the helper's log

    def on_log(self, line):
        self._bump(line.t)
        if line.foreign:
            if not self.foreign_warned:
                self.foreign_warned = True
                self.note(
                    "log lines from a process other than %s are being ignored: the stream's "
                    "predicate is missing its process clause (F1)" % HELPER_PROCESS, "WARN")
            return
        msg = line.msg
        self._guard(self.check_x_fault, line)
        self._guard(self.check_r4_refused, line)
        self._guard(self.check_r7_prep_step, line)
        if msg.startswith("Wrote"):
            self._guard(self.check_r5_write, line)
            wrote = parse_wrote(msg)
            if wrote is not None:
                self._guard(self._track_write, line.t, wrote)

    def check_x_fault(self, line):
        """Any `Fault` line from the helper, at every stage of the run: a refused exit restore is
        the one that matters most after the last step, and nothing is left to end by then."""
        if line.level != "Fault":
            return
        text = line.msg if len(line.msg) <= 300 else line.msg[:300] + "..."
        self.event("x-fault", "HELPER FAULT", text)

    def check_r4_refused(self, line):
        """Rule 4: an engagement refused, or an undo that could not be made. The phrases are
        read where the helper puts them: the line begins `The engagement of fan N was refused
        after M attempt(s): <detail>.`, and its outcome is the sentence after the detail, which is
        the last. Nothing the detail quotes can stand in for the outcome."""
        msg = line.msg
        if msg.startswith("Could not undo the engagement of fan "):
            self.event("r4-reset", "ABORT 4 — RESET", "the hand-back of an engagement was refused")
        elif _REFUSED_RE.match(msg):
            outcome = msg.rsplit(". ", 1)[-1]
            if outcome == "Nothing was written.":
                self.note("an engagement was refused and nothing was written (not an abort)")
            elif outcome.endswith("the restore landed."):
                self.r4_pending.append((line.t, msg))
                for s in self.fan_hist:  # the sample may have arrived before the line did
                    if s.t >= line.t:
                        self.check_r4_verdict(s)
                        break
            else:
                self.event(
                    "r4-reset", "ABORT 4 — RESET",
                    "an engagement was refused and the line does not say the restore landed")

    def _r4_decide(self, sample, msg):
        v = sample.v
        clean = v.get("Ftst") == 0 and all(v.get("F%dMd" % n) in SAFE_MODES for n in (0, 1))
        if clean:
            self.event(
                "r4-verify", "ABORT 4 — VERIFY",
                "the line says the restore landed and the first sample after it, %s, agrees"
                % format_time(sample.t))
        else:
            self.event(
                "r4-reset", "ABORT 4 — RESET",
                "the line says the restore landed but the first sample after it, %s, shows "
                "Ftst %s F0Md %s F1Md %s" % (
                    format_time(sample.t), v.get("Ftst"), v.get("F0Md"), v.get("F1Md")))

    def check_r4_escalate(self):
        """Rule 4: no verdict 10 s after the line is RESET."""
        for line_t, _ in list(self.r4_pending):
            if self.now - line_t >= VERIFY_ESCALATE_SECONDS:
                self.r4_pending = [p for p in self.r4_pending if p[0] != line_t]
                self.event(
                    "r4-reset", "ABORT 4 — RESET",
                    "no sample followed the line within %.0f s: no verdict" % VERIFY_ESCALATE_SECONDS)

    def check_r5_write(self, line):
        """Rule 5: a write whose round trip took 1 s or more, parsed as a float (F2)."""
        wrote = parse_wrote(line.msg)
        seconds = parse_duration_seconds(wrote[3]) if wrote is not None else None
        if seconds is None:
            self.event("r5-unparsed", "UNPARSED WRITE", "cannot read a duration from: %s" % line.msg[:200])
            return
        if seconds >= WRITE_NOTE_50MS:
            self.note("above 50 ms: forward writes end after this hold (%s took %.4g s)" % (
                wrote[0], seconds))
        elif seconds >= WRITE_NOTE_20MS:
            self.note("above G's 20 ms (%s took %.4g s)" % (wrote[0], seconds))
        if seconds >= WRITE_ABORT_SECONDS:
            self.event(
                "r5-slow", "ABORT 5", "%s = %s took %.4g s to answer" % (wrote[0], wrote[1], seconds))

    def check_r7_prep_step(self, line):
        """Rule 7: a second preparation-step line after CTX armed."""
        if self.armed and line.t > self.armed_t and (
                "The write path's preparation step" in line.msg):
            self._r7_fire("a second preparation-step line appeared")

    def _r7_fire(self, why):
        """During a hold, ABORT 7, whatever CTX says. Otherwise HELPER RESTARTED, except after
        CTX end: the reinstall of the main build replaces the helper by design, so a restart is a
        note there. That is the one thing CTX end changes."""
        if self.ended and not self.hold_active:
            self.note("after CTX end: %s (the reinstall replaces the helper)" % why)
            return
        title = "ABORT 7" if self.hold_active else "HELPER RESTARTED"
        self.event("r7", title, why)

    def _track_write(self, t, wrote):
        key, data, answer = wrote[0], wrote[1], wrote[2]
        self.writes.append((t, key, data))
        self._trim(self.writes, t, key=lambda item: item[0])
        if key != "F0Md":
            return
        if data == "0x1":
            if self.engage_t is None:
                self.engage_t, self.r8_warned = t, False
                self.info("engage: first `Wrote F0Md = 0x1` of the step (answered %s)" % answer)
            if answer == "0x00":
                if not self.hold_active:
                    self.tg_hit_t = None
                    self.r2_since[0] = self.r2_held_since = None
                    # A stop line after CTX end ended its source, but a hold that begins now is
                    # not the teardown: rule 12 watches both samplers again (#652's review S1).
                    self.ended_sources.clear()
                self.hold_active = True
                self.hold_since = self.hold_since or t
        elif data == "0x0":
            if self.hold_active:
                self.hold_end_t = t
            self.hold_active, self.hold_since = False, None
            if self.engage_t is not None:
                self.restore_t, self.clean_since = t, None
                self._track_restore()

    def _wrote(self, key, lo, hi):
        """Whether any `Wrote <key>` is stamped in [lo, hi]."""
        return any(k == key and lo <= t <= hi for t, k, _ in self.writes)

    def _wrote_value(self, key, value, lo, hi):
        """Whether a `Wrote <key>` of the one-byte `value` is stamped in [lo, hi]."""
        return any(
            k == key and lo <= t <= hi and _byte(data) == value for t, k, data in self.writes)

    # ---------------------------------------------------------------- events: CTX and polls

    def on_ctx(self, c):
        self._bump(c.t)
        kind = c.kind
        closing = self.step  # the step a `step=none` closes, for the at-rest clock
        self._guard(self.check_x_bad_context, c)
        self._gate_guard(self.track_gate_ctx, c, closing)
        if kind == "armed":
            self.armed, self.armed_t = True, c.t
            self.armed_pids = frozenset([c.pid]) if c.pid else self.last_pgrep
            self.info("armed; helper PIDs %s" % (sorted(self.armed_pids) if self.armed_pids else "to be read"))
        elif kind == "step":
            if c.step in (None, "none"):
                self.step, self.target, self.b, self.b_due = None, None, None, None
                if self.load_stopped:  # the first step=none after load-stop ends the load window
                    self.load_window = self.load_stopped = False
                self.info("CTX step=none")
            else:
                self.step, self.target, self.step_t = c.step, c.target, c.t
                self.tg_hit_t, self.r2_held_since = None, None
                self.b, self.b_due = None, c.t
                self._guard(self._resolve_b)
                self.info("CTX step=%s target=%s" % (c.step, "none" if c.target is None else "%g" % c.target))
        elif kind == "load-start":
            self.load_active, self.load_window, self.load_stopped, self.t_L = True, True, False, c.t
            if c.step == "1d":
                self.r11 = {"t_L": c.t, "warned": False}
            self.info("CTX load-start step=%s" % c.step)
        elif kind == "load-stop":
            self.load_active = False
            if self.step is None:  # no step is open to carry the window past the load
                self.load_window = False
            else:
                self.load_stopped = True
            if self.r11 is not None:
                self.r11 = None
                self.level("r11-time", "ABORT 11 TIME", False)
                self.level("r11-temperature", "ABORT 11 TEMPERATURE", False)
            self.info("CTX load-stop")
        elif kind == "test-alert":
            self.event("test-alert", "TEST ALERT", "CTX test-alert: this is only a test", latch=0)
        elif kind == "end":
            self.ended = True
            self.info(
                "CTX end: outside a hold, a helper restart is now a note, and a sampler's stop line "
                "now ends its source; nothing else stands down")
        else:
            self.note("unknown CTX line: %s" % c.raw[:120])

    def check_x_bad_context(self, c):
        """A CTX line whose target cannot be read as RPM, or a step line (other than `step=none`)
        with no target at all. Either would otherwise leave rule 9 and the held-fan clause of
        rule 2 off with no word. It holds until a later step line is valid, and is spoken."""
        if c.kind == "step" or c.bad_target is not None:
            self.bad_target = c.bad_target
        what = (
            "the CTX step line has no target= field" if self.bad_target == MISSING_TARGET
            else "the CTX target %r is not a number of RPM above 0" % (self.bad_target or "")[:40])
        self.level(
            "x-bad-context", "BAD CONTEXT", self.bad_target is not None,
            "%s: rule 9 and the held-fan clause of rule 2 are off until a valid CTX step line is "
            "written" % what)

    def on_pgrep(self, t, pids):
        self._bump(t)
        if pids is not None:
            self.last_pgrep = frozenset(pids)
        if pids is None or not self.armed:
            return
        if self.armed_pids is None:
            self.armed_pids = self.last_pgrep
            self.info("armed; helper PIDs %s" % sorted(self.armed_pids))
        else:
            self._guard(self.check_r7_restart, self.last_pgrep)

    def check_r7_restart(self, pids):
        """Rule 7: after CTX armed, the helper's PID changes or disappears."""
        if pids != self.armed_pids:
            self._r7_fire("helper PIDs %s -> %s" % (sorted(self.armed_pids), sorted(pids)))
            self.armed_pids = pids

    def on_pressure(self, t, level):
        self._bump(t)
        self.pressure = level
        if level is not None:
            self._guard(self.check_r6_pressure, level)

    def check_r6_pressure(self, level):
        self.level(
            "r6", "ABORT 6", level != 0,
            "com.apple.system.thermalpressurelevel reads %s, not 0" % level)

    def on_pmset(self, t, text):
        self._bump(t)
        if text is None:
            return
        if self.pmset_first is None:
            self.pmset_first = text
        elif text != self.pmset_first:
            self.pmset_first = text
            self.note("pmset -g therm changed: %s" % " | ".join(text.split("\n"))[:300])

    def on_source_stop(self, name, t):
        """A sampler's own `stop` line. It ends that source (rule 12 stops waiting for it) only in
        the teardown: after CTX end, with no hold active. A sampler that stops anywhere else (a
        `kill -INT` run early, a pattern `pkill`) has left the record blind, and rule 12 goes on
        saying so: ABORT 12 in a hold, BLIND — NO GO outside one. A source that has ended is
        watched again as soon as its sampler writes another sample (`on_fan`, `on_package`)."""
        self._bump(t)
        if self.ended and not self.hold_active:
            self.ended_sources.add(name)
            self.info(
                "%s file: its sampler wrote its stop line after CTX end; rule 12 no longer waits "
                "for it" % name)
            return
        where = "during a hold" if self.hold_active else "before CTX end"
        self.note(
            "%s file: its sampler wrote its stop line %s, so rule 12 does not stand down for it: "
            "a live watcher hears the gap as %s (a replay ends every file at its last sample and "
            "raises nothing for it)" % (
                name, where, "ABORT 12" if self.hold_active else "BLIND — NO GO"),
            "WARN")

    def on_logstream(self, t, alive):
        self._bump(t)
        self.logstream_alive = alive

    # ---------------------------------------------------------------- time-driven checks

    def advance(self, t):
        """Move the clock, and run what depends on it and on no new event."""
        self._bump(t)
        for aid, state in self.alerts.items():
            if state.kind == "event" and state.active and self.now >= state.latch_until:
                state.active = False
        guard = self._guard
        guard(self._judge_f0_modes)
        guard(self._judge_pending)
        guard(self._resolve_b)
        guard(self.check_r4_escalate)
        guard(self.check_r8_restore)
        guard(self.check_r11_time)
        guard(self.check_r12_blind)
        self._gate_guard(self.check_gate_t0)
        self._gate_guard(self.check_gate_rest)
        self._gate_guard(self.check_gate_engaged)
        self._gate_guard(self.check_gate_clock)
        guard(self._pump_speech)
        if self.next_status is not None and self.now >= self.next_status:
            self.next_status = self.now + STATUS_SECONDS
            guard(self._status)

    def check_r8_restore(self):
        """Rule 8: no verified restore 4 min after engage is a warning, 5 min is ABORT 8."""
        if self.engage_t is None:
            self.level("r8", "ABORT 8", False)
            return
        age = self.now - self.engage_t
        if age >= RESTORE_WARN_SECONDS and not self.r8_warned:
            self.r8_warned = True
            self.note("no verified restore %.0f s after engage; the lease ends at 5 min" % age, "WARN")
        self.level(
            "r8", "ABORT 8", age >= RESTORE_ABORT_SECONDS,
            "no verified restore %.0f s after engage (%s)" % (age, format_time(self.engage_t)))

    def check_r11_time(self):
        """Rule 11: F1Tg still 0 at 60 s after load-start step=1d."""
        r11 = self.r11
        if r11 is None:
            return
        elapsed = self.now - r11["t_L"]
        zero = self._f1_reads_zero()
        if zero and elapsed >= R11_WARN_SECONDS and not r11["warned"]:
            r11["warned"] = True
            self.note("F1Tg still reads 0 %.0f s after load-start step=1d" % elapsed, "WARN")
        self.level(
            "r11-time", "ABORT 11 TIME", zero and elapsed >= R11_TIME_SECONDS,
            "F1Tg still reads 0 %.0f s after load-start step=1d" % elapsed)

    def check_r12_blind(self):
        """Rule 12: the record has gone blind. During a hold it is an abort, otherwise a no-go. No
        CTX line stands it down: a source ends only with its own sampler's stop line, and that
        only after CTX end with no hold active (`on_source_stop`)."""
        if self.now is None:
            return
        title = "ABORT 12" if self.hold_active else "BLIND — NO GO"
        fan_ref = self.fan_last_t if self.fan_last_t is not None else self.t_start
        pkg_ref = self.pkg_last_t if self.pkg_last_t is not None else self.t_start
        fan_age, pkg_age = self.now - fan_ref, self.now - pkg_ref
        self.level(
            "r12-fans", title, "fans" not in self.ended_sources and fan_age > FAN_STALE_SECONDS,
            "no fan sample for %.1f s (the limit is %.0f s)" % (fan_age, FAN_STALE_SECONDS))
        self.level(
            "r12-package", title,
            "package" not in self.ended_sources and pkg_age > PACKAGE_STALE_SECONDS,
            "no package sample for %.1f s (the limit is %.0f s)" % (pkg_age, PACKAGE_STALE_SECONDS))
        self.level(
            "r12-logstream", title, self.logstream_alive is False,
            "the log stream's process is gone")

    # ---------------------------------------------------------------- derived gates (GATE lines)
    #
    # Advice, not rules. A gate states a fact the runbook needs (is the machine at rest, what was
    # T0, has 1b engaged, how long has the cool-down run) so that nobody works it out by hand. Its
    # line is written when its state changes, is neither an alert nor a note nor a warning, and is
    # never spoken. The newest `GATE <name>=` line is the gate's present state.

    def _gate_guard(self, check, *args):
        """Run one gate check. A gate is advice, so a bug in one is written to watch.log as an
        ERROR line, once per kind, and is not an alert: 'watcher error' said aloud in a hold would
        send the operator to reset for a note he was never meant to act on."""
        if not self.guard:
            check(*args)
            return
        try:
            check(*args)
        except Exception as error:  # noqa: BLE001  advice must not stop the rules after it
            key = ("gate", getattr(check, "__name__", "a gate"), type(error).__name__, str(error)[:200])
            count = self.error_counts[key] = self.error_counts.get(key, 0) + 1
            if count % 1000 == 1:  # the first occurrence, and every thousandth after it
                trace = " | ".join(traceback.format_exc().strip().splitlines()[-4:])
                self.out.line(
                    self._stamp(), "ERROR",
                    "gate check %s raised: %s (occurrence %d); the gate notes are advice and "
                    "nothing was said" % (key[1], trace, count))

    def gate(self, name, state, text):
        """One GATE line, if `state` is not what the gate's last line described."""
        if name in self.gate_keys and self.gate_keys[name] == state:
            return False
        self.gate_keys[name] = state
        self.out.line(self._stamp(), "GATE", text)
        return True

    @staticmethod
    def _run(since, holds, gap, t):
        """The start of a run of samples that satisfy a predicate, after the sample at `t`."""
        if not holds:
            return None
        return t if since is None or gap else since

    def check_gate_runs(self, s):
        """The newest unbroken stretch of fan samples that satisfy each gate's predicate. A sample
        that breaks it, or a gap in the record longer than 2 s, ends it: a stretch nobody
        recorded is not evidence of rest."""
        v = s.v
        gap = self.fan_prev is not None and s.t - self.fan_prev.t > GATE_MAX_GAP
        have = all(key in v for key in GATE_FAN_KEYS)
        quiet = have and v["Ftst"] == 0 and all(
            v["F%dMd" % n] in SAFE_MODES and not (v["F%dMd" % n] == 3 and v["F%dTg" % n] > 0)
            for n in (0, 1))
        rest = have and v["Ftst"] == 0 and all(
            v["F%dMd" % n] == 3 and v["F%dTg" % n] == 0 for n in (0, 1))
        engaged = "F0Tg" in v and v["F0Tg"] >= self.f0mn + GATE_ENGAGED_ABOVE_F0MN
        self.quiet_since = self._run(self.quiet_since, quiet, gap, s.t)
        self.rest_since = self._run(self.rest_since, rest, gap, s.t)
        self.engaged_since = self._run(self.engaged_since, engaged, gap, s.t)

    def check_gate_t0(self):
        """T0: the median of the hottest curated key over the newest complete quiescence window
        (D9: 120 s with Ftst 0, both modes in Apple's set, and no fan reading 3 with a target
        above 0). It follows that window until the first `CTX armed` or step line, and is frozen
        then: the baseline of the run is the one in force when the first write was prepared."""
        if self.t0_frozen or not self.t0_dirty:
            return
        since, end = self.quiet_since, self.fan_last_t
        if since is None or end is None or end - since < (
                GATE_QUIESCENCE_SECONDS - GATE_SPAN_TOLERANCE):
            return  # no complete window yet: T0 stays what it was
        if self.pkg_last_t is None or end - self.pkg_last_t >= GATE_PACKAGE_FRESH:
            return  # the package record has not caught up with the window
        self.t0_dirty = False
        start = max(since, end - GATE_QUIESCENCE_SECONDS)
        values = sorted(h for t, h in self.pkg_log if start <= t <= end)
        n = len(values)
        if n < GATE_T0_MIN_SAMPLES:
            self.gate(
                "t0", ("short", n), "t0=unavailable n=%d need=%d window=%s/%s" % (
                    n, GATE_T0_MIN_SAMPLES, format_time(start), format_time(end)))
            return
        mid = n // 2
        self.t0 = values[mid] if n % 2 else (values[mid - 1] + values[mid]) / 2.0
        self.t0_n, self.t0_window = n, (start, end)
        if self.t0_freeze_pending is not None:
            self._freeze_t0(self.t0_freeze_pending)
        else:
            self._report_t0()

    def _report_t0(self):
        start, end = self.t0_window
        state = "frozen" if self.t0_frozen else "provisional"
        # A provisional T0 follows the machine, so it is written once a minute; a frozen one once.
        key = (state, self.t0) if self.t0_frozen else (state, int(self.now // GATE_EVERY_SECONDS))
        self.gate(
            "t0", key, "t0=%.2f n=%d span=%.1fs ok=%s limit=%g state=%s%s window=%s/%s" % (
                self.t0, self.t0_n, end - start, "YES" if self.t0 < GATE_T0_LIMIT else "NO",
                GATE_T0_LIMIT, state,
                " by=%s" % self.t0_frozen_by.replace(" ", "_") if self.t0_frozen else "",
                format_time(start), format_time(end)))

    def _freeze_t0(self, why):
        """Freeze T0 at `why` (the first `CTX armed` or step line), now if there is one, else at
        the first complete window after it."""
        if self.t0_frozen:
            return
        if self.t0 is None:
            self.t0_freeze_pending = why
            self.gate(
                "t0-pending", why, "t0=unavailable freeze-at=%s" % why.replace(" ", "_"))
            return
        self.t0_frozen, self.t0_frozen_by, self.t0_freeze_pending = True, why, None
        self._report_t0()

    def check_gate_rest(self):
        """'At rest' (item 8): both fans raw 3 with a target of 0, and Ftst 0, for 60 s, and the
        hottest curated at most T0 + 3 C. It is an entry gate, so an open step is not at rest."""
        s = self.fan
        if s is None:
            return
        held = 0.0 if self.rest_since is None else self.fan_last_t - self.rest_since
        limit = None if self.t0 is None else self.t0 + GATE_REST_MARGIN
        if self.now - self.fan_last_t > FAN_STALE_SECONDS:
            why = "stale"
        elif self.step is not None or self.hold_active:
            why = "step-open"
        elif self.rest_since is None:
            why = "fans"
        elif held < GATE_REST_SECONDS - GATE_SPAN_TOLERANCE:
            why = "short"
        elif self.t0 is None:
            why = "t0"
        elif self.hottest is None or self.pkg_last_t is None or (
                self.fan_last_t - self.pkg_last_t >= GATE_PACKAGE_FRESH):
            why = "package"
        elif self.hottest > limit:
            why = "warm"
        else:
            why = None
        self.rest_yes = why is None
        facts = "held=%.1fs hottest=%s limit=%s t0=%s" % (
            held, "?" if self.hottest is None else "%.2f" % self.hottest,
            "?" if limit is None else "%.2f" % limit, "?" if self.t0 is None else "%.2f" % self.t0)
        if why is None:
            self.gate("at-rest", why, "at-rest=YES %s" % facts)
        else:
            self.gate("at-rest", why, "at-rest=NO why=%s %s %s" % (
                why, facts, " ".join("%s=%g" % (k, s.v[k]) for k in GATE_FAN_KEYS if k in s.v)))

    def check_gate_engaged(self):
        """1b's engaged condition (item 8): F0Tg at least F0Mn + 300 RPM (1,650 on this Mac) for
        30 s. Nothing is written until it first rises."""
        if self.fan is None:
            return
        threshold = self.f0mn + GATE_ENGAGED_ABOVE_F0MN
        held = 0.0 if self.engaged_since is None else self.fan_last_t - self.engaged_since
        if self.now - self.fan_last_t > FAN_STALE_SECONDS:
            state = "stale"
        elif self.engaged_since is None:
            state = "NO"
        else:
            state = "YES" if held >= GATE_ENGAGED_SECONDS else "rising"
        if state == "NO" and "engaged" not in self.gate_keys:
            return
        self.gate(
            "engaged", state, "engaged=%s held=%.1fs thr=%g F0Tg=%s F0Mn=%g" % (
                state, held, threshold, "%g" % self.fan.v["F0Tg"] if "F0Tg" in self.fan.v else "?",
                self.f0mn))

    def track_gate_ctx(self, c, closing):
        """The CTX lines the gates depend on. The at-rest clock starts at `armed` (the entry to
        1a) and at the end of each step but 1b's, whose load 1b' continues under (the cool-down
        after the others). T0 freezes at the first `armed` or step line."""
        if c.kind == "armed":
            self._freeze_t0("CTX armed")
            self._start_clock(c.t, "CTX armed")
        elif c.kind == "step":
            if c.step in (None, "none"):
                if closing is not None and closing != "1b":
                    self._start_clock(c.t, "CTX step=none after step %s" % closing)
            else:
                self._freeze_t0("CTX step=%s" % c.step)
                self._end_clock(c.step)

    def _start_clock(self, t, why):
        self.clock_start, self.clock_why, self.clock_state = t, why, "ticking"
        self.gate(
            "rest-clock", ("start", t), "rest-clock=START limit=%gs from=%s" % (
                GATE_CLOCK_SECONDS, why.replace(" ", "_")))

    def _end_clock(self, step):
        """A step opened: the entry was used, or skipped. A clock that was still ticking, or had
        expired, is written down as abandoned, because the step ran on a gate that never held."""
        if self.clock_state in ("ticking", "expired"):
            self.gate(
                "rest-clock", ("abandoned", self.clock_start),
                "rest-clock=ABANDONED elapsed=%.0fs was=%s step=%s" % (
                    self.now - self.clock_start, self.clock_state, step))
        self.clock_start, self.clock_why, self.clock_state = None, None, None

    def check_gate_clock(self):
        """The at-rest clock: 30 minutes from the end of a step (or `armed`) for the at-rest gate
        to hold. If it does not, the session writes nothing forward (item 8)."""
        if self.clock_state != "ticking":
            return
        elapsed = self.now - self.clock_start
        if self.rest_yes:
            self.clock_state = "met"
            self.gate(
                "rest-clock", ("met", self.clock_start),
                "rest-clock=MET elapsed=%.0fs limit=%gs" % (elapsed, GATE_CLOCK_SECONDS))
        elif elapsed >= GATE_CLOCK_SECONDS:
            self.clock_state = "expired"
            self.gate(
                "rest-clock", ("expired", self.clock_start),
                "rest-clock=EXPIRED elapsed=%.0fs limit=%gs action=no-forward-writes" % (
                    elapsed, GATE_CLOCK_SECONDS))
        elif elapsed >= GATE_EVERY_SECONDS:  # the START line covers the first minute
            self.gate(
                "rest-clock", ("ticking", self.clock_start, int(elapsed // GATE_EVERY_SECONDS)),
                "rest-clock=TICKING elapsed=%.0fs left=%.0fs at-rest=NO why=%s" % (
                    elapsed, GATE_CLOCK_SECONDS - elapsed, self.gate_keys.get("at-rest")))

    # ---------------------------------------------------------------- shared tracking

    @staticmethod
    def _trim(history, t, key=None, span=HISTORY_SECONDS):
        key = key or (lambda item: item.t)
        while history and t - key(history[0]) > span:
            history.popleft()

    def _f1_reads_zero(self):
        return self.fan is not None and self.fan.v.get("F1Tg") == 0

    def _track_r11_release(self, s):
        """When F1Tg first leaves 0 the check disarms, having logged how long it took."""
        if self.r11 is not None and (s.v.get("F1Tg") or 0) > 0:
            self.info("F1Tg left 0 at %.1f s after load-start step=1d (F1Tg %g), hottest curated %s C" % (
                s.t - self.r11["t_L"], s.v["F1Tg"],
                "%.1f" % self.hottest if self.hottest is not None else "?"))
            self.r11 = None
            self.level("r11-time", "ABORT 11 TIME", False)
            self.level("r11-temperature", "ABORT 11 TEMPERATURE", False)

    def _track_restore(self):
        """A verified restore is a `Wrote F0Md = 0x0` followed by 10 s of clean samples."""
        if self.engage_t is None or self.restore_t is None:
            return
        for s in self.fan_hist:
            if s.t < self.restore_t:
                continue
            v = s.v
            clean = v.get("Ftst") == 0 and all(v.get("F%dMd" % n) in SAFE_MODES for n in (0, 1))
            if not clean:
                self.clean_since = None
            elif self.clean_since is None:
                self.clean_since = s.t
            if self.clean_since is not None and s.t - self.clean_since >= RESTORE_VERIFY_SECONDS:
                self.info("restore verified: %.0f s after engage" % (s.t - self.engage_t))
                self.engage_t = self.restore_t = self.clean_since = None
                return

    def _resolve_b(self):
        """B is the mean of the hottest over the 10 s before a GO line. It waits for the package
        samples stamped before the line to have been read: until one stamped at or after the line
        has arrived, or 2 s have passed."""
        if self.b_due is None:
            return
        caught_up = self.pkg_last_t is not None and self.pkg_last_t >= self.b_due
        if not caught_up and self.now < self.b_due + 2.0:
            return
        due, self.b_due = self.b_due, None
        window = [h for ts, h in self.pkg_hist if due - B_WINDOW <= ts < due]
        if window:
            self.b = sum(window) / len(window)
            self.info("B = %.2f C, the mean of %d package samples in the 10 s before %s" % (
                self.b, len(window), format_time(due)))
        else:
            self.b = None
            self.note("B is unavailable: no package sample in the 10 s before %s" % format_time(due), "WARN")

    def _judge_pending(self):
        ready = [p for p in self.pending if p[0] <= self.now]
        if not ready:
            return
        self.pending = [p for p in self.pending if p[0] > self.now]
        for _, kind, t, key, old, new in ready:
            lo, hi = t - EXPLAIN_BEFORE, t + EXPLAIN_AFTER
            if not self._wrote(key, lo, hi):
                self.event(
                    "r3-" + kind, "ABORT 3",
                    "%s went %s -> %s at %s with no `Wrote %s` in [-2 s, +0.5 s]" % (
                        key, "%g" % old, "%g" % new, format_time(t), key))

    # ---------------------------------------------------------------- speech and status

    def _pump_speech(self):
        if not self.speak:
            return
        for state in self.alerts.values():
            if state.active and self.now >= state.next_speak:
                state.next_speak = self.now + REPEAT_SECONDS
                self.say_queue.append(_voice(state.title))

    def _status(self):
        self.out.line(self.now, "STATUS", self.status_text())

    def status_text(self):
        f = self.fan.v if self.fan is not None else {}

        def show(key):
            return "%s=%s" % (key, "?" if key not in f else "%g" % f[key])

        thresholds = ["T>%g" % TEMP_ABSOLUTE]
        if self.load_window:
            thresholds.append("T>%g(load)" % TEMP_LOADED)
        elif self.step is not None and self.b is not None:
            thresholds.append("T>%.1f(B+10)" % (self.b + TEMP_RISE))
        if self.hold_active and self.target is not None:
            thresholds.append("F1Tg>%.0f(r9)" % (F1_FOLLOW_FRACTION * self.target))
        if self.r11 is not None:
            thresholds.append("r11(%.0f/%.0fs)" % (self.now - self.r11["t_L"], R11_TIME_SECONDS))
        engaged = "-" if self.engage_t is None else "%.0fs" % (self.now - self.engage_t)
        load = "-" if self.t_L is None or not self.load_active else "%.0fs" % (self.now - self.t_L)
        return "step=%s hold=%s %s hottest=%s thr[%s] since_engage=%s since_tL=%s pressure=%s alerts=[%s]%s" % (
            self.step or "none", "ACTIVE" if self.hold_active else "no",
            " ".join(show(k) for k in ("F0Md", "F1Md", "Ftst", "F0Tg", "F1Tg", "F0Ac", "F1Ac")),
            "?" if self.hottest is None else "%.1f" % self.hottest, " ".join(thresholds),
            engaged, load, "?" if self.pressure is None else self.pressure,
            ",".join(self.active_alerts()), " MUTED" if self.muted else "")


# --------------------------------------------------------------------------------------------
# Inputs: reading files, replaying them, tailing them.
# --------------------------------------------------------------------------------------------

PRIORITY = {
    "ctx": 0, "log": 1, "fan": 2, "fan_stop": 2, "package": 3, "package_stop": 3, "poll": 4}
STOP_KINDS = {"fans": "fan_stop", "package": "package_stop"}


def read_lines(path):
    """Every complete line of a file, read-only. A missing file has none."""
    if not path:
        return []
    try:
        with open(path, "rb") as handle:
            return handle.read().split(b"\n")
    except OSError:
        return []


def load_events(paths, replay_polls=None):
    """Every event of the given files as (time, priority, sequence, kind, payload)."""
    events, seq = [], 0

    def add(t, kind, payload):
        nonlocal seq
        seq += 1
        events.append((t, PRIORITY[kind], seq, kind, payload))

    for source, parse in (("fans", parse_fan_line), ("package", parse_package_line)):
        last = None  # a stop line has no stamp of its own: it is dated by the sample before it
        for raw in read_lines(paths.get(source)):
            sample = parse(raw)
            if sample is not None:
                last = sample.t
                add(sample.t, "fan" if source == "fans" else "package", sample)
            elif last is not None and is_stop_line(raw):
                add(last, STOP_KINDS[source], last)
    for raw in read_lines(paths.get("helper_log")):
        line = parse_log_line(raw)
        if line is not None:
            add(line.t, "log", line)
    for raw in read_lines(paths.get("phases")):
        ctx = parse_ctx_line(raw)
        if ctx is not None and ctx.t is not None:
            add(ctx.t, "ctx", ctx)
    for raw in read_lines(replay_polls):
        record = _record(raw)
        if record is not None and isinstance(record.get("t"), (int, float)):
            add(float(record["t"]), "poll", record)
    events.sort(key=lambda e: e[:3])
    return events


def dispatch(watcher, kind, payload):
    if kind == "fan":
        watcher.on_fan(payload)
    elif kind == "package":
        watcher.on_package(payload)
    elif kind == "fan_stop":
        watcher.on_source_stop("fans", payload)
    elif kind == "package_stop":
        watcher.on_source_stop("package", payload)
    elif kind == "log":
        watcher.on_log(payload)
    elif kind == "ctx":
        watcher.on_ctx(payload)
    elif kind == "poll":
        t, what = float(payload["t"]), payload.get("kind")
        if what == "pgrep":
            watcher.on_pgrep(t, frozenset(int(p) for p in payload.get("pids", [])))
        elif what == "pressure":
            watcher.on_pressure(t, payload.get("level"))
        elif what == "pmset":
            watcher.on_pmset(t, payload.get("text"))
        elif what == "logstream":
            watcher.on_logstream(t, bool(payload.get("alive")))


def _unguarded(watcher, function, *args):
    function(*args)


def guarded(watcher, function, *args):
    try:
        function(*args)
    except Exception as error:  # noqa: BLE001  a bug in a rule must be heard, not fatal
        watcher.internal_error(error)


def run_events(watcher, events, step=LOOP_SECONDS, mark_ended=False, guard=False):
    """Feed events in time order, ticking the clock between them as the live loop would. A
    replay lets a bug raise; the live loop's catch-up (`guard`) hears it and goes on."""
    call = guarded if guard else _unguarded
    if events:
        watcher.start(events[0][0])
    last_end = {}
    for name in ("fan", "package"):
        times = [e[0] for e in events if e[3] == name]
        if times:
            last_end[name] = times[-1]
    ended = {"fan": "fans", "package": "package"}
    for t, _, _, kind, payload in events:
        while watcher.now is not None and watcher.now + step < t:
            call(watcher, watcher.advance, watcher.now + (step if t - watcher.now < 120 else 5.0))
        call(watcher, dispatch, watcher, kind, payload)
        call(watcher, watcher.advance, t)
        if mark_ended:
            for name, when in last_end.items():
                if t >= when:
                    watcher.source_ended(ended[name])
    if events:
        call(watcher, watcher.advance, watcher.now)
    return watcher


class Tail:
    """Follows an append-only file from its start, whole lines only."""

    def __init__(self, path):
        self.path, self.handle, self.inode, self.pending = path, None, None, b""

    CHUNK = 8 << 20

    def read_new(self, limit=CHUNK):
        """The complete lines appended since the last call; `limit` caps the bytes, None reads
        to the end."""
        try:
            status = os.stat(self.path)
        except OSError:
            return []
        if self.handle is not None and (
                status.st_ino != self.inode or status.st_size < self.handle.tell()):
            self.handle.close()
            self.handle, self.pending = None, b""
        if self.handle is None:
            try:
                self.handle = open(self.path, "rb")
            except OSError:
                return []
            self.inode = os.fstat(self.handle.fileno()).st_ino
        data = self.pending + self.handle.read(limit)
        *lines, self.pending = data.split(b"\n")
        return lines

    def close(self):
        if self.handle is not None:
            self.handle.close()
            self.handle = None


class Speaker:
    """say and afplay, started without waiting, one batch at a time."""

    def __init__(self, spawn=_spawn):
        self.spawn, self.children = spawn, []

    def busy(self):
        self.children = [c for c in self.children if c.poll() is None]
        return bool(self.children)

    def speak(self, phrases):
        if not phrases or self.busy():
            return False
        unique = list(dict.fromkeys(phrases))
        try:
            self.children.append(self.spawn((AFPLAY, ALERT_SOUND)))
            self.children.append(self.spawn((SAY, ". ".join(unique))))
        except (OSError, PermissionError):
            return False
        return True


def _poll(name, spawn=_spawn):
    try:
        result = spawn(COMMANDS[name], capture=True, timeout=2.0)
    except (OSError, subprocess.SubprocessError):
        return None, None
    return result.returncode, result.stdout.decode("utf-8", "replace")


def poll_pgrep(spawn=_spawn):
    code, text = _poll("pgrep", spawn)
    if code == 0:
        return frozenset(int(x) for x in text.split() if x.isdigit())
    return frozenset() if code == 1 else None


def poll_pressure(spawn=_spawn):
    code, text = _poll("notifyutil", spawn)
    fields = text.split() if code == 0 and text else []
    return int(fields[-1]) if fields and re.match(r"^-?\d+$", fields[-1]) else None


def poll_pmset(spawn=_spawn):
    code, text = _poll("pmset", spawn)
    return text.strip() if code == 0 and text else None


def logstream_alive(pid_path):
    """Whether the process in logstream.pid exists. getpgid signals nothing."""
    try:
        with open(pid_path, "r", encoding="utf-8") as handle:
            pid = int(handle.read().split()[0])
        os.getpgid(pid)
        return True
    except (ProcessLookupError, ValueError, IndexError, OSError):
        return False


def input_paths(args):
    d = args.dir
    return {
        "fans": args.fans or os.path.join(d, "fans-10hz.ndjson"),
        "package": args.package or os.path.join(d, "package-1hz.ndjson"),
        "helper_log": args.helper_log or os.path.join(d, "helper-log.ndjson"),
        "phases": args.phases or os.path.join(d, "phases.log"),
        "logstream_pid": args.logstream_pid or os.path.join(d, "logstream.pid"),
    }


def check_start_records(paths, watcher):
    for name in ("fans", "package"):
        for raw in read_lines(paths[name])[:3]:
            record = _record(raw)
            if record is not None and record.get("kind") == "start":
                model = record.get("hwModel")
                watcher.info("%s file: hwModel=%s interval=%ss keys=%d" % (
                    name, model, record.get("intervalSeconds"), len(record.get("keys", []))))
                if model != "Mac16,5":
                    watcher.note("hwModel is %s, not Mac16,5: every threshold here is Mac16,5's" % model, "WARN")
                break


def run_replay(args):
    paths = input_paths(args)
    out = Output(args.out)
    watcher = Watcher(out)
    events = load_events(paths, args.replay_polls)
    if events:
        watcher.start(events[0][0])
    watcher.info("replay: %d events from %s" % (len(events), os.path.abspath(args.dir)))
    check_start_records(paths, watcher)
    run_events(watcher, events, mark_ended=True)
    out.heartbeat(time.time())
    watcher.info("replay finished at %s: %d alerts, %d warnings, %d notes" % (
        format_time(watcher.now or 0), len(watcher.raised), watcher.counts["WARN"], watcher.counts["NOTE"]))
    out.close()
    span = (events[-1][0] - events[0][0]) if events else 0.0
    print("replay: %d events, %.0f s of capture time, %d alerts, %d warnings, %d notes" % (
        len(events), span, len(watcher.raised), watcher.counts["WARN"], watcher.counts["NOTE"]))
    return watcher


def run_live(args, spawn=_spawn, stop=None, wall=time.time, sleep=time.sleep):
    paths = input_paths(args)
    out = Output(args.out)
    watcher = Watcher(out, guard=True)
    watcher.muted = args.mute
    speaker = None if args.mute else Speaker(spawn)
    tails = {k: Tail(paths[k]) for k in ("fans", "package", "helper_log", "phases")}
    parsers = {
        "fans": ("fan", parse_fan_line), "package": ("package", parse_package_line),
        "helper_log": ("log", parse_log_line), "phases": ("ctx", parse_ctx_line)}
    watcher.info("watcher started, pid %d, python %s%s" % (
        os.getpid(), sys.version.split()[0], ", MUTED: nothing will be said" if args.mute else ""))
    for k, v in sorted(paths.items()):
        watcher.info("%s: %s" % (k, v))
    check_start_records(paths, watcher)
    stopping = stop if stop is not None else {"flag": False}
    if stop is None:
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: stopping.update(flag=True))

    last_sample = {}  # per sampler's file, the stamp of its latest sample: a stop line's date

    def read_events(now, limit=Tail.CHUNK):
        events, seq = [], 0
        for name, tail in tails.items():
            kind, parse = parsers[name]
            for raw in tail.read_new(limit):
                parsed = parse(raw, now) if kind == "ctx" else parse(raw)
                if parsed is None and name in STOP_KINDS:
                    if name in last_sample and is_stop_line(raw):
                        seq += 1
                        stop = last_sample[name]
                        events.append((stop, PRIORITY[STOP_KINDS[name]], seq, STOP_KINDS[name], stop))
                    continue
                if parsed is None or (kind == "ctx" and parsed.t is None):
                    continue
                if name in STOP_KINDS:
                    last_sample[name] = parsed.t
                seq += 1
                events.append((parsed.t, PRIORITY[kind], seq, kind, parsed))
        events.sort(key=lambda e: e[:3])
        return events

    history = read_events(wall(), limit=None)  # to the end of each file, not one chunk of it
    watcher.info("catching up on %d events already in the files" % len(history))
    run_events(watcher, history, step=0.5, guard=True)
    watcher.go_live(wall())
    watcher.info("live")
    next_poll = {"pgrep": 0.0, "pressure": 0.0, "pmset": 0.0, "beat": 0.0}
    try:
        while not stopping["flag"]:
            now = wall()
            for t, _, _, kind, payload in read_events(now):
                guarded(watcher, dispatch, watcher, kind, payload)
            guarded(watcher, watcher.advance, now)
            if now >= next_poll["pgrep"]:
                next_poll["pgrep"] = now + 1.0
                guarded(watcher, watcher.on_pgrep, now, poll_pgrep(spawn))
                guarded(watcher, watcher.on_logstream, now, logstream_alive(paths["logstream_pid"]))
            if now >= next_poll["pressure"]:
                next_poll["pressure"] = now + 1.0
                guarded(watcher, watcher.on_pressure, now, poll_pressure(spawn))
            if now >= next_poll["pmset"]:
                next_poll["pmset"] = now + 5.0
                guarded(watcher, watcher.on_pmset, now, poll_pmset(spawn))
            if now >= next_poll["beat"]:
                next_poll["beat"] = now + 1.0
                out.heartbeat(now)
            phrases = watcher.take_speech()
            if speaker is not None and phrases and not speaker.speak(phrases):
                watcher.say_queue = phrases + watcher.say_queue
            sleep(LOOP_SECONDS)
    finally:
        watcher.info("watcher stopped")
        for tail in tails.values():
            tail.close()
        out.close()
    return watcher


def main(argv=None):
    p = argparse.ArgumentParser(description="The run-1 watcher: read-only, alerts aloud.")
    p.add_argument("--dir", required=True, help="the capture directory (inputs, and outputs when live)")
    p.add_argument("--out", help="where watch.log, watch.hb and ALERT go (live: --dir)")
    p.add_argument("--fans", help="fan file (default DIR/fans-10hz.ndjson)")
    p.add_argument("--package", help="package file (default DIR/package-1hz.ndjson)")
    p.add_argument("--helper-log", help="log-stream file (default DIR/helper-log.ndjson)")
    p.add_argument("--phases", help="CTX file (default DIR/phases.log)")
    p.add_argument("--logstream-pid", help="log-stream pid file (default DIR/logstream.pid)")
    p.add_argument("--replay", action="store_true", help="read the files once, clocked by their own stamps, silently")
    p.add_argument("--replay-polls", help="replay only: ndjson standing in for pgrep, notifyutil, pmset")
    p.add_argument("--mute", action="store_true", help="live, for rehearsal only: log, never say")
    args = p.parse_args(argv)
    if args.replay:
        if not args.out:
            p.error("--replay needs --out: it never writes into the capture directory")
        if os.path.realpath(args.out) == os.path.realpath(args.dir):
            p.error("--out must not be the capture directory in a replay")
        os.makedirs(args.out, exist_ok=True)
        run_replay(args)
        return 0
    if args.replay_polls:
        p.error("--replay-polls is for --replay only")
    args.out = args.out or args.dir
    run_live(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
