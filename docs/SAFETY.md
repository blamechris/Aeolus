# Safety

The failure this project is engineered against, stated concretely:

> A user drops their fans to 800 RPM because the machine is noisy and they are in a call.
> The app crashes an hour later. They start a two-hour video render. Nothing puts the fans
> back up.

Every mechanism below exists to make some version of that impossible. None of them can be
disabled by configuration, and none of them are addressable over XPC — there is no message
that turns off the lease or raises a ceiling, because those messages do not exist.

**Implementation status: none of this is built yet.** It is tracked as epic E5, and E5
blocks the write-path epics E3 and E4. No code that writes to the SMC merges before the
safety subsystem exists and is tested.

---

## 1. Manual control is a lease

The central mechanism. Manual fan control is not a setting the user turns on; it is a
lease that has to be actively held.

- A client requests control with a time-to-live — 30 seconds by default.
- It renews on a heartbeat, every 10 seconds by default.
- If the lease expires for **any** reason — the client crashed, was `kill -9`'d, the GUI
  hung, the user logged out, a deadlock stalled the renewal — the helper restores every
  affected fan to automatic and clears the Apple Silicon force key.

The heartbeat interval is a third of the TTL so that two consecutive missed beats are
tolerated. A single scheduling hiccup must not surrender control; a dead client must.

**"Persist across app quit" is not an exception.** It is a lease the helper renews on the
user's behalf, kept alive by the helper's own launchd job. The failure mode above is
prevented in that mode too — what keeps the fans under control is a live supervised
process, not a value written to disk.

*Tested by:* unit tests on expiry arithmetic; integration tests against a mock SMC
covering crash, kill, and hang; a manual hardware check that `kill -9` on the app returns
the fans to automatic.

## 2. Hardware clamps

Every target speed is clamped to `[F0Mn, F0Mx]` as read from the firmware at runtime.

- **The firmware's bounds win.** A configuration file may narrow the usable range; it may
  never widen it, and it is never trusted over what the hardware reports.
- **0 RPM is not reachable.** Not through a curve, not through a fixed setting, not
  through a malformed config, not through the CLI. Stopping a fan entirely is not
  something this software will do.

Clamping happens in the helper, after values cross the privilege boundary. Client-side
validation is a courtesy to the user; this is the actual control.

*Tested by:* `FanKit` unit tests including zero, negative, and above-maximum requests.

## 3. Thermal emergency override

The helper samples critical sensors every cycle. Above a compiled-in ceiling — 95 °C CPU,
90 °C storage by default — it forces the affected fan to maximum, then hands back to
automatic, and notifies the user.

**These ceilings are tunable downward only.** A configuration asking to raise one is
rejected rather than honoured. A safety limit the user can defeat is not a safety limit,
and the notification exists so that the override is never silent — a user whose machine
suddenly gets loud deserves to know why.

User curves cannot override this. It is checked after curve evaluation, not before.

*Tested by:* integration tests driving a mock SMC past each ceiling and asserting the
override engages, notifies, and releases; unit tests asserting that raising a ceiling is
rejected.

## 4. Sleep and wake supervision

The helper registers for system power notifications through `IORegisterForSystemPower` —
in the helper's own context, not the app's, because the app may not be running.

- Before sleep: release control and restore automatic mode.
- After wake: re-acquire, and re-run the Apple Silicon unlock sequence.

The re-run is not optional. Firmware resets `Ftst` across a sleep cycle and the system
reclaims the fans. Without this, manual control silently stops working the first time the
lid closes, while the UI carries on displaying a target speed nothing is honouring.

*Tested by:* integration tests simulating the notification sequence; a manual hardware
check that closing and reopening the lid preserves manual control.

## 5. Reclamation watchdog

The helper compares actual RPM against target every cycle. A persistent divergence means
the system has taken the fans back despite our request.

When that happens the helper either re-asserts control or falls back to automatic — and
either way **tells the user**. It never continues reporting a target speed the hardware is
ignoring.

This is a correctness rule as much as a safety one. A UI that lies about fan state is
worse than a UI that reports an error, because the user acts on it.

*Tested by:* integration tests where the mock SMC reverts a written value.

## 6. Restore on everything

Automatic control is restored on every exit path: app quit, helper `SIGTERM`, logout,
shutdown, uninstall, and crash — the last via a signal handler plus `atexit`.

The guarantee to match is Macs Fan Control's: quitting always returns the fans to Apple's
control. Anything less and users are right not to trust the software.

Note that the lease (§1) already covers the cases a signal handler cannot — `SIGKILL`,
a kernel panic, a power loss. The handlers make the common cases fast and clean; the lease
is what makes the guarantee hold.

*Tested by:* integration tests per exit path; a manual hardware checklist covering quit,
kill, logout, and restart.

## 7. Panic path

`fanctl reset --all` restores every fan to automatic, clears the force key, and drops all
leases. It must work when the helper's state is inconsistent and when the app will not
launch at all.

Handing the fans back to Apple's thermal management is always a valid state, so this
command is safe to run at any time, from anywhere, including over SSH.

[RECOVERY.md](RECOVERY.md) documents the procedure for when even that is unavailable,
including SMC reset key combinations by Mac family.

*Tested by:* integration tests invoked against a deliberately corrupted helper state; a
manual hardware check.

## 8. Rate limiting and hysteresis

Ramp rate is capped — 200 RPM/s by default — and curves apply hysteresis on falling
temperatures.

Without these, a curve with a steep segment near a threshold oscillates: the fan speeds
up, the temperature drops below the point, the fan slows, the temperature rises. The
result is audible, irritating, and hard on bearings. Multi-point curves make it more
likely rather than less, which is why both are part of the curve model rather than
optional refinements.

*Tested by:* `FanKit` unit tests driving a temperature series across a curve boundary and
asserting no oscillation and no ramp faster than the cap.

---

## Rules for contributors

If you are writing code in `AeolusHelper` or the write path of `SMCCore`:

1. **Safety before capability.** Nothing that writes to the SMC merges before E5 is done.
2. **Never trust configuration over firmware.**
3. **Never allow 0 RPM**, by any path, for any reason.
4. **Never claim control you do not have.** Report reclamation honestly.
5. **Every safety mechanism gets a test.** The lease and the emergency override get
   integration tests against a mock SMC, plus a manual hardware checklist entry.
6. **Strict concurrency is not negotiable here.** In a root daemon that drives cooling
   hardware, a data race is a hardware-safety issue, not a crash report.

## What none of this protects against

Stated so the guarantees are not read as broader than they are:

- A user who deliberately sets a low fixed speed within the permitted range, on a machine
  under sustained load, with the app running and healthy. The ceiling in §3 is the
  backstop; below it, the user's choice is the user's choice.
- Hardware faults — a failed fan, a blocked vent, a failing thermal sensor.
- Bugs in the safety subsystem itself. Which is why it is tested first and reviewed
  hardest, and why the panic path in §7 exists.
