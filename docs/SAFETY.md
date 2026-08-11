# Safety

The failure this project is engineered against, stated concretely:

> A user drops their fans to 800 RPM because the machine is noisy and they are in a call.
> The app crashes an hour later. They start a two-hour video render. Nothing puts the fans
> back up.

Every mechanism below exists to make some version of that impossible. None of them can be
disabled by configuration, and none of them are addressable over XPC — there is no message
that turns off the lease or raises a ceiling, because those messages do not exist.

**Implementation status: partial, and deliberately ahead of the write path.** The pure
constraint layer — § 2's clamp, its bounds gate, and § 3's and § 8's downward-only limits —
is built and tested in `FanKit`. The mechanisms that need a running helper are not: the
lease, the supervisor, sleep/wake, reclamation, and every restore path. All of it is
tracked as epic E5, and E5 blocks the write-path epics E3 and E4. No code that writes to
the SMC merges before the safety subsystem exists and is tested.

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

Every target speed is clamped to **`[max(F0Mn, 100), F0Mx]`**, using bounds read from the
firmware at runtime.

- **The firmware's bounds win.** A configuration file may narrow the usable range; it may
  never widen it, and it is never trusted over what the hardware reports.
- **0 RPM is not reachable.** Not through a curve, not through a fixed setting, not
  through a malformed config, not through the CLI. Stopping a fan entirely is not
  something this software will do.

### Why the floor is not simply `F0Mn`

Clamping to `[F0Mn, F0Mx]` alone does **not** deliver the second rule, and this document
said it did until #101. [RECOVERY.md](RECOVERY.md) records that a fan reading 0 RPM at idle
is normal on many Macs, so firmware may legitimately declare a minimum of zero — and a
clamp whose floor is that declaration then permits commanding a stop. The floor is
therefore `max(F0Mn, FanSafetyLimits.minimumManualRPM)`, with a compiled-in constant of
**100 RPM** that no configuration can lower.

100 separates "a fan turning slowly" from "a fan stopped", and is far below every minimum
real hardware declares — `Mac16,5` declares 1350 — so on machines that declare a sane
minimum the constant is inert and `F0Mn` governs. Being non-zero is the load-bearing
property; the figure itself is a judgement.

### Clamping governs targets, never observations

`F0Ac` was measured at **1343.07 against a declared `F0Mn` of 1350** on this project's
development machine. A reading below the declared minimum is a legitimate observation, not
a fault: it is reported exactly as read. Nothing in the read path compares a measured speed
against the declared bounds or nudges one toward the other, and no test may assume it does.

### Bounds are checked before they are trusted (#37)

Rule 4 assumes the decoded bounds are *real*. `F<n>Mn`/`F<n>Mx` are `flt` keys and a
byte-swapped `flt` is typically a denormal (≈ 0) or ~1e14, so **no single codec error may
silently become a clamp ceiling**. Before manual control is offered for a fan, its bounds
must pass a plausibility gate:

| Check | Why |
|---|---|
| Both bounds finite | `SMCValue.scalar()` applies no finiteness guard, so a NaN or infinity can reach the model on an otherwise-successful read |
| `F<n>Mn >= 0` | A negative speed is not a measurement of anything a fan can do |
| `F<n>Mn < F<n>Mx` | An inverted or single-point range has nothing to clamp into |
| `F<n>Mx >= 100` | A fan whose whole range sits below the floor has no speed honouring both the 0-RPM rule and the firmware maximum |
| `F<n>Mx <= 20,000` | Rejects the denormal and ~1e14 shapes of a byte-order fault, with wide margin over real hardware |

A fan that fails any of them is reported
`manualControlAvailability: .unavailable(.boundsImplausible)` — distinct from "no helper"
and from "no such fan" — and **no target write of any kind may be produced for it, ever**.
Inventing a maximum to write against would push a fabricated number through the exact path
rule 4 exists to guard; see [ADR 0007](ADR/0007-safety-composition.md). The only action such
a fan is subject to is the bounds-free mode verb, restore-to-automatic, which needs no
envelope. Automatic control is untouched throughout: the system keeps managing the fan as it
already was.

A declared minimum of zero is **not** a plausibility failure. It is a machine whose fans
stop when idle, which Aeolus must work on rather than refuse; the floor above handles it.

This is defence in depth, not a substitute for correct decoding — it catches a *class* of
error rather than a specific bug, which is what makes it worth keeping even once the codec
is trusted.

Clamping and the gate both happen in the helper, after values cross the privilege boundary.
Client-side validation is a courtesy to the user; this is the actual control. The types
enforce it in two halves, and the split matters — see
[ADR 0008](ADR/0008-write-authorisation.md):

- **The arithmetic**, in `FanKit`: only a fan whose bounds passed the gate yields a
  `FanControlEnvelope`, and an envelope is the only thing that can produce a *speed*.
- **The identity**, in the helper: only a `FanEnvelope` yields a permit, and a permit is the
  only thing that can produce a *write*. `FanControlEnvelope` carries no fan index and
  `FanKit` never touches firmware, so "these bounds belong to fan *n*" is a fact only a read
  establishes — and a permit binds the index and the bounds that came out of the *same*
  `FanEnvelope`, so the fan written to and the envelope clamped into cannot disagree. Both
  write verbs — engage and command — take a permit; restore-to-automatic takes none, and must
  never acquire one.

  What that does **not** deliver, stated here because the normative document is the wrong
  place to imply more than the code holds: a permit is not proof the bounds came from
  firmware. `FanEnvelope`'s initialiser is internal, so a fabricated one is possible inside
  the helper — a review red flag rather than a compiler error. See
  [ADR 0008](ADR/0008-write-authorisation.md), which names that hole and one other.

*Tested by:* `FanKit` unit tests including zero, negative, above-maximum, non-finite, and
the declared-minimum-of-zero case; a rejection test per gate check, using synthetic bounds
and no hardware; a test asserting an observation below the declared minimum passes through
unclamped; and, on the helper side, a permit refused for every implausible declaration,
granted for a legitimate zero minimum, and source tripwires asserting that both write verbs
take a permit and that the restore verb takes none.

## 3. Thermal emergency override

The helper samples critical sensors every cycle. Above a compiled-in ceiling — 95 °C CPU,
90 °C storage by default — it forces the affected fan to maximum, then hands back to
automatic, and notifies the user.

**These ceilings are tunable downward only.** A configuration asking to raise one is
rejected rather than honoured. A safety limit the user can defeat is not a safety limit,
and the notification exists so that the override is never silent — a user whose machine
suddenly gets loud deserves to know why.

A value that is not a temperature at all — NaN, an infinity — falls back to the compiled
ceiling rather than being honoured. `min(requested, ceiling)` alone returns NaN when handed
one, because every comparison with NaN is false, and a NaN ceiling *disables* the override
instead of tightening it: `temperature > ceiling` is then false at every temperature. That
is a configuration turning a safety mechanism off, which this document says cannot exist.

The same downward-only rule governs the ramp cap in § 8, which is client data carried
inside a settings payload, and it is applied helper-side after the payload crosses.

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

Ramp rate is capped — 200 RPM/s — and curves apply hysteresis on falling temperatures.

Without these, a curve with a steep segment near a threshold oscillates: the fan speeds
up, the temperature drops below the point, the fan slows, the temperature rises. The
result is audible, irritating, and hard on bearings. Multi-point curves make it more
likely rather than less, which is why both are part of the curve model rather than
optional refinements.

**The cap is tunable downward only**, by § 3's rule rather than by analogy with it.
`FanCurve.maximumRampRPMPerSecond` is client data that crosses the privilege boundary
inside a settings payload: a configuration may ask the fans to move more gently than the
compiled cap, and may never ask them to move more abruptly. The clamp is applied where the
curve is *decoded*, so it binds a payload arriving over XPC and not only a curve
constructed in Swift — a rule that holds everywhere except across the privilege boundary is
not a rule. A request that is not a rate at all — zero, negative, or NaN — falls back to the
compiled cap.

Ramp limiting shapes the control loop's output **only, and never delays a safety-actor
write**: the thermal override in § 3 is not rate-limited by a comfort mechanism. See
[ADR 0007](ADR/0007-safety-composition.md).

*Tested by:* `FanKit` unit tests driving a temperature series across a curve boundary and
asserting no oscillation and no ramp faster than the cap; unit tests asserting that neither
a Swift-constructed nor a JSON-decoded curve can hold a rate above the cap.

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
