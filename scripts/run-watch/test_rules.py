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

    def test_a_long_holds_restore_is_not_an_abort_while_a_sample_still_reads_one(self):
        # The write history is kept for 90 s, so by the restore of a two-minute hold the engage
        # write that explained F0Md = 1 is gone. The restore's log stamp comes when the write
        # returns; a sample read just before it can still say 1 for a moment, after the hold has
        # ended. That must not be an abort.
        run = idle(170).hold(go=10, restore=130, target=3000)
        self.assertEqual(titles(replay(run)), [])
        with mock.patch.object(rw, "HOLD_END_GRACE", 0.0):
            self.assertIn("ABORT 3", titles(replay(run.copy())))

    def test_the_grace_ends_half_a_second_after_the_restore(self):
        run = idle(170).hold(go=10, restore=130, target=3000)
        late = run.copy().patch_fan(130.0, 133.0, F0Md=1)  # still 1 three seconds after the restore
        self.assertIn("ABORT 3", titles(replay(late)))

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

    def test_nothing_after_ctx_end(self):
        run = idle(40).add_ctx(15, "end").drop(20, 40, "fans").drop(20, 40, "package")
        self.assertEqual(titles(replay(run)), [])


class Extras(unittest.TestCase):
    def test_a_fault_line(self):
        w = replay(idle(30).add_log(10, "Liveness watchdog fired", "Fault"))
        self.assertEqual(titles(w), ["HELPER FAULT"])

    def test_a_fault_after_end_is_a_warning(self):
        w = replay(idle(30).add_ctx(5, "end").add_log(10, "Something", "Fault"))
        self.assertEqual(titles(w), [])
        self.assertEqual(len(lines(w, "WARN")), 1)

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
