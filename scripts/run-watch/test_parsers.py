"""The parsers: pure functions of a line."""

import json
import unittest

import run_watch as rw
import synth


class TimeTests(unittest.TestCase):
    def test_iso_utc(self):
        self.assertEqual(rw.parse_iso_utc("2026-10-31T01:17:19.037Z"), 1793409439.037)
        self.assertEqual(rw.parse_iso_utc("2026-10-31T01:17:19Z"), 1793409439.0)
        self.assertIsNone(rw.parse_iso_utc("2026-10-31 01:17:19Z"))
        self.assertIsNone(rw.parse_iso_utc(None))

    def test_log_timestamp_carries_its_offset(self):
        utc = rw.parse_iso_utc("2026-10-28T22:20:10.311558Z")
        self.assertAlmostEqual(rw.parse_log_timestamp("2026-10-28 15:20:10.311558-0700"), utc, 6)
        self.assertAlmostEqual(rw.parse_log_timestamp("2026-10-28 23:50:10.311558+0130"), utc, 6)
        self.assertIsNone(rw.parse_log_timestamp("yesterday"))

    def test_synthetic_stamps_agree_with_the_parsers(self):
        t = synth.T0 + 12.345
        self.assertAlmostEqual(rw.parse_iso_utc(synth.iso(t)), t, 3)
        self.assertAlmostEqual(rw.parse_log_timestamp(synth.log_timestamp(t)), t, 5)


class DurationTests(unittest.TestCase):
    def test_exponents_are_read(self):
        self.assertAlmostEqual(rw.parse_duration_seconds("5.3083e-05"), 5.3083e-05)
        self.assertEqual(rw.parse_duration_seconds("1.2e+00"), 1.2)
        self.assertEqual(rw.parse_duration_seconds("1.2"), 1.2)
        self.assertEqual(rw.parse_duration_seconds("12"), 12.0)
        self.assertEqual(rw.parse_duration_seconds("1E2"), 100.0)

    def test_what_cannot_be_compared_is_refused(self):
        for text in ("nan", "inf", "-1.0", "1_0", " 1.0", "1.0 ", "", "abc", "1e999", None):
            self.assertIsNone(rw.parse_duration_seconds(text), text)


class WroteTests(unittest.TestCase):
    def test_the_helpers_line(self):
        parsed = rw.parse_wrote("Wrote F0Md = 0x1: answered 0x00, in 5.3083e-05 seconds.")
        self.assertEqual(parsed, ("F0Md", "0x1", "0x00", "5.3083e-05"))
        parsed = rw.parse_wrote("Wrote F0Tg = 0x0 0x0 0x80 0x3f: answered 0x82, in 1.2 seconds.")
        self.assertEqual(parsed, ("F0Tg", "0x0 0x0 0x80 0x3f", "0x82", "1.2"))

    def test_an_unanswered_write_with_commas_in_its_detail(self):
        line = "Wrote Ftst = 0x1: answered no answer (a, b, in the dark), in 0.5 seconds."
        self.assertEqual(rw.parse_wrote(line)[2:], ("no answer (a, b, in the dark)", "0.5"))

    def test_what_does_not_parse(self):
        self.assertIsNone(rw.parse_wrote("Wrote F0Md = 0x1: answered 0x00"))
        self.assertIsNone(rw.parse_wrote("Wrote F0Md = 0x1: answered 0x00, in a while."))

    def test_synthetic_wrote_matches_the_shape(self):
        self.assertEqual(rw.parse_wrote(synth.wrote("F0Md", "0x1"))[0], "F0Md")


class FileLineTests(unittest.TestCase):
    def test_fan_sample(self):
        sample = rw.parse_fan_line(synth.Run.idle(1).fan_lines()[1])
        self.assertEqual(sample.v["F0Md"], 3.0)
        self.assertEqual(sorted(sample.v), sorted(synth.FAN_KEYS))

    def test_only_samples_count(self):
        lines = synth.Run.idle(1).fan_lines()
        self.assertIsNone(rw.parse_fan_line(lines[0]))  # start
        self.assertIsNone(rw.parse_fan_line(json.dumps({"kind": "heartbeat"})))
        self.assertIsNone(rw.parse_fan_line("not json"))
        self.assertIsNone(rw.parse_fan_line(b'{"kind":"sample","wallClockUTC":'))
        self.assertIsNone(rw.parse_fan_line("[1]"))

    def test_a_reading_that_failed_is_absent_not_zero(self):
        record = synth.fan_record(synth.T0, 1)
        record["readings"][0].update(status="unknownKey", value=None)
        sample = rw.parse_fan_line(json.dumps(record))
        self.assertNotIn("F0Md", sample.v)
        record["readings"][1].update(value=True)  # a boolean is not a number
        self.assertNotIn("F1Md", rw.parse_fan_line(json.dumps(record)).v)

    def test_package_sample_takes_the_hottest_temperature_key_that_read(self):
        record = synth.package_record(synth.T0, 1, hottest=51.5, extra={"F0Mn": 1200, "F0Ac": 1500})
        sample = rw.parse_package_line(json.dumps(record))
        self.assertEqual(sample.hottest, 51.5)
        self.assertEqual(sample.f["F0Mn"], 1200)
        self.assertNotIn("F0Ac", [k for k in sample.f if k.startswith("T")])
        record["readings"][0].update(status="timeout", value=None)
        self.assertLess(rw.parse_package_line(json.dumps(record)).hottest, 51.5)

    def test_a_package_sample_with_no_temperature_has_no_hottest(self):
        record = synth.package_record(synth.T0, 1)
        record["readings"] = [r for r in record["readings"] if not r["key"].startswith("T")]
        self.assertIsNone(rw.parse_package_line(json.dumps(record)).hottest)


class LogLineTests(unittest.TestCase):
    def test_a_helper_line(self):
        record = synth.log_record(synth.T0, "hello", "Fault")
        line = rw.parse_log_line(json.dumps(record))
        self.assertEqual((line.msg, line.level, line.foreign), ("hello", "Fault", False))
        self.assertAlmostEqual(line.t, synth.T0, 5)

    def test_the_header_and_junk_are_skipped(self):
        self.assertIsNone(rw.parse_log_line('Filtering the log data using "subsystem == x"'))
        self.assertIsNone(rw.parse_log_line("{}"))
        self.assertIsNone(rw.parse_log_line(json.dumps({"eventMessage": "x", "timestamp": "no"})))

    def test_another_process_is_foreign(self):
        record = synth.log_record(synth.T0, "x", image="/usr/bin/swiftpm-testing-helper")
        self.assertTrue(rw.parse_log_line(json.dumps(record)).foreign)
        del record["processImagePath"]
        self.assertFalse(rw.parse_log_line(json.dumps(record)).foreign)


class StopTests(unittest.TestCase):
    def test_a_samplers_stop_line(self):
        line = json.dumps(synth.stop_record(50))
        self.assertTrue(rw.is_stop_line(line))
        self.assertIsNone(rw.parse_fan_line(line))  # it is not a sample
        self.assertIsNone(rw.parse_package_line(line))

    def test_the_line_the_sampler_really_writes_has_no_wall_clock_stamp(self):
        # The keys of `SamplerStopRecord` in Tools/SMCSampler/SMCSamplerCore.swift, and of the stop
        # lines in P1. A reader that wanted a stamp would never recognise one, and a sampler's stop
        # would go unseen: the teardown would be heard as blind.
        raw = (b'{"finalContinuousNanoseconds":9,"finalSuspendingNanoseconds":9,'
               b'"kind":"stop","totalTicks":3}')
        self.assertTrue(rw.is_stop_line(raw))
        self.assertEqual(
            sorted(synth.stop_record(3)),
            ["finalContinuousNanoseconds", "finalSuspendingNanoseconds", "kind", "totalTicks"])

    def test_nothing_else_is_one(self):
        self.assertFalse(rw.is_stop_line(json.dumps(synth.fan_record(synth.T0, 1))))
        self.assertFalse(rw.is_stop_line(json.dumps(synth.start_record(synth.FAN_KEYS, 0.1))))
        self.assertFalse(rw.is_stop_line(
            '{"continuousNanoseconds":1,"kind":"heartbeat","wallClockUTC":"2026-10-31T01:17:19.036Z"}'))
        self.assertFalse(rw.is_stop_line('{"kind":"stopped"}'))
        self.assertFalse(rw.is_stop_line("Filtering the log data"))
        self.assertFalse(rw.is_stop_line(""))


class WriteValueTests(unittest.TestCase):
    def test_a_one_byte_writes_value(self):
        self.assertEqual(rw._byte("0x1"), 1)
        self.assertEqual(rw._byte("0x03"), 3)
        self.assertEqual(rw._byte("0x0"), 0)
        for text in ("0x0 0x0 0x80 0x3f", "1", "0x", "0x123", "", None):
            self.assertIsNone(rw._byte(text), text)


class CtxTests(unittest.TestCase):
    def test_each_form(self):
        parse = rw.parse_ctx_line
        c = parse("1761870000.123 CTX step=1b target=5777 GO")
        self.assertEqual((c.kind, c.step, c.target, c.t), ("step", "1b", 5777.0, 1761870000.123))
        self.assertEqual(parse("1761870000.123 CTX step=1d target=none GO").target, None)
        self.assertEqual(parse("1761870000.123 CTX step=1b′ target=none GO").step, "1b'")
        c = parse("1761870001.5 CTX load-start step=1d")
        self.assertEqual((c.kind, c.step), ("load-start", "1d"))
        self.assertEqual(parse("1761870001.5 CTX load-stop").kind, "load-stop")
        self.assertEqual(parse("1761870001.5 CTX step=none").step, "none")
        self.assertEqual(parse("1761870001.5 CTX armed pid=542").pid, 542)
        self.assertEqual(parse("1761870001.5 CTX test-alert").kind, "test-alert")
        self.assertEqual(parse("1761870001.5 CTX end").kind, "end")

    def test_a_target_is_rpm_or_it_is_refused(self):
        for text in ("5777", "5777.5", "100"):
            self.assertEqual(rw.parse_ctx_line("1761870000.1 CTX step=1b target=%s GO" % text).bad_target, None)
        for text in ("5,777", "5777rpm", "nan", "inf", "0", "0.0", "-5", "1e3", "5_777", "",
                     "9" * 400):
            c = rw.parse_ctx_line("1761870000.1 CTX step=1b target=%s GO" % text)
            self.assertEqual((c.target, c.bad_target), (None, text), text)
        c = rw.parse_ctx_line("1761870000.1 CTX step=1b' target=none GO")
        self.assertEqual((c.target, c.bad_target), (None, None))

    def test_a_step_line_with_no_target_field_is_refused_as_a_target_is(self):
        # `step=1b GO` and a misspelt `targt=` leave rule 9 and the held-fan clause of rule 2 off
        # exactly as `target=5,777` does, so they are as loud. Only `step=none` needs no target.
        for body in ("step=1a GO", "step=1b targt=5777 GO", "step=1b 5777 GO", "step=1b'",
                     "step= GO"):
            c = rw.parse_ctx_line("1761870000.1 CTX " + body)
            self.assertEqual((c.kind, c.target, c.bad_target), ("step", None, rw.MISSING_TARGET), body)
        for body in ("step=none", "step=none target=none", "step=1b target=none GO",
                     "step=1b' target=none GO", "load-start step=1d", "load-stop", "armed pid=7",
                     "end", "test-alert"):
            c = rw.parse_ctx_line("1761870000.1 CTX " + body)
            self.assertIsNone(c.bad_target, body)

    def test_parse_rpm(self):
        self.assertEqual(rw.parse_rpm("5777"), 5777.0)
        for text in ("0", "-1", "nan", "inf", "1e3", " 5", "5 ", "5777\n", None, 5777):
            self.assertIsNone(rw.parse_rpm(text), text)

    def test_iso_stamp_and_missing_stamp(self):
        self.assertEqual(rw.parse_ctx_line("2026-10-31T02:19:52Z CTX load-stop").t, 1793413192.0)
        self.assertEqual(rw.parse_ctx_line("CTX end", arrival=7.0).t, 7.0)
        self.assertIsNone(rw.parse_ctx_line("CTX end").t)

    def test_other_lines_are_not_ctx(self):
        self.assertIsNone(rw.parse_ctx_line("2026-10-31T01:17:21Z recorders started"))
        self.assertIsNone(rw.parse_ctx_line("LOAD_DONE"))
        self.assertIsNone(rw.parse_ctx_line("1761870000.1 something CTX step=1a"))


if __name__ == "__main__":
    unittest.main()
