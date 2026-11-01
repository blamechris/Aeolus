"""The derived-gate notes: T0, "at rest", 1b's engaged condition and the at-rest clock.

They are advice that the runbook reads from watch.log, so these tests read the GATE lines, not the
alerts. Each gate has its control on the other side of every threshold, because a test that only
shows a gate saying YES cannot tell a gate from a constant."""

import glob
import os
import unittest

import run_watch as rw
import synth
from support import captures_dir, idle, replay, titles


def gate_lines(watcher, name):
    """(seconds from the run's start, text) of every GATE line that begins `name=`."""
    return [(t - synth.T0, text) for t, level, text in watcher.memory.lines
            if level == "GATE" and text.startswith(name + "=")]


def fields(text):
    return dict(token.split("=", 1) for token in text.split() if "=" in token)


def at_rest(watcher):
    """The at-rest gate's states in order: (seconds, 'YES' or the reason it says NO)."""
    return [(t, f["at-rest"] if f["at-rest"] == "YES" else f["why"])
            for t, text in gate_lines(watcher, "at-rest") for f in [fields(text)]]


def unreadable(run, start, end, key):
    """Make `key` fail to read on the fan samples in [start, end): the sampler's own record of a
    reading that did not come back, which the parser drops."""
    for record in run.fans:
        if start <= run._stamp(record) - run.t0 < end:
            for reading in record["readings"]:
                if reading["key"] == key:
                    reading["status"], reading["value"] = "unavailable", None
    return run


class T0Gate(unittest.TestCase):
    def test_a_quiet_run_gives_its_median_once_the_window_is_complete(self):
        w = replay(idle(150, hottest=40.0))
        lines = gate_lines(w, "t0")
        self.assertTrue(lines)
        t, text = lines[0]
        self.assertTrue(119.3 <= t <= 119.8, t)  # a 120 s window is complete at a span of 119.5 s
        f = fields(text)
        self.assertEqual((f["t0"], f["n"], f["ok"], f["state"]), ("40.00", "120", "YES", "provisional"))
        self.assertEqual(f["limit"], "50")
        self.assertEqual(w.t0, 40.0)

    def test_nothing_is_said_before_the_window_is_complete(self):
        self.assertEqual(gate_lines(replay(idle(119.0, hottest=40.0)), "t0"), [])

    def test_it_is_the_median_not_the_mean_or_the_maximum(self):
        # 30 samples at 70 C and 90 at 40 C: mean 47.5, maximum 70, median 40
        w = replay(idle(150, hottest=40.0).patch_hottest(0, 30, 70.0))
        self.assertEqual(fields(gate_lines(w, "t0")[0][1])["t0"], "40.00")

    def test_an_even_count_is_the_mean_of_the_two_middle_values(self):
        # 60 samples at 40 C and 60 at 44 C: the median is 42, the lower and upper middles 40 and 44
        w = replay(idle(150, hottest=40.0).patch_hottest(60, 150, 44.0))
        self.assertEqual(fields(gate_lines(w, "t0")[0][1])["t0"], "42.00")

    def test_t0_is_ok_only_below_50(self):
        for hottest, ok in ((49.99, "YES"), (50.0, "NO"), (52.0, "NO")):
            with self.subTest(hottest=hottest):
                w = replay(idle(150, hottest=hottest))
                self.assertEqual(fields(gate_lines(w, "t0")[0][1])["ok"], ok)

    def test_each_clause_of_quiescence_ends_the_window(self):
        # One bad pair of samples at 50 s starts the window again at 50.2 s, which is complete at
        # 169.7 s. Each is a clause of D9's rule: Ftst, a mode outside Apple's set, and a fan
        # reading 3 with a target above 0.
        for label, patch in (
                ("Ftst", {"Ftst": 1}), ("F0Md", {"F0Md": 1}), ("F1Md", {"F1Md": 2}),
                ("F0Tg", {"F0Tg": 1500}), ("F1Tg", {"F1Tg": 1500})):
            with self.subTest(clause=label):
                w = replay(idle(260, hottest=40.0).patch_fan(50, 50.2, **patch))
                t = gate_lines(w, "t0")[0][0]
                self.assertTrue(169.5 <= t <= 170.5, t)

    def test_a_mode_of_zero_with_a_target_is_not_a_violation_but_a_mode_of_three_is(self):
        # Apple's set is {0, 3}; D9 forbids only a fan reading 3 with a target above 0
        w = replay(idle(150, hottest=40.0).patch_fan(50, 50.2, F0Md=0, F0Tg=1500))
        self.assertTrue(119.3 <= gate_lines(w, "t0")[0][0] <= 119.8)

    def test_a_reading_that_did_not_read_ok_is_not_quiet(self):
        # a key that failed to read says nothing about the machine, so the window starts again
        for key in ("Ftst", "F0Md", "F1Tg"):
            with self.subTest(key=key):
                w = replay(unreadable(idle(260, hottest=40.0), 50, 50.2, key))
                t = gate_lines(w, "t0")[0][0]
                self.assertTrue(169.5 <= t <= 170.5, t)

    def test_a_package_record_that_has_not_caught_up_gives_no_t0_rather_than_a_short_one(self):
        w = replay(idle(200, hottest=40.0).drop(60, 200, "package"))
        self.assertEqual(gate_lines(w, "t0"), [])
        self.assertIsNone(w.t0)

    def test_a_gap_in_the_fan_record_ends_the_window_a_short_one_does_not(self):
        # 3.1 s with no sample: nobody saw the machine, so the window starts again at 53.0 s
        w = replay(idle(260, hottest=40.0).drop(50, 53, "fans"))
        t = gate_lines(w, "t0")[0][0]
        self.assertTrue(172.0 <= t <= 173.0, t)
        w = replay(idle(260, hottest=40.0).drop(50, 51.8, "fans"))
        self.assertTrue(119.3 <= gate_lines(w, "t0")[0][0] <= 119.8)

    def test_too_few_package_samples_say_so_and_recover(self):
        w = replay(idle(170, hottest=40.0).drop(10, 40, "package"))
        lines = gate_lines(w, "t0")
        self.assertEqual(fields(lines[0][1])["t0"], "unavailable")
        self.assertLess(int(fields(lines[0][1])["n"]), 100)
        self.assertEqual(fields(lines[0][1])["need"], "100")
        values = [(t, fields(x)) for t, x in lines if fields(x)["t0"] != "unavailable"]
        self.assertTrue(values)
        self.assertGreaterEqual(int(values[0][1]["n"]), 100)
        self.assertGreater(values[0][0], lines[0][0])
        self.assertEqual(w.t0, 40.0)

    def test_it_follows_the_machine_until_armed_and_is_then_frozen(self):
        run = idle(330, hottest=40.0).add_ctx(130, "armed").patch_hottest(140, 330, 46.0)
        w = replay(run)
        lines = gate_lines(w, "t0")
        self.assertEqual(w.t0, 40.0)  # the heat after armed did not move it
        states = [fields(x)["state"] for _, x in lines]
        self.assertEqual(states[0], "provisional")
        self.assertEqual(states[states.index("frozen"):], ["frozen"])  # nothing after it
        self.assertTrue(129.9 <= lines[-1][0] <= 130.1, lines[-1][0])
        self.assertEqual(fields(lines[-1][1])["by"], "CTX_armed")
        # the control: with nothing to freeze it, it follows the heat
        followed = replay(idle(330, hottest=40.0).patch_hottest(140, 330, 46.0))
        self.assertGreater(followed.t0, 44.0)

    def test_a_step_line_freezes_it_too(self):
        run = idle(330, hottest=40.0).add_ctx(130, "step=1a target=3000 GO")
        run.patch_hottest(140, 330, 46.0)
        w = replay(run)
        self.assertEqual(w.t0, 40.0)
        self.assertEqual(fields(gate_lines(w, "t0")[-1][1])["by"], "CTX_step=1a")

    def test_armed_before_any_window_freezes_it_at_the_first_one(self):
        run = idle(330, hottest=40.0).add_ctx(50, "armed").patch_hottest(140, 330, 46.0)
        w = replay(run)
        lines = gate_lines(w, "t0")
        self.assertEqual(fields(lines[0][1])["t0"], "unavailable")
        self.assertEqual(fields(lines[0][1])["freeze-at"], "CTX_armed")
        self.assertEqual(fields(lines[-1][1])["state"], "frozen")
        self.assertTrue(119.3 <= lines[-1][0] <= 119.8, lines[-1][0])
        self.assertEqual(w.t0, 40.0)


class AtRestGate(unittest.TestCase):
    def test_it_waits_for_60_s_and_for_t0_and_then_holds(self):
        states = at_rest(replay(idle(200, hottest=40.0)))
        self.assertEqual([s for _, s in states], ["short", "t0", "YES"])
        self.assertTrue(59.0 <= states[1][0] <= 60.0, states)
        self.assertTrue(119.3 <= states[2][0] <= 119.8, states)

    def test_each_clause_of_the_fan_state_is_needed(self):
        # Apple's set is {0, 3}, but "at rest" is raw 3: a mode of 0 is not rest. Every clause
        # ends the run, and 60 s of clean samples must follow before it says YES again.
        for label, patch in (
                ("F0Md", {"F0Md": 0}), ("F1Md", {"F1Md": 0}), ("Ftst", {"Ftst": 1}),
                ("F0Tg", {"F0Tg": 100.0}), ("F1Tg", {"F1Tg": 100.0})):
            with self.subTest(clause=label):
                states = at_rest(replay(idle(300, hottest=40.0).patch_fan(150, 150.2, **patch)))
                self.assertEqual([s for _, s in states], ["short", "t0", "YES", "fans", "short", "YES"])
                self.assertTrue(149.9 <= states[3][0] <= 150.1, states)
                # 60 s: the run starts at 150.2 s and counts as held at a span of 59.5 s
                self.assertTrue(209.5 <= states[5][0] <= 210.0, states)

    def test_an_open_step_is_not_at_rest_and_closing_it_restores_the_state(self):
        run = idle(300, hottest=40.0).add_ctx(150, "step=1a target=3000 GO").add_ctx(160, "step=none")
        states = at_rest(replay(run))
        self.assertEqual([s for _, s in states][-3:], ["YES", "step-open", "YES"])
        self.assertTrue(149.9 <= states[-2][0] <= 150.1 and 159.9 <= states[-1][0] <= 160.1, states)

    def test_a_hold_with_no_step_open_is_not_at_rest_either(self):
        run = idle(300, hottest=40.0).add_log(150, synth.wrote("F0Md", "0x1"))
        states = at_rest(replay(run))
        self.assertEqual(states[-1][1], "step-open")

    def test_the_hottest_must_be_at_most_t0_plus_3(self):
        run = idle(300, hottest=40.0).add_ctx(125, "armed")
        run.patch_hottest(150, 170, 43.0).patch_hottest(170, 190, 43.1)
        states = at_rest(replay(run))
        self.assertEqual([s for _, s in states], ["short", "t0", "YES", "warm", "YES"])
        self.assertTrue(169.9 <= states[3][0] <= 171.1, states)  # 43.0 holds, 43.1 does not
        self.assertTrue(189.9 <= states[4][0] <= 191.1, states)
        warm = gate_lines(replay(run), "at-rest")[3][1]
        self.assertIn("limit=43.00", warm)
        self.assertIn("t0=40.00", warm)

    def test_a_stale_package_record_is_not_at_rest(self):
        states = at_rest(replay(idle(300, hottest=40.0).drop(150, 160, "package")))
        self.assertEqual([s for _, s in states][3:], ["package", "YES"])
        self.assertTrue(151.5 <= states[3][0] <= 153.5, states)

    def test_a_stale_fan_record_is_not_at_rest_and_it_starts_again_afterwards(self):
        states = at_rest(replay(idle(300, hottest=40.0).drop(150, 160, "fans")))
        self.assertEqual([s for _, s in states][3:], ["stale", "short", "YES"])
        self.assertTrue(151.8 <= states[3][0] <= 152.5, states)
        self.assertTrue(219.3 <= states[5][0] <= 220.2, states)  # 60 s after the record came back

    def test_it_says_nothing_new_while_nothing_changes(self):
        w = replay(idle(900, hottest=40.0))
        self.assertEqual(len(gate_lines(w, "at-rest")), 3)


class EngagedGate(unittest.TestCase):
    def test_f0tg_at_f0mn_plus_300_for_30_s(self):
        w = replay(idle(100).patch_fan(10, 100, F0Tg=1700.0))
        lines = [(t, fields(x)) for t, x in gate_lines(w, "engaged")]
        self.assertEqual([f["engaged"] for _, f in lines], ["rising", "YES"])
        self.assertTrue(9.9 <= lines[0][0] <= 10.1, lines)
        self.assertTrue(39.9 <= lines[1][0] <= 40.3, lines)
        self.assertEqual((lines[1][1]["thr"], lines[1][1]["F0Mn"], lines[1][1]["F0Tg"]), ("1650", "1350", "1700"))

    def test_just_under_the_threshold_never_rises(self):
        self.assertEqual(gate_lines(replay(idle(100).patch_fan(10, 100, F0Tg=1649.0)), "engaged"), [])
        self.assertEqual(
            [fields(x)["engaged"] for _, x in gate_lines(
                replay(idle(100).patch_fan(10, 100, F0Tg=1650.0)), "engaged")], ["rising", "YES"])

    def test_the_threshold_is_the_f0mn_the_package_file_reports(self):
        # F0Mn 1500 makes the threshold 1800: 1700 RPM is no longer engaged
        self.assertEqual(
            gate_lines(replay(idle(100, f0mn=1500.0).patch_fan(10, 100, F0Tg=1700.0)), "engaged"), [])
        w = replay(idle(100, f0mn=1500.0).patch_fan(10, 100, F0Tg=1800.0))
        self.assertEqual(fields(gate_lines(w, "engaged")[-1][1])["thr"], "1800")
        self.assertEqual(fields(gate_lines(w, "engaged")[-1][1])["engaged"], "YES")

    def test_falling_back_below_the_threshold_ends_it(self):
        w = replay(idle(100).patch_fan(10, 50, F0Tg=1700.0))
        self.assertEqual([fields(x)["engaged"] for _, x in gate_lines(w, "engaged")], ["rising", "YES", "NO"])

    def test_a_dip_restarts_the_30_seconds(self):
        w = replay(idle(120).patch_fan(10, 120, F0Tg=1700.0).patch_fan(30, 30.2, F0Tg=1000.0))
        lines = [(t, fields(x)["engaged"]) for t, x in gate_lines(w, "engaged")]
        self.assertEqual([s for _, s in lines], ["rising", "NO", "rising", "YES"])
        self.assertTrue(59.9 <= lines[3][0] <= 60.5, lines)  # 30 s after 30.2 s

    def test_a_gap_in_the_record_restarts_the_30_seconds(self):
        w = replay(idle(120).patch_fan(10, 120, F0Tg=1700.0).drop(20, 25, "fans"))
        lines = [(t, fields(x)["engaged"]) for t, x in gate_lines(w, "engaged")]
        self.assertEqual(lines[-1][1], "YES")
        self.assertTrue(54.9 <= lines[-1][0] <= 55.5, lines)  # 30 s after the record came back at 25 s

    def test_a_dead_record_does_not_claim_it(self):
        w = replay(idle(100).patch_fan(10, 100, F0Tg=1700.0).drop(60, 100, "fans"))
        self.assertEqual([fields(x)["engaged"] for _, x in gate_lines(w, "engaged")][-1], "stale")


class RestClock(unittest.TestCase):
    def clock(self, w):
        return [(t, fields(x)) for t, x in gate_lines(w, "rest-clock")]

    def test_armed_starts_it_and_the_gate_holding_meets_it(self):
        w = replay(idle(200, hottest=40.0).add_ctx(5, "armed"))
        lines = self.clock(w)
        self.assertEqual([f["rest-clock"] for _, f in lines[:1]], ["START"])
        self.assertEqual((lines[0][1]["limit"], lines[0][1]["from"]), ("1800s", "CTX_armed"))
        self.assertEqual([f["rest-clock"] for _, f in lines], ["START", "TICKING", "MET"])
        self.assertTrue(119.3 <= lines[-1][0] <= 119.8, lines)
        self.assertIn(lines[-1][1]["elapsed"], ("114s", "115s"))

    def test_it_ticks_once_a_minute_and_names_why_the_gate_does_not_hold(self):
        # T0 freezes at 40 C (100 of its 120 samples), and the machine is at 48 C after that
        w = replay(idle(400, hottest=40.0).add_ctx(5, "armed").patch_hottest(100, 400, 48.0))
        ticks = [f for _, f in self.clock(w) if f["rest-clock"] == "TICKING"]
        self.assertEqual([f["elapsed"] for f in ticks[:3]], ["60s", "120s", "180s"])
        self.assertEqual([f["why"] for f in ticks[:3]], ["t0", "warm", "warm"])
        self.assertEqual(ticks[0]["left"], "1740s")

    def test_it_expires_at_30_minutes_and_says_to_write_nothing(self):
        # 40 C until the window is complete, then 45 C: T0 freezes at 40, the limit is 43
        run = idle(2000, hottest=40.0).patch_hottest(100, 2000, 45.0).add_ctx(130, "armed")
        lines = self.clock(replay(run))
        self.assertEqual(lines[0][1]["rest-clock"], "START")
        self.assertNotIn("MET", [f["rest-clock"] for _, f in lines])
        expired = [(t, f) for t, f in lines if f["rest-clock"] == "EXPIRED"]
        self.assertEqual(len(expired), 1)
        self.assertTrue(1929.5 <= expired[0][0] <= 1931.0, expired)
        self.assertEqual((expired[0][1]["elapsed"], expired[0][1]["action"]), ("1800s", "no-forward-writes"))

    def test_the_end_of_a_step_starts_it_but_1bs_does_not(self):
        # 1a, then 1b (whose load 1b' continues under), then 1b', then 1c
        run = idle(500, hottest=40.0).add_ctx(120, "armed")
        run.add_ctx(200, "step=1a target=3564 GO").add_ctx(210, "step=none")
        run.add_ctx(250, "step=1b target=5777 GO").add_ctx(260, "step=none")
        run.add_ctx(300, "step=1b' target=none GO").add_ctx(310, "step=none")
        starts = [(t, f["from"]) for t, f in self.clock(replay(run)) if f["rest-clock"] == "START"]
        self.assertEqual([s for _, s in starts], [
            "CTX_armed", "CTX_step=none_after_step_1a", "CTX_step=none_after_step_1b'"])
        self.assertTrue(209.9 <= starts[1][0] <= 210.1 and 309.9 <= starts[2][0] <= 310.1, starts)

    def test_a_step_that_opens_before_the_gate_held_abandons_it(self):
        run = idle(500, hottest=40.0).patch_hottest(100, 500, 48.0).add_ctx(130, "armed")
        run.add_ctx(400, "step=1a target=3564 GO")
        lines = self.clock(replay(run))
        abandoned = [f for _, f in lines if f["rest-clock"] == "ABANDONED"]
        self.assertEqual(len(abandoned), 1)
        self.assertEqual((abandoned[0]["was"], abandoned[0]["step"]), ("ticking", "1a"))

    def test_a_step_that_opens_after_the_gate_held_leaves_nothing_to_say(self):
        run = idle(300, hottest=40.0).add_ctx(5, "armed").add_ctx(200, "step=1a target=3564 GO")
        names = [f["rest-clock"] for _, f in self.clock(replay(run))]
        self.assertNotIn("ABANDONED", names)

    def test_met_stops_the_clock_so_it_cannot_expire_later(self):
        run = idle(2000, hottest=40.0).add_ctx(5, "armed")
        names = [f["rest-clock"] for _, f in self.clock(replay(run))]
        self.assertEqual(names.count("MET"), 1)
        self.assertNotIn("EXPIRED", names)


class GatesAreAdvice(unittest.TestCase):
    def scenarios(self):
        yield idle(200, hottest=40.0).add_ctx(5, "armed")
        yield idle(120, hottest=40.0).patch_fan(10, 100, F0Tg=1700.0, F0Ac=1700.0)
        yield idle(300, hottest=40.0).add_ctx(125, "armed").add_ctx(200, "step=1a target=3000 GO")

    def test_they_raise_nothing_and_count_for_nothing(self):
        for run in self.scenarios():
            w = replay(run, speak=True)
            self.assertTrue(any(level == "GATE" for _, level, _ in w.memory.lines))
            self.assertEqual(w.raised, [])
            self.assertEqual(w.counts, {"NOTE": 0, "WARN": 0})
            self.assertEqual(w.take_speech(), [])
            self.assertEqual(w.memory.alerts, [])

    def test_a_gate_line_is_a_name_and_key_value_tokens_and_nothing_else(self):
        names = {"at-rest", "t0", "engaged", "rest-clock"}
        seen = set()
        for run in list(self.scenarios()) + [
                idle(170).drop(10, 40, "package"), idle(330).add_ctx(50, "armed"),
                idle(2000, hottest=40.0).patch_hottest(100, 2000, 45.0).add_ctx(130, "armed")]:
            for _, level, text in replay(run).memory.lines:
                if level != "GATE":
                    continue
                tokens = text.split()
                self.assertTrue(all("=" in t and not t.startswith("=") for t in tokens), text)
                self.assertIn(tokens[0].split("=")[0], names, text)
                seen.add(tokens[0].split("=")[0])
        self.assertEqual(seen, names)

    def test_the_readme_documents_the_four_gate_lines(self):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "README.md"), encoding="utf-8") as handle:
            text = handle.read()
        for prefix in ("GATE at-rest=", "GATE t0=", "GATE engaged=", "GATE rest-clock="):
            self.assertTrue(prefix in text, "the README does not document %r" % prefix)

    def test_a_replay_of_a_gate_that_raises_is_not_swallowed(self):
        from unittest import mock
        with mock.patch.object(rw.Watcher, "check_gate_rest", side_effect=ValueError("boom")):
            with self.assertRaises(ValueError):
                replay(idle(10))


@unittest.skipUnless(captures_dir(), "P1's captures are not on this machine")
class OnP1(unittest.TestCase):
    """The gates on P1's real record, read and never copied."""

    @classmethod
    def setUpClass(cls):
        base = captures_dir()
        paths = {
            "fans": glob.glob(os.path.join(base, "capture-fans-10hz-*.ndjson"))[0],
            "package": glob.glob(os.path.join(base, "capture-package-1hz-*.ndjson"))[0]}
        out = rw.MemoryOutput()
        cls.watcher = rw.Watcher(out)
        rw.run_events(cls.watcher, rw.load_events(paths), mark_ended=True)
        cls.watcher.memory = out

    def test_p1_raises_nothing_and_the_gates_are_notes_only(self):
        self.assertEqual(titles(self.watcher), [])

    def test_engaged_comes_about_56_s_into_the_sixteen_way_load(self):
        # The ADR says about 56 s (item 8); the runbook's jq fallback, over an arbitrary tail
        # window, 58 s. Load B started at 02:19:52Z.
        started = rw.parse_iso_utc("2026-10-31T02:19:52Z")
        engaged = [(t, fields(x)) for t, x in gate_lines(self.watcher, "engaged")]
        yes = [t + synth.T0 - started for t, f in engaged if f["engaged"] == "YES"]
        self.assertEqual(len(yes), 1, engaged)
        self.assertTrue(54.0 <= yes[0] <= 60.0, yes)

    def test_t0_in_the_idle_phase_is_a_rest_temperature(self):
        idle_end = rw.parse_iso_utc("2026-10-31T01:53:15Z")
        values = [float(fields(x)["t0"]) for t, x in gate_lines(self.watcher, "t0")
                  if fields(x)["t0"] != "unavailable" and t + synth.T0 < idle_end]
        self.assertTrue(values)
        self.assertTrue(34.0 <= values[-1] <= 39.0, values[-1])


if __name__ == "__main__":
    unittest.main()
