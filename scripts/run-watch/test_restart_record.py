"""restart-record.sh, with stub binaries.

The script starts a sampler, a log stream, a watcher and their companions. Here every one of them
is a stub that writes down how it was called and then sleeps (`exec sleep`, so the PID the script
records is the PID of the sleeping process, and is killed by that PID). Nothing real is recorded,
no real `say` can be started (the companion is a stub), and no process is killed by a pattern.

The shipped script names its executables by absolute path, as the runbook's commands do. The tests
run a copy of it with those few paths replaced, and check that each replacement matched exactly
one place, so that the copy is the shipped script and not a rewrite of it.

The one thing the stubs do not replace is the record-only poll loop, which is a shell loop and
would run for ever. In the copy it is bounded to about 20 s (four rounds), so that a test that
loses its PID (a mutant that reuses a directory, say) leaves a loop that ends by itself.

The copy also defines `nohup` as a function that first writes down the first line of phases.log,
at the moment each recorder is launched. A stub that looks at the file when it starts runs a few
milliseconds after the script has moved on, and sees a `CTX end` written after it was launched;
the function looks before the launch, so it cannot."""

import contextlib
import hashlib
import os
import re
import signal
import subprocess
import tempfile
import unittest

import run_watch as rw

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "restart-record.sh")
SAMPLER = "smc-sampler-5b0d191"
SHA = "4bd72a2"
NAMES = ("fans-10hz", "package-1hz", "logstream", "poll", "watch", "watcher-down")

SAMPLER_STUB = """#!/bin/sh
D=$(ls -td "$STUB_CAP"/run1-*/ | head -n 1)
echo "sampler $* | first line of phases.log: $(head -n 1 "${D}phases.log")" >> "$STUB_LOG"
exec sleep 25
"""
LOG_STUB = """#!/bin/sh
D=$(ls -td "$STUB_CAP"/run1-*/ | head -n 1)
echo "log $* | first line of phases.log: $(head -n 1 "${D}phases.log")" >> "$STUB_LOG"
[ "$1" = show ] && exit 0
exec sleep 25
"""
PYTHON_STUB = """#!/bin/sh
D=$(ls -td "$STUB_CAP"/run1-*/ | head -n 1)
echo "python $* | first line of phases.log: $(head -n 1 "${D}phases.log")" >> "$STUB_LOG"
[ "${STUB_FAIL:-}" = python ] && exit 1
exec sleep 25
"""
PGREP_STUB = """#!/bin/sh
[ -n "${STUB_PGREP:-}" ] && { echo "$STUB_PGREP" | tr ' ' '\\n'; exit 0; }
exit 1
"""
COMPANION_STUB = """#!/bin/sh
echo "watcher-down $*" >> "$STUB_LOG"
exec sleep 25
"""


#: The poll loop as the runbook's PR-3 and the script have it, and the copy's: four rounds of five
#: seconds. The shipped text is what test_it_pins_what_the_runbook_pins looks for.
POLL_LOOP = ("while :; do date -u +%FT%TZ; sysctl -n vm.loadavg; notifyutil -g "
             "com.apple.system.thermalpressurelevel; sleep 5; done")
#: Inserted after the script has chosen its directory: every launch notes what phases.log begins with.
OBSERVE_LAUNCHES = (
    'DIR="$CAPTURES/run1-$N"\n',
    'DIR="$CAPTURES/run1-$N"\n'
    'nohup() { printf "%s\\n" "$(head -n 1 "$DIR/phases.log" 2>/dev/null)" >> "$STUB_ORDER"; '
    'command nohup "$@"; }\n')
BOUNDED_POLL_LOOP = ("n=0; while [ $n -lt 4 ]; do date -u +%FT%TZ; sysctl -n vm.loadavg; notifyutil -g "
                     "com.apple.system.thermalpressurelevel; sleep 5; n=$((n + 1)); done")


def write(path, text, mode=0o755):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, mode)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def shell_code(text):
    """A shell script's code with its comments removed and its whitespace collapsed, and what is
    quoted set aside: (the code, with every quoted span replaced by `"<n>"`, and the spans). A `#`
    starts a comment only at the start of a word and outside quotes; a backslash and a newline are
    a line continuation and are deleted, as the shell deletes them. So a command split over lines,
    spaced with tabs, or mentioned in a comment or a string reads the way the shell reads it,
    which a filter on lines does not."""
    text = text.replace("\\\n", "")
    code, spans, i, n = [], [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch in "'\"":
            j = i + 1
            while j < n and text[j] != ch:
                j += 2 if ch == '"' and text[j] == "\\" else 1
            spans.append(text[i + 1:j])
            code.append('"<%d>"' % (len(spans) - 1))
            i = j + 1
        elif ch == "#" and (not code or code[-1] in " \t\n;&|("):
            while i < n and text[i] != "\n":
                i += 1
        elif ch in " \t\n":
            if code and code[-1] != " ":
                code.append(" ")
            i += 1
        else:
            code.append(ch)
            i += 1
    return "".join(code).strip(), spans


LAUNCH = re.compile(r'(?:^|[\s;&|(])nohup(?=\s)|(?<![&>])&(?![&>])')
CTX_END_WRITE = re.compile(r'echo "<(\d+)>" (?<!>)>(?!>) "<(\d+)>"')


def ctx_end_position(text):
    """Where the script writes `CTX end` into phases.log, and where it first starts a process (a
    `nohup`, or a command put in the background with `&`): (write, first launch, launches), each a
    position in the normalised code, or None."""
    code, spans = shell_code(text)
    writes = [m.start() for m in CTX_END_WRITE.finditer(code)
              if spans[int(m.group(1))] == "$STAMP CTX end" and spans[int(m.group(2))] == "$DIR/phases.log"]
    launches = [m.start() for m in LAUNCH.finditer(code)]
    return (writes[0] if len(writes) == 1 else None, launches[0] if launches else None, len(launches))


class Staged(unittest.TestCase):
    """A captures directory with stubs where the runbook pins real tools, and a copy of the script."""

    def setUp(self):
        self._root = tempfile.TemporaryDirectory()
        self.addCleanup(self._root.cleanup)
        self.root = os.path.realpath(self._root.name)
        self.cap = os.path.join(self.root, "aeolus-captures")
        self.bin = os.path.join(self.cap, "bin")
        self.watch = os.path.join(self.bin, "run-watch-%s" % SHA, "scripts", "run-watch")
        os.makedirs(self.watch)
        os.makedirs(os.path.join(self.root, "stubs"))
        self.sampler = os.path.join(self.bin, SAMPLER)
        write(self.sampler, SAMPLER_STUB)
        write(os.path.join(self.watch, "run_watch.py"), "# a stub: the interpreter is a stub too\n", 0o644)
        write(os.path.join(self.watch, "watcher-down.sh"), COMPANION_STUB, 0o644)
        self.python = os.path.join(self.root, "stubs", "python3")
        self.logcmd = os.path.join(self.root, "stubs", "log")
        self.pgrep = os.path.join(self.root, "stubs", "pgrep")
        write(self.python, PYTHON_STUB)
        write(self.logcmd, LOG_STUB)
        write(self.pgrep, PGREP_STUB)
        self.stub_log = os.path.join(self.root, "stub-calls.txt")
        self.launch_order = os.path.join(self.root, "launch-order.txt")
        self.env = dict(os.environ, STUB_LOG=self.stub_log, STUB_CAP=self.cap, STUB_ORDER=self.launch_order)
        self.addCleanup(self.reap)
        self.script = self.copy_of_script()

    def copy_of_script(self, pin=None, perl=None):
        """The shipped script with its interpreter, `log` and pinned hash replaced."""
        with open(SCRIPT, encoding="utf-8") as handle:
            text = handle.read()
        with open(self.sampler, "rb") as handle:
            stub_hash = hashlib.sha256(handle.read()).hexdigest()
        for old, new in (('PYTHON="/opt/homebrew/bin/python3"', 'PYTHON="%s"' % self.python),
                         ('LOGCMD="/usr/bin/log"', 'LOGCMD="%s"' % self.logcmd),
                         ('PGREP="/usr/bin/pgrep"', 'PGREP="%s"' % self.pgrep),
                         (POLL_LOOP, BOUNDED_POLL_LOOP), OBSERVE_LAUNCHES) + (
                             (('PERL="/usr/bin/perl"', 'PERL="%s"' % perl),) if perl else ()):
            self.assertEqual(text.count(old), 1, old)
            text = text.replace(old, new)
        if pin is None:
            old = re.search(r'SAMPLER_SHA256="([0-9a-f]{64})"', text).group(0)
            self.assertEqual(text.count(old), 1)
            text = text.replace(old, 'SAMPLER_SHA256="%s"' % stub_hash)
        path = os.path.join(self.root, "restart-record-copy.sh")
        write(path, text)
        return path

    def run_script(self, *args, script=None, env=None):
        return subprocess.run(
            ["/bin/sh", script or self.script] + list(args), stdin=subprocess.DEVNULL,
            capture_output=True, env=env or self.env, timeout=60, check=False)

    def restart(self, *extra, **kwargs):
        return self.run_script("--watcher-sha", SHA, "--captures", self.cap, *extra, **kwargs)

    def records(self):
        return sorted(d for d in os.listdir(self.cap) if d.startswith("run1-"))

    def pids(self, directory):
        found = {}
        for name in NAMES:
            path = os.path.join(self.cap, directory, name + ".pid")
            if os.path.exists(path):
                with open(path, encoding="utf-8") as handle:
                    found[name] = int(handle.read())
        return found

    def reap(self):
        """What the script started, by the PIDs it recorded, and nothing else."""
        for directory in os.listdir(self.cap) if os.path.isdir(self.cap) else []:
            for pid in self.pids(directory).values():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)

    def calls(self):
        if not os.path.exists(self.stub_log):
            return []
        with open(self.stub_log, encoding="utf-8") as handle:
            return handle.read().splitlines()


class Restart(Staged):
    def test_it_starts_the_six_processes_into_a_new_directory_and_prints_their_pids(self):
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), ["run1-1"])
        out = result.stdout.decode()
        self.assertIn("directory %s" % os.path.join(self.cap, "run1-1"), out)
        pids = self.pids("run1-1")
        self.assertEqual(sorted(pids), sorted(NAMES))
        for name, pid in pids.items():
            self.assertTrue(alive(pid), name)
            self.assertRegex(out, r"%s +pid %d\n" % (re.escape(name), pid))
        self.assertEqual(len(set(pids.values())), 6)

    def test_each_process_is_started_with_the_runbooks_command(self):
        self.restart()
        d = os.path.join(self.cap, "run1-1")
        calls = [c.split(" | ")[0] for c in self.calls()]
        self.assertEqual(sorted(calls), sorted([
            "sampler --interval=0.1 --keys=F0Md,F1Md,Ftst,F0Tg,F1Tg,F0Ac,F1Ac",
            "sampler --interval=1",
            'log stream --style ndjson --level debug --predicate subsystem == "dev.aeolus.AeolusHelper" '
            'AND process == "AeolusHelper"',
            "python -I %s --dir %s" % (os.path.join(self.watch, "run_watch.py"), d),
            "watcher-down %s" % d]))
        # the files the runbook's redirections make, and the poll loop's
        for name in ("fans-10hz.ndjson", "fans-10hz.err", "package-1hz.ndjson", "package-1hz.err",
                     "helper-log.ndjson", "poll-5s.log", "watch.log", "phases.log"):
            self.assertTrue(os.path.exists(os.path.join(d, name)), name)

    def test_ctx_end_is_the_first_line_and_a_plain_note_says_why(self):
        self.restart()
        with open(os.path.join(self.cap, "run1-1", "phases.log"), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertRegex(lines[0], r"^\d{10}\.\d{3} CTX end$")  # the runbook's perl stamp
        self.assertEqual(rw.parse_ctx_line(lines[0]).kind, "end")
        self.assertIsNone(rw.parse_ctx_line(lines[1]))  # the watcher ignores it
        self.assertIn("items 10 and 13", lines[1])
        watcher = rw.Watcher(rw.MemoryOutput())
        watcher.on_ctx(rw.parse_ctx_line(lines[0]))
        self.assertTrue(watcher.ended)  # the new watcher starts in the teardown state

    def test_ctx_end_is_the_first_line_of_phases_log_at_the_moment_of_each_launch(self):
        # Observed by the copy's `nohup` before it launches, so no stub's start-up can hide a
        # CTX end that was written after the launch.
        self.restart()
        with open(self.launch_order, encoding="utf-8") as handle:
            seen = handle.read().splitlines()
        self.assertEqual(len(seen), 6)  # the two samplers, the log stream, the poll loop, the watcher, its companion
        for line in seen:
            self.assertRegex(line, r"^\d{10}\.\d{3} CTX end$")

    def test_ctx_end_is_in_the_file_before_any_recorder_starts(self):
        self.restart()
        for call in self.calls():
            if call.startswith("watcher-down"):
                continue
            self.assertRegex(call.split(" | first line of phases.log: ")[1], r"^\d{10}\.\d{3} CTX end$", call)

    def test_it_says_that_ctx_end_is_first_and_why(self):
        out = self.restart().stdout.decode()
        self.assertIn("CTX end written first", out)
        self.assertIn("teardown state (items 10 and 13)", out)

    def test_it_prints_the_commands_to_paste_next_with_the_real_directory_and_runs_none_of_them(self):
        out = self.restart().stdout.decode()
        d = os.path.join(self.cap, "run1-1")
        lines = out.splitlines()
        wanted = [
            'tail -f "%s/watch.log"' % d,
            # ADR 0014 item 13: the helper's own start, which the power cycle runs before any
            # recorder can, is read from `log show`; the process filter is the F1 trap's
            "/usr/bin/log show --predicate 'subsystem == \"dev.aeolus.AeolusHelper\" AND process == "
            "\"AeolusHelper\"' --info --debug --last boot > \"%s/helper-log-show.txt\"" % d,
            # E-6's check, on the new fans file
            'tail -n 200 "%s/fans-10hz.ndjson" | jq -s -c --argjson win 10 -f "%s/stage/jq/quiescence.jq"'
            % (d, self.cap),
            # E-10, in its order, for this directory
            'kill -INT $(cat "%s/fans-10hz.pid" "%s/package-1hz.pid")' % (d, d),
            'kill "$(cat "%s/watcher-down.pid")"' % d,
            'kill "$(cat "%s/watch.pid")"' % d,
            'kill $(cat "%s/logstream.pid" "%s/poll.pid")' % (d, d)]
        for command in wanted:
            self.assertIn(command, lines)
        positions = [lines.index(c) for c in wanted]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(lines.count(wanted[0]), 1)
        self.assertNotIn("run1/", "\n".join(wanted))  # never the first record's directory
        # printed, not run: no `log show` reached the stub, the file it would make is not there, no
        # kill was sent (the processes it started are alive), and no helper-log-show.txt exists
        self.assertFalse([c for c in self.calls() if c.startswith("log show")])
        self.assertFalse(os.path.exists(os.path.join(d, "helper-log-show.txt")))
        self.assertTrue(all(alive(p) for p in self.pids("run1-1").values()))

    def test_the_commands_name_the_directory_that_was_made_and_the_captures_given(self):
        os.mkdir(os.path.join(self.cap, "run1-1"))
        os.mkdir(os.path.join(self.cap, "run1-2"))
        out = self.restart().stdout.decode()
        self.assertIn('tail -f "%s/watch.log"' % os.path.join(self.cap, "run1-3"), out)
        self.assertNotIn("run1-1/", out)
        self.assertNotIn("run1-2/", out)

    def test_it_says_that_the_first_records_pid_files_are_from_the_previous_boot(self):
        out = self.restart().stdout.decode()
        note = [l for l in out.splitlines() if l.startswith("restart-record: NOTE:")]
        self.assertEqual(len(note), 1)
        self.assertIn("%s/run1/" % self.cap, note[0])
        self.assertIn("previous boot", note[0])
        self.assertIn("Never signal them", note[0])

    def test_the_commands_are_printed_even_when_a_process_did_not_stay_up(self):
        result = self.restart(env=dict(self.env, STUB_FAIL="python"))
        self.assertEqual(result.returncode, 1)
        self.assertIn('tail -f "%s/run1-1/watch.log"' % self.cap, result.stdout.decode())

    def test_the_next_free_number(self):
        for expected in ("run1-1", "run1-2"):
            self.assertEqual(self.restart().returncode, 0)
            self.assertIn(expected, self.records())
        os.mkdir(os.path.join(self.cap, "run1-4"))
        self.assertEqual(self.restart().returncode, 0)
        self.assertEqual(self.records(), ["run1-1", "run1-2", "run1-3", "run1-4"])
        self.assertTrue(self.pids("run1-3"))
        self.assertFalse(self.pids("run1-4"))  # an existing directory is never written into

    def test_a_file_where_a_directory_would_go_is_skipped(self):
        write(os.path.join(self.cap, "run1-1"), "not a directory\n", 0o644)
        self.assertEqual(self.restart().returncode, 0)
        self.assertTrue(self.pids("run1-2"))

    def test_the_first_record_in_run1_is_never_touched(self):
        os.mkdir(os.path.join(self.cap, "run1"))
        write(os.path.join(self.cap, "run1", "phases.log"), "1761870000.000 CTX armed\n", 0o644)
        self.restart()
        with open(os.path.join(self.cap, "run1", "phases.log"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "1761870000.000 CTX armed\n")
        self.assertEqual(os.listdir(os.path.join(self.cap, "run1")), ["phases.log"])

    def test_it_writes_only_into_the_new_directory(self):
        before = {n: os.stat(os.path.join(self.cap, n)).st_mtime_ns for n in os.listdir(self.cap)}
        self.restart()
        self.assertEqual(sorted(set(os.listdir(self.cap)) - set(before)), ["run1-1"])
        self.assertEqual(before, {n: os.stat(os.path.join(self.cap, n)).st_mtime_ns for n in before})

    def test_a_process_that_does_not_stay_up_is_reported_and_the_exit_is_not_zero(self):
        result = self.restart(env=dict(self.env, STUB_FAIL="python"))
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stderr.decode(), r"watch +pid \d+ IS NOT RUNNING")
        pids = self.pids("run1-1")
        self.assertTrue(all(alive(p) for n, p in pids.items() if n != "watch"))  # the rest started

    def test_it_warns_if_a_sampler_is_already_running_and_goes_on(self):
        # a stub `pgrep` stands in for the real one, so that the test does not depend on what
        # this machine happens to be running
        result = self.restart(env=dict(self.env, STUB_PGREP="4242 4243"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("smc-sampler-5b0d191 is already running (pid 4242 4243 )", result.stderr.decode())
        self.assertTrue(self.pids("run1-1"))  # and it went on
        quiet = self.restart()
        self.assertEqual(quiet.stderr.decode(), "")


class Refuses(Staged):
    """Every refusal comes before anything is made or started."""

    def assertRefused(self, result, fragment):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(fragment, result.stderr.decode())
        self.assertEqual(self.records(), [])
        self.assertEqual(self.calls(), [])

    def test_no_watcher_sha(self):
        self.assertRefused(self.run_script("--captures", self.cap), "--watcher-sha is required")

    def test_a_watcher_sha_that_could_name_another_path(self):
        for bad, fragment in (("../x", "may hold only"), ("a b", "may hold only"), ("a/b", "may hold only"),
                              ("$(id)", "may hold only"), ("", "is required")):
            with self.subTest(sha=bad):
                self.assertRefused(self.run_script("--watcher-sha", bad, "--captures", self.cap), fragment)

    def test_unknown_arguments_and_missing_values(self):
        self.assertRefused(self.run_script("--watcher-sha", SHA, "--frobnicate"), "unknown argument")
        self.assertRefused(self.run_script("--watcher-sha"), "needs a value")

    def test_a_missing_or_unrunnable_sampler(self):
        os.chmod(self.sampler, 0o644)
        self.assertRefused(self.restart(), "pinned sampler is not executable")
        os.remove(self.sampler)
        self.assertRefused(self.restart(), "pinned sampler is not executable")

    def test_a_sampler_that_is_not_the_pinned_build(self):
        script = self.copy_of_script(pin=True)  # the shipped pin, which the stub does not match
        self.assertRefused(self.restart(script=script), "not the pinned build")

    def test_a_missing_watcher_or_companion(self):
        os.remove(os.path.join(self.watch, "run_watch.py"))
        self.assertRefused(self.restart(), "pinned watcher is not at")
        write(os.path.join(self.watch, "run_watch.py"), "#\n", 0o644)
        os.remove(os.path.join(self.watch, "watcher-down.sh"))
        self.assertRefused(self.restart(), "companion is not at")

    def test_a_captures_directory_that_is_not_there(self):
        result = self.run_script("--watcher-sha", SHA, "--captures", os.path.join(self.root, "nowhere"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not a directory", result.stderr.decode())
        self.assertEqual(self.calls(), [])

    def test_a_ctx_line_that_cannot_be_stamped_leaves_no_directory(self):
        perl = os.path.join(self.root, "stubs", "perl")
        write(perl, "#!/bin/sh\necho garbage\n")
        self.assertRefused(self.restart(script=self.copy_of_script(perl=perl)), "could not stamp the CTX line")

    def test_a_ctx_end_that_cannot_be_written_leaves_no_directory_and_starts_nothing(self):
        # umask 0277 makes mkdir leave a directory no file can be made in
        result = subprocess.run(
            ["/bin/sh", "-c", 'umask 0277; exec /bin/sh "$0" "$@"', self.script, "--watcher-sha", SHA,
             "--captures", self.cap], stdin=subprocess.DEVNULL, capture_output=True, env=self.env,
            timeout=60, check=False)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("could not write CTX end", result.stderr.decode())
        self.assertIn("nothing was started", result.stderr.decode())
        self.assertEqual(self.records(), [])
        self.assertEqual(self.calls(), [])  # no recorder, no watcher, no companion

    def test_an_interpreter_that_is_not_there(self):
        os.remove(self.python)
        self.assertRefused(self.restart(), "pinned interpreter is not executable")


class TheScriptItself(unittest.TestCase):
    def setUp(self):
        with open(SCRIPT, encoding="utf-8") as handle:
            self.text = handle.read()

    def test_it_parses(self):
        self.assertEqual(subprocess.run(["/bin/sh", "-n", SCRIPT]).returncode, 0)

    def test_it_is_executable_and_runs_under_sh(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        self.assertTrue(self.text.startswith("#!/bin/sh\n"))

    def test_it_pins_what_the_runbook_pins(self):
        for pinned in ('SAMPLER_NAME="smc-sampler-5b0d191"',
                       'SAMPLER_SHA256="f2e630924b6a55667eb8b0115a00cd19057588fc66d4d858f929ba71a903db8a"',
                       'PYTHON="/opt/homebrew/bin/python3"', 'LOGCMD="/usr/bin/log"',
                       "--interval=0.1 --keys=F0Md,F1Md,Ftst,F0Tg,F1Tg,F0Ac,F1Ac",
                       '--predicate \'subsystem == "dev.aeolus.AeolusHelper" AND process == "AeolusHelper"\'',
                       "while :; do date -u +%FT%TZ; sysctl -n vm.loadavg; notifyutil -g "
                       "com.apple.system.thermalpressurelevel; sleep 5; done"):
            self.assertIn(pinned, self.text)

    def test_the_ctx_end_write_comes_before_the_first_process_is_started(self):
        # Static, and so not a race: the dynamic check above reads the file from inside a stub that
        # is itself started a few milliseconds after the script moves on.
        write, launch, launches = ctx_end_position(self.text)
        self.assertIsNotNone(write, "the script does not write `CTX end` into phases.log exactly once")
        self.assertIsNotNone(launch)
        self.assertLess(write, launch)
        self.assertEqual(launches, 12)  # six `nohup`s, and the six `&` that put them in the background

    def test_the_scan_that_finds_it_reads_the_script_as_the_shell_does(self):
        good = ('# nohup here is a comment\n'
                'STAMP=1\n'
                'echo "$STAMP CTX end" > "$DIR/phases.log"\n'
                'echo "a note: nohup is only a word in it" >> "$DIR/phases.log"\n'
                'nohup "$SAMPLER" > "$DIR/f" 2> "$DIR/e" < /dev/null &\n')
        write, launch, _ = ctx_end_position(good)
        self.assertTrue(write < launch)
        for label, text in (
                ("tabs and runs of spaces", good.replace('echo "$STAMP CTX end" > "$DIR/phases.log"',
                                                          'echo\t"$STAMP CTX end"   \t>\t "$DIR/phases.log"')),
                ("split over lines", good.replace('echo "$STAMP CTX end" > "$DIR/phases.log"',
                                                  'echo "$STAMP CTX end" \\\n    > "$DIR/phases.log"')),
                ("single quotes for the target", good.replace('"$DIR/phases.log"\necho "a note', "'$DIR/phases.log'\necho \"a note")),
                ("a trailing comment", good.replace('> "$DIR/phases.log"\necho "a note',
                                                    '> "$DIR/phases.log"  # CTX end first\necho "a note'))):
            with self.subTest(label):
                write, launch, _ = ctx_end_position(text)
                self.assertIsNotNone(write, text)
                self.assertTrue(write < launch)
        late = ('nohup "$SAMPLER" < /dev/null &\n'
                'echo "$STAMP CTX end" > "$DIR/phases.log"\n')
        for label, text in (
                ("after a nohup", late),
                ("after a backgrounded command with no nohup", late.replace("nohup ", "")),
                ("after a nohup whose name is split over a line", late.replace("nohup", "no\\\nhup")),
                ("moved down with its note", good.split("echo \"$STAMP")[0] + good.split("\n")[-2] + "\n"
                 + 'echo "$STAMP CTX end" > "$DIR/phases.log"\n'),
                ("appended with >> (not the first line)", late.replace("> ", ">> ")),
                ("missing", good.replace('echo "$STAMP CTX end" > "$DIR/phases.log"\n', "")),
                ("written twice", good + 'echo "$STAMP CTX end" > "$DIR/phases.log"\n')):
            with self.subTest(label):
                write, launch, _ = ctx_end_position(text)
                self.assertFalse(write is not None and launch is not None and write < launch, text)

    def test_the_help_prints_the_header_and_not_the_code(self):
        result = subprocess.run(["/bin/sh", SCRIPT, "--help"], capture_output=True, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertIn("restart-record.sh --watcher-sha <sha>", result.stdout.decode())
        self.assertNotIn("mkdir", result.stdout.decode())


if __name__ == "__main__":
    unittest.main()
