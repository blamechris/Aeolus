"""Alert states: entering, repeating aloud, clearing, latching; and the status line."""

import json
import os
import tempfile
import unittest

import run_watch as rw
import synth
from support import idle, lines, replay, titles


def speech_times(watcher):
    return watcher.spoken


class Speaking(unittest.TestCase):
    def watcher(self):
        out = rw.MemoryOutput()
        w = rw.Watcher(out, speak=True)
        w.start(1000.0)
        w.source_ended("fans")  # no recorders here: rule 12 has nothing to say
        w.source_ended("package")
        return w

    def test_a_level_alert_repeats_every_fifteen_seconds_while_it_holds(self):
        w = self.watcher()
        spoken = []
        for step in range(0, 60 * 20):
            now = 1000.0 + step * 0.05
            w.advance(now)
            w.level("x", "ABORT 6", True, "pressure")
            spoken.extend((now, v) for v in w.take_speech())
        # entered at 1000.0, then at 15, 30 and 45 s after: four announcements in 60 s
        self.assertEqual([v for _, v in spoken], ["abort 6"] * 4)
        gaps = [b[0] - a[0] for a, b in zip(spoken, spoken[1:])]
        for gap in gaps:
            self.assertAlmostEqual(gap, 15.0, delta=0.1)

    def test_it_stops_when_the_state_ends(self):
        w = self.watcher()
        w.level("x", "ABORT 6", True)
        w.take_speech()
        w.advance(1005.0)
        w.level("x", "ABORT 6", False)
        w.advance(1040.0)
        self.assertEqual(w.take_speech(), [])
        self.assertEqual(w.active_alerts(), [])
        self.assertEqual(len(lines_of(w, "CLEAR")), 1)

    def test_an_event_alert_holds_for_two_minutes_and_repeats(self):
        w = self.watcher()
        w.event("e", "ABORT 5", "slow write")
        said = len(w.take_speech())
        for step in range(1, 140 * 2):
            w.advance(1000.0 + step * 0.5)
            said += len(w.take_speech())
        # once on entry, then at 15, 30, ... 105 s: 8 in the 120 s it holds, none after
        self.assertEqual(said, 8)
        self.assertEqual(w.active_alerts(), [])

    def test_a_new_event_restarts_the_latch(self):
        w = self.watcher()
        w.event("e", "ABORT 5", "one")
        w.advance(1100.0)
        w.event("e", "ABORT 5", "two")
        w.advance(1210.0)
        self.assertEqual(w.active_alerts(), ["ABORT 5"])
        w.advance(1221.0)
        self.assertEqual(w.active_alerts(), [])

    def test_a_replay_says_nothing_and_a_live_watcher_does(self):
        quiet = replay(idle(30).patch_hottest(10, 11, 90.0))
        self.assertEqual(quiet.take_speech(), [])
        loud = replay(idle(30).patch_hottest(10, 11, 90.0), speak=True)
        self.assertEqual(loud.take_speech(), ["abort 1"])

    def test_voices(self):
        self.assertEqual(rw._voice("ABORT 4 — VERIFY"), "abort 4. verify")
        self.assertEqual(rw._voice("BLIND — NO GO"), "blind. no go")
        self.assertEqual(rw._voice("ABORT 11 TEMPERATURE"), "abort 11 temperature")
        for title in ("ABORT 4 — RESET", "HELPER RESTARTED", "UNPARSED WRITE", "NO CONTEXT"):
            self.assertRegex(rw._voice(title), rw.SAY_SAFE)

    def test_going_live_makes_a_state_that_still_holds_repeat_at_once(self):
        w = rw.Watcher(rw.MemoryOutput())
        w.start(1000.0)
        w.source_ended("fans")
        w.source_ended("package")
        w.level("x", "ABORT 1", True)
        self.assertEqual(w.take_speech(), [])
        w.go_live(1003.0)
        w.advance(1003.0)
        self.assertEqual(w.take_speech(), ["abort 1"])

    def test_a_level_alert_that_changes_its_name_is_cleared_and_entered_again(self):
        w = self.watcher()
        w.level("r12", "BLIND — NO GO", True, "gap")
        w.level("r12", "ABORT 12", True, "gap")
        self.assertEqual(w.take_speech(), ["blind. no go", "abort 12"])
        self.assertEqual(w.active_alerts(), ["ABORT 12"])


def lines_of(watcher, level):
    return [text for _, lvl, text in watcher.out.lines if lvl == level]


class WatchLog(unittest.TestCase):
    def test_an_alert_is_a_log_line_and_an_alert_file_entry(self):
        w = replay(idle(30).patch_hottest(10, 11, 90.0))
        alert_lines = lines(w, "ALERT")
        self.assertEqual(len(alert_lines), 1)
        self.assertTrue(alert_lines[0].startswith("ABORT 1: hottest curated 90.0 C"))
        self.assertEqual(len(w.memory.alerts), 1)

    def test_warnings_and_notes_never_touch_the_alert_file(self):
        w = replay(idle(80).add_ctx(5, "load-start step=1d").patch_fan(52, 80, F1Tg=1458, F1Ac=1458))
        self.assertEqual(titles(w), [])
        self.assertEqual(len(lines(w, "WARN")), 1)
        self.assertEqual(w.memory.alerts, [])

    def test_a_message_with_newlines_is_still_one_record(self):
        message = "Liveness watchdog fired\nin the cycle\r\nwith a TPD1 read in flight\u2028and more"
        with tempfile.TemporaryDirectory() as d:
            out = rw.Output(d)
            w = rw.Watcher(out)
            w.start(1000.0)
            w.source_ended("fans")
            w.source_ended("package")
            w.on_log(rw.parse_log_line(json.dumps(synth.log_record(1000.5, message, "Fault"))))
            out.close()
            for name in ("watch.log", "ALERT"):
                with open(os.path.join(d, name), encoding="utf-8") as handle:
                    records = handle.read().split("\n")
                if name == "watch.log":
                    records = [r for r in records if " ALERT " in r]
                records = [r for r in records if r]
                self.assertEqual(len(records), 1, name)
                self.assertIn("Liveness watchdog fired in the cycle with a TPD1 read in flight and more", records[0])

    def test_the_status_line_every_five_seconds(self):
        w = replay(idle(32))
        status = lines(w, "STATUS")
        self.assertEqual(len(status), 6)
        self.assertIn("step=none hold=no F0Md=3 F1Md=3 Ftst=0", status[0])
        self.assertIn("hottest=42.0", status[0])
        self.assertIn("thr[T>85]", status[0])

    def test_the_status_line_during_a_hold_with_a_load(self):
        run = idle(60).add_ctx(5, "load-start step=1d").hold(go=20, restore=50, target=3000, step="1b")
        w = replay(run)
        mid = [t for t in lines(w, "STATUS") if "hold=ACTIVE" in t][0]
        self.assertIn("step=1b", mid)
        self.assertIn("T>74(load)", mid)
        self.assertIn("F1Tg>2700(r9)", mid)
        self.assertRegex(mid, r"since_engage=\d+s")
        self.assertRegex(mid, r"since_tL=\d+s")

    def test_ctx_end_stands_the_blind_and_restart_checks_down(self):
        w = replay(idle(40).add_ctx(5, "end"))
        self.assertTrue(any("stand down" in t for t in lines(w, "INFO")))


if __name__ == "__main__":
    unittest.main()
