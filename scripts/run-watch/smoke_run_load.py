"""The one real load: two busy loops for two seconds, and two more for eleven.

    python3 -I -m unittest discover -s . -p smoke_run_load.py   # from scripts/run-watch; on request

It is not named `test_*`, so `python3 -I -m unittest` (the unit tests, and the dry run's sweep over
them) never starts it. It starts the driver as an operator would, with its real worker command
(perl's `alarm`, then `exec` of P1's `sh -c 'while :; do :; done'`) and `--max-seconds 2`, and
checks that:

  * the workers are real, running, and the PIDs in busy-1b.pids;
  * each is P1's loop once perl has exec'd it (`/bin/sh -c while :; do :; done`, in `ps`);
  * the driver ends them itself at its bound, and exits 0;
  * none of the recorded PIDs is left: not by `os.kill(pid, 0)`, and not in `pgrep -x sh`;
  * the CTX lines are in the file, and load.pid is gone.

The second test starts the driver with `--max-seconds 1`, SIGKILLs it, and requires both busy
loops to be alive a few seconds later and gone by their own SIGALRM, 11 s after they started (the
bound, rounded up, plus 10 s), with nothing else to have stopped them.

Whatever happens, it ends by killing what it started, by PID: the driver by its recorded PID, and
any worker still listed in busy-1b.pids. It never kills by pattern.
"""

import contextlib
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_LOAD = os.path.join(HERE, "run_load.py")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class RealLoad(unittest.TestCase):
    def test_two_real_busy_loops_for_two_seconds_and_none_left_after(self):
        with tempfile.TemporaryDirectory() as directory:
            pids_path = os.path.join(directory, "busy-1b.pids")
            driver = subprocess.Popen(
                [sys.executable, "-I", RUN_LOAD, "--mode", "1b", "--dir", directory,
                 "--workers", "2", "--max-seconds", "2"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pids = []
            try:
                deadline = time.time() + 10
                while time.time() < deadline and len(pids) < 2:
                    if os.path.exists(pids_path):
                        with open(pids_path, encoding="utf-8") as handle:
                            pids = [int(p) for p in handle.read().split()]
                    time.sleep(0.02)
                self.assertEqual(len(pids), 2, "the driver did not start two workers")
                started = time.time()
                self.assertTrue(all(alive(p) for p in pids), "a worker is not running")
                ps = subprocess.run(
                    ["/bin/ps", "-o", "pid=,comm=", "-p", ",".join(map(str, pids))],
                    stdin=subprocess.DEVNULL, capture_output=True, check=False)
                self.assertEqual(sorted(int(l.split()[0]) for l in ps.stdout.decode().splitlines()),
                                 sorted(pids))
                commands = set()
                for _ in range(100):  # perl execs within a few milliseconds
                    ps = subprocess.run(
                        ["/bin/ps", "-o", "command=", "-p", ",".join(map(str, pids))],
                        stdin=subprocess.DEVNULL, capture_output=True, check=False)
                    commands = set(ps.stdout.decode().strip().splitlines())
                    if commands == {"/bin/sh -c while :; do :; done"}:
                        break
                    time.sleep(0.05)
                self.assertEqual(commands, {"/bin/sh -c while :; do :; done"})
                self.assertEqual(driver.wait(timeout=15), 0)  # it stops itself at its bound
                self.assertGreaterEqual(time.time() - started, 1.0)
            finally:
                if driver.poll() is None:  # ours, by the PID Popen holds
                    driver.send_signal(signal.SIGTERM)
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        driver.wait(timeout=10)
                    if driver.poll() is None:
                        driver.kill()
                        driver.wait()
                for pid in pids:  # and any worker still running, by its recorded PID
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)
            self.assertFalse([p for p in pids if alive(p)], "a worker is still running")
            found = subprocess.run(
                ["/usr/bin/pgrep", "-x", "sh"], stdin=subprocess.DEVNULL, capture_output=True,
                check=False).stdout.decode().split()
            self.assertEqual(set(map(str, pids)) & set(found), set(), "pgrep -x sh lists a worker")
            with open(os.path.join(directory, "phases.log"), encoding="utf-8") as handle:
                kinds = [line.split(" ", 2)[2].split()[0] for line in handle]
            self.assertEqual(kinds, ["load-start", "load-stop"])
            self.assertFalse(os.path.exists(os.path.join(directory, "load.pid")))


class RealAlarm(unittest.TestCase):
    def test_the_busy_loops_of_a_sigkilled_driver_end_by_their_own_alarm(self):
        with tempfile.TemporaryDirectory() as directory:
            pids_path = os.path.join(directory, "busy-1b.pids")
            driver = subprocess.Popen(
                [sys.executable, "-I", RUN_LOAD, "--mode", "1b", "--dir", directory,
                 "--workers", "2", "--max-seconds", "1"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pids = []
            try:
                deadline = time.time() + 10
                while time.time() < deadline and len(pids) < 2:
                    if os.path.exists(pids_path):
                        with open(pids_path, encoding="utf-8") as handle:
                            pids = [int(p) for p in handle.read().split()]
                    time.sleep(0.02)
                self.assertEqual(len(pids), 2, "the driver did not start two workers")
                started = time.time()
                driver.kill()  # nothing can trap this: the driver cannot stop its workers
                driver.wait()
                time.sleep(4)
                self.assertTrue(all(alive(p) for p in pids), "a worker died with the driver")
                deadline = started + 11 + 5
                while time.time() < deadline and any(alive(p) for p in pids):
                    time.sleep(0.1)
                self.assertFalse([p for p in pids if alive(p)], "a worker outlived its alarm")
                self.assertGreaterEqual(time.time() - started, 10.0)  # at N = 11 s, not before
                found = subprocess.run(
                    ["/usr/bin/pgrep", "-x", "sh"], stdin=subprocess.DEVNULL, capture_output=True,
                    check=False).stdout.decode().split()
                self.assertEqual(set(map(str, pids)) & set(found), set(), "pgrep -x sh lists a worker")
            finally:
                if driver.poll() is None:
                    driver.kill()
                    driver.wait()
                for pid in pids:  # ours, by the PIDs recorded
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
