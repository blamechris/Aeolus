"""The rules, one class each. Every test replays a synthetic run and reads what was raised.

A rule's test has its own control on the other side of the threshold, because a test that only
shows a rule firing cannot tell a rule from a wrong constant."""

import unittest
from unittest import mock

import run_watch as rw
import synth
from synth import wrote
from support import first, idle, lines, notes, replay, titles

LINE_REFUSED_LANDED = (
    "The engagement of fan 0 was refused after 2 attempt(s): the plane refused. "
    "It was registered with § 3 and handed back, and the restore landed.")
LINE_REFUSED_NOTHING = (
    "The engagement of fan 0 was refused after 1 attempt(s): the entitlement. "
    "Nothing was written.")
LINE_REFUSED_UNDO = (
    "The engagement of fan 0 was refused after 3 attempt(s): the plane refused. "
    "Its hand-back was refused, so the fan may still be off automatic control.")
LINE_COULD_NOT_UNDO = (
    "Could not undo the engagement of fan 0: refused. The fan may still be off automatic control.")
RESET, VERIFY = "ABORT 4 — RESET", "ABORT 4 — VERIFY"


class Rule1Temperature(unittest.TestCase):
    def test_absolute_limit_is_strict(self):
        w = replay(idle(20).patch_hottest(10, 11, 85.0))
        self.assertEqual(titles(w), [])
        w = replay(idle(20).patch_hottest(10, 11, 85.1))
        self.assertEqual(titles(w), ["ABORT 1"])
        self.assertAlmostEqual(first(w, "ABORT 1"), 10.0, 1)

    def test_it_clears_when_the_reading_falls(self):
        w = replay(idle(20).patch_hottest(10, 11, 90.0))
        self.assertEqual(w.active_alerts(), [])
        self.assertEqual(len(lines(w, "CLEAR")), 1)

    def test_loaded_limit_applies_between_load_start_and_load_stop_only(self):
        run = idle(30).add_ctx(5, "load-start step=1b").add_ctx(20, "load-stop")
        self.assertEqual(titles(replay(run.copy().patch_hottest(10, 11, 74.0))), [])
        self.assertEqual(titles(replay(run.copy().patch_hottest(10, 11, 74.1))), ["ABORT 1"])
        self.assertEqual(titles(replay(run.copy().patch_hottest(2, 3, 74.1))), [])
        self.assertEqual(titles(replay(run.copy().patch_hottest(22, 23, 74.1))), [])

    def test_rise_above_b_applies_with_no_load(self):
        # B is the mean of the hottest over the 10 s before the GO: 42.0 here.
        run = idle(40).add_ctx(15, "step=1a target=3000 GO")
        self.assertEqual(titles(replay(run.copy().patch_hottest(25, 26, 52.0))), [])
        w = replay(run.copy().patch_hottest(25, 26, 52.1))
        self.assertEqual(titles(w), ["ABORT 1"])
        self.assertIn("B + 10", w.raised[0].detail)

    def run_1d(self):
        """1d in the runbook's order: GO at rest, then the load, then L2 while the hold and the
        step are still open, then V and step=none. The idle machine reads 42.0, so B is 42.0."""
        run = idle(80).add_ctx(5, "step=1d target=5777 GO").add_ctx(15, "load-start step=1d")
        return run.add_ctx(30, "load-stop").add_ctx(60, "step=none")

    def test_a_rest_baseline_does_not_apply_again_after_a_load_in_the_same_step(self):
        # 55 C is over B + 10 = 52 C, but the machine is heat-soaked from the load, and the load
        # window holds until the step ends: only 74 C applies.
        w = replay(self.run_1d().patch_hottest(40, 41, 55.0))
        self.assertEqual(titles(w), [])
        self.assertTrue(any("B = 42.00" in text for text in lines(w, "INFO")))  # B was taken

    def test_74_holds_after_the_load_stops_until_the_first_step_none(self):
        self.assertEqual(titles(replay(self.run_1d().patch_hottest(40, 41, 74.0))), [])
        w = replay(self.run_1d().patch_hottest(40, 41, 74.1))
        self.assertEqual(titles(w), ["ABORT 1"])
        self.assertIn("load window", w.raised[0].detail)
        self.assertAlmostEqual(first(w, "ABORT 1"), 40.0, 1)
        # ... and after the step=none that ends the window, 74.1 C is rule 1's business no more
        self.assertEqual(titles(replay(self.run_1d().patch_hottest(65, 66, 74.1))), [])

    def test_the_window_ends_at_that_step_none_and_the_next_step_has_its_own_baseline(self):
        run = self.run_1d().add_ctx(65, "step=1a target=3000 GO").patch_hottest(75, 76, 55.0)
        w = replay(run)
        self.assertEqual(titles(w), ["ABORT 1"])
        self.assertIn("B + 10", w.raised[0].detail)

    def run_1b(self):
        """1b's order: the load starts first; 1b's step=none comes while it still runs; 1b' is
        under load; L2 comes during 1b'; its step=none ends the window."""
        run = idle(80).add_ctx(5, "load-start step=1b").add_ctx(10, "step=1b target=5777 GO")
        run.add_ctx(25, "step=none").add_ctx(30, "step=1b' target=none GO")
        return run.add_ctx(40, "load-stop").add_ctx(55, "step=none")

    def test_a_step_none_before_load_stop_does_not_end_the_window(self):
        # 1b' opens at 30 s with B taken under load; at 33 s 60 C is over B + 10 and under 74
        self.assertEqual(titles(replay(self.run_1b().patch_hottest(33, 34, 60.0))), [])
        self.assertEqual(titles(replay(self.run_1b().patch_hottest(33, 34, 74.1))), ["ABORT 1"])

    def test_1b_prime_is_under_74_after_the_load_stops_too(self):
        self.assertEqual(titles(replay(self.run_1b().patch_hottest(45, 46, 60.0))), [])
        self.assertEqual(titles(replay(self.run_1b().patch_hottest(45, 46, 74.1))), ["ABORT 1"])
        self.assertEqual(titles(replay(self.run_1b().patch_hottest(60, 61, 74.1))), [])

    def test_a_load_stop_with_no_step_open_has_no_step_to_carry_the_window(self):
        run = idle(60).add_ctx(5, "load-start step=1b").add_ctx(15, "load-stop")
        run.add_ctx(20, "step=1a target=3000 GO").patch_hottest(40, 41, 55.0)
        self.assertEqual(titles(replay(run)), ["ABORT 1"])  # a step no window covers: B + 10

    def test_the_status_line_shows_74_for_as_long_as_the_window_lasts(self):
        w = replay(self.run_1d())
        status = [(t - synth.T0, text) for t, level, text in w.memory.lines if level == "STATUS"]
        after_load_stop = [text for t, text in status if 40 <= t < 45]
        after_step_none = [text for t, text in status if 65 <= t < 70]
        self.assertEqual((len(after_load_stop), len(after_step_none)), (1, 1))
        self.assertIn("T>74(load)", after_load_stop[0])
        self.assertNotIn("T>74(load)", after_step_none[0])

    def test_rise_does_not_apply_before_a_go_after_step_none_or_under_load(self):
        run = idle(40).add_ctx(15, "step=1a target=3000 GO").add_ctx(30, "step=none")
        self.assertEqual(titles(replay(run.copy().patch_hottest(5, 6, 60.0))), [])
        self.assertEqual(titles(replay(run.copy().patch_hottest(33, 34, 60.0))), [])
        loaded = idle(40).add_ctx(5, "load-start step=1b").add_ctx(15, "step=1b target=5777 GO")
        self.assertEqual(titles(replay(loaded.patch_hottest(25, 26, 60.0))), [])

    def test_b_is_the_mean_over_the_ten_seconds_before_the_stamp(self):
        run = idle(40).patch_hottest(5, 10, 40.0).patch_hottest(10, 15, 44.0)
        run.add_ctx(15, "step=1a target=3000 GO")
        w = replay(run)
        self.assertAlmostEqual(w.b, 42.0, 6)
        self.assertTrue(any("B = 42.00" in text for text in lines(w, "INFO")))

    def test_b_unavailable_is_a_warning_and_leaves_the_absolute_limit(self):
        run = idle(40).drop(0, 40, "package").add_ctx(15, "step=1a target=3000 GO")
        w = replay(run)
        self.assertIsNone(w.b)
        self.assertTrue(any("B is unavailable" in text for text in lines(w, "WARN")))


class Rule2ActualSpeed(unittest.TestCase):
    def loaded(self, seconds=40):
        return idle(seconds).patch_fan(0, seconds, F0Tg=1350, F0Ac=1350, F1Tg=1458, F1Ac=1458)

    def test_an_automatic_fan_halved_for_twelve_seconds(self):
        w = replay(self.loaded().scale_fan(10, 22, "F0Ac", 0.5))
        self.assertEqual(titles(w), ["ABORT 2"])
        self.assertTrue(20.0 <= first(w, "ABORT 2") <= 20.2, first(w, "ABORT 2"))

    def test_under_ten_seconds_is_a_lag_not_an_abort(self):
        self.assertEqual(titles(replay(self.loaded().scale_fan(10, 19.8, "F0Ac", 0.5))), [])

    def test_eighty_percent_exactly_is_not_low(self):
        self.assertEqual(titles(replay(self.loaded().scale_fan(10, 30, "F0Ac", 0.8))), [])
        self.assertEqual(titles(replay(self.loaded().scale_fan(10, 30, "F0Ac", 0.79))), ["ABORT 2"])

    def test_a_target_of_zero_is_not_demanded(self):
        run = idle(40).patch_fan(0, 40, F0Tg=0, F0Ac=0, F1Tg=0, F1Ac=0)
        self.assertEqual(titles(replay(run)), [])

    def test_fan_one_is_always_automatic(self):
        w = replay(self.loaded().scale_fan(10, 22, "F1Ac", 0.5))
        self.assertEqual(titles(w), ["ABORT 2"])

    def test_the_held_fan_is_counted_from_ten_seconds_after_it_reads_its_target(self):
        target = 3000

        def held(stall_from):
            run = idle(90).add_ctx(4.95, "step=1a target=%d GO" % target)
            run.add_log(5.0, wrote("F0Md", "0x1")).add_log(5.1, wrote("F0Tg", "0x0 0x0"))
            run.patch_fan(5.1, 90, F0Md=1, F0Tg=target, F0Ac=target)
            run.add_log(5.05, wrote("Ftst", "0x1")).patch_fan(5.1, 90, Ftst=1)
            return run.scale_fan(stall_from, 90, "F0Ac", 0.5)

        # F0Tg reads the target at 5.1 s; counting starts at 15.1 s; ten more seconds is 25.1 s.
        w = replay(held(15.2))
        self.assertEqual(titles(w), ["ABORT 2"])
        self.assertTrue(25.0 <= first(w, "ABORT 2") <= 26.0, first(w, "ABORT 2"))
        # A stall during the spin-up allowance is not counted.
        self.assertEqual(titles(replay(held(7.0).scale_fan(15.2, 90, "F0Ac", 2.0))), [])

    def test_a_held_fan_still_spinning_up_ten_seconds_after_its_target_is_not_an_abort(self):
        # F0Tg reads the target at 5.1 s and the fan takes 12 s to reach 80 % of it. Counting
        # starts 10 s in, so only 2 s of that is counted: a spin-up, not a stall. Without the
        # allowance the same 12 s is counted whole and is ABORT 2 at 15.1 s.
        run = idle(60).add_ctx(4.95, "step=1a target=3000 GO")
        run.add_log(5.0, wrote("Ftst", "0x1")).add_log(5.03, wrote("F0Md", "0x1"))
        run.add_log(5.06, wrote("F0Tg", "0x0 0x0 0x80 0x3f"))
        run.patch_fan(5.1, 60, Ftst=1, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)
        run.scale_fan(5.1, 17.1, "F0Ac", 0.5)
        self.assertEqual(titles(replay(run)), [])

    def test_fan_one_is_checked_during_a_hold(self):
        # Apple's fan stalls while fan 0 is held: abort 2 is still the automatic fan's rule.
        run = idle(60).hold(go=10, restore=50, target=3000)
        run.patch_fan(10, 60, F1Tg=1458.0, F1Ac=1458.0).scale_fan(25, 40, "F1Ac", 0.5)
        w = replay(run)
        self.assertEqual(titles(w), ["ABORT 2"])
        self.assertTrue(35.0 <= first(w, "ABORT 2") <= 35.3, first(w, "ABORT 2"))
        self.assertIn("fan 1", w.raised[0].detail)

    def test_a_well_formed_hold_raises_nothing(self):
        run = idle(60).hold(go=10, restore=40, target=3000)
        w = replay(run)
        self.assertEqual(titles(w), [])
        self.assertIsNone(w.engage_t)  # the restore was verified


class Rule3Unexplained(unittest.TestCase):
    def test_ftst_changing_with_no_write(self):
        w = replay(idle(30).patch_fan(10, 10.1, Ftst=1))
        self.assertEqual(set(titles(w)), {"ABORT 3"})
        self.assertTrue(12.0 <= first(w, "ABORT 3") <= 12.2, first(w, "ABORT 3"))

    def test_a_write_within_the_window_explains_it(self):
        for offset in (-1.8, -0.1, 0.0, 0.4):
            run = idle(30).patch_fan(10, 10.1, Ftst=1).add_log(10 + offset, wrote("Ftst", "0x1"))
            self.assertEqual(titles(replay(run)), [], offset)

    def test_a_write_outside_the_window_does_not(self):
        for offset in (-2.3, 0.7):
            run = idle(30).patch_fan(10, 10.1, Ftst=1).add_log(10 + offset, wrote("Ftst", "0x1"))
            self.assertIn("ABORT 3", titles(replay(run)), offset)

    def test_a_write_of_another_key_does_not_explain_it(self):
        run = idle(30).patch_fan(10, 10.1, Ftst=1).add_log(10, wrote("F0Md", "0x1"))
        self.assertIn("ABORT 3", titles(replay(run)))

    def test_any_f1md_outside_zero_and_three(self):
        for value in (1, 2):
            w = replay(idle(30).patch_fan(10, 10.1, F1Md=value))
            self.assertEqual(set(titles(w)), {"ABORT 3"}, value)
            self.assertAlmostEqual(first(w, "ABORT 3"), 10.0, 1)
        for value in (0, 3):
            self.assertEqual(titles(replay(idle(30).patch_fan(10, 10.1, F1Md=value))), [])

    def test_f0md_outside_the_set_for_two_seconds_with_no_hold(self):
        w = replay(idle(30).patch_fan(10, 12.5, F0Md=1))
        self.assertIn("ABORT 3", titles(w))
        self.assertTrue(12.0 <= first(w, "ABORT 3") <= 12.2, first(w, "ABORT 3"))
        self.assertNotIn("ABORT 3", titles(replay(idle(30).patch_fan(10, 11.9, F0Md=1))))

    def test_f0md_one_is_exempt_during_a_hold_but_two_is_not(self):
        base = idle(30).add_ctx(8, "step=1a target=3000 GO").add_log(9.9, wrote("F0Md", "0x1"))
        held = base.copy().patch_fan(10, 30, F0Md=1, F0Tg=3000, F0Ac=3000, Ftst=1)
        held.add_log(9.92, wrote("Ftst", "0x1")).add_log(9.95, wrote("F0Tg", "0x0"))
        self.assertEqual(titles(replay(held)), [])
        # The write at 9.9 s is not near a mode that first reads 2 at 14 s: nothing explains it.
        two = base.copy().patch_fan(14, 18, F0Md=2)
        self.assertIn("ABORT 3", titles(replay(two)))

    def test_a_mode_write_explains_a_mode_change(self):
        run = idle(30).patch_fan(10, 12.5, F0Md=2).add_log(9.5, wrote("F0Md", "0x2"))
        self.assertNotIn("ABORT 3", titles(replay(run)))

    def test_during_a_hold_the_target_may_not_move_unwritten(self):
        def hold(target_after):
            run = idle(40).add_ctx(4.9, "step=1a target=3000 GO")
            run.add_log(5, wrote("F0Md", "0x1")).add_log(5.05, wrote("F0Tg", "0x0"))
            run.patch_fan(5.1, 40, F0Md=1, F0Tg=3000, F0Ac=3000, Ftst=1)
            run.add_log(5.02, wrote("Ftst", "0x1"))
            return run.patch_fan(20, 40, F0Tg=target_after, F0Ac=target_after)

        self.assertEqual(titles(replay(hold(3001.0))), [])  # one RPM is not a move
        w = replay(hold(3002.0))
        self.assertIn("ABORT 3", titles(w))
        explained = hold(3002.0).add_log(19.9, wrote("F0Tg", "0x0"))
        self.assertNotIn("ABORT 3", titles(replay(explained)))

    def restored(self, hold_seconds, lag=None, go=3.0):
        """A hold of `hold_seconds` whose restore turn answers 0x00 and puts Ftst back to 0, with
        F0Md still reading 1 afterwards: for `lag` seconds after the restore's stamp (a readback
        that is late), or for good (a restore that did not take). Returns (run, restore)."""
        restore = go + hold_seconds
        run = idle(restore + 30.0, f0mn=1350.0)
        run.hold(go=go, restore=restore, target=3000, close=False)
        end = 1e9 if lag is None else restore + lag
        run.patch_fan(restore + 0.2, end, Ftst=0, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)
        return run, restore

    def test_a_restore_that_did_not_take_is_heard_two_seconds_after_it_whatever_the_hold(self):
        # F0Md stuck at 1 after the restore. The hold's own F0Md = 1 is exempt, so the 2 s clock
        # starts when the hold ends. Before, it started at the engagement: a hold under 90 s was
        # silent until ABORT 8, and a longer one was heard 0.6 s after the restore, before the
        # readback could have caught up.
        for hold in (30.0, 60.0, 85.0, 120.0):
            with self.subTest(hold=hold):
                run, restore = self.restored(hold)
                w = replay(run)
                self.assertEqual(titles(w), ["ABORT 3"])
                late = first(w, "ABORT 3") - restore
                self.assertTrue(2.0 <= late <= 4.5, late)

    def test_a_restore_whose_readback_lags_is_not_an_abort(self):
        for hold in (60.0, 120.0):
            for lag in (0.7, 1.5):
                with self.subTest(hold=hold, lag=lag):
                    run, _ = self.restored(hold, lag=lag)
                    self.assertEqual(titles(replay(run)), [])

    def test_a_readback_that_lags_past_two_seconds_is_an_abort(self):
        run, restore = self.restored(120.0, lag=2.5)
        w = replay(run)
        self.assertEqual(titles(w), ["ABORT 3"])
        self.assertTrue(2.0 <= first(w, "ABORT 3") - restore <= 4.5)

    def readback_as_read(self, lag, delay=0.05):
        """A hold restored at 30 s, whose F0Md still reads 1 for `lag` seconds after the restore's
        stamp, with the events fed in the order the live loop meets them rather than the order of
        their stamps: each fan sample is read `delay` after its stamp, the restore line 10 ms after
        its. The sample stamped 30 ms before the restore is therefore read after the line, when no
        hold is active any more. Returns (alert titles, seconds after the restore of the first)."""
        t0, restore = 1000.0, 1030.0
        watcher = rw.Watcher(rw.MemoryOutput())
        watcher.start(t0)
        watcher.on_ctx(rw.CtxLine(t0, "step", "1a", 3000.0, None, "step=1a target=3000 GO"))
        watcher.on_log(rw.LogLine(t0 + 0.08, "Default", wrote("Ftst", "0x1"), False))
        watcher.on_log(rw.LogLine(t0 + 0.10, "Default", wrote("F0Md", "0x1"), False))
        events = []
        for i in range(2, 400):
            stamp = t0 + i * 0.1 - 0.03
            values = {
                "F0Md": 1 if stamp < restore + (1e9 if lag is None else lag) else 0,
                "Ftst": 1 if stamp < restore else 0, "F0Tg": 3000.0, "F0Ac": 3000.0,
                "F1Md": 0, "F1Tg": 0.0, "F1Ac": 0.0}
            events.append((stamp + delay, "fan", rw.FanSample(stamp, values)))
        for i in range(40):
            events.append((t0 + i + 0.02, "package", rw.PackageSample(t0 + i, 42.0, {})))
        events.append((restore + 0.01, "log", rw.LogLine(
            restore, "Default", wrote("F0Md", "0x0"), False)))
        events.append((restore + 0.011, "log", rw.LogLine(
            restore + 0.03, "Default", wrote("Ftst", "0x0"), False)))
        handlers = {"fan": watcher.on_fan, "package": watcher.on_package, "log": watcher.on_log}
        wall = t0 + 0.2
        for arrival, kind, payload in sorted(events, key=lambda e: e[0]):
            while wall + 0.05 < arrival:
                wall += 0.05
                watcher.advance(wall)
            handlers[kind](payload)
            watcher.advance(arrival)
        raised = [(r.t - restore, r.title) for r in watcher.raised]
        return [title for _, title in raised], raised[0][0] if raised else None

    def test_a_readback_that_lags_by_under_two_seconds_is_silent_in_the_order_the_loop_reads_it(self):
        # Before, the sample stamped just before the restore was read after the restore line, with
        # no hold active, so it was queued as an out-of-set reading and judged 2 s after its own
        # stamp: a lag of 1.9 s was an abort, and the tolerance was about 1.9 s, not 2.
        for lag in (0.7, 1.5, 1.8, 1.9, 1.95):
            with self.subTest(lag=lag):
                self.assertEqual(self.readback_as_read(lag)[0], [])

    def test_a_readback_that_lags_by_over_two_seconds_is_an_abort_in_that_order_too(self):
        # The first sample stamped at or after the restore is 70 ms after it (the samples are 30 ms
        # before each tick), so it is 2 s old 2.07 s after the restore, which the loop's 50 ms grid
        # reads as 2.1 s. Counted from the stale sample stamped before the restore it was 2.0 s.
        for lag in (2.1, 2.5):
            with self.subTest(lag=lag):
                titles_, at = self.readback_as_read(lag)
                self.assertEqual(titles_, ["ABORT 3"])
                self.assertTrue(2.05 <= at <= 2.3, at)

    def test_a_restore_that_did_not_take_is_still_heard_two_seconds_after_it_in_that_order(self):
        titles_, at = self.readback_as_read(None)
        self.assertEqual(titles_, ["ABORT 3"])
        self.assertTrue(2.05 <= at <= 2.3, at)  # 2.1 s: see the test above

    def test_the_hold_itself_is_not_counted_towards_the_two_seconds(self):
        # a long hold with F0Md = 1 throughout, restored cleanly: nothing, at any length
        for hold in (30.0, 120.0):
            run = idle(3.0 + hold + 30.0).hold(go=3.0, restore=3.0 + hold, target=3000)
            self.assertEqual(titles(replay(run)), [], hold)

    def test_a_write_of_another_value_does_not_explain_a_reading(self):
        # F0Md reads 1 with no hold, 0.1 s after a `Wrote F0Md = 0x0`: that explains a 0
        run = idle(30).add_ctx(5, "step=1a target=3000 GO").add_log(9.9, wrote("F0Md", "0x0"))
        run.patch_fan(10, 13, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)
        w = replay(run)
        self.assertIn("ABORT 3", titles(w))
        self.assertTrue(12.0 <= first(w, "ABORT 3") <= 12.2, first(w, "ABORT 3"))

    def test_a_write_of_the_value_read_explains_it_for_its_own_window_only(self):
        # a refused `Wrote F0Md = 0x1` (so no hold): the samples within 2 s after it are explained
        # ...
        def reading(write_at):
            run = idle(30).add_ctx(5, "step=1a target=3000 GO")
            run.add_log(write_at, wrote("F0Md", "0x1", answer="0x82"))
            return run.patch_fan(10, 13, F0Md=1, F0Tg=3000.0, F0Ac=3000.0)

        self.assertNotIn("ABORT 3", titles(replay(reading(9.9))))
        # ... and a write three seconds earlier no longer explains the reading
        self.assertIn("ABORT 3", titles(replay(reading(7.0))))
        # a write after the reading has run on for 2 s does not reach back to it either
        self.assertIn("ABORT 3", titles(replay(reading(13.6))))

    def test_a_mode_write_stamped_after_the_reading_began_explains_it_only_within_half_a_second(self):
        # F0Md reads 2 from 10 s to 13 s with no hold. The only `Wrote F0Md = 0x2` is stamped at
        # 11.5 s, 1.5 s after the mode changed: the first sample, at 10.0 s, is explained by a
        # write up to 10.5 s, and is not. Judged 2 s on, that is ABORT 3 at 12.0 s. A window that
        # reached 2 s ahead of a sample, as the judging delay does, would explain every sample.
        run = idle(30).add_ctx(5, "step=1a target=3000 GO").add_log(11.5, wrote("F0Md", "0x2"))
        run.patch_fan(10, 13, F0Md=2)
        w = replay(run)
        self.assertEqual(set(titles(w)), {"ABORT 3"})
        self.assertTrue(12.0 <= first(w, "ABORT 3") <= 12.2, first(w, "ABORT 3"))

    def test_during_a_hold_the_mode_may_not_leave_one_unwritten(self):
        run = idle(40).add_ctx(4.9, "step=1a target=3000 GO").add_log(5, wrote("F0Md", "0x1"))
        run.add_log(5.02, wrote("Ftst", "0x1")).add_log(5.05, wrote("F0Tg", "0x0"))
        run.patch_fan(5.1, 40, F0Md=1, F0Tg=3000, F0Ac=3000, Ftst=1)
        run.patch_fan(20, 40, F0Md=0)
        self.assertIn("ABORT 3", titles(replay(run)))
        self.assertNotIn("ABORT 3", titles(replay(run.add_log(19.9, wrote("F0Md", "0x0")))))


class Rule4Refused(unittest.TestCase):
    def refusal(self, message, at=10, **patches):
        run = idle(40).add_log(at, message)
        return run

    def test_a_landed_undo_with_a_clean_sample_is_verify(self):
        w = replay(self.refusal(LINE_REFUSED_LANDED))
        self.assertEqual(titles(w), ["ABORT 4 — VERIFY"])
        self.assertTrue(10.0 <= first(w, "ABORT 4 — VERIFY") <= 10.2)

    def test_verify_is_not_escalated_later(self):
        w = replay(self.refusal(LINE_REFUSED_LANDED))
        self.assertNotIn("ABORT 4 — RESET", titles(w))

    def test_ftst_in_the_first_sample_after_it_is_reset(self):
        w = replay(self.refusal(LINE_REFUSED_LANDED).patch_fan(10.0, 10.2, Ftst=1))
        self.assertEqual(titles(w).count("ABORT 4 — RESET"), 1)
        self.assertNotIn("ABORT 4 — VERIFY", titles(w))

    def test_a_mode_outside_the_set_in_the_first_sample_is_reset(self):
        w = replay(self.refusal(LINE_REFUSED_LANDED).patch_fan(10.0, 10.2, F0Md=1))
        self.assertIn("ABORT 4 — RESET", titles(w))
        self.assertNotIn("ABORT 4 — VERIFY", titles(w))

    def test_a_fan_one_mode_outside_the_set_in_the_first_sample_is_reset(self):
        for value in (1, 2):
            with self.subTest(F1Md=value):
                w = replay(self.refusal(LINE_REFUSED_LANDED).patch_fan(10.0, 10.2, F1Md=value))
                self.assertIn(RESET, titles(w))
                self.assertNotIn(VERIFY, titles(w))

    def test_a_phrase_the_detail_quotes_is_not_the_outcome(self):
        # the detail says "the restore landed", the outcome (the last sentence) says it did not
        quoted = (
            "The engagement of fan 0 was refused after 3 attempt(s): the plane said the restore "
            "landed. Its hand-back was refused, so the fan may still be off automatic control.")
        w = replay(self.refusal(quoted))
        self.assertEqual(titles(w), [RESET])

    def test_a_nothing_was_written_in_the_detail_does_not_hide_a_landed_undo(self):
        quoted = (
            "The engagement of fan 0 was refused after 2 attempt(s): the plane said Nothing was "
            "written. It was registered with § 3 and handed back, and the restore landed.")
        w = replay(self.refusal(quoted))
        self.assertEqual(titles(w), [VERIFY])

    def test_another_lines_phrase_inside_a_detail_is_not_that_line(self):
        quoted = (
            "The engagement of fan 0 was refused after 1 attempt(s): see Could not undo the "
            "engagement of fan 1. Nothing was written.")
        w = replay(self.refusal(quoted))
        self.assertEqual(titles(w), [])
        self.assertTrue(any("nothing was written" in text for text in notes(w)))

    def test_a_dirty_sample_before_the_line_is_not_the_first_after_it(self):
        w = replay(self.refusal(LINE_REFUSED_LANDED).patch_fan(9.0, 9.95, Ftst=1))
        self.assertIn("ABORT 4 — VERIFY", titles(w))
        self.assertNotIn("ABORT 4 — RESET", titles(w))

    def test_a_hand_back_that_was_refused_is_reset(self):
        self.assertIn("ABORT 4 — RESET", titles(replay(self.refusal(LINE_REFUSED_UNDO))))

    def test_could_not_undo_is_reset_and_a_fault_when_logged_as_one(self):
        w = replay(idle(40).add_log(10, LINE_COULD_NOT_UNDO, "Fault"))
        self.assertEqual(set(titles(w)), {"ABORT 4 — RESET", "HELPER FAULT"})

    def test_nothing_written_is_not_an_abort(self):
        w = replay(self.refusal(LINE_REFUSED_NOTHING))
        self.assertEqual(titles(w), [])
        self.assertTrue(any("nothing was written" in text for text in notes(w)))

    def test_no_sample_within_ten_seconds_is_reset(self):
        run = idle(40).drop(9.95, 40, "fans").add_log(10, LINE_REFUSED_LANDED)
        w = replay(run)
        self.assertIn("ABORT 4 — RESET", titles(w))
        self.assertTrue(20.0 <= first(w, "ABORT 4 — RESET") <= 20.3)

    def test_a_line_that_arrives_after_later_samples_still_uses_the_first_after_its_stamp(self):
        # The sample stamped 10.0 is clean and 11.0 is not; the line is stamped 10.0. Feeding
        # the line after the 11.0 sample (a slow log stream) must not make it RESET.
        import run_watch as rw
        out = rw.MemoryOutput()
        watcher = rw.Watcher(out)
        run = idle(20).patch_fan(11.0, 11.2, Ftst=1)
        for record in run.fans:
            if rw.parse_fan_line(__import__("json").dumps(record)).t <= synth.T0 + 11.05:
                watcher.on_fan(rw.parse_fan_line(__import__("json").dumps(record)))
        line = rw.parse_log_line(__import__("json").dumps(
            synth.log_record(synth.T0 + 10.0, LINE_REFUSED_LANDED)))
        watcher.on_log(line)
        self.assertEqual([r.title for r in watcher.raised], ["ABORT 4 — VERIFY"])


class Rule5SlowWrite(unittest.TestCase):
    def duration(self, text):
        return replay(idle(30).add_log(10, wrote("F0Md", "0x1", seconds=text)).add_log(
            10.5, wrote("F0Md", "0x0")))

    def test_one_point_two_seconds_fires(self):
        self.assertIn("ABORT 5", titles(self.duration("1.2")))

    def test_the_same_in_scientific_notation_fires(self):
        self.assertIn("ABORT 5", titles(self.duration("1.2e+00")))

    def test_one_second_exactly_fires_and_just_under_does_not(self):
        self.assertIn("ABORT 5", titles(self.duration("1.0")))
        self.assertNotIn("ABORT 5", titles(self.duration("0.999")))

    def test_fifty_three_microseconds_does_not(self):
        w = self.duration("5.3083e-05")
        self.assertEqual(titles(w), [])
        self.assertEqual(notes(w), [])

    def test_a_naive_digit_match_would_have_read_it_as_slow(self):
        # F2: the text contains a nonzero digit after "in ". The parse must not care.
        text = wrote("F0Md", "0x1", seconds="5.3083e-05")
        self.assertRegex(text, r"in [1-9]")
        self.assertEqual(titles(replay(idle(20).add_log(5, text).add_log(5.5, wrote("F0Md", "0x0")))), [])

    def test_the_notes_at_twenty_and_fifty_milliseconds(self):
        self.assertTrue(any("above G's 20 ms" in n for n in notes(self.duration("0.025"))))
        slow = self.duration("0.06")
        self.assertTrue(any("above 50 ms: forward writes end after this hold" in n for n in notes(slow)))
        self.assertEqual(notes(self.duration("0.019")), [])
        self.assertEqual(titles(slow), [])

    def test_a_write_line_that_does_not_parse(self):
        for message in (
                "Wrote F0Md = 0x1: answered 0x00, in a while.",
                "Wrote F0Md = 0x1: answered 0x00, in nan seconds.",
                "Wrote F0Md = 0x1: answered 0x00, in -1.0 seconds.",
                "Wrote F0Md = 0x1",):
            w = replay(idle(20).add_log(5, message))
            self.assertEqual(titles(w), ["UNPARSED WRITE"], message)

    def test_a_line_that_is_not_a_write_is_not_read_as_one(self):
        self.assertEqual(titles(replay(idle(20).add_log(5, "Fan 0's engagement asks the plane"))), [])


class Rule6Pressure(unittest.TestCase):
    def test_pressure_not_zero(self):
        run = idle(30).add_poll(5, "pressure", level=0).add_poll(10, "pressure", level=1)
        run.add_poll(15, "pressure", level=0)
        w = replay(run)
        self.assertEqual(titles(w), ["ABORT 6"])
        self.assertAlmostEqual(first(w, "ABORT 6"), 10.0, 1)
        self.assertEqual(w.active_alerts(), [])

    def test_zero_throughout_is_silent(self):
        run = idle(30)
        for s in range(0, 30):
            run.add_poll(s, "pressure", level=0)
        self.assertEqual(titles(replay(run)), [])

    def test_pmset_changing_is_a_note_not_an_alert(self):
        run = idle(30).add_poll(5, "pmset", text="a").add_poll(10, "pmset", text="a")
        self.assertEqual(notes(replay(run)), [])
        run.add_poll(15, "pmset", text="b")
        w = replay(run)
        self.assertEqual(titles(w), [])
        self.assertEqual(len(notes(w)), 1)


class Rule7HelperRestart(unittest.TestCase):
    def armed(self):
        return idle(40).add_ctx(5, "armed pid=100").add_poll(6, "pgrep", pids=[100])

    def test_the_same_pid_is_silent(self):
        self.assertEqual(titles(replay(self.armed().add_poll(20, "pgrep", pids=[100]))), [])

    def test_a_new_pid_outside_a_hold(self):
        w = replay(self.armed().add_poll(20, "pgrep", pids=[101]))
        self.assertEqual(titles(w), ["HELPER RESTARTED"])

    def test_a_new_or_missing_pid_during_a_hold_is_abort_7(self):
        run = self.armed().add_log(10, wrote("F0Md", "0x1"))
        self.assertEqual(titles(replay(run.copy().add_poll(20, "pgrep", pids=[101]))), ["ABORT 7"])
        self.assertEqual(titles(replay(run.copy().add_poll(20, "pgrep", pids=[]))), ["ABORT 7"])

    def test_a_second_preparation_step_line_after_armed(self):
        line = "The write path's preparation step enumerated 2 fan(s) [0, 1], found the force key"
        self.assertEqual(titles(replay(idle(40).add_log(2, line).add_ctx(5, "armed pid=100"))), [])
        w = replay(idle(40).add_log(2, line).add_ctx(5, "armed pid=100").add_log(20, line))
        self.assertEqual(titles(w), ["HELPER RESTARTED"])

    def test_without_a_pid_on_the_line_the_first_poll_is_adopted(self):
        run = idle(40).add_ctx(5, "armed").add_poll(6, "pgrep", pids=[100])
        self.assertEqual(titles(replay(run.add_poll(20, "pgrep", pids=[100]))), [])
        self.assertEqual(titles(replay(run.add_poll(25, "pgrep", pids=[101]))), ["HELPER RESTARTED"])

    def test_nothing_before_armed_and_nothing_after_end(self):
        run = idle(40).add_poll(2, "pgrep", pids=[100]).add_poll(3, "pgrep", pids=[101])
        self.assertEqual(titles(replay(run)), [])
        after = self.armed().add_ctx(10, "end").add_poll(20, "pgrep", pids=[101])
        self.assertEqual(titles(replay(after)), [])


class Rule8Restore(unittest.TestCase):
    def engaged(self, seconds=330):
        run = idle(seconds).add_ctx(9.9, "step=1a target=3000 GO")
        run.add_log(10, wrote("Ftst", "0x1")).add_log(10.03, wrote("F0Md", "0x1"))
        run.add_log(10.06, wrote("F0Tg", "0x0"))
        return run.patch_fan(10.1, seconds, Ftst=1, F0Md=1, F0Tg=3000, F0Ac=3000)

    def test_warning_at_four_minutes_and_abort_at_five(self):
        w = replay(self.engaged())
        self.assertEqual(set(titles(w)), {"ABORT 8"})
        self.assertTrue(309.9 <= first(w, "ABORT 8") <= 310.2, first(w, "ABORT 8"))
        warned = lines(w, "WARN")
        self.assertEqual(len(warned), 1)
        self.assertTrue(any("4" in text or "240" in text for text in warned))

    def test_four_minutes_fifty_nine_is_only_a_warning(self):
        w = replay(self.engaged(seconds=309.0))
        self.assertEqual(titles(w), [])
        self.assertEqual(len(lines(w, "WARN")), 1)

    def restored(self, seconds, dirty_at=None):
        """Engaged at 10 s, restored by a write at 100 s; the samples return to Apple's set."""
        run = self.engaged(seconds).patch_fan(100, seconds, Ftst=0, F0Md=3, F0Tg=0, F0Ac=0)
        run.add_log(100, wrote("F0Md", "0x0")).add_log(100.03, wrote("Ftst", "0x0"))
        if dirty_at is not None:
            run.patch_fan(dirty_at, dirty_at + 0.1, F0Md=2)  # one sample outside {0, 3}
        return run

    def test_a_verified_restore_ends_it(self):
        w = replay(self.restored(330))
        self.assertEqual(titles(w), [])
        self.assertIsNone(w.engage_t)

    def test_a_restore_is_not_verified_until_ten_clean_seconds_follow(self):
        self.assertIsNotNone(replay(self.restored(109.5)).engage_t)
        self.assertIsNone(replay(self.restored(111)).engage_t)

    def test_a_dirty_sample_inside_the_ten_seconds_restarts_the_count(self):
        self.assertIsNotNone(replay(self.restored(114, dirty_at=105)).engage_t)
        self.assertIsNone(replay(self.restored(116, dirty_at=105)).engage_t)

    def test_an_unverified_restore_still_ends_in_abort_8(self):
        w = replay(self.restored(330, dirty_at=105).patch_fan(106, 330, F0Md=2))
        self.assertIn("ABORT 8", titles(w))

    def test_a_refused_engage_starts_the_clock_but_not_the_hold(self):
        run = idle(330).add_log(10, wrote("F0Md", "0x1", answer="0x82"))
        w = replay(run)
        self.assertFalse(w.hold_active)
        self.assertIn("ABORT 8", titles(w))


class Rule9Rule10(unittest.TestCase):
    def held(self, target, **fan):
        run = idle(60).add_ctx(9.9, "step=1b target=%s GO" % target)
        run.add_log(10, wrote("Ftst", "0x1")).add_log(10.03, wrote("F0Md", "0x1"))
        run.add_log(10.06, wrote("F0Tg", "0x0"))
        run.patch_fan(10.1, 60, Ftst=1, F0Md=1, F0Tg=target, F0Ac=target)
        return run

    def test_fan_one_following_apple_above_ninety_percent(self):
        run = self.held(5000).patch_fan(30, 40, F1Tg=4501.0, F1Ac=4501.0)
        w = replay(run)
        self.assertEqual(set(titles(w)), {"ABORT 9"})
        self.assertAlmostEqual(first(w, "ABORT 9"), 30.0, 1)

    def test_ninety_percent_exactly_is_not_over(self):
        run = self.held(5000).patch_fan(30, 40, F1Tg=4500.0, F1Ac=4500.0)
        self.assertEqual(titles(replay(run)), [])

    def test_not_during_a_hold_and_not_with_no_target(self):
        quiet = idle(60).add_ctx(9.9, "step=1b target=5000 GO").patch_fan(30, 40, F1Tg=4900, F1Ac=4900)
        self.assertEqual(titles(replay(quiet)), [])
        run = idle(60).add_ctx(9.9, "step=1b' target=none GO")
        run.add_log(10, wrote("F0Md", "0x1")).patch_fan(30, 40, F1Tg=4900, F1Ac=4900)
        self.assertNotIn("ABORT 9", titles(replay(run)))

    def floor(self, seconds, tg=0, mn=None):
        run = idle(40, f0mn=mn).add_ctx(4, "step=1a target=3000 GO").add_log(5, wrote("F0Md", "0x1"))
        return run.patch_fan(10, 10 + seconds, F0Md=1, F0Tg=tg)

    def test_f0md_one_with_the_target_under_the_floor_for_more_than_a_second(self):
        w = replay(self.floor(1.2))
        self.assertIn("ABORT 10", titles(w))
        self.assertTrue(11.0 < first(w, "ABORT 10") <= 11.3, first(w, "ABORT 10"))
        self.assertNotIn("ABORT 10", titles(replay(self.floor(1.0))))

    def test_a_recovery_above_the_floor_restarts_the_second(self):
        # below the floor for 0.5 s, above it for 0.5 s, below it for 0.5 s: never a second at a
        # time, so no abort. A recovery that did not restart the count would make it 1.1 s.
        run = self.floor(0.0, tg=3000.0).patch_fan(10, 40, F0Md=1, F0Tg=3000.0)
        run.patch_fan(10, 10.5, F0Tg=0.0).patch_fan(11, 11.5, F0Tg=0.0)
        self.assertNotIn("ABORT 10", titles(replay(run)))
        # the same dips run together are a second and a half
        together = self.floor(0.0, tg=3000.0).patch_fan(10, 40, F0Md=1, F0Tg=3000.0)
        self.assertIn("ABORT 10", titles(replay(together.patch_fan(10, 11.5, F0Tg=0.0))))

    def test_the_floor_is_the_packages_f0mn_once_read(self):
        self.assertIn("ABORT 10", titles(replay(self.floor(2.0, tg=1700, mn=1800.0))))
        self.assertNotIn("ABORT 10", titles(replay(self.floor(2.0, tg=1800, mn=1800.0))))
        self.assertIn("ABORT 10", titles(replay(self.floor(2.0, tg=1349))))
        self.assertNotIn("ABORT 10", titles(replay(self.floor(2.0, tg=1350))))


class Rule11F1Idle(unittest.TestCase):
    def run1d(self, seconds=80):
        return idle(seconds).add_ctx(5, "load-start step=1d")

    def test_time_at_sixty_seconds(self):
        w = replay(self.run1d())
        self.assertEqual(set(titles(w)), {"ABORT 11 TIME"})
        self.assertTrue(64.9 <= first(w, "ABORT 11 TIME") <= 65.2, first(w, "ABORT 11 TIME"))
        self.assertEqual(len(lines(w, "WARN")), 1)

    def test_fifty_nine_seconds_is_a_warning_only(self):
        w = replay(self.run1d(seconds=64.5))
        self.assertEqual(titles(w), [])
        self.assertEqual(len(lines(w, "WARN")), 1)

    def test_temperature_at_fifty_with_f1tg_still_zero(self):
        w = replay(self.run1d().patch_hottest(35, 36, 50.0))
        self.assertIn("ABORT 11 TEMPERATURE", titles(w))
        self.assertAlmostEqual(first(w, "ABORT 11 TEMPERATURE"), 35.0, 1)
        self.assertNotIn("ABORT 11 TEMPERATURE", titles(replay(self.run1d().patch_hottest(35, 36, 49.9))))

    def test_f1tg_leaving_zero_disarms_and_is_logged(self):
        run = self.run1d().patch_fan(19, 80, F1Tg=1458, F1Ac=1458).patch_hottest(0, 80, 40.0)
        w = replay(run)
        self.assertEqual(titles(w), [])
        left = [t for t in lines(w, "INFO") if "F1Tg left 0" in t]
        self.assertEqual(len(left), 1)
        self.assertIn("14.0 s", left[0])
        self.assertIn("40.0 C", left[0])

    def test_after_it_has_left_zero_a_hot_machine_is_rule_1s_business(self):
        run = self.run1d().patch_fan(19, 80, F1Tg=1458, F1Ac=1458).patch_hottest(40, 41, 55.0)
        self.assertEqual(titles(replay(run)), [])

    def test_load_stop_disarms_it(self):
        self.assertEqual(titles(replay(self.run1d().add_ctx(30, "load-stop"))), [])

    def test_only_step_1d_arms_it(self):
        self.assertEqual(titles(replay(idle(80).add_ctx(5, "load-start step=1b"))), [])


class Rule12Blind(unittest.TestCase):
    def test_a_three_second_fan_gap_during_a_hold_is_abort_12(self):
        run = idle(40).hold(go=10, restore=30, target=3000).drop(20, 23, "fans")
        w = replay(run)
        self.assertEqual(set(titles(w)), {"ABORT 12"})
        self.assertTrue(21.9 <= first(w, "ABORT 12") <= 22.2, first(w, "ABORT 12"))

    def test_the_same_gap_outside_a_hold_is_blind_no_go(self):
        w = replay(idle(40).drop(20, 23, "fans"))
        self.assertEqual(set(titles(w)), {"BLIND — NO GO"})

    def test_a_gap_under_two_seconds_is_fine(self):
        self.assertEqual(titles(replay(idle(40).drop(20, 21.8, "fans"))), [])

    def test_a_package_gap_over_five_seconds(self):
        w = replay(idle(40).drop(10, 16.5, "package"))
        self.assertEqual(set(titles(w)), {"BLIND — NO GO"})
        self.assertTrue(13.9 <= first(w, "BLIND — NO GO") <= 14.2, first(w, "BLIND — NO GO"))
        self.assertEqual(titles(replay(idle(40).drop(10, 13.0, "package"))), [])

    def test_the_log_stream_dying(self):
        run = idle(40).add_poll(5, "logstream", alive=True).add_poll(15, "logstream", alive=False)
        self.assertEqual(titles(replay(run)), ["BLIND — NO GO"])
        held = run.add_log(8, wrote("F0Md", "0x1"))
        self.assertEqual(titles(replay(held)), ["ABORT 12"])

    def test_the_alert_changes_its_name_when_a_hold_begins_mid_gap(self):
        run = idle(40).drop(20, 30, "fans").add_log(25, wrote("F0Md", "0x1"))
        w = replay(run)
        self.assertIn("BLIND — NO GO", titles(w))

    def test_a_sampler_that_stops_without_a_stop_line_is_blind(self):
        run = idle(60).drop(20, 60, "fans")
        self.assertEqual(set(titles(replay(run, mark_ended=False))), {"BLIND — NO GO"})

    def test_a_samplers_own_stop_line_ends_its_source_and_only_that_one(self):
        # the teardown: CTX end, then each sampler is stopped. An event at 59 s keeps the clock
        # running after the samplers' last samples
        run = idle(60).add_ctx(10, "end").drop(20, 60, "fans").add_stop("fans", 20.0)
        run.add_poll(59, "pressure", level=0)
        self.assertEqual(titles(replay(run, mark_ended=False)), [])
        both = run.copy().drop(20, 60, "package").add_stop("package", 20.0)
        self.assertEqual(titles(replay(both, mark_ended=False)), [])
        # a stop line for the fans says nothing about the package file
        other = run.copy().drop(20, 60, "package")
        self.assertEqual(set(titles(replay(other, mark_ended=False))), {"BLIND — NO GO"})

    def test_a_sampler_that_starts_again_after_its_stop_line_is_watched_again(self):
        run = idle(80).add_ctx(10, "end").drop(20, 40, "fans").add_stop("fans", 20.0)
        run.drop(60, 80, "fans")
        w = replay(run, mark_ended=False)
        self.assertEqual(set(titles(w)), {"BLIND — NO GO"})
        self.assertTrue(61.9 <= first(w, "BLIND — NO GO") <= 62.3, first(w, "BLIND — NO GO"))


class SamplerStopLine(unittest.TestCase):
    """A sampler's own `stop` line ends its source for rule 12 only in the teardown: after
    `CTX end`, with no hold active. A sampler that stops anywhere else (a `kill -INT` run early, a
    pattern `pkill`) has left the record blind, and rule 12 must go on saying so: ABORT 12 in a
    hold, BLIND — NO GO outside one. The fan sampler is the source with 2 s of slack, the package
    sampler the one with 5 s."""

    LATEST = {"fans": (31.9, 32.3), "package": (34.0, 34.4)}  # when the gap becomes an alert

    def stopped(self, which, hold=False, end=None, at=30.0):
        run = idle(80)
        if hold:
            run.hold(go=10, restore=None, target=3000)
        if end is not None:
            run.add_ctx(end, "end")
        return replay(run.drop(at, 80, which).add_stop(which, at), mark_ended=False)

    def assertGapIs(self, w, which, title):
        self.assertEqual(set(titles(w)), {title})
        low, high = self.LATEST[which]
        self.assertTrue(low <= first(w, title) <= high, (which, first(w, title)))

    def test_a_stop_line_in_a_hold_is_abort_12(self):
        for which in ("fans", "package"):
            with self.subTest(source=which):
                w = self.stopped(which, hold=True)
                self.assertGapIs(w, which, "ABORT 12")
                self.assertTrue(any("stop line during a hold" in t for t in lines(w, "WARN")))

    def test_a_stop_line_in_a_hold_after_ctx_end_is_still_abort_12(self):
        for which in ("fans", "package"):
            with self.subTest(source=which):
                self.assertGapIs(self.stopped(which, hold=True, end=8), which, "ABORT 12")

    def test_a_stop_line_before_ctx_end_with_no_hold_is_blind_no_go(self):
        for which in ("fans", "package"):
            with self.subTest(source=which):
                w = self.stopped(which)
                self.assertGapIs(w, which, "BLIND — NO GO")
                self.assertTrue(any("stop line before CTX end" in t for t in lines(w, "WARN")))

    def test_a_stop_line_after_ctx_end_with_no_hold_is_silent(self):
        # the teardown
        for which in ("fans", "package"):
            with self.subTest(source=which):
                w = self.stopped(which, end=10)
                self.assertEqual(titles(w), [])
                self.assertEqual(lines(w, "WARN"), [])
                self.assertTrue(any("stop line after CTX end" in t for t in lines(w, "INFO")))

    def test_the_teardown_after_a_hold_is_silent(self):
        # the hold is restored at 40 s, CTX end at 50 s, both samplers stopped at 55 s. An event
        # at 79 s keeps the clock running for 24 s after the samplers' last samples: without it
        # the replay would end with them and nothing could ever be heard as blind.
        run = idle(80).hold(go=10, restore=40, target=3000).add_ctx(50, "end")
        run.drop(55, 80, "fans").add_stop("fans", 55.0)
        run.drop(55, 80, "package").add_stop("package", 55.0)
        w = replay(run.add_poll(79, "pressure", level=0), mark_ended=False)
        self.assertEqual(titles(w), [])
        self.assertEqual(lines(w, "WARN"), [])

    def test_a_stop_line_while_a_hold_is_still_active_is_not_the_teardown(self):
        # CTX end has been written, but the hold was never restored: the stop line is not honoured
        run = idle(80).hold(go=10, restore=None, target=3000).add_ctx(50, "end")
        run.drop(55, 80, "fans").add_stop("fans", 55.0)
        w = replay(run, mark_ended=False)
        self.assertEqual(set(titles(w)), {"ABORT 12"})


class CtxEnd(unittest.TestCase):
    """`CTX end` changes one thing: outside a hold, a helper restart is a note. Nothing else
    stands down, and in a hold every abort stays armed."""

    PREP = "The write path's preparation step enumerated 2 fan(s) [0, 1], found the force key"

    def after_end(self, hold):
        run = idle(60).add_ctx(3, "armed pid=100").add_poll(4, "pgrep", pids=[100])
        run.add_ctx(8, "end")
        return run.hold(go=10, restore=50, target=3000) if hold else run

    def test_a_fan_gap_in_a_hold_is_abort_12(self):
        w = replay(self.after_end(True).drop(25, 29, "fans"))
        self.assertEqual(set(titles(w)), {"ABORT 12"})

    def test_a_pid_change_in_a_hold_is_abort_7(self):
        w = replay(self.after_end(True).add_poll(30, "pgrep", pids=[101]))
        self.assertEqual(titles(w), ["ABORT 7"])
        w = replay(self.after_end(True).add_poll(30, "pgrep", pids=[]))
        self.assertEqual(titles(w), ["ABORT 7"])

    def test_a_second_preparation_step_line_in_a_hold_is_abort_7(self):
        w = replay(self.after_end(True).add_log(1, self.PREP).add_log(30, self.PREP))
        self.assertEqual(titles(w), ["ABORT 7"])

    def test_could_not_undo_in_a_hold_is_reset_and_a_fault(self):
        w = replay(self.after_end(True).add_log(30, LINE_COULD_NOT_UNDO, "Fault"))
        self.assertEqual(set(titles(w)), {RESET, "HELPER FAULT"})

    def test_a_pid_change_with_no_hold_is_only_a_note(self):
        w = replay(self.after_end(False).add_poll(30, "pgrep", pids=[101]))
        self.assertEqual(titles(w), [])
        self.assertTrue(any("after CTX end" in text and "[100] -> [101]" in text for text in notes(w)))

    def test_a_vanished_helper_with_no_hold_is_only_a_note(self):
        self.assertEqual(titles(replay(self.after_end(False).add_poll(30, "pgrep", pids=[]))), [])

    def test_a_second_preparation_step_line_with_no_hold_is_only_a_note(self):
        w = replay(self.after_end(False).add_log(1, self.PREP).add_log(30, self.PREP))
        self.assertEqual(titles(w), [])
        self.assertTrue(any("preparation-step" in text for text in notes(w)))

    def test_without_the_end_line_the_same_pid_change_is_an_alert(self):
        run = idle(60).add_ctx(3, "armed pid=100").add_poll(4, "pgrep", pids=[100])
        self.assertEqual(titles(replay(run.add_poll(30, "pgrep", pids=[101]))), ["HELPER RESTARTED"])

    def test_a_fault_with_no_hold_is_a_spoken_alert(self):
        w = replay(self.after_end(False).add_log(30, "Could not restore Ftst", "Fault"), speak=True)
        self.assertEqual(titles(w), ["HELPER FAULT"])
        self.assertEqual(set(w.take_speech()), {"helper fault"})

    def test_a_gap_with_no_hold_is_still_blind(self):
        w = replay(self.after_end(False).drop(20, 24, "fans"))
        self.assertEqual(set(titles(w)), {"BLIND — NO GO"})
        w = replay(self.after_end(False).drop(20, 27, "package"))
        self.assertEqual(set(titles(w)), {"BLIND — NO GO"})

    def test_the_log_stream_dying_is_still_blind(self):
        run = self.after_end(False).add_poll(5, "logstream", alive=True)
        self.assertEqual(titles(replay(run.add_poll(30, "logstream", alive=False))), ["BLIND — NO GO"])

    def test_a_reading_after_the_end_is_judged_as_before(self):
        self.assertEqual(titles(replay(self.after_end(False).patch_hottest(30, 31, 90.0))), ["ABORT 1"])


class BadContext(unittest.TestCase):
    """A CTX target that cannot be read as RPM would switch off rule 9 and the held-fan clause of
    rule 2 without a word. It is a spoken alert instead."""

    def hold_with(self, text):
        return self.hold_under("step=1b target=%s GO" % text)

    def hold_under(self, ctx_body):
        # Apple demands 5500 RPM of fan 1 during the hold: ABORT 9 if the target is 5777
        run = idle(60).patch_fan(0, 60, F1Tg=5500.0, F1Ac=5500.0)
        run.add_ctx(4.95, ctx_body)
        run.add_log(5.0, wrote("Ftst", "0x1")).add_log(5.03, wrote("F0Md", "0x1"))
        run.add_log(5.06, wrote("F0Tg", "0x0 0x0 0x80 0x3f"))
        return run.patch_fan(5.1, 60, Ftst=1, F0Md=1, F0Tg=5777.0, F0Ac=5777.0)

    def test_a_target_that_is_not_rpm_is_bad_context(self):
        for text in ("5,777", "5777rpm", "nan", "inf", "0", "-5", "1e3", "5_777", "5777.", "",
                     "0x1691", "five"):
            with self.subTest(target=text):
                w = replay(self.hold_with(text))
                self.assertIn("BAD CONTEXT", titles(w))
                self.assertNotIn("ABORT 9", titles(w))  # the rule that is off, now heard about

    def test_a_readable_target_is_not(self):
        for text in ("5777", "5777.5", "100"):
            with self.subTest(target=text):
                self.assertNotIn("BAD CONTEXT", titles(replay(self.hold_with(text))))
        self.assertIn("ABORT 9", titles(replay(self.hold_with("5777"))))  # and the rule is live

    def test_none_is_not_bad_context(self):
        run = idle(30).add_ctx(5, "step=1b' target=none GO")
        self.assertEqual(titles(replay(run)), [])

    def test_it_is_spoken_and_a_valid_step_line_ends_it(self):
        # the corrected line gives a target Apple's 5500 RPM is under 0.9 of, so rule 9 is quiet
        w = replay(self.hold_with("5,777").add_ctx(9, "step=1b target=6500 GO"), speak=True)
        self.assertEqual(titles(w), ["BAD CONTEXT"])
        self.assertEqual(w.take_speech(), ["bad context"])
        self.assertEqual(w.active_alerts(), [])
        self.assertTrue(any("BAD CONTEXT no longer holds" in text for text in lines(w, "CLEAR")))

    def test_a_step_line_with_no_target_field_is_bad_context_too(self):
        # `step=1b GO` or a misspelt `targt=5777` would leave rule 9 off with no word, as an
        # unreadable target did. Only `step=none` needs no target.
        for body in ("step=1b GO", "step=1b targt=5777 GO", "step=1b 5777 GO"):
            with self.subTest(line=body):
                w = replay(self.hold_under(body), speak=True)
                self.assertEqual(titles(w), ["BAD CONTEXT"])
                spoken = w.take_speech()
                self.assertEqual(set(spoken), {"bad context"})
                self.assertGreaterEqual(len(spoken), 3)  # and, while it holds, said again
                self.assertEqual(w.active_alerts(), ["BAD CONTEXT"])
                self.assertIn("no target= field", w.raised[0].detail)

    def test_a_step_line_with_no_target_field_is_repeated_and_a_valid_line_ends_it(self):
        w = replay(self.hold_under("step=1b GO").add_ctx(30, "step=1b target=6500 GO"), speak=True)
        self.assertEqual(titles(w), ["BAD CONTEXT"])
        self.assertEqual(w.active_alerts(), [])
        # said when it begins (5 s) and again 15 s on, while it holds; the line at 30 s ends it
        self.assertEqual(w.take_speech(), ["bad context", "bad context"])

    def test_step_none_needs_no_target(self):
        run = idle(30).add_ctx(5, "step=1b target=3000 GO").add_ctx(9, "step=none")
        self.assertEqual(titles(replay(run)), [])

    def test_a_bad_target_on_any_ctx_line_is_heard(self):
        run = idle(30).add_ctx(5, "step=none target=abc")
        self.assertIn("BAD CONTEXT", titles(replay(run)))


class Extras(unittest.TestCase):
    def test_a_fault_line(self):
        w = replay(idle(30).add_log(10, "Liveness watchdog fired", "Fault"))
        self.assertEqual(titles(w), ["HELPER FAULT"])

    def test_f0md_one_with_no_open_step(self):
        run = idle(30).add_log(9.9, wrote("F0Md", "0x1")).add_log(10.0, wrote("F0Tg", "0x0"))
        run.patch_fan(10, 11.5, F0Md=1, F0Tg=1500)
        self.assertEqual(set(titles(replay(run))), {"NO CONTEXT"})

    def test_an_open_step_is_context(self):
        run = idle(30).add_ctx(9, "step=1a target=3000 GO").add_log(9.9, wrote("F0Md", "0x1"))
        run.patch_fan(10, 11.5, F0Md=1, F0Tg=1500)
        self.assertNotIn("NO CONTEXT", titles(replay(run)))

    def test_no_context_after_step_none(self):
        run = idle(30).add_ctx(5, "step=1a target=3000 GO").add_ctx(8, "step=none")
        run.add_log(9.9, wrote("F0Md", "0x1")).patch_fan(10, 11.5, F0Md=1, F0Tg=1500)
        self.assertIn("NO CONTEXT", titles(replay(run)))

    def test_lines_from_another_process_are_ignored_with_one_warning(self):
        run = idle(30)
        for at in (5, 6, 7):
            run.add_log(at, wrote("F0Md", "0x1", seconds="9.9"), image="/x/swiftpm-testing-helper")
        w = replay(run)
        self.assertEqual(titles(w), [])
        self.assertFalse(w.hold_active)
        self.assertEqual(len(lines(w, "WARN")), 1)

    def test_a_test_alert(self):
        w = replay(idle(30).add_ctx(10, "test-alert"), speak=True)
        self.assertEqual(titles(w), ["TEST ALERT"])
        self.assertEqual(w.take_speech(), ["test alert"])

    def test_a_quiet_idle_run_raises_nothing(self):
        w = replay(idle(120))
        self.assertEqual(titles(w), [])
        self.assertEqual(w.counts, {"NOTE": 0, "WARN": 0})


if __name__ == "__main__":
    unittest.main()
