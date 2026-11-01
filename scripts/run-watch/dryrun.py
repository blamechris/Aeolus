#!/usr/bin/env python3
"""The watcher's dry run: D1 to D4 of the run-1 gap rulings (section 3), re-runnable.

    python3 -I dryrun.py <P1 capture dir> [--work DIR] [--mutations DIR] [d1 d2 d3 d4 unit tools]

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
tools The load driver's and the record restart's guards, one edit each, in a private copy of this
      directory, against that tool's own tests: every one must go red. (Not part of the default
      parts; the watcher's sweep never copies those tools, so it never runs their tests.)

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
    ("r3 S1: a hold that starts does not re-arm rule 12 for a source whose stop line was honoured", (
        "text", "                    self.ended_sources.clear()\n", "")),
    ("r3 N-b: the live loop reads a stop line that has no sample before it", (
        "text", "if name in last_sample and is_stop_line(raw):", "if is_stop_line(raw):")),
    ("r3 N-b: the replay reads a stop line that has no sample before it", (
        "text", "elif last is not None and is_stop_line(raw):", "elif is_stop_line(raw):")),
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
    # The derived-gate notes: one mutant for each guard and each constant
    ("gate: a gate line is an alert", (
        "text", 'self.out.line(self._stamp(), "GATE", text)',
        'self.event("gate-" + name, "GATE", text)')),
    ("gate: a gate that raises on every sample writes a traceback at every one", (
        "text", "if count % 1000 == 1:  # the first occurrence", "if True:  # the first occurrence")),
    ("gate: a gate that raises is heard as a watcher error", (
        "replace", "_gate_guard", "def _gate_guard(self, check, *args):\n    self._guard(check, *args)\n")),
    ("gate quiet: Ftst is not a clause", (
        "text", 'quiet = have and v["Ftst"] == 0 and all(', "quiet = have and all(")),
    ("gate quiet: a mode outside Apple's set is not a clause", (
        "text", 'v["F%dMd" % n] in SAFE_MODES and not (v["F%dMd" % n] == 3 and v["F%dTg" % n] > 0)',
        'not (v["F%dMd" % n] == 3 and v["F%dTg" % n] > 0)')),
    ("gate quiet: a fan reading 3 with a target is not a clause", (
        "text", ' and not (v["F%dMd" % n] == 3 and v["F%dTg" % n] > 0)', "")),
    ("gate quiet: a key that did not read ok does not break the run", (
        "text", "have = all(key in v for key in GATE_FAN_KEYS)", "have = True")),
    ("gate rest: Ftst is not a clause", (
        "text", 'rest = have and v["Ftst"] == 0 and all(', "rest = have and all(")),
    ("gate rest: a mode of 0 is rest as well as 3", (
        "text", 'v["F%dMd" % n] == 3 and v["F%dTg" % n] == 0 for n in (0, 1))',
        'v["F%dMd" % n] in SAFE_MODES and v["F%dTg" % n] == 0 for n in (0, 1))')),
    ("gate rest: a target above 0 is not a clause", (
        "text", 'v["F%dMd" % n] == 3 and v["F%dTg" % n] == 0 for n in (0, 1))',
        'v["F%dMd" % n] == 3 for n in (0, 1))')),
    ("gate runs: a gap in the fan record does not end a run", (
        "text", "gap = self.fan_prev is not None and s.t - self.fan_prev.t > GATE_MAX_GAP",
        "gap = False")),
    ("gate T0: a window is complete at any span", (
        "text", "GATE_QUIESCENCE_SECONDS - GATE_SPAN_TOLERANCE):", "0.0):")),
    ("gate T0: the package record need not have caught up", (
        "text", "if self.pkg_last_t is None or end - self.pkg_last_t >= GATE_PACKAGE_FRESH:",
        "if False:")),
    ("gate T0: a window with 1 package sample is enough", (
        "text", "GATE_T0_MIN_SAMPLES = 100", "GATE_T0_MIN_SAMPLES = 1")),
    ("gate T0: the upper middle value, not the mean of the two", (
        "text", "values[mid] if n % 2 else (values[mid - 1] + values[mid]) / 2.0", "values[mid]")),
    ("gate T0: the mean, not the median", (
        "text", "values[mid] if n % 2 else (values[mid - 1] + values[mid]) / 2.0", "sum(values) / n")),
    ("gate T0: ok below 50.2, not 50", (
        "text", "GATE_T0_LIMIT = 50.0", "GATE_T0_LIMIT = 50.2")),
    ("gate T0: not frozen by CTX armed", (
        "text", 'self._freeze_t0("CTX armed")', "pass")),
    ("gate T0: not frozen by a step line", (
        "text", 'self._freeze_t0("CTX step=%s" % c.step)', "pass")),
    ("gate T0: armed before any window freezes nothing", (
        "text", "            self.t0_freeze_pending = why\n", "            pass\n")),
    ("gate rest: an open step is at rest", (
        "text", "elif self.step is not None or self.hold_active:", "elif self.hold_active:")),
    ("gate rest: a hold with no step open is at rest", (
        "text", "elif self.step is not None or self.hold_active:", "elif self.step is not None:")),
    ("gate rest: 30 s are enough", (
        "text", "GATE_REST_SECONDS = 60.0", "GATE_REST_SECONDS = 30.0")),
    ("gate rest: T0 + 4, not T0 + 3", (
        "text", "GATE_REST_MARGIN = 3.0", "GATE_REST_MARGIN = 4.0")),
    ("gate rest: at T0 + 3 is too warm", (
        "text", "elif self.hottest > limit:", "elif self.hottest >= limit:")),
    ("gate rest: a package record behind the fans' does not matter", (
        "text", "self.fan_last_t - self.pkg_last_t >= GATE_PACKAGE_FRESH):", "False):")),
    ("gate rest: a stale fan record is at rest", (
        "text", '        if self.now - self.fan_last_t > FAN_STALE_SECONDS:\n            why = "stale"',
        '        if False:\n            why = "stale"')),
    ("gate engaged: the threshold is 1,650, not F0Mn + 300", (
        "text", 'engaged = "F0Tg" in v and v["F0Tg"] >= self.f0mn + GATE_ENGAGED_ABOVE_F0MN',
        'engaged = "F0Tg" in v and v["F0Tg"] >= 1650.0')),
    ("gate engaged: F0Mn + 200", (
        "text", "GATE_ENGAGED_ABOVE_F0MN = 300.0", "GATE_ENGAGED_ABOVE_F0MN = 200.0")),
    ("gate engaged: strictly above the threshold", (
        "text", 'v["F0Tg"] >= self.f0mn + GATE_ENGAGED_ABOVE_F0MN', 'v["F0Tg"] > self.f0mn + GATE_ENGAGED_ABOVE_F0MN')),
    ("gate engaged: 20 s, not 30", (
        "text", "GATE_ENGAGED_SECONDS = 30.0", "GATE_ENGAGED_SECONDS = 20.0")),
    ("gate engaged: a stale fan record is still engaged", (
        "text", '        if self.now - self.fan_last_t > FAN_STALE_SECONDS:\n            state = "stale"',
        '        if False:\n            state = "stale"')),
    ("gate clock: the end of every step starts it, 1b's too", (
        "text", 'if closing is not None and closing != "1b":', "if closing is not None:")),
    ("gate clock: CTX armed does not start it", (
        "text", '            self._start_clock(c.t, "CTX armed")', "            pass")),
    ("gate clock: 25 minutes, not 30", (
        "text", "GATE_CLOCK_SECONDS = 1800.0", "GATE_CLOCK_SECONDS = 1500.0")),
    ("gate clock: the gate holding does not meet it", (
        "text", "        if self.rest_yes:\n            self.clock_state = \"met\"",
        "        if False:\n            self.clock_state = \"met\"")),
    ("gate clock: a step that opens early abandons nothing", (
        "text", 'if self.clock_state in ("ticking", "expired"):', "if False:")),
    ("gate clock: it ticks from the first second", (
        "text", "elif elapsed >= GATE_EVERY_SECONDS:", "elif True:")),
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
    "_resolve_b", "_pump_speech",
    "check_gate_runs", "check_gate_t0", "check_gate_rest", "check_gate_engaged", "check_gate_clock",
    "track_gate_ctx", "gate")


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



#: The load driver's and the record restart's guards, one edit each:
#: (file, its tests, label, ((old text, new text), ...)). Every old text is found once in the file.
TOOL_MUTANTS = [
    ('run_load.py', 'test_run_load', 'ctx after the fork, not before',
     (('        wall = self.ctx("load-start step=%s" % self.config.mode)\n'
       '        self.load_started = True',
       '        wall = self.clock.wall()\n        self.load_started = True'),
      ('        self.log("workers: %s" % " ".join(str(w.pid) for w in self.workers))',
       '        self.log("workers: %s" % " ".join(str(w.pid) for w in self.workers))\n'
       '        wall = self.ctx("load-start step=%s" % self.config.mode)'))),
    ('run_load.py', 'test_run_load', 'pids written after all forks, not as each starts',
     (('                pids.write("%d\\n" % worker.pid)\n', ''),
      ('        self.log("workers: %s"',
       '        open(self.workers_path, "w").write("".join("%d\\n" % w.pid for w in self.workers))\n'
       '        self.log("workers: %s"'))),
    ('run_load.py', 'test_run_load', 'pids not written',
     (('                pids.write("%d\\n" % worker.pid)\n', '                pass\n'),)),
    ('run_load.py', 'test_run_load', '8 workers by default',
     (('DEFAULT_WORKERS = 16', 'DEFAULT_WORKERS = 8'),)),
    ('run_load.py', 'test_run_load', '1b bound 700 s',
     (('BOUNDS = {"1b": 600.0,', 'BOUNDS = {"1b": 700.0,'),)),
    ('run_load.py', 'test_run_load', '1d bound 90 s', (('"1d": 80.0}', '"1d": 90.0}'),)),
    ('run_load.py', 'test_run_load', 'bound on the wall clock only',
     (('return max(self.clock.wall() - self.wall0, self.clock.mono() - self.mono0)',
       'return self.clock.wall() - self.wall0'),)),
    ('run_load.py', 'test_run_load', 'bound on the monotonic clock only',
     (('return max(self.clock.wall() - self.wall0, self.clock.mono() - self.mono0)',
       'return self.clock.mono() - self.mono0'),)),
    ('run_load.py', 'test_run_load', "bound from the driver's start, not the load's",
     (('        self.wall0, self.mono0 = self.clock.wall(), self.clock.mono()\n'
       '        self.log("load-start',
       '        self.log("load-start'),
      ('        code = EXIT_OK\n        try:\n            self.check_writable()',
       '        code = EXIT_OK\n'
       '        self.wall0, self.mono0 = self.clock.wall(), self.clock.mono()\n'
       '        try:\n'
       '            self.check_writable()'))),
    ('run_load.py', 'test_run_load', 'SIGTERM never sent',
     (('            if worker.poll() is None:\n                worker.terminate()',
       '            if worker.poll() is None:\n                pass'),)),
    ('run_load.py', 'test_run_load', 'SIGKILL never sent',
     (('                worker.kill()\n        self.wait_for_workers()',
       '                pass\n        self.wait_for_workers()'),)),
    ('run_load.py', 'test_run_load', 'no wait after SIGTERM (grace 0)',
     (('STOP_GRACE_SECONDS = 2.0', 'STOP_GRACE_SECONDS = 0.0'),)),
    ('run_load.py', 'test_run_load', 'a reaped worker is signalled again',
     (('            if worker.poll() is None:\n                worker.terminate()',
       '            if True:\n                worker.terminate()'),)),
    ('run_load.py', 'test_run_load', 'load-stop written with a worker still running',
     (('            self.log("STILL RUNNING after SIGKILL: %s. No CTX load-stop was written." % '
       'alive)\n'
       '            return alive\n',
       '            self.log("STILL RUNNING after SIGKILL: %s. No CTX load-stop was written." % '
       'alive)\n'),)),
    ('run_load.py', 'test_run_load', 'survivors do not change the exit code',
     (('                if survivors:\n                    code = EXIT_SURVIVOR',
       '                if False:\n                    code = EXIT_SURVIVOR'),)),
    ('run_load.py', 'test_run_load', 'stop_load acts on a load that never started',
     (('        if not self.load_started:\n'
       '            return []\n'
       '        for worker in self.workers:',
       '        for worker in self.workers:'),)),
    ('run_load.py', 'test_run_load', 'a second driver is allowed',
     (('                if holder is not None and self.alive(holder):',
       '                if False:'),)),
    ('run_load.py', 'test_run_load', 'the pid file is removed whoever owns it',
     (('        if self.owns_pid_file and self.read_pid(self.pid_path) == os.getpid():',
       '        if self.owns_pid_file:'),)),
    ('run_load.py', 'test_run_load', 'a missing directory is not refused',
     (('        if not os.path.isdir(self.config.directory):', '        if False:'),)),
    ('run_load.py', 'test_run_load', 'phases.log as a directory is not refused',
     (('        if os.path.isdir(self.config.phases) or not os.access(',
       '        if not os.access('),)),
    ('run_load.py', 'test_run_load', '1d dwell 5 s',
     (('DWELL_SECONDS = 10.0', 'DWELL_SECONDS = 5.0'),)),
    ('run_load.py', 'test_run_load', '1d tolerance 3 rpm',
     (('TARGET_TOLERANCE_RPM = 1.0', 'TARGET_TOLERANCE_RPM = 3.0'),)),
    ('run_load.py', 'test_run_load', 'a sample gap does not restart the dwell',
     (('SAMPLE_GAP_SECONDS = 2.0', 'SAMPLE_GAP_SECONDS = 200.0'),)),
    ('run_load.py', 'test_run_load', 'a dip does not restart the dwell',
     (('                    if target is None or abs(target - config.target_rpm) > '
       'TARGET_TOLERANCE_RPM:\n'
       '                        run_since = None',
       '                    if target is None or abs(target - config.target_rpm) > '
       'TARGET_TOLERANCE_RPM:\n'
       '                        pass'),)),
    ('run_load.py', 'test_run_load', 'the start window is 40 s',
     (('START_WINDOW_SECONDS = 30.0', 'START_WINDOW_SECONDS = 40.0'),)),
    ('run_load.py', 'test_run_load', 'a late dwell still starts the load',
     (('if started is not None and due and now <= started + START_WINDOW_SECONDS:',
       'if started is not None and due:'),)),
    ('run_load.py', 'test_run_load', 'no arm timeout',
     (('                if max(now - armed_wall, self.clock.mono() - armed_mono) >= '
       'config.arm_timeout:',
       '                if False:'),)),
    ('run_load.py', 'test_run_load', 'arm timeout on the wall clock only',
     (('max(now - armed_wall, self.clock.mono() - armed_mono) >= config.arm_timeout',
       'now - armed_wall >= config.arm_timeout'),)),
    ('run_load.py', 'test_run_load', 'a stale started counts',
     (('if event is None or event.t < armed_wall - STALE_STARTED_SECONDS:', 'if event is None:'),)),
    ('run_load.py', 'test_run_load', 'a failed set before started does not stop the arming',
     (('elif event.event in ("failed", "ended") and started is None:', 'elif False:'),)),
    ('run_load.py', 'test_run_load', 'the fan history is read',
     (('Follow(config.fans, from_end=True)', 'Follow(config.fans, from_end=False)'),)),
    ('run_load.py', 'test_run_load', 'the set file is followed by offset',
     (('Whole(config.set_json)', 'Follow(config.set_json)'),)),
    ('run_load.py', 'test_run_load', '1d stops 30 s after F1Tg leaves 0',
     (('TAIL_SECONDS = 20.0', 'TAIL_SECONDS = 30.0'),)),
    ('run_load.py', 'test_run_load', "a sample before t_L can be 'left 0'",
     (('if sample is not None and sample.t >= t_l and sample.v.get("F1Tg", 0.0) > 0:',
       'if sample is not None and sample.v.get("F1Tg", 0.0) > 0:'),)),
    ('run_load.py', 'test_run_load', 'F1Tg at 0 counts as left 0',
     (('sample.v.get("F1Tg", 0.0) > 0:', 'sample.v.get("F1Tg", 0.0) >= 0:'),)),
    ('run_load.py', 'test_run_load', 'a dead record can start the load',
     (('\n                       and now - last_t <= SAMPLE_GAP_SECONDS)', ')'),)),
    ('run_load.py', 'test_run_load', 'a stop request while armed is ignored',
     (('                if self.stop_signal is not None:\n'
       '                    self.log("stop requested by SIG%s before',
       '                if False:\n                    self.log("stop requested by SIG%s before'),)),
    ('run_load.py', 'test_run_load', 'a stop request during the load is ignored',
     (('        if self.stop_signal is not None:\n'
       '            self.log("stop requested by SIG%s" % self.stop_signal)\n'
       '            return False',
       '        if False:\n            return False'),)),
    ('run_load.py', 'test_run_load', 'no handler for HUP',
     (('((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP"))',
       '((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"))'),)),
    ('run_load.py', 'test_run_load', 'no handler for INT',
     (('((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP"))',
       '((signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP"))'),)),
    ('run_load.py', 'test_run_load', 'no handler for TERM',
     (('((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP"))',
       '((signal.SIGINT, "INT"), (signal.SIGHUP, "HUP"))'),)),
    ('run_load.py', 'test_run_load', 'the handler names the wrong signal',
     (('lambda *_args, name=name: self.request_stop(name)',
       'lambda *_args, name=name: self.request_stop("INT")'),)),
    ('run_load.py', 'test_run_load', 'the last signal is kept, not the first',
     (('        if self.stop_signal is None:\n            self.stop_signal = name',
       '        self.stop_signal = name'),)),
    ('run_load.py', 'test_run_load', '--max-seconds can lengthen',
     (('if max_seconds is not None and not 0 < max_seconds <= bound:',
       'if max_seconds is not None and not 0 < max_seconds:'),)),
    ('run_load.py', 'test_run_load', 'any number of workers',
     (('if not 1 <= workers <= MAX_WORKERS:', 'if not 1 <= workers:'),)),
    ('run_load.py', 'test_run_load', 'workers inherit stdin',
     (('                    self.worker_argv, stdin=subprocess.DEVNULL, stdout=',
       '                    self.worker_argv, stdout='),)),
    ('run_load.py', 'test_run_load', 'CTX stamp to the second',
     (('return "%.3f CTX %s\\n" % (wall, body)', 'return "%d CTX %s\\n" % (wall, body)'),)),
    ('run_load.py', 'test_run_load', 'CTX load-start without step=',
     (('self.ctx("load-start step=%s" % self.config.mode)',
       'self.ctx("load-start %s" % self.config.mode)'),)),
    ('run_load.py', 'test_run_load', 'CTX load-stop misspelt',
     (('self.ctx("load-stop")', 'self.ctx("load stop")'),)),
    ('run_load.py', 'test_run_load', 'the P1 worker command changed',
     (('WORKER_ARGV = ("/bin/sh", "-c", "while :; do :; done")',
       'WORKER_ARGV = ("/bin/sh", "-c", "while true; do :; done")'),)),
    ('run_load.py', 'test_run_load', 'the pid file is not claimed',
     (('            self.claim_pid_file()\n', '            pass\n'),)),
    ('restart-record.sh', 'test_restart_record', 'CTX end written after the recorders, not before',
     (('echo "$STAMP CTX end" > "$DIR/phases.log"\n', ''),
      ('echo $! > "$DIR/watcher-down.pid"\n',
       'echo $! > "$DIR/watcher-down.pid"\necho "$STAMP CTX end" > "$DIR/phases.log"\n'))),
    ('restart-record.sh', 'test_restart_record', 'no plain note after CTX end',
     (('echo "$(date -u +%FT%TZ) restart-record.sh: CTX end is first because',
       ': "$(date -u +%FT%TZ) restart-record.sh: CTX end is first because'),)),
    ('restart-record.sh', 'test_restart_record', 'CTX armed, not CTX end',
     (('echo "$STAMP CTX end" > ', 'echo "$STAMP CTX armed" > '),)),
    ('restart-record.sh', 'test_restart_record', 'the pinned sampler hash is not checked',
     (('[ "$GOT" = "$SAMPLER_SHA256" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record', "the log stream's process clause dropped",
     ((' AND process == "AeolusHelper"\'', "'"),)),
    ('restart-record.sh', 'test_restart_record', 'the fan sampler at 2 Hz',
     (('--interval=0.1 --keys', '--interval=0.5 --keys'),)),
    ('restart-record.sh', 'test_restart_record', 'the package sampler at 0.5 Hz',
     (('--interval=1 > "$DIR/package-1hz.ndjson"', '--interval=2 > "$DIR/package-1hz.ndjson"'),)),
    ('restart-record.sh', 'test_restart_record', 'a key missing from the fan sampler',
     (('F0Tg,F1Tg,F0Ac,F1Ac >', 'F0Tg,F1Tg,F0Ac >'),)),
    ('restart-record.sh', 'test_restart_record', 'the watcher without -I',
     (('"$PYTHON" -I "$WATCH_DIR/run_watch.py"', '"$PYTHON" "$WATCH_DIR/run_watch.py"'),)),
    ('restart-record.sh', 'test_restart_record', "the watcher watches the first record's directory",
     (('--dir "$DIR" >> "$DIR/watch.log"', '--dir "$CAPTURES/run1" >> "$DIR/watch.log"'),)),
    ('restart-record.sh', 'test_restart_record', "the watcher's pid file under another name",
     (('echo $! > "$DIR/watch.pid"', 'echo $! > "$DIR/watcher.pid"'),)),
    ('restart-record.sh', 'test_restart_record', 'an existing directory is reused',
     (('while ! mkdir "$CAPTURES/run1-$N" 2>/dev/null; do',
       'while ! mkdir -p "$CAPTURES/run1-$N" 2>/dev/null; do'),)),
    ('restart-record.sh', 'test_restart_record', 'the numbering starts at 2',
     (('N=1\nwhile', 'N=2\nwhile'),)),
    ('restart-record.sh', 'test_restart_record',
     'a process that is not running does not change the exit status',
     (('    STATUS=1\n', '    STATUS=0\n'),)),
    ('restart-record.sh', 'test_restart_record', 'every process is reported running',
     (('if kill -0 "$PID" 2>/dev/null; then', 'if true; then'),)),
    ('restart-record.sh', 'test_restart_record', 'the watcher sha is not validated',
     (('  *[!0-9a-zA-Z._-]*) die "--watcher-sha may hold only letters, digits, \'.\', \'_\' and '
       '\'-\'" ;;',
       '  *[!0-9a-zA-Z._-]*) ;;'),)),
    ('restart-record.sh', 'test_restart_record', 'the sampler need not be executable',
     (('[ -x "$SAMPLER" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record', 'the watcher need not be there',
     (('[ -f "$WATCH_DIR/run_watch.py" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record', 'the companion need not be there',
     (('[ -f "$WATCH_DIR/watcher-down.sh" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record', 'the interpreter need not be there',
     (('[ -x "$PYTHON" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record', 'the captures directory need not be there',
     (('[ -d "$CAPTURES" ] ||', 'true ||'),)),
    ('restart-record.sh', 'test_restart_record',
     'a CTX line that cannot be stamped is written anyway',
     (('  *) rmdir "$DIR"; die "could not stamp the CTX line" ;;', '  *) ;;'),)),
    ('restart-record.sh', 'test_restart_record', 'a running sampler is not warned about',
     (('if [ -n "$RUNNING" ]; then', 'if false; then'),)),
    ('restart-record.sh', 'test_restart_record', 'no wait before the liveness check',
     (('\nsleep 1\nSTATUS=0', '\nsleep 0\nSTATUS=0'),)),
]


def tool_text(filename, edits):
    """The tool's source with every edit applied; each old text must be in it exactly once."""
    with open(os.path.join(HERE, filename), encoding="utf-8") as handle:
        text = handle.read()
    for old, new in edits:
        if text.count(old) != 1:
            raise LookupError("%s: %r occurs %d times" % (filename, old[:60], text.count(old)))
        text = text.replace(old, new)
    return text


def check_tool_mutations():
    """Every tool mutation applied in memory before anything runs, as `check_mutations` does."""
    stale = []
    for filename, _, label, edits in TOOL_MUTANTS:
        try:
            tool_text(filename, edits)
        except LookupError as error:
            stale.append("  %s: %s" % (label, error))
    if stale:
        raise SystemExit("stale tool mutations:\n%s" % "\n".join(stale))
    return len(TOOL_MUTANTS)


def tools_sweep(mutations):
    """Each tool mutation in a private copy of this directory, against that tool's tests alone.
    Every one must go red; none of these runs the smoke test (which is not a `test_*` module)."""
    print("tools  the load driver's and the record restart's guards: every one must go red")
    print()
    print("| mutation | tests failed | result |")
    print("|---|---|---|")
    allok = True
    with mutate.Sweep(mutations) as sweep:
        for index, (filename, module, label, edits) in enumerate(TOOL_MUTANTS):
            target = os.path.join(sweep.directory, "tool-%d" % index)
            shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(HERE, target, ignore=shutil.ignore_patterns("__pycache__"))
            with open(os.path.join(target, filename), "w", encoding="utf-8") as handle:
                handle.write(tool_text(filename, edits))
            try:
                result = subprocess.run(
                    [sys.executable, "-I", "-m", "unittest", "discover", "-s", ".", "-p", module + ".py"],
                    cwd=target, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, timeout=180, check=False)
                text = result.stdout.decode("utf-8", "replace")
                ran = any(line.startswith("Ran ") for line in text.splitlines())
                failed = [l.split(" ")[1] for l in text.splitlines() if l.startswith(("FAIL:", "ERROR:"))]
                ok = ran and result.returncode != 0 and bool(failed)
            except subprocess.TimeoutExpired:  # a test that hangs is not green, but it should fail fast
                failed, ok = ["(hung for 180 s)"], True
            allok = allok and ok
            print("| %s: %s | %d: %s | %s |" % (
                filename, label, len(failed), ", ".join(dict.fromkeys(failed[:2])) + (" ..." if len(failed) > 2 else ""),
                "red" if ok else "STILL GREEN"))
            shutil.rmtree(target, ignore_errors=True)
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
    if "tools" in args.parts:
        print("tool mutations: all %d applied to the tools' text before anything runs" % check_tool_mutations())
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
        elif part == "tools":
            results[part] = tools_sweep(args.mutations)
        else:
            raise SystemExit("unknown part %r" % part)
        print()
    print("summary: " + ", ".join("%s %s" % (k, "PASS" if v else "FAIL") for k, v in results.items()))
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
