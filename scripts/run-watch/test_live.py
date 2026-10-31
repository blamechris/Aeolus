"""The live loop, driven by a fake clock and a fake system, and the watcher's confinement.

Nothing here starts a real process or says anything aloud. `FakeSystem` stands in for
`_spawn` and applies the same allow-list, so a command the watcher has no business running
fails the test whichever code path asked for it."""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import run_watch as rw
import synth
from synth import wrote
from support import idle


class FakeChild:
    def poll(self):
        return 0


class FakeSystem:
    """The commands the watcher may start, answered from fields a test sets."""

    def __init__(self):
        self.calls = []
        self.pids = [100]
        self.pressure = 0
        self.therm = "Note: No thermal warning level has been recorded\n"

    def __call__(self, argv, capture=False, timeout=None):
        argv = tuple(argv)
        assert rw._allowed(argv), "the watcher asked to start %r" % (argv,)
        self.calls.append(argv)
        if not capture:
            return FakeChild()
        if argv == rw.COMMANDS["pgrep"]:
            body, code = ("".join("%d\n" % p for p in self.pids), 0 if self.pids else 1)
        elif argv == rw.COMMANDS["notifyutil"]:
            body, code = ("com.apple.system.thermalpressurelevel %d\n" % self.pressure, 0)
        else:
            body, code = (self.therm, 0)
        return types.SimpleNamespace(returncode=code, stdout=body.encode())

    def spoken(self):
        return [c[1] for c in self.calls if c[0] == rw.SAY]

    def sounds(self):
        return [c for c in self.calls if c[0] == rw.AFPLAY]


class Clock:
    """Wall time that only moves when the loop sleeps, and a feeder that appends the lines of a
    synthetic run to the files as their stamps fall due, as the recorders would."""

    def __init__(self, directory, run, start, end, on_sleep=None):
        self.t, self.end, self.stop, self.on_sleep = start, end, {"flag": False}, on_sleep
        self.paths = {
            "fans": os.path.join(directory, "fans-10hz.ndjson"),
            "package": os.path.join(directory, "package-1hz.ndjson"),
            "helper_log": os.path.join(directory, "helper-log.ndjson"),
            "phases": os.path.join(directory, "phases.log")}
        self.queue = {k: [] for k in self.paths}
        for r in run.fans:
            self.queue["fans"].append((synth.parse_stamp(r["wallClockUTC"]), synth._line(r)))
        for r in run.packages:
            self.queue["package"].append((synth.parse_stamp(r["wallClockUTC"]), synth._line(r)))
        for r in run.log:
            self.queue["helper_log"].append((rw.parse_log_timestamp(r["timestamp"]), synth._line(r)))
        for line in run.ctx:
            self.queue["phases"].append((rw.parse_ctx_line(line).t, line))
        for key, path in self.paths.items():
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("")
        self.feed()

    def feed(self):
        for key, items in self.queue.items():
            due = [line for t, line in items if t <= self.t]
            self.queue[key] = [(t, line) for t, line in items if t > self.t]
            if due:
                with open(self.paths[key], "a", encoding="utf-8") as handle:
                    handle.write("".join(line + "\n" for line in due))

    def wall(self):
        return self.t

    def sleep(self, seconds):
        self.t += seconds
        self.feed()
        if self.on_sleep:
            self.on_sleep(self.t)
        if self.t >= self.end:
            self.stop["flag"] = True


_DIRECTORIES = []


def tearDownModule():
    for directory in _DIRECTORIES:
        shutil.rmtree(directory, ignore_errors=True)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def live(run, start, end, mute=False, system=None, logstream_pid=True, on_sleep=None):
    """Run the live loop over `run` from `start` to `end`; returns (watcher, system, dir)."""
    system = system or FakeSystem()
    directory = tempfile.mkdtemp(prefix="run-watch-live-")
    _DIRECTORIES.append(directory)
    clock = Clock(directory, run, start, end, on_sleep)
    if logstream_pid:
        with open(os.path.join(directory, "logstream.pid"), "w", encoding="utf-8") as handle:
            handle.write("%d\n" % os.getpid())
    args = types.SimpleNamespace(
        dir=directory, out=directory, fans=None, package=None, helper_log=None, phases=None,
        logstream_pid=None, mute=mute)
    watcher = rw.run_live(args, spawn=system, stop=clock.stop, wall=clock.wall, sleep=clock.sleep)
    return watcher, system, directory


def hashes(directory, names):
    result = {}
    for name in names:
        with open(os.path.join(directory, name), "rb") as handle:
            result[name] = hashlib.sha256(handle.read()).hexdigest()
    return result


class LiveLoop(unittest.TestCase):
    INPUTS = ("fans-10hz.ndjson", "package-1hz.ndjson", "helper-log.ndjson", "phases.log")

    def test_a_quiet_minute_raises_nothing_and_writes_only_its_own_files(self):
        run = idle(60)
        t0 = synth.T0
        watcher, system, directory = live(run, t0 + 5, t0 + 45)
        self.assertEqual(watcher.raised, [])
        self.assertEqual(system.spoken(), [])
        self.assertEqual(sorted(os.listdir(directory)), sorted(
            list(self.INPUTS) + ["logstream.pid", "watch.log", "watch.hb"]))
        self.assertAlmostEqual(
            float(read(os.path.join(directory, "watch.hb"))), t0 + 45, delta=1.5)

    def test_the_polls_run_at_their_rates(self):
        _, system, _ = live(idle(70), synth.T0 + 5, synth.T0 + 45)
        count = lambda spec: sum(1 for c in system.calls if c == rw.COMMANDS[spec])
        self.assertAlmostEqual(count("pgrep"), 40, delta=2)
        self.assertAlmostEqual(count("notifyutil"), 40, delta=2)
        self.assertAlmostEqual(count("pmset"), 8, delta=1)

    def test_an_alert_is_said_and_repeats(self):
        run = idle(80).patch_hottest(20, 21, 90.0)
        t0 = synth.T0
        watcher, system, directory = live(run, t0 + 5, t0 + 70)
        self.assertEqual([r.title for r in watcher.raised], ["ABORT 1"])
        # the reading is gone a second later, so the state clears and does not repeat
        self.assertEqual(system.spoken(), ["abort 1"])
        self.assertEqual(system.sounds(), [(rw.AFPLAY, rw.ALERT_SOUND)])
        alert_file = read(os.path.join(directory, "ALERT"))
        self.assertIn("ABORT 1: hottest curated 90.0 C", alert_file)

    def test_a_state_that_holds_is_repeated_every_fifteen_seconds(self):
        run = idle(120).patch_hottest(20, 100, 90.0)
        t0 = synth.T0
        watcher, system, _ = live(run, t0 + 5, t0 + 70)
        self.assertEqual(system.spoken(), ["abort 1"] * 4)  # 20, 35, 50, 65 s

    def test_mute_logs_and_says_nothing(self):
        run = idle(80).patch_hottest(20, 100, 90.0)
        watcher, system, directory = live(run, synth.T0 + 5, synth.T0 + 40, mute=True)
        self.assertEqual(len(watcher.raised), 1)
        self.assertEqual([c for c in system.calls if c[0] in (rw.SAY, rw.AFPLAY)], [])
        self.assertIn("MUTED", read(os.path.join(directory, "watch.log")))

    def test_a_missing_logstream_pid_is_blind(self):
        watcher, system, _ = live(idle(60), synth.T0 + 5, synth.T0 + 20, logstream_pid=False)
        self.assertEqual([r.title for r in watcher.raised][:1], ["BLIND — NO GO"])
        self.assertEqual(system.spoken()[:1], ["blind. no go"])

    def test_the_helper_restarting_after_armed(self):
        run = idle(80).add_ctx(10, "armed")

        def on_sleep(now):
            if now >= synth.T0 + 30:
                system.pids = [101]

        system = FakeSystem()
        watcher, _, _ = live(run, synth.T0 + 5, synth.T0 + 40, system=system, on_sleep=on_sleep)
        self.assertEqual([r.title for r in watcher.raised], ["HELPER RESTARTED"])
        self.assertEqual(system.spoken(), ["helper restarted"])

    def test_pressure_from_the_os(self):
        system = FakeSystem()

        def on_sleep(now):
            system.pressure = 2 if now >= synth.T0 + 20 else 0

        watcher, _, _ = live(idle(80), synth.T0 + 5, synth.T0 + 30, system=system, on_sleep=on_sleep)
        self.assertEqual([r.title for r in watcher.raised], ["ABORT 6"])

    def test_pgrep_failing_is_not_the_helper_vanishing(self):
        system = FakeSystem()
        original = system.__call__

        def broken(argv, capture=False, timeout=None):
            if tuple(argv) == rw.COMMANDS["pgrep"]:
                raise OSError("no pgrep")
            return original(argv, capture, timeout)

        run = idle(60).add_ctx(10, "armed pid=100")
        watcher, _, _ = live(run, synth.T0 + 5, synth.T0 + 30, system=broken)
        self.assertEqual(watcher.raised, [])

    def test_history_in_the_files_is_caught_up_before_the_loop_starts(self):
        # The watcher is started 100 s into a hold, as after a restart of the watcher.
        run = idle(200).hold(go=10, restore=150, target=3000)
        watcher, system, _ = live(run, synth.T0 + 100, synth.T0 + 110)
        self.assertTrue(watcher.hold_active)
        self.assertEqual(watcher.step, "1a")
        self.assertEqual(watcher.raised, [])
        self.assertAlmostEqual(watcher.engage_t, synth.T0 + 10.03, delta=0.01)

    def test_a_hold_with_no_restore_is_abort_8_even_for_a_watcher_started_late(self):
        run = idle(400).hold(go=10, restore=390, target=3000)
        watcher, system, _ = live(run, synth.T0 + 200, synth.T0 + 330)
        self.assertEqual([r.title for r in watcher.raised], ["ABORT 8"])


class TailTests(unittest.TestCase):
    def test_whole_lines_only_and_a_file_that_appears_later(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "f")
            tail = rw.Tail(path)
            self.addCleanup(tail.close)
            self.assertEqual(tail.read_new(), [])
            with open(path, "wb") as h:
                h.write(b"one\ntw")
            self.assertEqual(tail.read_new(), [b"one"])
            with open(path, "ab") as h:
                h.write(b"o\nthree\n")
            self.assertEqual(tail.read_new(), [b"two", b"three"])
            self.assertEqual(tail.read_new(), [])

    def test_a_truncated_or_replaced_file_is_read_again_from_its_start(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "f")
            with open(path, "wb") as h:
                h.write(b"aaaa\nbbbb\n")
            tail = rw.Tail(path)
            self.addCleanup(tail.close)
            self.assertEqual(len(tail.read_new()), 2)
            with open(path, "wb") as h:
                h.write(b"c\n")
            self.assertEqual(tail.read_new(), [b"c"])
            os.rename(path, path + ".old")
            with open(path, "wb") as h:
                h.write(b"dd\nee\nff\n")
            self.assertEqual(tail.read_new(), [b"dd", b"ee", b"ff"])


class Confinement(unittest.TestCase):
    def test_the_spawner_refuses_everything_off_the_list(self):
        for argv in (
                ("/usr/bin/sudo", "true"), ("sudo", "-v"), ("/bin/kill", "1"), ("kill", "-9", "1"),
                ("/bin/launchctl", "list"), ("/usr/bin/fanctl", "reset", "--all"),
                ("/Applications/Aeolus.app/Contents/MacOS/fanctl", "status"),
                ("/usr/bin/pgrep", "-x", "Finder"), ("/usr/bin/pgrep", "AeolusHelper"),
                ("/usr/bin/pmset", "sleepnow"), ("/usr/bin/pmset", "-g", "log"),
                ("/usr/bin/afplay", "/tmp/other.aiff"), ("/usr/bin/say",),
                ("/usr/bin/say", "-v", "Bad", "x"), ("/usr/bin/say", "hi; rm -rf /"),
                ("/usr/bin/say", "-x"), ("say", "hi"), ("/usr/bin/notifyutil", "-p", "x")):
            with self.assertRaises(PermissionError, msg=str(argv)):
                rw._spawn(argv)

    def test_the_spawner_accepts_exactly_the_listed_commands(self):
        for argv in (
                ("/usr/bin/pgrep", "-x", "AeolusHelper"),
                ("/usr/bin/notifyutil", "-g", "com.apple.system.thermalpressurelevel"),
                ("/usr/bin/pmset", "-g", "therm"), ("/usr/bin/afplay", rw.ALERT_SOUND),
                ("/usr/bin/say", "abort 4. verify")):
            self.assertTrue(rw._allowed(argv), argv)

    def test_whatever_a_whole_run_does_goes_through_the_list_and_into_its_own_files(self):
        """Patch every way the process could start a program or change a file. Run a replay and
        a live loop with the real spawner. Nothing off the list may be asked for."""
        asked, opened, forbidden = [], [], []

        def fake_run(argv, **kwargs):
            asked.append(tuple(argv))
            return subprocess.CompletedProcess(argv, 0, b"x 0\n", b"")

        class FakePopen:
            def __init__(self, argv, **kwargs):
                asked.append(tuple(argv))

            def poll(self):
                return 0

        real_open = open

        def recording_open(path, mode="r", *args, **kwargs):
            if any(flag in mode for flag in "wax+"):
                opened.append((os.path.abspath(str(path)), mode))
            return real_open(path, mode, *args, **kwargs)

        def forbid(name):
            def refuse(*args, **kwargs):
                forbidden.append(name)
                raise AssertionError("the watcher called %s" % name)
            return refuse

        run = idle(60).patch_hottest(20, 100, 90.0)
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as out:
            clock = Clock(d, run, synth.T0 + 5, synth.T0 + 40)
            with open(os.path.join(d, "logstream.pid"), "w", encoding="utf-8") as h:
                h.write("%d\n" % os.getpid())
            args = types.SimpleNamespace(
                dir=d, out=out, fans=None, package=None, helper_log=None, phases=None,
                logstream_pid=None, mute=False, replay_polls=None)
            inputs = ("fans-10hz.ndjson", "package-1hz.ndjson", "helper-log.ndjson", "phases.log")
            patches = [
                mock.patch.object(subprocess, "run", fake_run),
                mock.patch.object(subprocess, "Popen", FakePopen),
                mock.patch.object(rw, "open", recording_open, create=True)]
            for name in ("system", "kill", "killpg", "popen", "remove", "unlink", "rename",
                         "replace", "rmdir", "mkdir", "chmod", "execv", "execvp", "fork",
                         "posix_spawn", "symlink", "link", "truncate", "utime"):
                if hasattr(os, name):
                    patches.append(mock.patch.object(os, name, forbid("os." + name)))
            with contextlib_exit(patches):
                rw.run_live(args, stop=clock.stop, wall=clock.wall, sleep=clock.sleep)
                before = hashes(d, inputs)  # the feeder's last write is in; the replay adds none
                with contextlib.redirect_stdout(io.StringIO()):
                    rw.run_replay(args)
            after = hashes(d, inputs)
        self.assertEqual(before, after)
        self.assertEqual(forbidden, [])
        for argv in asked:
            self.assertTrue(rw._allowed(argv), argv)
        self.assertTrue(any(a[0] == rw.SAY for a in asked))
        self.assertTrue(any(a == rw.COMMANDS["pgrep"] for a in asked))
        self.assertEqual({os.path.basename(p) for p, _ in opened}, set(rw.OWN_FILES))
        self.assertTrue(all(
            os.path.dirname(p) in (os.path.abspath(out), os.path.realpath(out)) for p, _ in opened))

    def test_a_replay_refuses_to_write_into_the_capture_directory(self):
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stderr(io.StringIO()):
            for argv in (["--replay", "--dir", d], ["--replay", "--dir", d, "--out", d]):
                with self.assertRaises(SystemExit):
                    rw.main(argv)
            self.assertEqual(os.listdir(d), [])

    def test_replay_polls_are_for_replays(self):
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                rw.main(["--dir", d, "--replay-polls", os.path.join(d, "x")])


class contextlib_exit:
    """Enter several patches and leave them all."""

    def __init__(self, patches):
        self.patches = patches

    def __enter__(self):
        for p in self.patches:
            p.start()

    def __exit__(self, *exc):
        for p in reversed(self.patches):
            p.stop()


if __name__ == "__main__":
    unittest.main()
