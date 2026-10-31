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
