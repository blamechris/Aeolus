"""The committed synthetic fixture, its shapes against P1's, and the shell companion."""

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest

import run_watch as rw
import synth
from support import captures_dir

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixtures", "synthetic")


def skeleton(value):
    """The shape of a JSON value: its keys and the types of its leaves, never the values."""
    if isinstance(value, dict):
        return {k: skeleton(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [skeleton(value[0])] if value else []
    return "null" if value is None else ("number" if isinstance(value, (int, float)) and not isinstance(value, bool) else type(value).__name__)


def first_record(path, kind):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("{"):
                record = json.loads(line)
                if record.get("kind") == kind:
                    return record
    raise AssertionError("no %s record in %s" % (kind, path))


class Fixture(unittest.TestCase):
    def test_the_committed_files_are_what_the_builder_makes(self):
        with tempfile.TemporaryDirectory() as d:
            synth.fixture_run().write(d)
            for name in sorted(os.listdir(d)):
                with open(os.path.join(d, name), "rb") as made, open(os.path.join(FIXTURE, name), "rb") as kept:
                    self.assertEqual(made.read(), kept.read(), name)
            self.assertEqual(sorted(os.listdir(d)), sorted(os.listdir(FIXTURE)))

    def test_nothing_real_is_in_it(self):
        for name in os.listdir(FIXTURE):
            with open(os.path.join(FIXTURE, name), encoding="utf-8") as handle:
                text = handle.read()
            self.assertNotIn(os.uname().nodename.split(".")[0].lower(), text.lower(), name)
        start = first_record(os.path.join(FIXTURE, "fans-10hz.ndjson"), "start")
        self.assertEqual(start["hostname"], synth.HOST)
        with open(os.path.join(FIXTURE, "helper-log.ndjson"), encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("{"):
                    record = json.loads(line)
                    self.assertEqual(record["processImagePath"], "/synthetic/AeolusHelper")
                    self.assertEqual(sorted(record), sorted(synth.log_record(0, "x")))

    def test_the_watcher_replays_it_from_the_command_line_with_nothing_to_say(self):
        with tempfile.TemporaryDirectory() as out:
            result = subprocess.run(
                [sys.executable, "-I", os.path.join(HERE, "run_watch.py"), "--replay", "--dir", FIXTURE,
                 "--out", out, "--replay-polls", os.path.join(FIXTURE, "polls.ndjson")],
                stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=120)
            self.assertIn(b"0 alerts, 0 warnings, 0 notes", result.stdout)
            self.assertEqual(sorted(os.listdir(out)), ["watch.hb", "watch.log"])
            with open(os.path.join(out, "watch.log"), encoding="utf-8") as handle:
                log = handle.read()
        self.assertIn("restore verified", log)
        self.assertIn("armed; helper PIDs [4242]", log)
        self.assertIn("hold=ACTIVE", log)
        self.assertNotIn(" ALERT ", log)

    def test_the_fixture_stays_inside_the_repository_budget(self):
        total = sum(os.path.getsize(os.path.join(FIXTURE, n)) for n in os.listdir(FIXTURE))
        self.assertLess(total, 300 * 1024)


@unittest.skipUnless(captures_dir(), "P1's captures are not on this machine")
class ShapesMatchP1(unittest.TestCase):
    """The builder's records have the keys and leaf types of the real recorders'."""

    def setUp(self):
        import glob
        base = captures_dir()
        self.fans = glob.glob(os.path.join(base, "capture-fans-10hz-*.ndjson"))[0]
        self.package = glob.glob(os.path.join(base, "capture-package-1hz-*.ndjson"))[0]

    def test_start_sample_and_heartbeat_records(self):
        for real, made_path in ((self.fans, "fans-10hz.ndjson"), (self.package, "package-1hz.ndjson")):
            made = os.path.join(FIXTURE, made_path)
            for kind in ("start", "sample"):
                a, b = skeleton(first_record(real, kind)), skeleton(first_record(made, kind))
                if kind == "sample":
                    a["readings"], b["readings"] = [a["readings"][0]], [b["readings"][0]]
                self.assertEqual(a, b, (kind, made_path))

    def test_a_sample_after_the_first_has_the_same_shape(self):
        with open(self.fans, encoding="utf-8") as handle:
            lines = [json.loads(l) for _, l in zip(range(5), handle) if l.startswith("{")]
        later = [r for r in lines if r["kind"] == "sample"][-1]
        made = synth.fan_record(synth.T0, 7)
        self.assertEqual(skeleton(later)["readings"], skeleton(made)["readings"])
        self.assertEqual(sorted(later), sorted(made))

    def test_the_parsers_read_p1s_own_first_lines(self):
        with open(self.fans, encoding="utf-8") as handle:
            sample = next(rw.parse_fan_line(l) for l in handle if '"kind":"sample"' in l)
        self.assertEqual(sorted(sample.v), sorted(synth.FAN_KEYS))
        with open(self.package, encoding="utf-8") as handle:
            package = next(rw.parse_package_line(l) for l in handle if '"kind":"sample"' in l)
        self.assertIsNotNone(package.hottest)


@unittest.skipUnless(sys.platform == "darwin", "the companion uses BSD stat")
class WatcherDown(unittest.TestCase):
    def run_companion(self, beat_age, seconds=2.4, defaults=False):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as bin_dir:
            fake = os.path.join(bin_dir, "say")
            record = os.path.join(bin_dir, "said")
            with open(fake, "w", encoding="utf-8") as handle:
                handle.write('#!/bin/sh\necho "$@" >> "%s"\n' % record)
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            if beat_age is not None:
                beat = os.path.join(d, "watch.hb")
                with open(beat, "w", encoding="utf-8") as handle:
                    handle.write("x\n")
                os.utime(beat, (time.time() - beat_age, time.time() - beat_age))
            args = [d] if defaults else [d, "1", "0.5"]
            child = subprocess.Popen(
                ["/bin/sh", os.path.join(HERE, "watcher-down.sh")] + args,
                env=dict(os.environ, SAY=fake), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                time.sleep(seconds)
            finally:
                child.terminate()
                child.wait(timeout=10)
            if not os.path.exists(record):
                return []
            with open(record, encoding="utf-8") as handle:
                return handle.read().splitlines()

    def test_a_stale_heartbeat_is_spoken(self):
        said = self.run_companion(beat_age=30)
        self.assertGreaterEqual(len(said), 2)
        self.assertEqual(set(said), {"watcher down"})

    def test_a_missing_heartbeat_is_spoken(self):
        self.assertIn("watcher down", self.run_companion(beat_age=None))

    def test_a_fresh_heartbeat_is_silent(self):
        self.assertEqual(self.run_companion(beat_age=0.0, seconds=0.9), [])

    def test_the_default_limit_is_ten_seconds(self):
        # Run with no arguments but the directory: the first look is at once.
        self.assertEqual(self.run_companion(beat_age=8.0, seconds=1.0, defaults=True), [])
        self.assertEqual(self.run_companion(beat_age=12.0, seconds=1.0, defaults=True), ["watcher down"])

    def test_the_loop_is_five_lines(self):
        with open(os.path.join(HERE, "watcher-down.sh"), encoding="utf-8") as handle:
            body = handle.read().split("while :; do")[1].split("done")[0].strip().splitlines()
        self.assertEqual(len(body), 3)  # the lines between `while` and `done`; five with them


if __name__ == "__main__":
    unittest.main()
