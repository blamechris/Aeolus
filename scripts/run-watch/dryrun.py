#!/usr/bin/env python3
"""The watcher's dry run: D1 to D4 of the run-1 gap rulings (section 3), re-runnable.

    python3 -I dryrun.py <P1 capture dir> [--work DIR] [--mutations DIR] [d1 d2 d3 d4 unit]

D1  P1 replayed as captured raises no alert.
D2  P1 plus synthetic CTX lines: no ABORT 11 (F1Tg leaves 0 and the check disarms), no ABORT 9
    at 1b's GO. A synthetic accepted engage is added so rule 9 is live, and the target is moved
    to show the same replay fires when it should. D2e replays 1d in the runbook's order (GO at
    rest, then the load, then load-stop while the hold is open): no alert, 74.1 C after the stop
    still raises ABORT 1, and a watcher whose window ends at load-stop goes red.
D3  Each injection (one violation in a copy of a P1 window, plus synthetic log lines) raises its
    own alert within its latency and no other.
D4  Each injection against a copy of the watcher with that rule's check removed stays silent;
    each mutated copy is shown to run by a control injection that it still fires on.
unit  The same mutated copies against the unit tests: every one must go red.

P1's captures are read, never copied into the repository and never written to. Everything this
script writes goes under --work and --mutations, which must be outside the working tree. It runs
the watcher as a subprocess, `python3 -I run_watch.py --replay`, as an operator would."""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import mutate  # noqa: E402
import run_watch as rw  # noqa: E402  (its pure parsers only; the watcher under test is a subprocess)
import synth  # noqa: E402
from synth import wrote  # noqa: E402

SAMPLE = 0.13  # P1's fan sample spacing is about 0.11 s
LANDED = (
    "The engagement of fan 0 was refused after 2 attempt(s): the plane refused. "
    "It was registered with § 3 and handed back, and the restore landed.")
NOTHING = (
    "The engagement of fan 0 was refused after 1 attempt(s): the entitlement. "
    "Nothing was written.")
HANDBACK = (
    "The engagement of fan 0 was refused after 3 attempt(s): the plane refused. "
    "Its hand-back was refused, so the fan may still be off automatic control.")
COULD_NOT = "Could not undo the engagement of fan 0: refused. The fan may still be off automatic control."
PREP = "The write path's preparation step enumerated 2 fan(s) [0, 1], found the force key"
V = "ABORT 4 — VERIFY"
R = "ABORT 4 — RESET"
BLIND = "BLIND — NO GO"
QUOTED = (
    "The engagement of fan 0 was refused after 3 attempt(s): the plane said the restore landed. "
    "Its hand-back was refused, so the fan may still be off automatic control.")


# ---------------------------------------------------------------------------------------------
# Running the watcher and reading what it wrote
# ---------------------------------------------------------------------------------------------


def run_watcher(watcher, directory, out, fans=None, package=None, helper_log=None, phases=None,
                polls=None):
    argv = [sys.executable, "-I", watcher, "--replay", "--dir", directory, "--out", out]
    for flag, value in (("--fans", fans), ("--package", package), ("--helper-log", helper_log),
                        ("--phases", phases), ("--replay-polls", polls)):
        if value:
            argv += [flag, value]
    started = time.time()
    result = subprocess.run(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=600, check=False)
    if result.returncode != 0:
        raise RuntimeError("watcher failed: %s\n%s" % (
            result.returncode, result.stderr.decode("utf-8", "replace")[-800:]))
    log = []
    with open(os.path.join(out, "watch.log"), encoding="utf-8") as handle:
        for line in handle:
            stamp, level, text = line.rstrip("\n").split(" ", 2)
            log.append((rw.parse_iso_utc(stamp), level, text))
    return {"log": log, "seconds": time.time() - started,
            "summary": result.stdout.decode("utf-8", "replace").strip()}


def alerts_of(result):
    found = []
    for t, level, text in result["log"]:
        if level == "ALERT":
            title, _, detail = text.partition(": ")
            found.append((t, title, detail))
    return found


def lines_of(result, level, contains=""):
    return [text for _, lvl, text in result["log"] if lvl == level and contains in text]


# ---------------------------------------------------------------------------------------------
# P1
# ---------------------------------------------------------------------------------------------


class P1:
    def __init__(self, directory):
        self.dir = directory

        def one(pattern):
            found = sorted(glob.glob(os.path.join(directory, pattern)))
            if len(found) != 1:
                raise SystemExit("expected one %s in %s, found %d" % (pattern, directory, len(found)))
            return found[0]

        self.fans = one("capture-fans-10hz-*.ndjson")
        self.package = one("capture-package-1hz-*.ndjson")
        self.phases = one("phases-*.log")
        self._lines = {}

    def lines(self, which):
        if which not in self._lines:
            with open(getattr(self, which), "rb") as handle:
                self._lines[which] = handle.read().decode("utf-8").split("\n")
        return self._lines[which]

    def window(self, start_iso, seconds):
        start = rw.parse_iso_utc(start_iso)
        run = synth.Run.from_lines(self.lines("fans"), self.lines("package"), start, start + seconds)
        return run

    def fan_stats(self, start_iso, end_iso):
        lo, hi = rw.parse_iso_utc(start_iso), rw.parse_iso_utc(end_iso)
        samples = [s for s in map(rw.parse_fan_line, self.lines("fans")) if s and lo <= s.t < hi]
        return samples


def tmpdir(base, label):
    path = os.path.join(base, label)
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)
    return path


# ---------------------------------------------------------------------------------------------
# D1 and D2
# ---------------------------------------------------------------------------------------------


def d1(p1, work, watcher):
    out = tmpdir(work, "d1-out")
    result = run_watcher(watcher, p1.dir, out, fans=p1.fans, package=p1.package, phases=p1.phases)
    alerts = alerts_of(result)
    fans = [s for s in map(rw.parse_fan_line, p1.lines("fans")) if s]
    pkgs = [s for s in map(rw.parse_package_line, p1.lines("package")) if s]
    span = fans[-1].t - fans[0].t
    print("D1  P1 as captured (%s)" % os.path.basename(p1.fans).split("-")[-1])
    print("    watcher summary : %s" % result["summary"])
    print("    capture duration: %.0f s (%s to %s)" % (
        span, rw.format_time(fans[0].t), rw.format_time(fans[-1].t)))
    print("    alerts          : %d" % len(alerts))
    print("    warnings/notes  : %d / %d" % (len(lines_of(result, "WARN")), len(lines_of(result, "NOTE"))))
    print("    P1's hottest    : %.1f C; fan samples %d, package samples %d" % (
        max(p.hottest for p in pkgs), len(fans), len(pkgs)))
    # P1's own stop lines carry no wall-clock stamp: both must still be recognised as stop lines
    stops = sorted(e[3] for e in rw.load_events({"fans": p1.fans, "package": p1.package}) if e[3].endswith("_stop"))
    print("    stop lines read : %s (the samplers' own, with no wall-clock stamp)" % (", ".join(stops) or "none"))
    print("    replay took     : %.1f s of wall time" % result["seconds"])
    return len(alerts) == 0 and stops == ["fan_stop", "package_stop"]


def _p1_epoch(iso):
    return rw.parse_iso_utc(iso)


def _d2_files(p1, work, label, ctx, logs):
    directory = tmpdir(work, label)
    with open(os.path.join(directory, "phases.log"), "w", encoding="utf-8") as handle:
        handle.write("".join(synth.ctx_line(_p1_epoch(t), body) + "\n" for t, body in ctx))
    with open(os.path.join(directory, "helper-log.ndjson"), "w", encoding="utf-8") as handle:
        handle.write("".join(
            synth._line(synth.log_record(_p1_epoch(t), message)) + "\n" for t, message in logs))
    return directory


def d2(p1, work, watcher, mutations):
    ok = True
    print("D2  P1 plus synthetic CTX lines")
    load = ("2026-10-31T02:19:52Z", "load-start step=1d")
    go_1b = ("2026-10-31T02:20:48Z", "step=1b target=5777 GO")
    engage = ("2026-10-31T02:20:48.500Z", wrote("F0Md", "0x1"))
    restore = ("2026-10-31T02:22:00Z", wrote("F0Md", "0x0"))

    cases = [
        ("a", "CTX only, as specified", [load, go_1b], [], 5777),
        ("b", "plus a synthetic accepted engage (rule 9 live) at GO and a restore at 02:22:00",
         [load, go_1b], [engage, restore], 5777),
        ("c", "as b with target 4100: 0.9 x 4100 = 3690 < F1Tg's peak 3731", [load, ("2026-10-31T02:20:48Z", "step=1b target=4100 GO")], [engage, restore], 4100),
        ("d", "as b with target 4200: 0.9 x 4200 = 3780 > 3731", [load, ("2026-10-31T02:20:48Z", "step=1b target=4200 GO")], [engage, restore], 4200),
    ]
    fans = p1.fan_stats("2026-10-31T02:20:48Z", "2026-10-31T02:22:00Z")
    peak = max(s.v["F1Tg"] for s in fans)
    # P1's F0Tg is Apple's, and it moves. Rule 3 forbids F0Tg moving during a hold without a
    # `Wrote F0Tg`, so the synthetic hold writes it at every move (b, c and d only).
    moves = [
        (b.t - 0.01, wrote("F0Tg", "0x0 0x0 0x80 0x3f")) for a, b in zip(fans, fans[1:])
        if abs(b.v["F0Tg"] - a.v["F0Tg"]) > 1.0]
    for key, label, ctx, logs, target in cases:
        if logs:
            logs = logs + [(rw.format_time(t), m) for t, m in moves]
        directory = _d2_files(p1, work, "d2-" + key, ctx, logs)
        out = tmpdir(work, "d2-out-" + key)
        result = run_watcher(
            watcher, directory, out, fans=p1.fans, package=p1.package,
            helper_log=os.path.join(directory, "helper-log.ndjson"),
            phases=os.path.join(directory, "phases.log"))
        alerts = alerts_of(result)
        titles = sorted({a[1] for a in alerts})
        left = lines_of(result, "INFO", "F1Tg left 0")
        status = [t for t in lines_of(result, "STATUS") if "hold=ACTIVE" in t]
        want_fire = key in ("c",)
        passed = (titles == ["ABORT 9"]) if want_fire else (titles == [])
        ok = ok and passed
        print("    D2%s %s" % (key, label))
        print("        alerts: %s  -> %s" % (titles or "none", "as expected" if passed else "UNEXPECTED"))
        if key == "a":
            print("        %s" % (left[0] if left else "no F1Tg-left-0 line"))
            for line in lines_of(result, "INFO", "B = "):
                print("        %s" % line)
        if key == "b":
            print("        hold active in %d status lines; rule 9 limit shown: %s; F1Tg peak in the hold %.0f" % (
                len(status), sorted({s.split("F1Tg>")[1].split("(")[0] for s in status if "F1Tg>" in s}), peak))
        if key == "c":
            print("        first alert at %s (F1Tg crossed 0.9 x %d)" % (
                rw.format_time(alerts[0][0]) if alerts else "-", target))
    return d2e(p1, work, watcher, mutations) and ok


def _d2e_ctx(tl, stop):
    """1d in the runbook's order: GO at rest 30 s before the load, the load, L2 `stop` s into it,
    and step=none at t_L + 130 s."""
    return [
        (rw.format_time(tl - 30), "step=1d target=5777 GO"), (rw.format_time(tl), "load-start step=1d"),
        (rw.format_time(tl + stop), "load-stop"), (rw.format_time(tl + 130), "step=none")]


def d2e(p1, work, watcher, mutations):
    """B2: P1's load B with 1d's CTX lines in the runbook's order, load-stop at t_L + 34 s and at
    t_L + 60 s. Each replay: no alert; B about 35.5 C; F1Tg leaves 0 at about 14 s at about
    40 C; an injected 74.1 C at t_L + 90 s (after load-stop, before step=none) raises ABORT 1; and
    a watcher whose window ends at load-stop goes red at the stop."""
    ok = True
    tl = _p1_epoch("2026-10-31T02:19:52Z")
    print("    D2e 1d in the runbook's order: GO at t_L - 30 s, load-start at t_L, load-stop, "
          "step=none at t_L + 130 s")
    with mutate.Sweep(mutations) as sweep:
        mutant = sweep.make(
            "d2e-window-ends-at-load-stop",
            apply_mutation(("text", "self.load_stopped = True", "self.load_window = False")))
        for stop in (34, 60):
            ctx = _d2e_ctx(tl, stop)
            directory = _d2_files(p1, work, "d2e-%d" % stop, ctx, [])
            files = dict(
                fans=p1.fans, package=p1.package, helper_log=os.path.join(directory, "helper-log.ndjson"),
                phases=os.path.join(directory, "phases.log"))
            result = run_watcher(watcher, directory, tmpdir(work, "d2e-out-%d" % stop), **files)
            alerts = alerts_of(result)
            b = [float(t.split("B = ")[1].split(" ")[0]) for t in lines_of(result, "INFO", "B = ")]
            left = [re.search(r"left 0 at ([0-9.]+) s .* hottest curated ([0-9.]+) C", t)
                    for t in lines_of(result, "INFO", "F1Tg left 0")]
            clean = (not alerts and len(b) == 1 and 35.0 <= b[0] <= 36.0 and len(left) == 1
                     and left[0] is not None and 13.0 <= float(left[0].group(1)) <= 15.0
                     and 39.0 <= float(left[0].group(2)) <= 41.0)
            # 74.1 C at t_L + 90 s, in a copy of the window around the load
            run = p1.window(rw.format_time(tl - 60), 220)
            for t, body in ctx:
                run.add_ctx(_p1_epoch(t) - run.t0, body)
            run.patch_next_package(tl + 90 - run.t0, 74.1)
            inj_dir = tmpdir(work, "d2e-inj-%d" % stop)
            paths = run.write(inj_dir)
            injected = alerts_of(run_watcher(
                watcher, inj_dir, tmpdir(work, "d2e-inj-out-%d" % stop), fans=paths["fans"],
                package=paths["package"], helper_log=paths["helper_log"], phases=paths["phases"]))
            fired = bool(injected) and {a[1] for a in injected} == {"ABORT 1"} and (
                0.0 <= injected[0][0] - tl - 90 <= 1.2)
            red = alerts_of(run_watcher(
                mutant, directory, tmpdir(work, "d2e-mut-out-%d" % stop), **files))
            went_red = bool(red) and red[0][1] == "ABORT 1" and stop <= red[0][0] - tl <= stop + 5
            ok = ok and clean and fired and went_red
            print("        load-stop at t_L + %d s" % stop)
            print("            alerts: %s  B = %s C  %s -> %s" % (
                [a[1] for a in alerts] or "none", ", ".join("%.2f" % x for x in b) or "-",
                left[0].group(0) if left and left[0] else "no F1Tg-left-0 line",
                "as expected" if clean else "UNEXPECTED"))
            print("            74.1 C at t_L + 90 s: %s -> %s" % (
                ["%s at t_L + %.1f s" % (a[1], a[0] - tl) for a in injected] or "no alert",
                "ABORT 1, as expected" if fired else "UNEXPECTED"))
            print("            window ends at load-stop (mutant): %s -> %s" % (
                ["%s at t_L + %.1f s" % (a[1], a[0] - tl) for a in red[:1]] or "no alert",
                "red, as expected" if went_red else "NOT RED"))
    return ok


# ---------------------------------------------------------------------------------------------
# D3: the injections
# ---------------------------------------------------------------------------------------------

INJECTIONS = []


def injection(ident, rule, window, seconds, expect, note=None, quiet=False):
    """Register an injection. The builder patches the run and returns the reference instant,
    in seconds from the window's start, that the latency is measured from."""

    def register(build):
        INJECTIONS.append(dict(
            id=ident, rule=rule, window=window, seconds=seconds, expect=expect, note=note,
            quiet=quiet, build=build, name=build.__doc__.strip()))
        return build

    return register


def landed(run, at=20):
    run.add_log(at, LANDED)
    return at


@injection("M1", "3", "idle", 40, [("ABORT 3", 2.0, 2.2)])
def _m1(run):
    """Ftst = 1 in one sample"""
    return run.patch_next_fan(20, Ftst=1)


@injection("M2", "3", "idle", 40, [("ABORT 3", 0.0, 2.2)])
def _m2(run):
    """F1Md = 1 in one sample"""
    return run.patch_next_fan(20, F1Md=1)


@injection("M3", "2", "load", 70, [("ABORT 2", 10.0, 10.3)])
def _m3(run):
    """F0Ac halved for 12 s while F0Tg > 0"""
    run.scale_fan(20, 32, "F0Ac", 0.5)
    return run.next_fan_time(20)


@injection("M4", "1", "idle", 40, [("ABORT 1", 0.0, 1.1)])
def _m4(run):
    """hottest 85.1 C"""
    return run.patch_next_package(20, 85.1)


@injection("M5", "12", "idle", 60, [("ABORT 12", 2.0, 2.3)])
def _m5(run):
    """a 3 s fan gap during a synthetic hold"""
    run.hold(go=10, restore=40, target=3000).drop(20, 23, "fans")
    return run.last_time_before(20)


@injection("M6", "11", "idle", 80, [("ABORT 11 TIME", 60.0, 60.3)])
def _m6(run):
    """F1Tg held at 0 for 70 s after load-start step=1d"""
    run.add_ctx(5, "load-start step=1d")
    return 5


@injection("M7", "11", "idle", 60, [("ABORT 11 TEMPERATURE", 0.0, 1.1)])
def _m7(run):
    """F1Tg 0 and hottest 50.1 C, 30 s after load-start step=1d"""
    run.add_ctx(5, "load-start step=1d")
    return run.patch_next_package(35, 50.1)


@injection("M8", "10", "idle", 40, [("ABORT 10", 1.0, 1.3)])
def _m8(run):
    """F0Md 1 with F0Tg 0 for 1.2 s after a synthetic accepted Wrote F0Md = 0x1"""
    run.add_ctx(9.9, "step=1a target=3000 GO").add_log(9.95, wrote("F0Md", "0x1"))
    ref = run.next_fan_time(10)
    run.patch_fan(10, 11.2, F0Md=1)
    return ref


@injection("M9a", "5", "idle", 40, [("ABORT 5", 0.0, 0.2)])
def _m9a(run):
    """a write line `in 1.2 seconds.`"""
    run.add_log(20, wrote("Ftst", "0x1", seconds="1.2"))
    return 20


@injection("M9b", "5", "idle", 40, [("ABORT 5", 0.0, 0.2)])
def _m9b(run):
    """a write line `in 1.2e+00 seconds.`"""
    run.add_log(20, wrote("Ftst", "0x1", seconds="1.2e+00"))
    return 20


@injection("M9c", "5", "idle", 40, [], quiet=True)
def _m9c(run):
    """a write line `in 5.3083e-05 seconds.` (must not fire)"""
    run.add_log(20, wrote("Ftst", "0x1", seconds="5.3083e-05"))
    return 20


@injection("M10a", "4", "idle", 40, [(V, 0.0, 0.3)])
def _m10a(run):
    """a refused engagement, `the restore landed`, clean samples"""
    return landed(run)


@injection("M10b", "4", "idle", 40, [(R, 0.0, 0.3)])
def _m10b(run):
    """the same line with Ftst = 1 in the first sample after it"""
    run.add_log(19.5, wrote("Ftst", "0x1")).add_log(20.2, wrote("Ftst", "0x0"))
    run.patch_fan(19.6, 20.3, Ftst=1)
    return landed(run)


@injection("E1a", "1", "idle", 40, [("ABORT 1", 0.0, 1.1)])
def _e1a(run):
    """74.1 C between load-start and load-stop"""
    run.add_ctx(5, "load-start step=1b")
    return run.patch_next_package(20, 74.1)


@injection("E1b", "1", "idle", 40, [], quiet=True)
def _e1b(run):
    """74.0 C under load (must not fire)"""
    run.add_ctx(5, "load-start step=1b")
    return run.patch_next_package(20, 74.0)


@injection("E1c", "1", "idle", 40, [], quiet=True)
def _e1c(run):
    """85.0 C (must not fire)"""
    return run.patch_next_package(20, 85.0)


@injection("E2a", "1", "idle", 40, [("ABORT 1", 0.0, 1.1)])
def _e2a(run):
    """B + 10.3 C with no load, after a GO"""
    run.add_ctx(15, "step=1a target=3000 GO")
    return run.patch_next_package(25, run.hottest_mean(5, 15) + 10.3)


@injection("E2b", "1", "idle", 40, [], quiet=True)
def _e2b(run):
    """B + 9.7 C with no load, after a GO (must not fire)"""
    run.add_ctx(15, "step=1a target=3000 GO")
    return run.patch_next_package(25, run.hottest_mean(5, 15) + 9.7)


@injection("E3", "2", "load", 70, [("ABORT 2", 10.0, 10.3)])
def _e3(run):
    """F1Ac halved for 12 s while F1Tg > 0"""
    run.scale_fan(20, 32, "F1Ac", 0.5)
    return run.next_fan_time(20)


@injection("E4", "2", "idle", 90, [("ABORT 2", 10.0, 10.3)])
def _e4(run):
    """the held fan's F0Ac halved for 15 s, 20 s after its target is read"""
    run.hold(go=10, restore=70, target=3000).scale_fan(30, 45, "F0Ac", 0.5)
    return run.next_fan_time(30)


@injection("E5", "3", "idle", 60, [("ABORT 3", 2.0, 2.2)])
def _e5(run):
    """F0Tg moves 50 RPM during a hold with no Wrote F0Tg"""
    run.hold(go=10, restore=50, target=3000).patch_fan(30, 50, F0Tg=3050)
    return run.next_fan_time(30)


@injection("E6", "3", "idle", 60, [("ABORT 3", 2.0, 2.2)])
def _e6(run):
    """F0Md leaves 1 during a hold with no Wrote F0Md"""
    run.hold(go=10, restore=50, target=3000).patch_fan(30, 50.3, F0Md=0)
    return run.next_fan_time(30)


@injection("E7", "3", "idle", 60, [("ABORT 3", 2.0, 2.3)])
def _e7(run):
    """F0Md = 1 for 3 s with no hold and no Wrote F0Md"""
    run.add_ctx(25, "step=1a target=3000 GO").patch_fan(30, 33, F0Md=1, F0Tg=3000, F0Ac=3000)
    return run.next_fan_time(30)


@injection("E8", "9", "idle", 60, [("ABORT 9", 0.0, 0.2)])
def _e8(run):
    """F1Tg 2750 during a hold with CTX target 3000"""
    run.hold(go=10, restore=50, target=3000).patch_fan(30, 40, F1Tg=2750, F1Ac=2750)
    return run.next_fan_time(30)


@injection("E9", "6", "idle", 40, [("ABORT 6", 0.0, 0.1)])
def _e9(run):
    """thermal pressure level 1"""
    run.add_poll(5, "pressure", level=0).add_poll(10, "pressure", level=0)
    run.add_poll(20, "pressure", level=1)
    return 20


@injection("E10", "6", "idle", 40, [], note="pmset -g therm changed", quiet=False)
def _e10(run):
    """pmset -g therm changes (a note only)"""
    run.add_poll(5, "pmset", text="a").add_poll(20, "pmset", text="b")
    return 20


@injection("E11", "7", "idle", 40, [("HELPER RESTARTED", 0.0, 0.1)])
def _e11(run):
    """the helper's PID changes after CTX armed, no hold"""
    run.add_ctx(5, "armed pid=100").add_poll(6, "pgrep", pids=[100]).add_poll(20, "pgrep", pids=[101])
    return 20


@injection("E12", "7", "idle", 60, [("ABORT 7", 0.0, 0.1)])
def _e12(run):
    """the helper's PID changes during a hold"""
    run.hold(go=10, restore=50, target=3000)
    run.add_ctx(5, "armed pid=100").add_poll(6, "pgrep", pids=[100]).add_poll(30, "pgrep", pids=[101])
    return 30


@injection("E13", "7", "idle", 40, [("HELPER RESTARTED", 0.0, 0.1)])
def _e13(run):
    """a second preparation-step line after CTX armed"""
    run.add_log(2, PREP).add_ctx(5, "armed pid=100").add_log(20, PREP)
    return 20


@injection("E14", "8", "idle", 330, [("ABORT 8", 300.0, 300.3)], note="no verified restore 240 s")
def _e14(run):
    """no verified restore 5 min after engage"""
    run.hold(go=10, restore=None, target=3000)
    return 10.03


@injection("E15", "8", "idle", 60, [], quiet=True)
def _e15(run):
    """a well-formed hold, restored and verified (must not fire)"""
    run.hold(go=10, restore=40, target=3000)
    return 40


@injection("E16", "fault", "idle", 40, [("HELPER FAULT", 0.0, 0.1)])
def _e16(run):
    """a helper line with messageType Fault"""
    run.add_log(20, "Liveness watchdog: the safety-cycle trigger fired", "Fault")
    return 20


@injection("E17", "context", "idle", 40, [("NO CONTEXT", 0.0, 0.3)])
def _e17(run):
    """F0Md = 1 with no open CTX step"""
    run.add_log(9.9, wrote("F0Md", "0x1")).add_log(9.92, wrote("F0Tg", "0x0"))
    ref = run.next_fan_time(10)
    run.patch_fan(10, 11.5, F0Md=1, F0Tg=3000, F0Ac=3000)
    return ref


@injection("E18", "5", "idle", 40, [("UNPARSED WRITE", 0.0, 0.1)])
def _e18(run):
    """a Wrote line with `in nan seconds.`"""
    run.add_log(20, "Wrote F0Md = 0x1: answered 0x00, in nan seconds.")
    return 20


@injection("E19a", "12", "idle", 40, [(BLIND, 0.0, 0.1)])
def _e19a(run):
    """the log stream's process gone, no hold"""
    run.add_poll(5, "logstream", alive=True).add_poll(20, "logstream", alive=False)
    return 20


@injection("E19b", "12", "idle", 60, [("ABORT 12", 0.0, 0.1)])
def _e19b(run):
    """the log stream's process gone, during a hold"""
    run.hold(go=10, restore=50, target=3000)
    run.add_poll(5, "logstream", alive=True).add_poll(30, "logstream", alive=False)
    run.add_poll(31, "logstream", alive=True)  # restarted, so it does not outlive the hold
    return 30


@injection("E20", "12", "idle", 40, [(BLIND, 5.0, 5.2)])
def _e20(run):
    """a 6.5 s package gap"""
    run.drop(20, 26.5, "package")
    return run.last_time_before(20, "package")


@injection("E21", "4", "idle", 40, [(R, 0.0, 0.1), ("HELPER FAULT", 0.0, 0.1)])
def _e21(run):
    """`Could not undo the engagement` (a Fault line): RESET and HELPER FAULT together"""
    run.add_log(20, COULD_NOT, "Fault")
    return 20


@injection("E22", "4", "idle", 40, [], note="nothing was written", quiet=False)
def _e22(run):
    """a refused engagement with `Nothing was written.` (a note only)"""
    run.add_log(20, NOTHING)
    return 20


@injection("E23", "4", "idle", 40, [(R, 0.0, 0.1)])
def _e23(run):
    """a refused engagement whose hand-back was refused"""
    run.add_log(20, HANDBACK)
    return 20


@injection("E24", "4", "idle", 40, [(R, 10.0, 10.3)])
def _e24(run):
    """a landed undo with no fan sample after it: RESET at 10 s"""
    run.drop(19.95, 40, "fans")
    return landed(run)


@injection("E25", "3", "idle", 40, [], quiet=True)
def _e25(run):
    """Ftst changes with a Wrote Ftst on either side (must not fire)"""
    run.patch_next_fan(20, Ftst=1)
    run.add_log(19.95, wrote("Ftst", "0x1")).add_log(20.05, wrote("Ftst", "0x0"))
    return 20


@injection("E26", "test", "idle", 40, [("TEST ALERT", 0.0, 0.1)])
def _e26(run):
    """CTX test-alert"""
    run.add_ctx(20, "test-alert")
    return 20


@injection("E27", "3", "idle", 90, [("ABORT 3", 2.0, 2.3)])
def _e27(run):
    """F0Md stuck at 1 after a 30 s hold's restore (latency from the restore line)"""
    run.hold(go=10, restore=40, target=3000, close=False)
    run.patch_fan(40.2, 90, Ftst=0, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)
    return 40


@injection("E28", "3", "idle", 170, [], quiet=True)
def _e28(run):
    """a 120 s hold whose F0Md readback lags the restore by 1.5 s (must not fire)"""
    run.hold(go=10, restore=130, target=3000)
    run.patch_fan(130.2, 131.5, Ftst=0, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)
    return 130


@injection("E29", "context", "idle", 40, [("BAD CONTEXT", 0.0, 0.1)])
def _e29(run):
    """a CTX line with `target=5,777`"""
    run.add_ctx(20, "step=1b target=5,777 GO")
    return 20


@injection("E30", "4", "idle", 40, [(R, 0.0, 0.3)])
def _e30(run):
    """a refusal whose detail quotes `the restore landed` but whose outcome is a refused hand-back"""
    run.add_log(20, QUOTED)
    return 20


def _run_1d(run, stop=20):
    """1d's CTX lines in the runbook's order, on a short window."""
    run.add_ctx(5, "step=1d target=5777 GO").add_ctx(10, "load-start step=1d")
    run.add_ctx(stop, "load-stop").add_ctx(60, "step=none")


@injection("E31", "1", "idle", 70, [("ABORT 1", 0.0, 1.1)])
def _e31(run):
    """74.1 C after load-stop and before step=none (1d's order)"""
    _run_1d(run)
    return run.patch_next_package(40, 74.1)


@injection("E32", "1", "idle", 70, [], quiet=True)
def _e32(run):
    """60 C after load-stop and before step=none, over B + 10 (must not fire)"""
    _run_1d(run)
    return run.patch_next_package(40, 60.0)


def _ended(run):
    return run.add_ctx(5, "armed pid=100").add_poll(6, "pgrep", pids=[100]).add_ctx(8, "end")


@injection("E33", "12", "idle", 60, [("ABORT 12", 2.0, 2.3)])
def _e33(run):
    """a 4 s fan gap during a hold after CTX end"""
    _ended(run).hold(go=10, restore=50, target=3000).drop(25, 29, "fans")
    return run.last_time_before(25)


@injection("E34", "fault", "idle", 40, [("HELPER FAULT", 0.0, 0.1)])
def _e34(run):
    """a Fault line after CTX end"""
    _ended(run).add_log(20, "Could not restore Ftst", "Fault")
    return 20


@injection("E35", "7", "idle", 60, [("ABORT 7", 0.0, 0.1)])
def _e35(run):
    """the helper's PID changes during a hold after CTX end"""
    _ended(run).hold(go=10, restore=50, target=3000).add_poll(30, "pgrep", pids=[101])
    return 30


@injection("E36", "7", "idle", 40, [], note="after CTX end", quiet=False)
def _e36(run):
    """the helper's PID changes after CTX end, no hold (a note only)"""
    _ended(run).add_poll(20, "pgrep", pids=[101])
    return 20


WINDOWS = {"idle": ("2026-10-31T01:44:00Z", 330), "load": ("2026-10-31T01:56:00Z", 90)}


def build(p1, inj):
    start, length = WINDOWS[inj["window"]]
    run = p1.window(start, length).truncate(inj["seconds"])
    ref = inj["build"](run)
    return run, ref


def execute(p1, inj, watcher, work, label):
    run, ref = build(p1, inj)
    directory = tmpdir(work, "inj-" + label)
    paths = run.write(directory)
    out = tmpdir(work, "inj-out-" + label)
    result = run_watcher(
        watcher, directory, out, fans=paths["fans"], package=paths["package"],
        helper_log=paths["helper_log"], phases=paths["phases"],
        polls=paths["polls"] if run.polls else None)
    result["rel"] = [(t - run.t0, title, detail) for t, title, detail in alerts_of(result)]
    result["ref"] = ref
    return result


def judge(inj, result):
    """(passed, text) for an injection's result against what it expects."""
    seen = {}
    for rel, title, _ in result["rel"]:
        seen.setdefault(title, rel - result["ref"])
    wanted = {title: (lo, hi) for title, lo, hi in inj["expect"]}
    problems = []
    for title in sorted(set(seen) - set(wanted)):
        problems.append("extra alert %s" % title)
    for title, (lo, hi) in wanted.items():
        if title not in seen:
            problems.append("missing %s" % title)
        elif not lo - 0.01 <= seen[title] <= hi:
            problems.append("%s at %+.2f s, wanted %.1f to %.1f s" % (title, seen[title], lo, hi))
    if inj["note"] and not any(inj["note"] in t for _, lvl, t in result["log"] if lvl in ("NOTE", "WARN")):
        problems.append("missing note %r" % inj["note"])
    if inj["quiet"] and any(lvl in ("NOTE", "WARN") for _, lvl, _ in result["log"]):
        problems.append("unexpected note or warning")
    return not problems, "; ".join(problems)


def d3(p1, work, watcher):
    print("D3  injections: each must raise its own alert, within its latency, and no other")
    print()
    print("| id | rule | injection | expected | observed (latency from the violation) | other | result |")
    print("|---|---|---|---|---|---|---|")
    allok = True
    for inj in INJECTIONS:
        result = execute(p1, inj, watcher, work, inj["id"])
        passed, why = judge(inj, result)
        allok = allok and passed
        seen = {}
        for rel, title, _ in result["rel"]:
            seen.setdefault(title, rel - result["ref"])
        wanted = [t for t, _, _ in inj["expect"]]
        expected = ", ".join(wanted) if wanted else ("note: " + inj["note"] if inj["note"] else "no alert")
        observed = ", ".join("%s (%+.2f s)" % (t, round(seen[t], 2) + 0.0) for t in seen if t in wanted) or "none"
        other = ", ".join(t for t in seen if t not in wanted) or "none"
        print("| %s | %s | %s | %s | %s | %s | %s |" % (
            inj["id"], inj["rule"], inj["name"], expected, observed, other,
            "PASS" if passed else "FAIL: " + why))
    print()
    return allok


# ---------------------------------------------------------------------------------------------
# D4: the same injections against mutated copies
# ---------------------------------------------------------------------------------------------

#: The check each injection exists for. Blanking the function must leave the injection silent.
BLANKED = [
    ("check_r1_absolute", ["M4"]), ("check_r1_loaded", ["E1a", "E31"]), ("check_r1_rise", ["E2a"]),
    ("check_r2_automatic", ["M3", "E3"]), ("check_r2_held", ["E4"]),
    ("check_r3_ftst", ["M1"]), ("check_r3_f1_mode", ["M2"]), ("check_r3_f0_mode", ["E7", "E27"]),
    ("_judge_f0_modes", ["E7", "E27"]),
    ("check_r3_hold", ["E5", "E6"]),
    ("check_r4_refused", ["M10a", "M10b", "E23", "E30"]), ("_r4_decide", ["M10a", "M10b"]),
    ("check_r5_write", ["M9a", "M9b", "E18"]), ("check_r6_pressure", ["E9"]),
    ("check_r7_restart", ["E11", "E12", "E35"]), ("check_r7_prep_step", ["E13"]),
    ("check_r8_restore", ["E14"]), ("check_r9_f1_follows", ["E8"]),
    ("check_r10_floor", ["M8"]), ("check_r11_time", ["M6"]),
    ("check_r11_temperature", ["M7"]),
    ("check_r12_blind", ["M5", "E19a", "E19b", "E20", "E33"]),
    ("check_x_fault", ["E16", "E34"]), ("check_x_no_context", ["E17"]),
    ("check_x_bad_context", ["E29"]),
]

NAIVE_DURATION = '''
def parse_duration_seconds(text):
    return 1.0 if isinstance(text, str) and re.match(r"[1-9]", text) else 0.0
'''
ALWAYS_VERIFY = '''
def _r4_decide(self, sample, msg):
    self.event("r4-verify", "ABORT 4 \\u2014 VERIFY", "mutated")
'''

#: Mutations that change a result rather than silence it: (label, how, injection, expectation).
SEMANTIC = [
    ("F2: the duration read by a leading nonzero digit", ("replace", "parse_duration_seconds", NAIVE_DURATION), "M9c", "ABORT 5"),
    ("rule 4: every landed undo called VERIFY", ("replace", "_r4_decide", ALWAYS_VERIFY), "M10b", "no " + R),
    ("rule 4: no 10 s escalation", ("blank", "check_r4_escalate"), "E24", "no " + R),
    ("rule 1: the limit raised from 85 to 85.2", ("text", "TEMP_ABSOLUTE = 85.0", "TEMP_ABSOLUTE = 85.2"), "M4", "no ABORT 1"),
    ("rule 1: the loaded limit raised from 74 to 74.2", ("text", "TEMP_LOADED = 74.0", "TEMP_LOADED = 74.2"), "E1a", "no ABORT 1"),
    ("rule 2: 10 s lengthened to 11 s", ("text", "RULE2_SECONDS = 10.0", "RULE2_SECONDS = 11.0"), "M3", "ABORT 2 late"),
    ("rule 10: 1.0 s lengthened to 1.2 s", ("text", "FLOOR_SECONDS = 1.0", "FLOOR_SECONDS = 1.2"), "M8", "no ABORT 10"),
    ("rule 11: 60 s lengthened to 61 s", ("text", "R11_TIME_SECONDS = 60.0", "R11_TIME_SECONDS = 61.0"), "M6", "ABORT 11 TIME late"),
    ("rule 11: 50 C raised to 50.2 C", ("text", "R11_TEMPERATURE = 50.0", "R11_TEMPERATURE = 50.2"), "M7", "no ABORT 11 TEMPERATURE"),
    ("rule 12: 2 s lengthened to 3 s", ("text", "FAN_STALE_SECONDS = 2.0", "FAN_STALE_SECONDS = 3.0"), "M5", "ABORT 12 late"),
    ("rule 8: 300 s lengthened to 330 s", ("text", "RESTORE_ABORT_SECONDS = 300.0", "RESTORE_ABORT_SECONDS = 330.0"), "E14", "ABORT 8 late"),
    ("rule 1: the load window ends at load-stop", ("text", "self.load_stopped = True", "self.load_window = False"), "E32", "ABORT 1 appears"),
]

#: Mutations the unit tests must kill, with no injection of their own (the unit sweep only):
#: (label, how). The first four are the first review's surviving mutants (S1); the rest are the
#: guards the two rounds added or changed (N1, S-a, S-b and the readback nit are the delta
#: review's). Each edit is the exact text, found once in run_watch.py.
UNIT_ONLY = [
    ("S1 R2a: the held fan's 10 s spin-up allowance removed", (
        "text", "counted = self.tg_hit_t is not None and s.t >= self.tg_hit_t + HELD_SPINUP_SECONDS",
        "counted = self.tg_hit_t is not None")),
    ("S1 R2c: fan 1 not checked during a hold", (
        "text", "            if n == 0 and self.hold_active:\n", "            if self.hold_active:\n")),
    ("S1 R4a: VERIFY ignores F1Md", (
        "text", 'for n in (0, 1))\n        if clean:', 'for n in (0,))\n        if clean:')),
    ("S1 R10b: a recovery above the floor no longer restarts the 1 s", (
        "text", "                self.r10_since = s.t\n        else:\n            self.r10_since = None",
        "                self.r10_since = s.t\n        elif md != 1:\n            self.r10_since = None")),
    ("B1: a write of any value explains a mode", (
        "text", "k == key and lo <= t <= hi and _byte(data) == value", "k == key and lo <= t <= hi")),
    ("B1: a sample is judged after 0.5 s, not 2 s (the readback's slack gone)", (
        "text", "delay = max(MODE_SECONDS, JUDGE_AFTER)", "delay = 0.5")),
    ("B1: the hold's F0Md = 1 is not exempt", (
        "text", "or (mode == 1 and held):", "or False:")),
    ("B2: 74 C holds only while the load runs", (
        "text", "self.load_window and hottest > TEMP_LOADED", "self.load_active and hottest > TEMP_LOADED")),
    ("B2: B + 10 applies again in the window", (
        "text", "self.step is not None and not self.load_window and limit is not None",
        "self.step is not None and not self.load_active and limit is not None")),
    ("B2: the window never ends", (
        "text", "if self.load_stopped:  # the first step=none", "if False:  # the first step=none")),
    ("B2: any step=none ends the window", (
        "text", "if self.load_stopped:  # the first step=none", "if self.load_window:  # the first step=none")),
    ("B2: a load-stop with no step open leaves the window", (
        "text", "if self.step is None:  # no step is open to carry", "if False:  # no step is open to carry")),
    ("S2 (ruling): the hold-blind `ended` guard back in rule 7", (
        "text", '        if self.ended and not self.hold_active:\n            self.note("after CTX end',
        '        if self.ended:\n            self.note("after CTX end')),
    ("S2 (ruling): the `ended` guard back in rule 12", (
        "text", "        if self.now is None:\n            return\n        title = \"ABORT 12\"",
        "        if self.ended or self.now is None:\n            return\n        title = \"ABORT 12\"")),
    ("S2 (ruling): the Fault demotion back", (
        "text", 'self.event("x-fault", "HELPER FAULT", text)',
        '(self.note(text, "WARN") if self.ended else self.event("x-fault", "HELPER FAULT", text))')),
    ("S2: a sampler's stop line is ignored", ("blank", "on_source_stop")),
    ("S2: a sampler that starts again stays over", (
        "text", 'self.ended_sources.discard("fans")', "pass")),
    ("N1: a stop line ends its source whenever it comes", (
        "text", "        if self.ended and not self.hold_active:\n            self.ended_sources.add(name)",
        "        if True:\n            self.ended_sources.add(name)")),
    ("N1: a stop line ends its source in a hold after CTX end", (
        "text", "        if self.ended and not self.hold_active:\n            self.ended_sources.add(name)",
        "        if self.ended:\n            self.ended_sources.add(name)")),
    ("N1: a stop line ends its source before CTX end", (
        "text", "        if self.ended and not self.hold_active:\n            self.ended_sources.add(name)",
        "        if not self.hold_active:\n            self.ended_sources.add(name)")),
    ("N1: a stop line is read only if it carries a wall-clock stamp (no sampler writes one)", (
        "text", 'return record is not None and record.get("kind") == "stop"',
        'return record is not None and record.get("kind") == "stop" and '
        'parse_iso_utc(record.get("wallClockUTC")) is not None')),
    ("N1: the replay does not read a sampler's stop line", (
        "text", "elif last is not None and is_stop_line(raw):", "elif False:")),
    ("S-a: rule 3's window for F0Md reaches 2 s ahead of the sample, not 0.5 s", (
        "text", '"F0Md", mode, t - EXPLAIN_BEFORE, t + EXPLAIN_AFTER)',
        '"F0Md", mode, t - EXPLAIN_BEFORE, t + JUDGE_AFTER)')),
    ("S-a: rule 3's window for the other keys reaches 2 s ahead of the sample", (
        "text", "lo, hi = t - EXPLAIN_BEFORE, t + EXPLAIN_AFTER", "lo, hi = t - EXPLAIN_BEFORE, t + JUDGE_AFTER")),
    ("S-b: a step line with no target= field is accepted", (
        "text", 'elif kind == "step" and step != "none":', "elif False:")),
    ("S-b: step=none needs a target too", (
        "text", 'elif kind == "step" and step != "none":', 'elif kind == "step":')),
    ("S-b: a load-start line, which carries step=, is held to a target too", (
        "text", 'elif kind == "step" and step != "none":', 'elif step is not None and step != "none":')),
    ("nit: a sample stamped before the restore is not in the hold", (
        "text", "held = self.hold_active or (self.hold_end_t is not None and s.t < self.hold_end_t)",
        "held = self.hold_active")),
    ("nit: a sample stamped up to 0.5 s after the restore is still in the hold", (
        "text", "and s.t < self.hold_end_t)", "and s.t < self.hold_end_t + 0.5)")),
    ("nit: any F0Md in the hold's span is exempt, not only 1", (
        "text", "(mode == 1 and held)", "(held and mode is not None)")),
    ("S2: the live loop does not read a sampler's stop line", (
        "text", "if parsed is None and name in STOP_KINDS:", "if False and name in STOP_KINDS:")),
    ("S3: an unreadable target is not heard", ("blank", "check_x_bad_context")),
    ("S3: a target of 0 is read as RPM", (
        "text", "return value if math.isfinite(value) and value > 0 else None",
        "return value if math.isfinite(value) else None")),
    ("S4: one raising check ends the event's other checks", (
        "replace", "_guard", "def _guard(self, check, *args):\n    check(*args)\n")),
    ("S4: a persistent bug writes a traceback at every sample", (
        "text", "if count == 1 or count % 1000 == 0:", "if True:")),
    ("S5: `Nothing was written.` read anywhere in the line", (
        "text", 'outcome == "Nothing was written."', '"Nothing was written." in msg')),
    ("S5: `the restore landed` read anywhere in the line", (
        "text", 'outcome.endswith("the restore landed.")', '"the restore landed" in msg')),
    ("S5: `Could not undo` read anywhere in the line", (
        "text", 'msg.startswith("Could not undo the engagement of fan ")',
        '"Could not undo the engagement" in msg')),
]


def apply_mutation(how):
    kind = how[0]
    if kind == "blank":
        return lambda text: mutate.blank_function(text, how[1])
    if kind == "replace":
        return lambda text: mutate.replace_function(text, how[1], how[2])

    def by_text(text):
        if text.count(how[1]) != 1:
            raise LookupError("%r occurs %d times" % (how[1], text.count(how[1])))
        return text.replace(how[1], how[2])

    return by_text


def by_id(ident):
    return next(i for i in INJECTIONS if i["id"] == ident)


def d4(p1, work, watcher, mutations):
    print("D4  each injection against a copy of the watcher with that rule's check removed")
    print()
    print("| mutation (function emptied) | injection | alerts from the copy | control on the same copy | result |")
    print("|---|---|---|---|---|")
    allok = True
    with mutate.Sweep(mutations) as sweep:
        for function, ids in BLANKED:
            path = sweep.make("blank-" + function, apply_mutation(("blank", function)))
            control = by_id("M4" if function != "check_r1_absolute" else "M3")
            c = execute(p1, control, path, work, "ctl-" + function)
            c_ok, _ = judge(control, c)
            for ident in ids:
                inj = by_id(ident)
                result = execute(p1, inj, path, work, "mut-%s-%s" % (function, ident))
                titles = sorted({t for _, t, _ in result["rel"]})
                silent = not titles
                ok = silent and c_ok
                allok = allok and ok
                print("| `%s` | %s %s | %s | %s %s | %s |" % (
                    function, ident, inj["name"], "none" if silent else ", ".join(titles),
                    control["id"], "fires" if c_ok else "DID NOT FIRE",
                    "PASS (silent)" if ok else "FAIL"))
        print()
        print("D4+ mutations that change a result instead of silencing it")
        print()
        print("| mutation | injection | observed from the copy | wanted | result |")
        print("|---|---|---|---|---|")
        for index, (label, how, ident, wanted) in enumerate(SEMANTIC):
            path = sweep.make("sem-%d" % index, apply_mutation(how))
            inj = by_id(ident)
            result = execute(p1, inj, path, work, "sem-" + ident)
            passed, why = judge(inj, result)
            titles = sorted({t for _, t, _ in result["rel"]})
            # the copy must now disagree with the unmutated expectation
            ok = not passed
            allok = allok and ok
            print("| %s | %s | %s | %s | %s |" % (
                label, ident, ", ".join(titles) or "none", why or "(matches the unmutated run)",
                "PASS (the injection notices)" if ok else "FAIL (the injection did not notice)"))
        # the disarm path of rule 11, on D2's own replay
        path = sweep.make("sem-disarm", apply_mutation(("blank", "_track_r11_release")))
        directory = _d2_files(
            p1, work, "d2-disarm", [("2026-10-31T02:19:52Z", "load-start step=1d"),
                                     ("2026-10-31T02:20:48Z", "step=1b target=5777 GO")], [])
        out = tmpdir(work, "d2-disarm-out")
        result = run_watcher(
            path, directory, out, fans=p1.fans, package=p1.package,
            helper_log=os.path.join(directory, "helper-log.ndjson"),
            phases=os.path.join(directory, "phases.log"))
        titles = sorted({t for _, t, _ in alerts_of(result)})
        ok = titles == ["ABORT 11 TIME"]
        allok = allok and ok
        print("| rule 11: F1Tg leaving 0 no longer disarms | D2a (P1 + CTX) | %s | ABORT 11 TIME when F1Tg returns to 0 | %s |" % (
            ", ".join(titles) or "none", "PASS (D2a notices)" if ok else "FAIL"))
    print()
    return allok


#: Functions the unit sweep empties besides BLANKED's (each has its own unit tests, no injection).
ALSO_BLANKED = (
    "check_r4_escalate", "check_r4_verdict", "_track_restore", "_track_r11_release", "_judge_pending",
    "_resolve_b", "_pump_speech")


def check_mutations(watcher):
    """Apply every mutation to the watcher's text, in memory, before anything runs. A mutation
    whose anchor the tree has since changed would otherwise stop the unit sweep with a
    LookupError after ten minutes and more. Returns how many were applied."""
    with open(watcher, encoding="utf-8") as handle:
        text = handle.read()
    jobs = [("blank " + f, ("blank", f)) for f, _ in BLANKED]
    jobs += [("blank " + f, ("blank", f)) for f in ALSO_BLANKED]
    jobs += [("sem " + label, how) for label, how, _, _ in SEMANTIC] + UNIT_ONLY
    stale = []
    for label, how in jobs:
        try:
            changed = apply_mutation(how)(text)
            compile(changed, "<mutant>", "exec")
            if changed == text:
                raise LookupError("changes nothing")
        except (LookupError, SyntaxError) as error:
            stale.append("  %s: %s" % (label, error))
    if stale:
        raise SystemExit("stale mutations (their anchors are not in %s):\n%s" % (
            watcher, "\n".join(stale)))
    return len(jobs)


def unit_sweep(work, mutations, python):
    print("unit  the unit tests against each mutated copy: every one must go red")
    print()
    print("| mutation | exit | tests failed | result |")
    print("|---|---|---|---|")
    allok = True
    extra = [("sem-" + label, how) for label, how, _, _ in SEMANTIC] + UNIT_ONLY
    jobs = [("blank-" + f, ("blank", f)) for f, _ in BLANKED] + [
        ("blank-" + f, ("blank", f)) for f in ALSO_BLANKED]
    with mutate.Sweep(mutations) as sweep:
        for index, (label, how) in enumerate(jobs + extra):
            path = sweep.make("unit-%d" % index, apply_mutation(how))
            directory = os.path.dirname(path)
            code, text = mutate.run_unit_tests(directory, python)
            failed = [l.split(" ")[1] for l in text.splitlines() if l.startswith(("FAIL:", "ERROR:"))]
            ok = code != 0 and bool(failed)
            allok = allok and ok
            print("| %s | %d | %d: %s | %s |" % (
                label, code, len(failed), ", ".join(failed[:3]) + (" ..." if len(failed) > 3 else ""),
                "red" if ok else "STILL GREEN"))
    print()
    return allok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("p1", help="the P1 capture directory (read only)")
    p.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "run-watch-dryrun"))
    p.add_argument("--mutations", default=os.path.join(tempfile.gettempdir(), "run-watch-mut"))
    p.add_argument("parts", nargs="*", default=["d1", "d2", "d3", "d4"])
    args = p.parse_args()
    for path in (args.work, args.mutations):
        real = os.path.realpath(path)
        if real == mutate.REPO or real.startswith(mutate.REPO + os.sep):
            raise SystemExit("refusing a work directory inside the working tree: %s" % real)
    os.makedirs(args.work, exist_ok=True)
    p1 = P1(args.p1)
    watcher = os.path.join(HERE, "run_watch.py")
    results = {}
    if "d4" in args.parts or "unit" in args.parts:
        print("mutations: all %d applied to the watcher's text before anything runs" % check_mutations(watcher))
        print()
    for part in args.parts:
        if part == "d1":
            results[part] = d1(p1, args.work, watcher)
        elif part == "d2":
            results[part] = d2(p1, args.work, watcher, args.mutations)
        elif part == "d3":
            results[part] = d3(p1, args.work, watcher)
        elif part == "d4":
            results[part] = d4(p1, args.work, watcher, args.mutations)
        elif part == "unit":
            results[part] = unit_sweep(args.work, args.mutations, sys.executable)
        else:
            raise SystemExit("unknown part %r" % part)
        print()
    print("summary: " + ", ".join("%s %s" % (k, "PASS" if v else "FAIL") for k, v in results.items()))
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
