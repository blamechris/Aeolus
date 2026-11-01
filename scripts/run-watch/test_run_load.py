"""The load driver, on a fake clock with fake workers.

No test here starts a load generator. The driver is given a worker command and a spawner, and the
tests give it a fake one; the processes that do start (a few tests run the driver as a real
process, to see its signal handlers work) run `/bin/sleep`, which uses no CPU. The one real load,
two busy loops for two seconds, is `smoke_run_load.py`, and runs once, on request.

Each test has its control on the other side of the threshold it pins, because a test that only
shows the load starting cannot tell a bound from a constant."""

import builtins
import contextlib
import glob
import io
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import run_load as rl
import run_watch as rw
import synth
from support import captures_dir

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = synth.T0  # an integer second, so a whole-second `at` is exact
FAKE_ARGV = ("fake-worker", "--spin")


#: The `started` line that docs/CLI.md (at 4c7b62a, `fanctl set --json`) prints as its example,
#: verbatim: the real shape of the event the driver reads, not one made to suit it.
DOCUMENTED_STARTED = (
    "{\"at\":\"2026-10-07T23:24:57Z\",\"durationSeconds\":20,\"event\":\"started\",\"fans\":[{\"commandedRPM"
    "\":4670,\"index\":0,\"observed\":{\"actualRPM\":{\"unavailableReason\":null,\"value\":1350},\"firmware"
    "Name\":null,\"index\":0,\"isReclaimedBySystem\":false,\"manualControl\":{\"advice\":null,\"reason\":n"
    "ull,\"state\":\"available\",\"summary\":null},\"maximumRPM\":{\"unavailableReason\":null,\"value\":577"
    "7},\"minimumRPM\":{\"unavailableReason\":null,\"value\":1350},\"mode\":\"manualFixed\",\"targetRPM\":4"
    "670},\"requested\":{\"unit\":\"percent\",\"value\":75}}],\"leaseID\":\"FEDA5A4F-912F-49CB-84B7-512889"
    "10401A\",\"schema\":1}")


def iso_seconds(t):
    """`fanctl set --json`'s `at`: UTC to the second."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def exists(directory, name):
    return os.path.exists(os.path.join(directory, name))


class FakeClock(rl.Clock):
    """Both clocks, moved only by `sleep`, with a hook that runs after each step."""

    def __init__(self, wall=T0, on_sleep=None):
        # Offsets are kept apart from the (1.76e9) epoch, so that thousands of 0.05 s steps do not
        # lose a millisecond to the float's spacing at that size.
        self.base_w, self.base_m, self.ow, self.om, self.on_sleep = wall, 5000.0, 0.0, 0.0, on_sleep
        self.sleeps = 0

    @property
    def w(self):
        return self.base_w + self.ow

    @w.setter
    def w(self, value):
        self.ow = value - self.base_w

    @property
    def m(self):
        return self.base_m + self.om

    @m.setter
    def m(self, value):
        self.om = value - self.base_m

    def wall(self):
        return self.w

    def mono(self):
        return self.m

    def sleep(self, seconds):
        self.sleeps += 1
        if self.sleeps > 100000:  # a driver that never stops fails the test; it does not hang it
            raise AssertionError("the driver was still waiting after 5,000 simulated seconds")
        self.ow += seconds
        self.om += seconds
        if self.on_sleep:
            self.on_sleep(self)

    def since(self, t=T0):
        return self.ow + (self.base_w - t)


class FakeWorker:
    def __init__(self, pid, ignores_term=False, immortal=False, slow=None):
        self.pid, self.returncode = pid, None
        self.ignores_term, self.immortal = ignores_term, immortal
        self.slow, self.dies_at = slow, None  # (clock, seconds): obedient, but not at once
        self.terminated = self.killed = self.polls = 0

    def poll(self):
        self.polls += 1
        if self.dies_at is not None and self.slow[0].mono() >= self.dies_at:
            self.returncode = -signal.SIGTERM
        return self.returncode

    def terminate(self):
        self.terminated += 1
        if self.slow is not None:
            self.dies_at = self.slow[0].mono() + self.slow[1]
        elif not (self.ignores_term or self.immortal):
            self.returncode = -signal.SIGTERM

    def kill(self):
        self.killed += 1
        if not self.immortal:
            self.returncode = -signal.SIGKILL


class FakeSpawner:
    """What the driver starts its workers with. It records each worker, and can look at the world
    as each is started (`on_spawn`), refuse the Nth (`fail_at`), or make one stubborn."""

    def __init__(self, ignores_term=(), immortal=(), fail_at=None, on_spawn=None, slow=None):
        self.workers, self.calls = [], []
        self.ignores_term, self.immortal = set(ignores_term), set(immortal)
        self.fail_at, self.on_spawn = fail_at, on_spawn
        self.slow = slow  # (clock, seconds) for every worker

    def __call__(self, argv, **kwargs):
        index = len(self.workers)
        if self.on_spawn:
            self.on_spawn(index)
        if self.fail_at == index:
            raise OSError("fork: Resource temporarily unavailable")
        self.calls.append((tuple(argv), kwargs))
        worker = FakeWorker(
            5000 + index, index in self.ignores_term, index in self.immortal, self.slow)
        self.workers.append(worker)
        return worker


class Feeder:
    """Appends fan samples (and `set --json` lines) to the files as the fake clock passes their
    stamps, as the recorder and `tee` would. `values(t)` is the sample's readings (None for no
    sample); `sets` is a list of (time, event line)."""

    def __init__(self, directory, values, sets=(), step=0.1, late=()):
        self.fans = os.path.join(directory, "fans-10hz.ndjson")
        self.set = os.path.join(directory, "set-1d.ndjson")
        self.values, self.sets, self.step = values, sorted(sets, key=lambda s: s[0]), step
        self.late = sorted(late, key=lambda s: s[0])  # (when appended, the line): out of order
        self.k = 1

    def prime(self, seconds=60, **values):
        """History written before the driver is armed: the driver must not read it."""
        with open(self.fans, "w", encoding="utf-8") as handle:
            for i in range(int(seconds * 10)):
                t = T0 - seconds + i * 0.1
                handle.write(synth._line(synth.fan_record(t, i, values)) + "\n")

    def __call__(self, clock):
        lines = []
        while T0 + self.k * self.step <= clock.w + 1e-6:
            t = T0 + self.k * self.step
            readings = self.values(t)
            if readings is not None:
                lines.append(synth._line(synth.fan_record(t, self.k, readings)))
            self.k += 1
        if lines:
            with open(self.fans, "a", encoding="utf-8") as handle:
                handle.write("".join(line + "\n" for line in lines))
        while self.sets and self.sets[0][0] <= clock.w + 1e-6:
            with open(self.set, "a", encoding="utf-8") as handle:
                handle.write(self.sets.pop(0)[1] + "\n")
        while self.late and self.late[0][0] <= clock.w + 1e-6:
            with open(self.fans, "a", encoding="utf-8") as handle:
                handle.write(self.late.pop(0)[1] + "\n")


_DEFAULT = object()


def started_line(at, rpm=5777, fans=_DEFAULT):
    """`fanctl set --json`'s started event, to the keys the driver reads and a few it does not.
    `fans` replaces the whole fans value (docs/CLI.md: a list of `index`, `commandedRPM`,
    `requested`, `observed`)."""
    if fans is _DEFAULT:
        fans = [{"commandedRPM": rpm, "index": 0, "requested": {"unit": "percent", "value": 100}}]
    return json.dumps({"at": iso_seconds(at), "durationSeconds": 120, "event": "started",
                       "fans": fans, "leaseID": "x", "schema": 1},
                      sort_keys=True, separators=(",", ":"))


def event_line(event, at):
    return json.dumps({"at": iso_seconds(at), "event": event, "schema": 1},
                      sort_keys=True, separators=(",", ":"))


HELD = {"F0Md": 1, "Ftst": 1}  # a held fan: raw mode 1, the force key set (ADR 0014)
AT_REST = {"F0Md": 3, "Ftst": 0}  # what a fan nobody manages reads on this Mac


def target_from(start, rpm=5777.0, f1_from=None, until=None, f1=1500.0, gaps=(), held=HELD,
                released=AT_REST):
    """A fan held on `rpm` from `start` (to `until`): the mode and `Ftst` of `held`, F0Tg `rpm`.
    Otherwise `released`'s. F1Tg reads `f1` from `f1_from`. Pass `held=AT_REST` for a target that
    reads right and a mode that never does."""

    def values(t):
        if any(a <= t < b for a, b in gaps):
            return None
        on = t >= start and (until is None or t < until)
        return dict(held if on else released, F0Tg=rpm if on else 0.0,
                    F1Tg=f1 if f1_from is not None and t >= f1_from else 0.0)

    return values


class Base(unittest.TestCase):
    def setUp(self):
        self.fresh()

    def between(self, value, low, high):
        """`low <= value <= high`, to a microsecond: the fake clock adds 0.05 s thousands of times."""
        self.assertTrue(low - 1e-6 <= value <= high, "%r is not in [%r, %r]" % (value, low, high))

    def fresh(self):
        """A new, empty capture directory (a test that runs the driver twice wants two)."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.dir = directory.name

    def drive(self, mode, spawner=None, clock=None, **cfg):
        self.spawner = spawner or FakeSpawner()
        self.clock = clock or FakeClock()
        config = rl.make_config(mode, self.dir, **cfg)
        self.echoed = []
        self.driver = rl.Driver(config, FAKE_ARGV, self.clock, self.spawner, echo=self.echoed.append)
        self.code = self.driver.run()
        return self.code

    def phases(self):
        path = os.path.join(self.dir, "phases.log")
        return read(path).splitlines() if os.path.exists(path) else []

    def ctx(self, kind):
        found = []
        for line in self.phases():
            parsed = rw.parse_ctx_line(line)
            if parsed is not None and parsed.kind == kind:
                found.append(parsed)
        return found

    def log(self, mode="1b"):
        return read(os.path.join(self.dir, "load-%s.log" % mode))


class Load1b(Base):
    def test_it_writes_load_start_before_it_forks_and_each_pid_as_its_worker_starts(self):
        snapshots = []

        def on_spawn(index):
            snapshots.append((
                self.phases(), read(os.path.join(self.dir, "busy-1b.pids")).split()
                if exists(self.dir, "busy-1b.pids") else None,
                read(os.path.join(self.dir, "load.pid")).split()))

        self.drive("1b", FakeSpawner(on_spawn=on_spawn), max_seconds=1)
        self.assertEqual(len(snapshots), 16)
        for index, (phases, pids, load_pid) in enumerate(snapshots):
            self.assertEqual([l.split(" ", 1)[1] for l in phases], ["CTX load-start step=1b"], index)
            self.assertEqual(load_pid, [str(os.getpid())])  # its own PID is in place before any worker
            if index:
                self.assertEqual(pids, [str(5000 + i) for i in range(index)], index)  # one per line
        self.assertEqual(read(os.path.join(self.dir, "busy-1b.pids")).split(), [str(5000 + i) for i in range(16)])

    def test_sixteen_workers_by_default_each_the_given_command_and_no_other(self):
        self.drive("1b", max_seconds=1)
        self.assertEqual(len(self.spawner.workers), 16)
        self.assertEqual({argv for argv, _ in self.spawner.calls}, {FAKE_ARGV})
        self.assertEqual(rl.P1_LOOP, ("/bin/sh", "-c", "while :; do :; done"))  # P1's load
        self.drive("1b", max_seconds=1, workers=3)
        self.assertEqual(len(self.spawner.workers), 3)

    def test_the_workers_get_no_input_and_no_output_to_inherit(self):
        self.drive("1b", max_seconds=1, workers=1)
        kwargs = self.spawner.calls[0][1]
        self.assertEqual(kwargs, {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                                  "stderr": subprocess.DEVNULL})

    def test_it_stops_itself_at_600_s_and_not_before(self):
        seen = {}

        def on_sleep(clock):
            if 599.0 <= clock.since() < 599.5:
                seen["alive_at_599"] = all(w.poll() is None for w in self.spawner.workers)

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep))
        self.assertTrue(seen["alive_at_599"])
        self.between(self.clock.since(), 600.0, 600.3)
        self.assertEqual(self.code, rl.EXIT_OK)
        self.assertTrue(all(w.terminated == 1 and w.killed == 0 for w in self.spawner.workers))

    def test_the_bound_runs_from_the_load_start_not_the_driver_start(self):
        # started 30 s late (the clock moves before the load does): 600 s from the load
        clock = FakeClock()
        original = rl.Driver.start_load

        def late(driver):
            clock.w += 30
            clock.m += 30
            return original(driver)

        with mock.patch.object(rl.Driver, "start_load", late):
            self.drive("1b", clock=clock)
        self.between(self.clock.since(), 630.0, 630.3)

    def test_either_clock_passing_the_bound_stops_it(self):
        # the Mac sleeps: the wall clock jumps, the monotonic clock does not. Or the wall clock
        # is set back and the monotonic clock carries on.
        for which in ("w", "m"):
            with self.subTest(clock=which):
                self.fresh()

                jumped = []

                def on_sleep(clock, which=which):
                    if not jumped and clock.ow >= 100:
                        jumped.append(True)
                        setattr(clock, which, getattr(clock, which) + 600)

                self.drive("1b", clock=FakeClock(on_sleep=on_sleep))
                self.assertLess(self.clock.sleeps, 2100)  # 100 s of ticks, and no more
                self.assertTrue(self.phases()[-1].endswith("CTX load-stop"))
        # the control: a wall clock set BACK does not lengthen the load past the monotonic bound
        self.fresh()
        jumped = []

        def back(clock):
            if not jumped and clock.ow >= 100:
                jumped.append(True)
                clock.w -= 5000

        self.drive("1b", clock=FakeClock(on_sleep=back))
        self.assertTrue(self.phases()[-1].endswith("CTX load-stop"))
        self.assertLess(self.clock.sleeps, 12100)  # 600 s of ticks (the monotonic clock's), not 5600 more

    def test_max_seconds_can_shorten_the_bound_and_not_lengthen_it(self):
        self.drive("1b", max_seconds=5)
        self.between(self.clock.since(), 5.0, 5.3)
        with self.assertRaises(ValueError):
            rl.make_config("1b", self.dir, max_seconds=601)
        with self.assertRaises(ValueError):
            rl.make_config("1d", self.dir, max_seconds=81)
        with self.assertRaises(ValueError):
            rl.make_config("1b", self.dir, max_seconds=0)
        self.assertEqual(rl.make_config("1b", self.dir, max_seconds=600).max_seconds, 600.0)
        self.fresh()
        for argv in (["--mode", "1b", "--max-seconds", "601"], ["--mode", "1c"],
                     ["--mode", "1b", "--workers", "0"], ["--mode", "1b", "--workers", "33"]):
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                rl.main(argv + ["--dir", self.dir], worker_argv=FAKE_ARGV, install_signals=False)
            self.assertEqual(raised.exception.code, 2)
            self.assertFalse(exists(self.dir, "phases.log"))

    def test_a_stop_request_stops_it_within_a_poll_and_says_load_stop(self):
        for name in ("INT", "TERM", "HUP"):
            with self.subTest(signal=name):
                self.fresh()

                def on_sleep(clock, name=name):
                    if clock.since() >= 30:
                        self.driver.request_stop(name)

                self.drive("1b", clock=FakeClock(on_sleep=on_sleep))
                self.between(self.clock.since(), 30.0, 30.2)
                self.assertEqual(self.code, rl.EXIT_OK)
                self.assertTrue(all(w.returncode is not None for w in self.spawner.workers))
                self.assertEqual([c.kind for c in map(rw.parse_ctx_line, self.phases())], ["load-start", "load-stop"])
                self.assertIn("stop requested by SIG" + name, self.log())

    def test_the_signal_handlers_are_installed_for_int_term_and_hup(self):
        with mock.patch.object(signal, "signal") as install:
            driver = rl.Driver(rl.make_config("1b", self.dir), FAKE_ARGV, FakeClock(), FakeSpawner())
            driver.install_signals()
        handlers = {call.args[0]: call.args[1] for call in install.call_args_list}
        self.assertEqual(set(handlers), {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        for number, name in ((signal.SIGINT, "INT"), (signal.SIGTERM, "TERM"), (signal.SIGHUP, "HUP")):
            with mock.patch.object(signal, "signal") as again:
                fresh = rl.Driver(rl.make_config("1b", self.dir), FAKE_ARGV, FakeClock(), FakeSpawner())
                fresh.install_signals()
            handler = {c.args[0]: c.args[1] for c in again.call_args_list}[number]
            handler(number, None)  # the handler does nothing but note which signal it was
            self.assertEqual(fresh.stop_signal, name)
        driver.request_stop("INT")
        driver.request_stop("TERM")
        self.assertEqual(driver.stop_signal, "INT")  # the first one is the one that is kept

    def test_a_worker_that_ignores_sigterm_is_killed_and_only_that_one(self):
        self.drive("1b", FakeSpawner(ignores_term={3}), max_seconds=1)
        self.assertEqual([w.killed for w in self.spawner.workers], [0, 0, 0, 1] + [0] * 12)
        self.assertEqual(self.code, rl.EXIT_OK)
        self.assertTrue(self.phases()[-1].endswith("CTX load-stop"))
        self.assertIn("pid 5003 ignored SIGTERM", self.log())

    def test_a_worker_that_exits_within_the_grace_is_not_killed(self):
        clock = FakeClock()
        self.drive("1b", FakeSpawner(slow=(clock, 1.0)), clock=clock, max_seconds=1)
        self.assertEqual({w.killed for w in self.spawner.workers}, {0})
        self.assertEqual({w.terminated for w in self.spawner.workers}, {1})
        self.assertTrue(self.phases()[-1].endswith("CTX load-stop"))

    def test_a_worker_that_has_already_exited_is_not_signalled_again(self):
        # its PID may be somebody else's by now: a handle that has been reaped is never signalled
        def on_sleep(clock):
            if clock.since() >= 0.5:
                self.spawner.workers[2].returncode = 1

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep), max_seconds=1)
        self.assertEqual((self.spawner.workers[2].terminated, self.spawner.workers[2].killed), (0, 0))
        self.assertEqual({w.terminated for i, w in enumerate(self.spawner.workers) if i != 2}, {1})

    def test_workers_killed_from_outside_end_the_driver_within_a_poll_and_say_load_stop(self):
        # the runbook's T6 and L2: `kill $(cat busy-1b.pids)`. With nothing to run, the load has
        # stopped; the old driver sat on to its 600 s bound and wrote load-stop then.
        def on_sleep(clock):
            if clock.since() >= 30:
                for worker in self.spawner.workers:
                    if worker.returncode is None:
                        worker.returncode = -signal.SIGTERM

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep))
        self.assertEqual(self.code, rl.EXIT_OK)
        self.between(self.ctx("load-stop")[0].t - T0, 30.0, 30.2)
        self.assertIn("every worker has exited (return codes -15): no load is left", self.log())
        self.assertEqual({(w.terminated, w.killed) for w in self.spawner.workers}, {(0, 0)})
        self.assertFalse(exists(self.dir, "load.pid"))

    def test_some_workers_killed_from_outside_do_not_end_it_and_every_one_is_still_polled(self):
        # worker 0 lives; worker 5 is killed at 30 s. The driver goes on to its bound, and the
        # killed one is polled on every tick, which is what reaps it (a <defunct> is L3's failure).
        seen = {}

        def on_sleep(clock):
            if 30 <= clock.since() < 30.05:
                self.spawner.workers[5].returncode = -signal.SIGKILL
                seen["at_kill"] = self.spawner.workers[5].polls
            if 31 <= clock.since() < 31.05:
                seen["a_second_later"] = self.spawner.workers[5].polls

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep), max_seconds=40)
        self.between(self.clock.since(), 40.0, 40.3)
        self.assertGreaterEqual(seen["a_second_later"] - seen["at_kill"], 15)
        self.assertNotIn("every worker has exited", self.log())
        self.assertTrue(self.phases()[-1].endswith("CTX load-stop"))

    def test_a_driver_whose_workers_all_died_on_their_own_says_so_and_still_stops(self):
        # a crashed worker command, say: nothing runs, and the record must not say it does
        def on_sleep(clock):
            if clock.since() >= 5:
                for worker in self.spawner.workers:
                    worker.returncode = 127

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep))
        self.between(self.clock.since(), 5.0, 5.2)
        self.assertIn("return codes 127", self.log())
        self.assertEqual([c.kind for c in map(rw.parse_ctx_line, self.phases())], ["load-start", "load-stop"])

    def test_load_stop_is_not_written_while_a_worker_still_runs(self):
        self.drive("1b", FakeSpawner(immortal={2}), max_seconds=1)
        self.assertEqual(self.code, rl.EXIT_SURVIVOR)
        self.assertEqual([c.kind for c in map(rw.parse_ctx_line, self.phases())], ["load-start"])
        self.assertIn("STILL RUNNING after SIGKILL: [5002]", self.log())
        self.assertEqual(self.spawner.workers[2].killed, 1)

    def test_a_failed_fork_stops_the_workers_already_started_and_says_load_stop(self):
        with self.assertRaises(OSError):
            self.drive("1b", FakeSpawner(fail_at=5))
        self.assertEqual(len(self.spawner.workers), 5)
        self.assertTrue(all(w.returncode is not None for w in self.spawner.workers))
        self.assertEqual([c.kind for c in map(rw.parse_ctx_line, self.phases())], ["load-start", "load-stop"])
        self.assertFalse(exists(self.dir, "load.pid"))

    def test_it_kills_only_the_workers_it_started_and_by_no_pattern(self):
        calls = []
        forbidden = []

        def forbid(name):
            def refuse(*args, **kwargs):
                forbidden.append(name)
                raise AssertionError("the driver called %s" % name)
            return refuse

        gone = subprocess.Popen(["/usr/bin/true"])
        gone.wait()
        with open(os.path.join(self.dir, "load.pid"), "w", encoding="utf-8") as handle:
            handle.write("%d\n" % gone.pid)  # a dead driver's: the driver asks whether it is alive
        real_kill = os.kill
        patches = [mock.patch.object(os, "kill", lambda pid, sig: calls.append((pid, sig)) or real_kill(pid, sig))]
        for name in ("system", "killpg", "popen", "execv", "execvp", "fork", "posix_spawn"):
            if hasattr(os, name):
                patches.append(mock.patch.object(os, name, forbid("os." + name)))
        patches.append(mock.patch.object(subprocess, "run", forbid("subprocess.run")))
        patches.append(mock.patch.object(subprocess, "check_output", forbid("subprocess.check_output")))
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            self.drive("1b", max_seconds=1)
        self.assertEqual(forbidden, [])
        # the only real kill is `signal 0` on load.pid's holder; the workers are stopped through
        # their own handles
        self.assertEqual(calls, [(gone.pid, 0)])
        terminated = {w.pid for w in self.spawner.workers if w.terminated}
        self.assertEqual(terminated, {w.pid for w in self.spawner.workers})

    def test_it_writes_only_its_own_files(self):
        written = []
        real_open, real_os_open = builtins.open, os.open

        def recording_open(path, mode="r", *args, **kwargs):
            if any(flag in mode for flag in "wax+"):
                written.append(os.path.basename(str(path)))
            return real_open(path, mode, *args, **kwargs)

        def recording_os_open(path, flags, *args, **kwargs):
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
                written.append(os.path.basename(str(path)))
            return real_os_open(path, flags, *args, **kwargs)

        with mock.patch.object(rl, "open", recording_open, create=True), \
                mock.patch.object(os, "open", recording_os_open):
            self.drive("1b", max_seconds=1)
        self.assertEqual(set(written), {"load.pid", "busy-1b.pids", "load-1b.log", "phases.log"})
        self.assertEqual(sorted(os.listdir(self.dir)), ["busy-1b.pids", "load-1b.log", "phases.log"])

    def test_the_ctx_lines_are_the_watchers_grammar_stamped_as_the_runbook_stamps(self):
        self.drive("1b", max_seconds=1)
        lines = self.phases()
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertRegex(line, r"^\d{10}\.\d{3} CTX ")  # perl's printf "%.3f", time
        start, stop = (rw.parse_ctx_line(l) for l in lines)
        self.assertEqual((start.kind, start.step, start.bad_target), ("load-start", "1b", None))
        self.assertEqual(stop.kind, "load-stop")
        self.assertEqual(float(lines[0].split()[0]), start.t)
        self.assertLessEqual(start.t, stop.t)
        self.assertTrue(lines[0].endswith("CTX load-start step=1b"))
        self.assertTrue(lines[1].endswith("CTX load-stop"))

    def test_the_watcher_opens_a_load_window_on_its_lines_and_closes_the_rule_on_load_stop(self):
        # the driver's lines drive the watcher as the coordinator's would: the 74 C limit applies
        # between them (and on to the first step=none)
        from support import idle, replay, titles
        self.drive("1b", max_seconds=2)

        def with_heat(at):
            run = idle(30, hottest=40.0)
            for line in self.phases():
                parsed = rw.parse_ctx_line(line)
                run.add_ctx(parsed.t - T0, parsed.raw)
            return run.patch_hottest(at, at + 1, 75.0)

        self.assertEqual(titles(replay(with_heat(1.0))), ["ABORT 1"])  # inside the driver's window
        self.assertEqual(titles(replay(with_heat(10.0))), [])  # after its load-stop

    def test_it_does_not_start_if_it_cannot_write_the_ctx_line(self):
        os.mkdir(os.path.join(self.dir, "phases.log"))  # a directory where the file should be
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
        self.assertEqual(self.spawner.workers, [])
        self.assertIn("phases.log cannot take a CTX line", "".join(self.echoed))
        self.assertFalse(exists(self.dir, "load.pid"))

    def test_it_does_not_start_in_a_directory_that_is_not_there(self):
        self.dir = os.path.join(self.dir, "nowhere")
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
        self.assertEqual(self.spawner.workers, [])
        self.assertIn("nowhere is not a directory", "".join(self.echoed))

    def test_one_driver_at_a_time_and_a_dead_ones_pid_file_does_not_count(self):
        with open(os.path.join(self.dir, "load.pid"), "w", encoding="utf-8") as handle:
            handle.write("%d\n" % os.getpid())  # a process that is running: this one
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
        self.assertEqual(self.spawner.workers, [])
        self.assertFalse(exists(self.dir, "phases.log"))  # no CTX line was written
        self.assertEqual(read(os.path.join(self.dir, "load.pid")).split(), [str(os.getpid())])  # not removed
        gone = subprocess.Popen(["/usr/bin/true"])
        gone.wait()
        with open(os.path.join(self.dir, "load.pid"), "w", encoding="utf-8") as handle:
            handle.write("%d\n" % gone.pid)
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_OK)
        self.assertEqual(len(self.spawner.workers), 16)
        self.assertFalse(exists(self.dir, "load.pid"))  # and its own is removed when it ends

    def test_the_pid_file_is_removed_when_the_driver_ends_and_only_if_it_is_its_own(self):
        def on_sleep(clock):
            if clock.since() >= 1:
                with open(os.path.join(self.dir, "load.pid"), "w", encoding="utf-8") as handle:
                    handle.write("1\n")  # someone else's, now

        self.drive("1b", clock=FakeClock(on_sleep=on_sleep), max_seconds=2)
        self.assertEqual(read(os.path.join(self.dir, "load.pid")).split(), ["1"])


class Load1d(Base):
    """1d is armed before `set`, reads `started` from the --json file, and starts on F0Tg."""

    def run_1d(self, values, sets=(), prime=True, **cfg):
        feeder = Feeder(self.dir, values, sets)
        if prime:  # sixty seconds of history at the target: it is history, and must be ignored
            feeder.prime(60, F0Tg=5777.0, F1Tg=0.0, **HELD)
        clock = FakeClock(on_sleep=feeder)
        self.drive("1d", clock=clock, **cfg)
        return clock

    def load_start(self):
        found = self.ctx("load-start")
        return found[0].t - T0 if found else None

    def test_it_starts_when_f0tg_has_read_the_target_for_10_s_and_that_is_t_l(self):
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=5)
        t_l = self.load_start()
        self.between(t_l, 13.0, 13.2)  # 3 s + 10 s
        self.assertEqual(len(self.spawner.workers), 16)
        self.assertEqual([c.step for c in self.ctx("load-start")], ["1d"])
        self.assertEqual(self.phases()[0].split(" ", 2)[0], "%.3f" % (T0 + t_l))  # t_L is the stamp

    def test_it_does_not_start_on_history_written_before_it_was_armed(self):
        # `started` is already in the file, and a minute of samples at the target is there when it
        # arms: that minute is history. The samples since are off the target.
        with open(os.path.join(self.dir, "set-1d.ndjson"), "w", encoding="utf-8") as handle:
            handle.write(started_line(T0) + "\n")
        self.run_1d(lambda t: {"F0Tg": 0.0, "F1Tg": 0.0}, arm_timeout=20)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual(self.spawner.workers, [])
        self.assertEqual(self.phases(), [])

    def test_nine_seconds_is_not_ten(self):
        # the target is read from 3 s to 12.9 s and then not: no load, and a note when the window ends
        self.run_1d(target_from(T0 + 3, until=T0 + 12.9), sets=[(T0 + 2, started_line(T0 + 2))])
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.assertIn("NOT STARTED", self.log("1d"))
        self.assertIn("fan 0 had not read as held (F0Md 1, F0Tg 5777) for 10 s", self.log("1d"))

    def test_a_dip_restarts_the_10_seconds(self):
        values = target_from(T0 + 3)
        dip = lambda t: dict(values(t), F0Tg=0.0) if 8.0 <= t - T0 < 8.2 else values(t)
        self.run_1d(dip, sets=[(T0 + 2, started_line(T0 + 2))])
        self.between(self.load_start(), 18.2, 18.4)  # 10 s after 8.2 s

    def test_a_gap_in_the_record_restarts_the_10_seconds(self):
        self.run_1d(target_from(T0 + 3, gaps=[(T0 + 8, T0 + 11)]),
                    sets=[(T0 + 2, started_line(T0 + 2))])
        self.between(self.load_start(), 21.0, 21.3)  # 10 s after 11 s

    def test_the_target_is_read_to_within_one_rpm(self):
        for rpm, starts in ((5776.5, True), (5777.9, True), (5775.0, False), (5779.0, False)):
            with self.subTest(rpm=rpm):
                self.fresh()
                self.run_1d(target_from(T0 + 3, rpm=rpm), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
                self.assertEqual(self.load_start() is not None, starts)

    def test_it_starts_no_later_than_30_s_after_started_and_not_after(self):
        started = [(T0 + 2, started_line(T0 + 2))]
        # the dwell completes at 28.5 s after `started`: inside the window
        self.run_1d(target_from(T0 + 20.5), sets=started, max_seconds=2)
        self.between(self.load_start(), 30.5, 30.7)
        self.assertEqual(len(self.spawner.workers), 16)
        # at 31.5 s after `started`: past it. No load, a note, and an exit that says so.
        self.fresh()
        self.run_1d(target_from(T0 + 23.5), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.between(self.clock.since(), 32.0, 32.3)  # it stopped waiting at 30 s
        self.assertIn("NOT STARTED: ", self.log("1d"))
        self.assertIn("past its 30 s window", self.log("1d"))
        self.assertFalse(exists(self.dir, "busy-1d.pids"))
        self.assertFalse(exists(self.dir, "load.pid"))

    def test_a_dwell_that_a_late_sample_completes_after_the_window_does_not_start_it(self):
        # F0Tg is on its target from 22.0 s. The sample stamped 32.0 s, which would make the 10 s,
        # reaches the file at 32.05 s, 0.05 s after the window (`started` 2 s + 30 s) has closed:
        # the stamp is inside the window, the start would not be.
        late = synth._line(synth.fan_record(T0 + 32.0, 1, dict(HELD, F0Tg=5777.0, F1Tg=0.0)))
        feeder = Feeder(self.dir, target_from(T0 + 22, gaps=[(T0 + 31.95, T0 + 32.05)]),
                        sets=[(T0 + 2, started_line(T0 + 2))], late=[(T0 + 32.05, late)])
        self.drive("1d", clock=FakeClock(on_sleep=feeder), max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        # the control: the same sample, in time, starts it
        self.fresh()
        feeder = Feeder(self.dir, target_from(T0 + 22, gaps=[(T0 + 31.95, T0 + 32.05)]),
                        sets=[(T0 + 2, started_line(T0 + 2))], late=[(T0 + 31.95, late)])
        self.drive("1d", clock=FakeClock(on_sleep=feeder), max_seconds=2)
        self.assertEqual(len(self.spawner.workers), 16)

    def test_it_does_not_start_without_started_and_gives_up_at_the_arm_timeout(self):
        self.run_1d(target_from(T0 + 3), arm_timeout=30)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.between(self.clock.since(), 30.0, 30.2)
        self.assertIn("no `started` event within 30 s of arming", self.log("1d"))

    def test_either_clock_passing_the_arm_timeout_ends_the_wait(self):
        for which in ("w", "m"):
            with self.subTest(clock=which):
                self.fresh()

                def on_sleep(clock, which=which):
                    if 1.0 <= clock.since() < 1.1:
                        setattr(clock, which, getattr(clock, which) + 400)

                self.drive("1d", clock=FakeClock(on_sleep=on_sleep))
                self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
                self.assertLess(self.clock.sleeps, 100)  # it did not sit out the 300 s
                self.assertEqual(self.spawner.workers, [])

    def test_a_set_that_failed_before_started_means_no_load(self):
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 1, event_line("failed", T0 + 1))])
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.assertLess(self.clock.since(), 2.0)
        self.assertIn("`set` ended before `started` (failed)", self.log("1d"))

    def test_events_from_an_earlier_attempt_in_the_same_file_are_ignored(self):
        # 1d is repeated once from its entry, into the same file: the old failed event is old
        with open(os.path.join(self.dir, "set-1d.ndjson"), "w", encoding="utf-8") as handle:
            handle.write(started_line(T0 - 100) + "\n" + event_line("failed", T0 - 90) + "\n")
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.between(self.load_start(), 13.0, 13.2)
        # and an old `started` is not this attempt's: the deadline is not computed from it
        self.fresh()
        with open(os.path.join(self.dir, "set-1d.ndjson"), "w", encoding="utf-8") as handle:
            handle.write(started_line(T0 - 100) + "\n")
        self.run_1d(target_from(T0 + 3), arm_timeout=20)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual(self.spawner.workers, [])

    def test_a_file_the_tee_truncates_and_writes_again_is_read_again(self):
        path = os.path.join(self.dir, "set-1d.ndjson")
        with open(path, "w", encoding="utf-8") as handle:  # the earlier attempt's: short
            handle.write(started_line(T0 - 100) + "\n" + event_line("holding", T0 - 90) + "\n")

        def rewrite(clock):
            if 1.0 <= clock.since() < 1.1:
                with open(path, "w", encoding="utf-8") as handle:  # what `tee` does: longer
                    handle.write(started_line(T0 + 1) + "\n" + "".join(
                        event_line("holding", T0 + 1) + "\n" for _ in range(8)))

        feeder = Feeder(self.dir, target_from(T0 + 3))
        feeder.prime(60, F0Tg=5777.0, **HELD)
        self.drive("1d", clock=FakeClock(on_sleep=lambda c: (feeder(c), rewrite(c))), max_seconds=2)
        self.between(self.load_start(), 13.0, 13.2)

    def test_a_started_with_a_fractional_second_is_read(self):
        line = json.dumps({"at": iso_seconds(T0 + 2)[:-1] + ".250Z", "event": "started"})
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, line)], max_seconds=2)
        self.between(self.load_start(), 13.0, 13.2)

    def test_it_stops_20_s_after_f1tg_leaves_0(self):
        self.run_1d(target_from(T0 + 3, f1_from=T0 + 25), sets=[(T0 + 2, started_line(T0 + 2))])
        stop = self.ctx("load-stop")[0].t - T0
        self.between(stop, 45.0, 45.3)  # 25 s + 20 s; the 80 s bound is 93 s
        self.assertEqual(self.code, rl.EXIT_OK)
        self.assertIn("F1Tg left 0 at ", self.log("1d"))
        self.assertTrue(all(w.terminated for w in self.spawner.workers))

    def test_it_stops_at_80_s_if_f1tg_never_leaves_0(self):
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))])
        t_l = self.load_start()
        stop = self.ctx("load-stop")[0].t - T0
        self.between(stop - t_l, 80.0, 80.3)
        self.assertEqual(self.code, rl.EXIT_OK)
        self.assertIn("reached its bound of 80 s", self.log("1d"))

    def test_the_80_s_runs_from_t_l_and_a_f1tg_that_leaves_late_still_ends_at_80(self):
        self.run_1d(target_from(T0 + 3, f1_from=T0 + 100), sets=[(T0 + 2, started_line(T0 + 2))])
        self.between(self.ctx("load-stop")[0].t - T0 - self.load_start(), 80.0, 80.3)

    def test_f1tg_reading_above_0_at_t_l_counts_from_the_first_sample_after_it(self):
        # as the watcher reads it: the first sample after load-start that reads above 0
        self.run_1d(target_from(T0 + 3, f1_from=T0 + 5), sets=[(T0 + 2, started_line(T0 + 2))])
        stop = self.ctx("load-stop")[0].t - T0
        self.between(stop, 33.0, 33.3)  # the first sample after t_L (13 s) + 20 s

    def test_a_sample_stamped_before_t_l_is_not_after_the_load_started(self):
        # A sample with F1Tg above 0, stamped 12.5 s, is appended to the file only after the load
        # has started (a recorder's delay). It is not evidence about the load, which began at
        # 13 s: nothing leaves 0, and the bound ends the load.
        late = synth._line(synth.fan_record(T0 + 12.5, 1, dict(HELD, F0Tg=5777.0, F1Tg=1500.0)))
        feeder = Feeder(self.dir, target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))],
                        late=[(T0 + 14, late)])
        self.drive("1d", clock=FakeClock(on_sleep=feeder))
        self.between(self.ctx("load-stop")[0].t - T0 - self.load_start(), 80.0, 80.3)
        self.assertNotIn("F1Tg left 0", self.log("1d"))

    def test_a_stop_request_while_armed_means_no_load_and_no_ctx_line(self):
        def on_sleep(clock):
            if clock.since() >= 5:
                self.driver.request_stop("TERM")

        feeder = Feeder(self.dir, target_from(T0 + 3))
        self.drive("1d", clock=FakeClock(on_sleep=lambda c: (feeder(c), on_sleep(c))))
        self.assertEqual(self.code, rl.EXIT_OK)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.assertFalse(exists(self.dir, "load.pid"))
        self.assertLess(self.clock.since(), 5.3)
        self.assertIn("before the load started: no load", self.log("1d"))

    def test_a_stop_request_during_the_load_stops_it(self):
        def on_sleep(clock):
            if clock.since() >= 40:
                self.driver.request_stop("TERM")

        feeder = Feeder(self.dir, target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))])
        self.drive("1d", clock=FakeClock(on_sleep=lambda c: (feeder(c), on_sleep(c))))
        self.between(self.ctx("load-stop")[0].t - T0, 40.0, 40.3)

    def test_workers_killed_from_outside_end_a_1d_load_within_a_poll(self):
        def on_sleep(clock):
            if clock.since() >= 40:
                for worker in self.spawner.workers:
                    if worker.returncode is None:
                        worker.returncode = -signal.SIGTERM

        feeder = Feeder(self.dir, target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))])
        self.drive("1d", clock=FakeClock(on_sleep=lambda c: (feeder(c), on_sleep(c))))
        self.between(self.ctx("load-stop")[0].t - T0, 40.0, 40.2)
        self.assertEqual(self.code, rl.EXIT_OK)

    def test_samples_from_before_started_do_not_count_toward_the_dwell(self):
        # The sampler died at 15 s, after 12 s at the target, and `started` is read at 20 s. The
        # target is `started`'s to name, so nothing before it was a dwell on that target; and
        # nothing is recording now.
        self.run_1d(target_from(T0 + 3, gaps=[(T0 + 15, T0 + 1000)]), sets=[(T0 + 20, started_line(T0 + 20))])
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))

    def burst(self, arrives):
        """Samples stamped 3 s to 14 s, held on the target, that reach the file all at once at
        `arrives` seconds, with `started` read at 2 s and the sampler silent after them."""
        lines = [(T0 + arrives, synth._line(synth.fan_record(
            T0 + 3 + i / 10, i, dict(HELD, F0Tg=5777.0, F1Tg=0.0)))) for i in range(111)]
        feeder = Feeder(self.dir, lambda t: None, sets=[(T0 + 2, started_line(T0 + 2))], late=lines)
        self.drive("1d", clock=FakeClock(on_sleep=feeder), max_seconds=2)

    def test_a_dwell_that_is_over_by_the_samples_stamps_but_is_read_late_does_not_start_the_load(self):
        # the Mac slept, or the recorder's lines arrived in a burst: 11 s of samples held on the
        # target, the last of them stamped 11 s before they are read. They say the fan was held;
        # they do not say it is. A record that is not being written now is not evidence.
        self.burst(arrives=25)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        # the control: the same samples, read as they are written, start the load at once
        self.fresh()
        self.burst(arrives=14.5)
        self.between(self.load_start(), 14.5, 14.7)
        self.assertEqual(len(self.spawner.workers), 16)

    # ------------------------------------------------------------------ a held fan, and only that

    def test_a_hold_released_before_t_l_does_not_get_a_load(self):
        # Reviewer A's scenario, on a realistic held state: `started` at 2 s, fan 0 held on its
        # target (mode 1) from 3 s, the owner's reset at 6 s after an alert. `set` prints `failed`,
        # the mode returns to Apple's, and Apple has not yet rewritten the target (the ADR leaves
        # open whether it rewrites an unchanged one). At 13 s the old driver started sixteen
        # loops on a fan that had been released.
        def values(t):
            s = t - T0
            if s < 3:
                return dict(AT_REST, F0Tg=0.0, F1Tg=0.0)
            if s < 6:
                return dict(HELD, F0Tg=5777.0, F1Tg=0.0)
            return {"F0Md": 0, "Ftst": 0, "F0Tg": 5777.0, "F1Tg": 0.0}

        self.run_1d(values, sets=[(T0 + 2, started_line(T0 + 2)), (T0 + 6.2, event_line("failed", T0 + 6))],
                    max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.assertFalse(exists(self.dir, "busy-1d.pids"))
        self.assertLess(self.clock.since(), 7.0)  # it said so at once, and did not wait out the window

    def test_a_failed_or_ended_set_after_started_means_no_load_even_if_the_fan_still_reads_held(self):
        # the mode and target are read back a moment after the release: only the event says it
        for event in ("failed", "ended"):
            with self.subTest(event=event):
                self.fresh()
                self.run_1d(target_from(T0 + 3),
                            sets=[(T0 + 2, started_line(T0 + 2)), (T0 + 6.2, event_line(event, T0 + 6))],
                            max_seconds=2)
                self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
                self.assertEqual((self.spawner.workers, self.phases()), ([], []))
                self.assertIn("`set` ended (%s) 4.0 s after `started`, before the load started" % event,
                              self.log("1d"))

    def test_a_target_that_stays_after_the_mode_leaves_1_is_not_a_hold(self):
        # no event in the file yet, but the mode says the hold is gone: the dwell starts again
        values = target_from(T0 + 3, released=dict(F0Md=0, Ftst=0), until=T0 + 6)
        self.run_1d(lambda t: dict(values(t), F0Tg=5777.0) if t >= T0 + 3 else values(t),
                    sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.assertIn("fan 0 had not read as held", self.log("1d"))

    def test_a_target_on_its_number_with_a_mode_that_never_reads_1_never_starts_the_load(self):
        for mode in (3, 0, 2):
            with self.subTest(mode=mode):
                self.fresh()
                self.run_1d(target_from(T0 + 3, held=dict(F0Md=mode, Ftst=0)),
                            sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
                self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
                self.assertEqual((self.spawner.workers, self.phases()), ([], []))

    def test_one_sample_off_mode_1_restarts_the_10_seconds(self):
        # the target never leaves 5,777; the mode reads 3 for 0.2 s at 8 s
        values = target_from(T0 + 3)
        blip = lambda t: dict(values(t), F0Md=3) if 8.0 <= t - T0 < 8.2 else values(t)
        self.run_1d(blip, sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.between(self.load_start(), 18.2, 18.4)  # 10 s after 8.2 s

    def test_a_sample_with_no_mode_reading_is_not_held(self):
        # a reading that did not come back (the sampler's own "unavailable") says nothing about the
        # fan; it is not mode 1
        values = target_from(T0 + 3)
        blank = lambda t: dict(values(t), F0Md=None) if 8.0 <= t - T0 < 8.2 else values(t)
        self.run_1d(blank, sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.between(self.load_start(), 18.2, 18.4)

    def test_a_failed_set_after_the_load_started_stops_the_load(self):
        for event in ("failed", "ended"):
            with self.subTest(event=event):
                self.fresh()
                self.run_1d(target_from(T0 + 3),
                            sets=[(T0 + 2, started_line(T0 + 2)), (T0 + 20, event_line(event, T0 + 20))])
                self.assertEqual(self.code, rl.EXIT_OK)
                stop = self.ctx("load-stop")[0].t - T0
                self.between(stop, 20.0, 20.2)  # at once, not at the 80 s bound (93 s)
                self.assertIn("`set` ended (%s)" % event, self.log("1d"))
                self.assertIn("the hold is over, stopping", self.log("1d"))
                self.assertTrue(all(w.terminated for w in self.spawner.workers))
                self.assertFalse(exists(self.dir, "load.pid"))

    def test_a_holding_event_or_an_old_failed_one_does_not_stop_the_load(self):
        with open(os.path.join(self.dir, "set-1d.ndjson"), "w", encoding="utf-8") as handle:
            handle.write(event_line("failed", T0 - 90) + "\n")  # an earlier attempt's
        self.run_1d(target_from(T0 + 3),
                    sets=[(T0 + 2, started_line(T0 + 2)), (T0 + 20, event_line("holding", T0 + 20))])
        self.between(self.ctx("load-stop")[0].t - T0 - self.load_start(), 80.0, 80.3)
        self.assertIn("reached its bound of 80 s", self.log("1d"))

    # ------------------------------------------------------------------ the driver's inputs

    def test_a_started_dated_in_the_future_does_not_stretch_the_window(self):
        # `at` says +200, the file got it at +2: the window runs from the earlier, to +32. A dwell
        # that completes at +40 is too late; one that completes at +30.5 is not.
        self.run_1d(target_from(T0 + 30), sets=[(T0 + 2, started_line(T0 + 200))], max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))
        self.between(self.clock.since(), 32.0, 32.3)
        self.assertIn("its `at` says", self.log("1d"))
        self.fresh()
        self.run_1d(target_from(T0 + 20.5), sets=[(T0 + 2, started_line(T0 + 200))], max_seconds=2)
        self.between(self.load_start(), 30.5, 30.7)

    def test_a_started_whose_at_is_the_file_time_is_taken_as_it_is(self):
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.assertNotIn("its `at` says", self.log("1d"))
        self.assertIn("started at %.3f: the load must start by %.3f" % (T0 + 2, T0 + 32), self.log("1d"))

    def test_the_target_is_the_one_started_commanded_and_the_log_says_where_it_came_from(self):
        # `started` commands 4,000: the dwell waits for 4,000, whatever --target-rpm says
        self.run_1d(target_from(T0 + 3, rpm=4000.0), sets=[(T0 + 2, started_line(T0 + 2, rpm=4000))],
                    max_seconds=2)
        self.between(self.load_start(), 13.0, 13.2)
        self.assertIn("target 4000 RPM, from `started` (fans[0].commandedRPM); --target-rpm says 5777 "
                      "and differs: `started`'s is used", self.log("1d"))
        # the converse: --target-rpm's number on the fan is not the target when `started` says 4,000
        self.fresh()
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2, rpm=4000))], max_seconds=2)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual(self.spawner.workers, [])
        # agreement is logged as agreement
        self.fresh()
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.assertIn("target 5777 RPM, from `started` (fans[0].commandedRPM); --target-rpm agrees",
                      self.log("1d"))

    def test_a_started_with_no_usable_target_falls_back_to_the_flag_and_says_so(self):
        unusable = (
            [], [{"index": 1, "commandedRPM": 4000}], [{"index": 0}], [{"index": 0, "commandedRPM": 0}],
            [{"index": 0, "commandedRPM": -5}], [{"index": 0, "commandedRPM": "5777"}],
            [{"index": 0, "commandedRPM": True}], [{"index": True, "commandedRPM": 4000}],
            [{"index": False, "commandedRPM": 4000}], "none", None,
            ["not a fan"])
        for fans in unusable:
            with self.subTest(fans=fans):
                self.fresh()
                self.run_1d(target_from(T0 + 3), max_seconds=2,
                            sets=[(T0 + 2, started_line(T0 + 2, fans=fans))])
                self.between(self.load_start(), 13.0, 13.2)
                self.assertIn("target 5777 RPM, from --target-rpm: `started` carries no usable "
                              "fans[0].commandedRPM", self.log("1d"))
        self.fresh()  # no fans key at all
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, event_line("started", T0 + 2))], max_seconds=2)
        self.assertIn("from --target-rpm", self.log("1d"))
        self.between(self.load_start(), 13.0, 13.2)
        # JSON's NaN and Infinity are not numbers of RPM either
        for text in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(text=text):
                self.fresh()
                line = ('{"at":"%s","event":"started","fans":[{"commandedRPM":%s,"index":0}]}'
                        % (iso_seconds(T0 + 2), text))
                self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, line)], max_seconds=2)
                self.assertIn("from --target-rpm", self.log("1d"))
                self.between(self.load_start(), 13.0, 13.2)

    def test_the_target_flag_is_used_when_it_is_the_only_target(self):
        self.run_1d(target_from(T0 + 3, rpm=3455.0), target_rpm=3455.0, max_seconds=2,
                    sets=[(T0 + 2, started_line(T0 + 2, fans=[]))])
        self.between(self.load_start(), 13.0, 13.2)

    def test_every_numeric_flag_is_finite_and_in_range_or_the_driver_refuses_with_exit_2(self):
        bad = (("--target-rpm", ("nan", "inf", "-inf", "0", "-5", "499", "12001", "1e9")),
               ("--arm-timeout", ("nan", "inf", "-inf", "0", "-1", "0.5", "3601", "1e9")),
               ("--max-seconds", ("nan", "inf", "-inf", "0", "-1", "601")))
        for flag, values in bad:
            for value in values:
                with self.subTest(flag=flag, value=value):
                    self.fresh()
                    with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                        rl.main(["--mode", "1b", "--dir", self.dir, flag, value], worker_argv=FAKE_ARGV,
                                install_signals=False)
                    self.assertEqual(raised.exception.code, 2)
                    self.assertEqual(os.listdir(self.dir), [])  # nothing written, nothing forked
        for kwargs in ({"target_rpm": 500}, {"target_rpm": 12000}, {"arm_timeout": 1},
                       {"arm_timeout": 3600}, {"max_seconds": 0.5}):
            with self.subTest(ok=kwargs):
                rl.make_config("1d", self.dir, **kwargs)

    def test_the_pid_files_and_the_log_are_per_step(self):
        self.run_1d(target_from(T0 + 3), sets=[(T0 + 2, started_line(T0 + 2))], max_seconds=2)
        self.assertEqual(
            sorted(os.listdir(self.dir)),
            ["busy-1d.pids", "fans-10hz.ndjson", "load-1d.log", "phases.log", "set-1d.ndjson"])


class RealProcesses(Base):
    """The driver as the real process an operator starts, with `/bin/sleep` for the workers (it
    uses no CPU): its signal handlers, its children, and the bystander it must not touch."""

    def start(self, workers=3, mode="1b", extra=(), bounded=False, margin=None):
        """The driver as a real process, its workers `/bin/sleep 60`. With `bounded` they are
        `sleep` under the driver's own alarm wrapper (`margin` seconds past the bound, in place of
        the shipped 10); without it they are bare `sleep`."""
        argv = ["--mode", mode, "--dir", self.dir, "--workers", str(workers)] + list(extra)
        seam = "worker_loop=('/bin/sleep', '60')" if bounded else "worker_argv=('/bin/sleep', '60')"
        code = ("import sys; sys.path.insert(0, %r); import run_load; %s"
                "sys.exit(run_load.main(%r, %s))" % (
                    HERE, "run_load.ALARM_MARGIN_SECONDS = %d; " % margin if margin is not None else "",
                    argv, seam))
        self.driver_proc = subprocess.Popen(
            [sys.executable, "-I", "-c", code], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        self.addCleanup(self.reap)
        deadline = time.time() + 15
        while time.time() < deadline:
            path = os.path.join(self.dir, "busy-%s.pids" % mode)
            if os.path.exists(path) and len(read(path).split()) == workers:
                return [int(p) for p in read(path).split()]
            time.sleep(0.05)
        self.fail("the driver did not start its workers")

    def reap(self):
        """Whatever a failed test left: by PID, ours only."""
        if self.driver_proc.poll() is None:
            self.driver_proc.kill()
            self.driver_proc.wait()
        path = os.path.join(self.dir, "busy-1b.pids")
        if os.path.exists(path):
            for pid in read(path).split():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pid), signal.SIGKILL)

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def ps_listing(self, pids):
        """The owner's L3, as the runbook gives it: nothing listed means nothing is left."""
        result = subprocess.run(
            ["/bin/ps", "-o", "pid=,stat=,command=", "-p", ",".join(str(p) for p in pids)],
            stdin=subprocess.DEVNULL, capture_output=True, check=False)
        return result.stdout.decode().strip()

    def wait_for(self, predicate, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.02)
        return predicate()

    def test_workers_killed_by_pid_end_the_driver_leave_no_zombie_and_say_load_stop(self):
        # the runbook's T6, L2 by PID: `kill $(cat busy-1b.pids)`. The driver's bound is 600 s.
        pids = self.start()
        killed_at = time.time()
        for pid in pids:
            os.kill(pid, signal.SIGTERM)
        phases = os.path.join(self.dir, "phases.log")
        stopped = lambda: os.path.exists(phases) and "CTX load-stop" in read(phases)
        self.assertTrue(self.wait_for(stopped, 10), "no CTX load-stop within 10 s of the kill")
        self.assertLess(time.time() - killed_at, 5.0)  # one poll and a bit, not the bound
        self.assertEqual(self.ps_listing(pids), "")  # L3 passes: no worker, and no <defunct> either
        self.assertEqual(self.driver_proc.wait(timeout=10), 0)
        self.assertFalse(exists(self.dir, "load.pid"))
        self.assertIn("every worker has exited", read(os.path.join(self.dir, "load-1b.log")))

    def test_a_killed_workers_zombie_is_reaped_while_the_driver_is_still_running(self):
        pids = self.start(workers=3)
        os.kill(pids[2], signal.SIGKILL)  # one of three: the driver goes on
        time.sleep(0.6)
        self.assertEqual(self.ps_listing([pids[2]]), "")  # not <defunct>
        self.assertTrue(self.alive(pids[0]) and self.alive(pids[1]))
        self.assertIsNone(self.driver_proc.poll())

    def test_workers_of_a_sigkilled_driver_end_by_their_own_alarm(self):
        # Nothing can trap SIGKILL, so the driver cannot stop its workers then. Each worker has an
        # alarm of the bound (2 s, rounded up) plus a margin (here 1 s, not the shipped 10), and
        # that survives the exec. Nobody but the alarm ends them.
        pids = self.start(workers=3, extra=["--max-seconds", "2"], bounded=True, margin=1)
        started = time.time()
        self.driver_proc.kill()
        self.driver_proc.wait()
        time.sleep(0.5)
        self.assertTrue(all(self.alive(p) for p in pids), "a worker died with the driver")
        self.assertTrue(self.wait_for(lambda: not any(self.alive(p) for p in pids), 12),
                        "a worker outlived its alarm: %s" % self.ps_listing(pids))
        self.assertGreaterEqual(time.time() - started, 2.0)  # at N = 3 s, not before the bound
        listed = subprocess.run(["/usr/bin/pgrep", "-x", "sleep"], stdin=subprocess.DEVNULL,
                                capture_output=True, check=False).stdout.decode().split()
        self.assertEqual(set(map(str, pids)) & set(listed), set())  # pgrep says none is left
        self.assertEqual(self.ps_listing(pids), "")
        self.assertTrue(exists(self.dir, "load.pid"))  # the driver could not tidy: the alarm did

    def test_each_signal_stops_the_workers_writes_load_stop_and_leaves_a_bystander_alone(self):
        for name in ("SIGTERM", "SIGINT", "SIGHUP"):
            with self.subTest(signal=name):
                self.fresh()
                bystander = subprocess.Popen(["/bin/sleep", "60"], stdin=subprocess.DEVNULL)
                try:
                    pids = self.start()
                    load_pid = int(read(os.path.join(self.dir, "load.pid")))
                    self.assertEqual(load_pid, self.driver_proc.pid)
                    self.assertTrue(all(self.alive(p) for p in pids))
                    os.kill(load_pid, getattr(signal, name))  # the owner's L2
                    self.assertEqual(self.driver_proc.wait(timeout=15), 0)
                    self.assertFalse(any(self.alive(p) for p in pids), pids)
                    self.assertIsNone(bystander.poll())  # it kills nobody else's
                    self.assertFalse(exists(self.dir, "load.pid"))
                    self.assertEqual(
                        [c.kind for c in map(rw.parse_ctx_line, read(os.path.join(self.dir, "phases.log")).splitlines())],
                        ["load-start", "load-stop"])
                finally:
                    bystander.kill()
                    bystander.wait()
                    self.reap()


class WorkerCommand(Base):
    """Each worker bounds itself: P1's loop under a perl `alarm`."""

    PROGRAM = re.compile(r'alarm (\d+); exec ((?:"[^"]*"(?:, )?)+)')

    def argv(self, mode, **cfg):
        return rl.Driver(rl.make_config(mode, self.dir, **cfg), clock=FakeClock(), spawn=FakeSpawner()).worker_argv

    def test_the_default_worker_is_perl_with_an_alarm_past_the_bound_and_p1s_loop_unchanged(self):
        for mode, cfg, alarm in (("1b", {}, 610), ("1d", {}, 90), ("1b", {"max_seconds": 5}, 15),
                                 ("1d", {"max_seconds": 2.5}, 13), ("1b", {"max_seconds": 600}, 610)):
            with self.subTest(mode=mode, **cfg):
                argv = self.argv(mode, **cfg)
                self.assertEqual(argv[:2], ("/usr/bin/perl", "-e"))
                self.assertEqual(len(argv), 3)
                found = self.PROGRAM.fullmatch(argv[2])
                self.assertIsNotNone(found, argv[2])
                self.assertEqual(int(found.group(1)), alarm)  # the bound, rounded up, plus 10 s
                # what perl exec's is P1's loop, word for word
                self.assertEqual(tuple(re.findall(r'"([^"]*)"', found.group(2))),
                                 ("/bin/sh", "-c", "while :; do :; done"))
                self.assertEqual(rl.P1_LOOP, ("/bin/sh", "-c", "while :; do :; done"))

    def test_perl_reads_the_program_and_runs_the_loop_it_names(self):
        # -c compiles and does not run: the shipped program, with P1's loop, is valid perl
        argv = self.argv("1b")
        result = subprocess.run([argv[0], "-c", argv[1], argv[2]], stdin=subprocess.DEVNULL,
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        # and the same wrapper really execs what it is given (a harmless command, not the loop)
        wrapped = rl.worker_argv_for(5, loop=("/bin/echo", "ran", "it"))
        ran = subprocess.run(wrapped, stdin=subprocess.DEVNULL, capture_output=True, check=False)
        self.assertEqual((ran.returncode, ran.stdout), (0, b"ran it\n"))

    def test_a_loop_perl_would_read_as_more_than_text_is_refused(self):
        for bad in ('echo "x"', "echo $HOME", "a@b", "back\\slash", "two\nlines"):
            with self.subTest(argument=bad):
                with self.assertRaises(ValueError):
                    rl.worker_argv_for(10, loop=("/bin/sh", "-c", bad))

    def test_the_driver_starts_its_workers_with_that_command(self):
        self.spawner = FakeSpawner()
        driver = rl.Driver(rl.make_config("1b", self.dir, max_seconds=1), None, FakeClock(), self.spawner)
        driver.run()
        self.assertEqual({argv for argv, _ in self.spawner.calls}, {rl.worker_argv_for(1)})
        self.assertEqual(len(self.spawner.calls), 16)


class PidFile(Base):
    """load.pid is claimed with O_CREAT|O_EXCL and replaced only if its process is dead."""

    def pid_file(self, text):
        with open(os.path.join(self.dir, "load.pid"), "w", encoding="utf-8") as handle:
            handle.write(text)

    def test_a_pid_file_that_names_no_process_is_not_replaced(self):
        # the loser of a race reads the winner's file in the instant before it is written; the
        # old driver took that for a dead driver's and removed it
        for text in ("", "\n", "not a pid\n", "pid 1\n"):
            with self.subTest(text=text):
                self.fresh()
                self.pid_file(text)
                self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
                self.assertEqual(read(os.path.join(self.dir, "load.pid")), text)
                self.assertEqual((self.spawner.workers, self.phases()), ([], []))
                self.assertIn("names no process", "".join(self.echoed))

    def test_a_pid_file_that_is_being_written_is_waited_for_and_then_respected(self):
        # empty when the driver looks, the other driver's PID (a live one) a moment later
        def on_sleep(clock):
            self.pid_file("%d\n" % os.getpid())

        self.pid_file("")
        self.assertEqual(self.drive("1b", clock=FakeClock(on_sleep=on_sleep), max_seconds=1), rl.EXIT_REFUSED)
        self.assertEqual(read(os.path.join(self.dir, "load.pid")).split(), [str(os.getpid())])
        self.assertIn("names a running process", "".join(self.echoed))
        self.assertLess(self.clock.since(), 0.2)  # it did not wait out the second

    def test_a_pid_file_that_stays_empty_is_waited_for_a_second_and_no_more(self):
        self.pid_file("")
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
        self.between(self.clock.since(), 1.0, 1.1)

    def test_a_pid_the_driver_may_not_signal_is_a_live_one(self):
        # pid 1 is launchd: a user cannot signal it, and EPERM means it is there
        self.assertTrue(rl.Driver.alive(1))
        with mock.patch.object(os, "kill", side_effect=PermissionError):
            self.assertTrue(rl.Driver.alive(4242))
        with mock.patch.object(os, "kill", side_effect=ProcessLookupError):
            self.assertFalse(rl.Driver.alive(4242))
        self.pid_file("1\n")
        self.assertEqual(self.drive("1b", max_seconds=1), rl.EXIT_REFUSED)
        self.assertIn("names a running process (pid 1)", "".join(self.echoed))
        self.assertEqual(read(os.path.join(self.dir, "load.pid")).split(), ["1"])


class Follows(unittest.TestCase):
    """Follow reads what a file gains, and starts again from the top of one that was replaced or
    truncated (a `tee` that starts again)."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = os.path.join(directory.name, "f.ndjson")
        self.follow = rl.Follow(self.path)
        self.addCleanup(self.follow.close)

    def put(self, text, path=None, mode="w"):
        with open(path or self.path, mode, encoding="utf-8") as handle:
            handle.write(text)

    def test_it_reads_only_what_is_new_and_whole_lines(self):
        self.put("a\nb\npartial")
        self.assertEqual(self.follow.read_new(), [b"a", b"b"])
        self.assertEqual(self.follow.read_new(), [])
        self.put(" line\nc\n", mode="a")
        self.assertEqual(self.follow.read_new(), [b"partial line", b"c"])

    def test_a_replaced_file_is_read_from_its_start(self):
        self.put("a\nb\nc\n")
        self.assertEqual(self.follow.read_new(), [b"a", b"b", b"c"])
        replacement = self.path + ".new"
        self.put("w\nx\ny\nz\n", replacement)  # longer than what was read: only the inode differs
        os.replace(replacement, self.path)
        self.assertEqual(self.follow.read_new(), [b"w", b"x", b"y", b"z"])

    def test_a_truncated_file_is_read_from_its_start(self):
        self.put("aaaa\nbbbb\ncccc\n")
        self.assertEqual(self.follow.read_new(), [b"aaaa", b"bbbb", b"cccc"])
        with open(self.path, "r+b") as handle:  # the same file, emptied and written again, shorter
            handle.truncate(0)
            handle.write(b"x\ny\n")
        self.assertEqual(self.follow.read_new(), [b"x", b"y"])

    def test_a_file_read_from_its_end_ignores_what_was_there_and_not_what_comes_after_a_rewrite(self):
        self.put("old1\nold2\n")
        follow = rl.Follow(self.path, from_end=True)
        self.addCleanup(follow.close)
        self.assertEqual(follow.read_new(), [])
        self.put("new\n", mode="a")
        self.assertEqual(follow.read_new(), [b"new"])
        with open(self.path, "r+b") as handle:
            handle.truncate(0)
            handle.write(b"again\n")
        self.assertEqual(follow.read_new(), [b"again"])  # after a rewrite it is all new


@unittest.skipUnless(os.path.exists(rl.PERL), "perl is not here")
class StubbornWorkers(Base):
    """Real workers that ignore SIGTERM: SIGKILL has to be sent, and waited for, before the driver
    can say that none is left. A worker that dies on the instant is a fake; this one is not."""

    def test_workers_that_ignore_sigterm_are_killed_and_reaped_before_load_stop(self):
        ready = os.path.join(self.dir, "ready")
        program = ('$SIG{TERM} = "IGNORE"; open F, ">>", "%s" or die; print F "x"; close F; '
                   'sleep 60 while 1;' % ready)

        class AfterTheWorkersAreUp(rl.Clock):
            """The first wait of the load is real: until every worker has set its handler."""
            up = False

            def sleep(self, seconds):
                if not self.up:
                    deadline = time.time() + 15
                    while time.time() < deadline and not (
                            os.path.exists(ready) and os.path.getsize(ready) >= 16):
                        time.sleep(0.02)
                    self.up = True
                time.sleep(seconds)

        config = rl.make_config("1b", self.dir, workers=16, max_seconds=1)
        driver = rl.Driver(config, (rl.PERL, "-e", program), AfterTheWorkersAreUp(), subprocess.Popen,
                           echo=lambda text: None)

        def reap():
            path = os.path.join(self.dir, "busy-1b.pids")
            for pid in read(path).split() if os.path.exists(path) else []:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pid), signal.SIGKILL)

        self.addCleanup(reap)
        with mock.patch.object(rl, "STOP_GRACE_SECONDS", 0.4):
            code = driver.run()
        pids = [int(p) for p in read(os.path.join(self.dir, "busy-1b.pids")).split()]
        self.assertEqual(len(pids), 16)
        log = read(os.path.join(self.dir, "load-1b.log"))
        self.assertEqual(log.count("ignored SIGTERM: SIGKILL"), 16)  # the SIGKILL path really ran
        self.assertNotIn("STILL RUNNING", log)
        self.assertEqual(code, rl.EXIT_OK)
        self.assertEqual([c.kind for c in map(rw.parse_ctx_line, read(
            os.path.join(self.dir, "phases.log")).splitlines())], ["load-start", "load-stop"])
        self.assertFalse([p for p in pids if RealProcesses.alive(p)])


class CheckSet(Base):
    """`--check-set FILE`: what 1d would make of a `set --json` file, read-only."""

    def check(self, *lines, extra=(), name="set-1a.ndjson"):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("".join(line + "\n" for line in lines))
        return self.run_check(path, *extra)

    @staticmethod
    def run_check(path, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = rl.main(["--check-set", path] + list(extra))
        return code, out.getvalue()

    def test_the_documented_started_line_is_read_and_its_target_and_source_are_printed(self):
        code, out = self.check(DOCUMENTED_STARTED)
        self.assertEqual(code, 0)
        self.assertIn("started at 2026-10-07T23:24:57Z (epoch 1791415497.000)", out)
        self.assertIn("fan 0 target 4670 RPM, source: started.fans[0].commandedRPM", out)
        self.assertIn("--target-rpm is 5777 and differs; 1d uses `started`'s", out)
        # the parser sees the same thing
        event = rl.parse_set_event(DOCUMENTED_STARTED)
        self.assertEqual((event.event, event.target), ("started", 4670.0))

    def test_a_whole_hold_is_read_and_its_end_is_named(self):
        code, out = self.check(started_line(T0), event_line("holding", T0 + 5), event_line("ended", T0 + 20))
        self.assertEqual(code, 0)
        self.assertIn("then ended at %s" % iso_seconds(T0 + 20), out)
        self.assertIn("fan 0 target 5777 RPM, source: started.fans[0].commandedRPM", out)
        self.assertNotIn("differs", out)

    def test_a_started_with_no_target_says_it_would_use_the_flag(self):
        code, out = self.check(event_line("started", T0), extra=["--target-rpm", "3455"])
        self.assertEqual(code, 0)  # a usable `started`: 1d can run from it
        self.assertIn("fan 0 target 3455 RPM, source: --target-rpm (`started` carries no usable "
                      "fans[0].commandedRPM", out)

    def test_no_usable_started_is_exit_3_and_says_why(self):
        for label, lines in (
                ("empty", []), ("only junk", ["not json", "{", "[1]"]),
                ("only failed", [event_line("failed", T0)]),
                ("started without a time", ['{"event":"started","fans":[]}']),
                ("a started that is not a string", ['{"at":"%s","event":7}' % iso_seconds(T0)]),
                ("a time that is not UTC", ['{"at":"2026-10-07 23:24:57","event":"started"}'])):
            with self.subTest(label):
                code, out = self.check(*lines)
                self.assertEqual(code, 3, out)
                self.assertIn("no `started` event", out)
        code, out = self.run_check(os.path.join(self.dir, "nowhere.ndjson"))
        self.assertEqual(code, 3)
        self.assertIn("cannot read", out)

    def test_the_first_started_is_the_one_read(self):
        code, out = self.check(started_line(T0, rpm=4000), started_line(T0 + 50, rpm=5000))
        self.assertIn("fan 0 target 4000 RPM", out)

    def test_it_forks_nothing_and_writes_nothing(self):
        path = os.path.join(self.dir, "set-1a.ndjson")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(started_line(T0) + "\n")
        os.chmod(path, 0o444)
        os.chmod(self.dir, 0o555)  # read-only: any file it tried to make would fail
        self.addCleanup(os.chmod, self.dir, 0o755)
        before = sorted(os.listdir(self.dir)), os.stat(path).st_mtime_ns
        forbidden = []
        real_open = builtins.open

        def guarded_open(file, mode="r", *args, **kwargs):
            if any(flag in mode for flag in "wax+"):
                forbidden.append(("open", file, mode))
            return real_open(file, mode, *args, **kwargs)

        def refuse(name):
            def called(*args, **kwargs):
                forbidden.append((name, args))
                raise AssertionError("--check-set called %s" % name)
            return called

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(rl, "open", guarded_open, create=True))
            for owner, name in ((subprocess, "Popen"), (subprocess, "run"), (os, "fork"), (os, "system"),
                                (os, "kill"), (os, "unlink"), (os, "mkdir")):
                if hasattr(owner, name):
                    stack.enter_context(mock.patch.object(owner, name, refuse(name)))
            code, out = self.run_check(path)
        self.assertEqual((code, forbidden), (0, []))
        self.assertEqual((sorted(os.listdir(self.dir)), os.stat(path).st_mtime_ns), before)

    def test_it_takes_no_other_flag_and_checks_its_own(self):
        path = os.path.join(self.dir, "set-1a.ndjson")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(started_line(T0) + "\n")
        for extra in (["--mode", "1d"], ["--dir", self.dir], ["--workers", "4"], ["--max-seconds", "5"],
                      ["--arm-timeout", "20"], ["--fans", path], ["--phases", path], ["--set-json", path],
                      ["--target-rpm", "nan"], ["--target-rpm", "0"]):
            with self.subTest(extra=extra):
                with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                    self.run_check(path, *extra)
                self.assertEqual(raised.exception.code, 2)
        self.assertEqual(os.listdir(self.dir), ["set-1a.ndjson"])

    def test_without_it_a_mode_and_a_directory_are_required(self):
        for argv in ([], ["--mode", "1b"], ["--dir", self.dir]):
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                    rl.main(argv, worker_argv=FAKE_ARGV, install_signals=False)
                self.assertEqual(raised.exception.code, 2)
        self.assertEqual(os.listdir(self.dir), [])


@unittest.skipUnless(captures_dir(), "P1's captures are not on this machine")
class AgainstP1(Base):
    """The driver's reading of the sampler's real records, from P1's capture (read, never copied)."""

    def setUp(self):
        super().setUp()
        base = captures_dir()
        self.fans = glob.glob(os.path.join(base, "capture-fans-10hz-*.ndjson"))[0]
        with open(self.fans, encoding="utf-8") as handle:
            self.lines = [l.rstrip("\n") for l in handle]

    def test_the_fixture_the_other_tests_feed_has_the_keys_of_a_real_sample(self):
        # Synthetic fixtures hid #652's stop-line bug: the records the driver is tested with must
        # be the shape of the real ones, key for key and type for type.
        from test_fixture import skeleton
        samples = [json.loads(l) for l in self.lines[:20] if l.startswith("{") and '"kind":"sample"' in l]
        real, made = samples[5], synth.fan_record(T0, 7)
        self.assertEqual(sorted(real), sorted(made))
        self.assertEqual(skeleton(real)["readings"], skeleton(made)["readings"])
        self.assertEqual({r["key"] for r in real["readings"]}, set(synth.FAN_KEYS))
        self.assertEqual(skeleton(real), skeleton(made))

    def test_the_driver_reads_every_kind_of_line_in_p1_as_the_watcher_does(self):
        kinds = set()
        for raw in self.lines[:4000] + self.lines[-3:]:
            mine, theirs = rl.parse_fan_sample(raw), rw.parse_fan_line(raw)
            kinds.add("sample" if mine else "other")
            self.assertEqual(mine is None, theirs is None, raw[:80])
            if mine:
                self.assertEqual((mine.t, mine.v), (theirs.t, theirs.v))
        self.assertEqual(kinds, {"sample", "other"})  # the start line, a heartbeat and the stop line are "other"

    def window(self, first, count):
        """`count` real sample lines from index `first` on, with their stamps."""
        samples = [(rl.parse_fan_sample(l), l) for l in self.lines if l.startswith("{") and '"kind":"sample"' in l]
        return samples[first:first + count]

    @staticmethod
    def as_held(line):
        """A real line with fan 0's mode read as 1, which is what a held fan reads. P1 never held
        a fan (Apple ran both), so that one value is substituted; every key, type and stamp
        around it is the real one."""
        record = json.loads(line)
        for reading in record["readings"]:
            if reading["key"] == "F0Md":
                reading["value"] = 1
        return json.dumps(record, sort_keys=True, separators=(",", ":"))

    def replay_real(self, samples, started_at, held=True, rpm=5777, **cfg):
        """The 1d driver over real lines, appended to the file as the fake clock passes their
        stamps. With `held` each line's F0Md is read as 1 (see `as_held`); without it the lines
        are P1's own, in which Apple, not a hold, has fan 0 at its target."""
        fans = os.path.join(self.dir, "fans-10hz.ndjson")
        open(fans, "w").close()
        queue = [(s, self.as_held(l) if held else l) for s, l in samples]
        with open(os.path.join(self.dir, "set-1d.ndjson"), "w", encoding="utf-8") as handle:
            handle.write(started_line(started_at, rpm) + "\n")

        def feed(clock):
            due = []
            while queue and queue[0][0].t <= clock.w:
                due.append(queue.pop(0)[1])
            if due:
                with open(fans, "a", encoding="utf-8") as handle:
                    handle.write("".join(l + "\n" for l in due))

        clock = FakeClock(wall=samples[0][0].t - 0.5, on_sleep=feed)
        self.drive("1d", clock=clock, **cfg)
        return clock

    def test_the_dwell_is_found_in_p1s_real_lines_where_an_independent_scan_finds_it(self):
        # P1's fan 0 sat at 3455 RPM for about 470 s under Apple's own control. The driver, told
        # to wait for 3455, must start 10 s into the first such stretch.
        samples = [(rl.parse_fan_sample(l), l) for l in self.lines if l.startswith("{") and '"kind":"sample"' in l]
        first = next(i for i, (s, _) in enumerate(samples) if s.v["F0Tg"] == 3455.0)
        window = samples[max(0, first - 50):first + 400]
        run_start = next(s.t for s, _ in window if s.v["F0Tg"] == 3455.0)
        expected = next(s.t for s, _ in window if s.v["F0Tg"] == 3455.0 and s.t - run_start >= 10.0)
        self.replay_real(window, started_at=window[0][0].t, rpm=3455, max_seconds=1)
        t_l = self.ctx("load-start")[0].t
        self.between(t_l, expected, expected + 0.35)

    def test_p1s_real_plateau_under_apples_control_is_not_a_hold(self):
        # The same 3455 RPM plateau, as P1 recorded it: Apple's controller, fan 0 in mode 0. A
        # target on its number is not a hold. This is the shape 1d's driver must not start on.
        samples = [(rl.parse_fan_sample(l), l) for l in self.lines if l.startswith("{") and '"kind":"sample"' in l]
        first = next(i for i, (s, _) in enumerate(samples) if s.v["F0Tg"] == 3455.0)
        window = samples[max(0, first - 50):first + 400]
        self.assertEqual({s.v["F0Md"] for s, _ in window if s.v["F0Tg"] == 3455.0}, {0.0})
        self.replay_real(window, started_at=window[0][0].t, held=False, rpm=3455, max_seconds=1)
        self.assertEqual(self.code, rl.EXIT_NOT_STARTED)
        self.assertEqual((self.spawner.workers, self.phases()), ([], []))

    def test_f1tg_leaving_0_is_found_in_p1s_real_lines_where_an_independent_scan_finds_it(self):
        # load B started at 02:19:52Z and fan 1's target left 0 14.1 s later
        t_l = rw.parse_iso_utc("2026-10-31T02:19:52Z")
        window = [(s, l) for s, l in self.window(0, 10 ** 6) if t_l - 1 <= s.t < t_l + 60]
        expected = next(s.t for s, _ in window if s.t >= t_l and s.v["F1Tg"] > 0)
        self.between(expected - t_l, 13.0, 15.0)
        fans = os.path.join(self.dir, "fans-10hz.ndjson")
        open(fans, "w").close()
        queue = list(window)

        def feed(clock):
            due = []
            while queue and queue[0][0].t <= clock.w:
                due.append(queue.pop(0)[1])
            if due:
                with open(fans, "a", encoding="utf-8") as handle:
                    handle.write("".join(l + "\n" for l in due))

        clock = FakeClock(wall=t_l, on_sleep=feed)
        driver = rl.Driver(rl.make_config("1d", self.dir), FAKE_ARGV, clock, FakeSpawner(), echo=lambda text: None)
        driver.wall0, driver.mono0 = clock.w, clock.m  # the load began at t_L
        follow = rl.Follow(fans)
        self.addCleanup(follow.close)
        self.assertEqual(driver.run_1d_load(follow, t_l), rl.EXIT_OK)
        self.assertRegex(read(os.path.join(self.dir, "load-1d.log")), r"F1Tg left 0 at %.3f" % expected)
        self.between(clock.w, expected + 20.0, expected + 20.3)


if __name__ == "__main__":
    unittest.main()
