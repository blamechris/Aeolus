"""Synthetic captures in P1's record shapes, for the unit tests and the dry run.

Nothing here is a real capture or a real log line. The records have the keys and the types of
P1's, so the watcher's parsers are exercised on the real shapes; their values are made up, and
the start line carries a made-up host name.

A `Run` holds fan samples and package samples as parsed records. It is built either from nothing
(`Run.idle`) or from a window of lines taken from another capture (`Run.from_lines`, which the
dry run uses on P1). Either way it is then patched: a value changed for a span, a span of
samples dropped, a log line, a CTX line or a poll added. `write` serialises it as the files the
watcher reads.
"""

from __future__ import annotations

import calendar
import copy
import json
import os
import time

T0 = 1_761_870_000.0  # an arbitrary UTC instant; every synthetic run starts here

FAN_KEYS = ("F0Md", "F1Md", "Ftst", "F0Tg", "F1Tg", "F0Ac", "F1Ac")
PACKAGE_KEYS = tuple(
    prefix + suffix for prefix in ("TPD", "TRD") for suffix in "0123456789abcdefX")
FAN_DEFAULTS = {"F0Md": 3, "F1Md": 3, "Ftst": 0, "F0Tg": 0, "F1Tg": 0, "F0Ac": 0, "F1Ac": 0}
HOST = "fixture-host.local"


def iso(t):
    """The `wallClockUTC` text of an instant, as P1's recorders wrote it."""
    whole = int(t)
    millis = int(round((t - whole) * 1000))
    if millis == 1000:
        whole, millis = whole + 1, 0
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole)) + ".%03dZ" % millis


def parse_stamp(text):
    """The inverse of `iso`, written apart from the watcher's own parser on purpose."""
    whole, _, millis = text[:-1].partition(".")
    fields = time.strptime(whole, "%Y-%m-%dT%H:%M:%S")
    return calendar.timegm(fields) + (int(millis) / 1000.0 if millis else 0.0)


def _line(record):
    return json.dumps(record, sort_keys=True, separators=(",", ":"))


def _reading(key, value, kind="unknown"):
    return {"failureReason": None, "key": key, "kind": kind, "status": "ok", "value": value}


def start_record(keys, interval):
    return {
        "fanEnumerationFailed": False, "hostname": HOST, "hwModel": "Mac16,5",
        "intervalSeconds": interval, "keySource": "custom", "keys": list(keys), "kind": "start",
        "osVersion": "Version 27.2 (Build 26B123)", "pid": 1000, "uid": 501}


def fan_record(t, tick, values=None):
    merged = dict(FAN_DEFAULTS, **(values or {}))
    readings = [
        _reading(k, merged[k], "rpm" if k.endswith(("Tg", "Ac")) else "unknown")
        for k in FAN_KEYS]
    return {
        "continuousDeltaNanoseconds": None if tick == 0 else 100000000,
        "continuousNanoseconds": int(tick * 1e8), "kind": "sample", "readings": readings,
        "suspendingDeltaNanoseconds": None if tick == 0 else 100000000,
        "suspendingNanoseconds": int(tick * 1e8), "tick": tick, "wallClockUTC": iso(t)}


def package_record(t, tick, hottest=42.0, extra=None):
    readings = [_reading(k, hottest - 1.0 - (i % 3) * 0.1) for i, k in enumerate(PACKAGE_KEYS)]
    readings[0] = _reading(PACKAGE_KEYS[0], hottest)
    for key, value in (extra or {}).items():
        readings.append(_reading(key, value, "rpm"))
    return {
        "continuousDeltaNanoseconds": None if tick == 0 else 1000000000,
        "continuousNanoseconds": int(tick * 1e9), "kind": "sample", "readings": readings,
        "suspendingDeltaNanoseconds": None if tick == 0 else 1000000000,
        "suspendingNanoseconds": int(tick * 1e9), "tick": tick, "wallClockUTC": iso(t)}


def stop_record(t, ticks):
    return {"kind": "stop", "ticks": ticks, "wallClockUTC": iso(t)}


def log_timestamp(t):
    """`log stream --style ndjson`'s timestamp: local time with a UTC offset (here -0700)."""
    whole = int(t)
    micros = int(round((t - whole) * 1e6))
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(whole - 7 * 3600))
    return "%s.%06d-0700" % (stamp, micros)


def log_record(t, message, message_type="Default", pid=4242, image="/synthetic/AeolusHelper"):
    return {
        "category": "Safety", "eventMessage": message, "messageType": message_type,
        "processID": pid, "processImagePath": image, "subsystem": "dev.aeolus.AeolusHelper",
        "timestamp": log_timestamp(t)}


def wrote(key, data, answer="0x00", seconds="5.3083e-05"):
    """The text of the helper's `Wrote` line (`SafetyLog.planeWrote`)."""
    return "Wrote %s = %s: answered %s, in %s seconds." % (key, data, answer, seconds)


def ctx_line(t, body):
    return "%.3f CTX %s" % (t, body)


class Run:
    def __init__(self, fans, packages, t0):
        self.fans, self.packages, self.t0 = fans, packages, t0
        self.log, self.ctx, self.polls = [], [], []

    # ------------------------------------------------------------------ construction

    @classmethod
    def idle(cls, seconds=60.0, hottest=42.0, fan_dt=0.1, package_dt=1.0, t0=T0, f0mn=None):
        n_fan = int(round(seconds / fan_dt))
        fans = [fan_record(t0 + i * fan_dt, i) for i in range(n_fan)]
        extra = {"F0Mn": f0mn} if f0mn is not None else None
        n_pkg = int(round(seconds / package_dt))
        packages = [package_record(t0 + i * package_dt, i, hottest, extra) for i in range(n_pkg)]
        return cls(fans, packages, t0)

    @classmethod
    def from_lines(cls, fan_lines, package_lines, start, end):
        """The records of two captures whose stamps fall in [start, end), copied, for patching."""
        def window(lines):
            kept = []
            for raw in lines:
                if not raw.startswith('{"'):
                    continue
                record = json.loads(raw)
                if record.get("kind") != "sample":
                    continue
                if start <= parse_stamp(record["wallClockUTC"]) < end:
                    kept.append(record)
            return kept

        return cls(window(fan_lines), window(package_lines), start)

    def copy(self):
        clone = Run(copy.deepcopy(self.fans), copy.deepcopy(self.packages), self.t0)
        clone.log, clone.ctx, clone.polls = list(self.log), list(self.ctx), list(self.polls)
        return clone

    # ------------------------------------------------------------------ patches (seconds from t0)

    def at(self, seconds):
        return self.t0 + seconds

    @staticmethod
    def _stamp(record):
        return parse_stamp(record["wallClockUTC"])

    def patch_fan(self, start, end, **fields):
        """Set fan keys on every sample in [start, end) seconds from t0. A value may be a
        function of the sample's time in seconds from t0."""
        for record in self.fans:
            rel = self._stamp(record) - self.t0
            if start <= rel < end:
                for reading in record["readings"]:
                    if reading["key"] in fields:
                        value = fields[reading["key"]]
                        reading["value"] = value(rel) if callable(value) else value
        return self

    def scale_fan(self, start, end, key, factor):
        """Multiply a fan key by `factor` over [start, end): halving F0Ac, say."""
        for record in self.fans:
            rel = self._stamp(record) - self.t0
            if start <= rel < end:
                for reading in record["readings"]:
                    if reading["key"] == key:
                        reading["value"] = reading["value"] * factor
        return self

    def patch_hottest(self, start, end, value):
        """Make the hottest curated key read `value` on the package samples in [start, end)."""
        for record in self.packages:
            rel = self._stamp(record) - self.t0
            if start <= rel < end:
                readings = record["readings"]
                readings[0]["value"] = value
                for i, reading in enumerate(readings[1:], 1):
                    if reading["key"] in PACKAGE_KEYS:
                        reading["value"] = min(reading["value"], value - 1.0 - (i % 3) * 0.1)
        return self

    def drop(self, start, end, which="fans"):
        records = self.fans if which == "fans" else self.packages
        kept = [r for r in records if not start <= self._stamp(r) - self.t0 < end]
        if which == "fans":
            self.fans = kept
        else:
            self.packages = kept
        return self

    def add_log(self, seconds, message, message_type="Default", **kwargs):
        self.log.append(log_record(self.t0 + seconds, message, message_type, **kwargs))
        return self

    def add_ctx(self, seconds, body):
        self.ctx.append(ctx_line(self.t0 + seconds, body))
        return self

    def add_poll(self, seconds, kind, **fields):
        self.polls.append(dict(fields, t=self.t0 + seconds, kind=kind))
        return self

    def hold(self, go, restore, target, step="1a", sit=None):
        """A well-formed hold: the CTX line, the unlock, the engage, the floor target, the fan
        spinning up over 4 s and holding, then the restore. `restore` is when the restore turn's
        first write is stamped; the samples return to Apple's set 0.2 s later."""
        self.add_ctx(go - 0.05, "step=%s target=%d GO" % (step, target))
        self.add_log(go, wrote("Ftst", "0x1"))
        self.add_log(go + 0.03, wrote("F0Md", "0x1"))
        self.add_log(go + 0.06, wrote("F0Tg", "0x0 0x0 0x80 0x3f"))
        spin = 4.0

        def tg(rel):
            return float(target)

        def ac(rel):
            return float(target) * min(1.0, max(0.0, (rel - go) / spin))

        self.patch_fan(go + 0.1, restore + 0.2, Ftst=1, F0Md=1, F0Tg=tg, F0Ac=ac)
        self.add_log(restore, wrote("F0Md", "0x0"))
        self.add_log(restore + 0.03, wrote("Ftst", "0x0"))
        self.add_ctx(restore + (sit if sit is not None else 12.0), "step=none")
        return self

    # ------------------------------------------------------------------ serialisation

    def fan_lines(self):
        return [_line(start_record(FAN_KEYS, 0.1))] + [_line(r) for r in self.fans]

    def package_lines(self):
        return [_line(start_record(PACKAGE_KEYS, 1))] + [_line(r) for r in self.packages]

    def log_lines(self):
        ordered = sorted(self.log, key=lambda r: r["timestamp"])
        return ["Filtering the log data using \"subsystem == ...\""] + [_line(r) for r in ordered]

    def phases_lines(self):
        return list(self.ctx)

    def polls_lines(self):
        return [_line(p) for p in sorted(self.polls, key=lambda p: p["t"])]

    def write(self, directory, names=None):
        """Write the files; returns the paths by the names run_watch's arguments use."""
        names = dict(
            {"fans": "fans-10hz.ndjson", "package": "package-1hz.ndjson",
             "helper_log": "helper-log.ndjson", "phases": "phases.log", "polls": "polls.ndjson"},
            **(names or {}))
        os.makedirs(directory, exist_ok=True)
        contents = {
            "fans": self.fan_lines(), "package": self.package_lines(),
            "helper_log": self.log_lines(), "phases": self.phases_lines(),
            "polls": self.polls_lines()}
        paths = {}
        for key, lines in contents.items():
            paths[key] = os.path.join(directory, names[key])
            with open(paths[key], "w", encoding="utf-8") as handle:
                handle.write("".join(line + "\n" for line in lines))
        return paths
