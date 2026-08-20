# Safety

The failure this project is engineered against, stated concretely:

> A user drops their fans to 800 RPM because the machine is noisy and they are in a call.
> The app crashes an hour later. They start a two-hour video render. Nothing puts the fans
> back up.

Every mechanism below exists to make some version of that impossible. None of them can be
disabled by configuration, and none of them are addressable over XPC — there is no message
that turns off the lease or raises a ceiling, because those messages do not exist.

**Implementation status: partial, and deliberately ahead of the write path.** Three layers
are built. The pure constraint layer — § 2's clamp, its bounds gate, and § 3's and § 8's
downward-only limits — is in `Sources/FanKit`. § 2's write authorisation, the permit binding
a fan index to the bounds a read established, is in
`Sources/AeolusHelper/FanWriteAuthorisation.swift` (ADR 0008). § 1's lease — the table,
monotonic expiry, tombstones and the teardown paths — is in `Sources/AeolusHelper/Lease`,
driven against in-memory doubles. Not built: § 3's override, § 5's watchdog, § 4's power
notifications, § 6's signal teardown and startup reconciliation, and § 7's body. All of it
is tracked as epic E5, and E5 blocks the write-path epics E3 and E4. No code that writes to
the SMC merges before the safety subsystem exists and is tested.

**How to read the *Tested by:* lines.** A bare *Tested by:* is a claim that those tests
exist and pass today. Where a mechanism is not built, the line reads
*Tested by (pending #N):* and names the issue that will satisfy it. The distinction is
load-bearing: a coverage claim naming a test that does not exist is worse than no line at
all, because it retires the question. #119 split every one of the eight sections against the
suite as it stands, so a bare line here is now a statement about tests that are in it.

**Where this document and [ADR 0007](ADR/0007-safety-composition.md) disagreed, ADR 0007
won.** Design review before E5 found that the eight mechanisms below do not compose as
written. ADR 0007 re-decided § 4's wake semantics, § 6's crash path, and § 8's standing
relative to § 3. **§ 5's primary signal is #102's ruling, not the ADR's** — worth being
exact about, in a document whose whole subject this round is not stating things more
strongly than the source does. This document was amended to match in #119; the paragraphs
that changed say so, in place, rather than quietly reading as though they had always said
it. ADR 0007 is still `Proposed`, as are ADR 0006 and ADR 0008 — the latter implemented and
merged — so that field lags practice here rather than signalling doubt.

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

**It is also not in the first release.** [ADR 0007](ADR/0007-safety-composition.md) refuses
self-renewing leases in E5 v1: persist-across-quit ships as a follow-on, once restart and
reconciliation (§ 6) are hardware-verified, because that pair *is* its entire safety story
and shipping it first would assert the guarantee rather than hold it. One consequence is
worth stating because the rest of this document leans on it — with no helper-renewed lease,
**the TTL backstops every mechanism here for as long as the helper is alive**, which is what
makes bounded tombstone eviction safe in #95's fix; enabling self-renewal has to revisit that
eviction in the same change. Two conditions sit outside the backstop, and both are covered
elsewhere rather than by the lease: helper death, where nothing is counting the TTL at all
and § 6's reconciliation is the only cover, and possibly sleep, per § 4's clock caveat.

The launchd job named in the paragraph above is itself part of what must be verified, not
something that exists: `KeepAlive` and `RunAtLoad` are absent from the plist today. § 6 says
what is scheduled to put them back — #86 holds that gap open and #103 closes it.

*Tested by:* unit tests on expiry arithmetic, including a wall clock moved in either
direction and a monotonic jump (`LeaseExpiryTests`); tests against a recording restorer
double covering connection death, an invalidation that never arrives at all, and a repeated
one (`LeaseTeardownTests`). Not against the scripted mock control plane — that is what § 3's,
§ 5's and § 6's pending lines will be driven through, and naming it here would have claimed
a fidelity these tests do not have.

*Tested by (pending #104):* a manual hardware check that `kill -9` on the app returns the
fans to automatic. It cannot run until a write path exists to put them anywhere else, which
is the ordering rule at the top of this document, not an omission.

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

**"95 °C CPU" means the package, not a core**, and the distinction is not pedantry: on the
one machine this project has measured, an all-core load put **27 of 45 per-core sensors above
this ceiling**, the hottest at 111 °C, while the package sat at 56 °C and the system's own
thermal management stayed relaxed at 2372 of 5777 RPM. Apple Silicon cores are designed to
run there. Compared against a core, this ceiling fires under any sustained multi-core work;
compared against the package, the same load leaves 39 °C of headroom, and the worst reading
in the whole session — 62 °C, during the heat soak after the load stopped — still leaves 33 °C.

The load was a synthetic twelve-way busy loop, held for 40 s. That is stated because it is
what was actually run: `docs/SMC-RESEARCH.md` carries the method, and an earlier draft of this
paragraph described it as a `swift build`, which no measurement in that session was taken
during. A number in a safety document has to be re-runnable by whoever doubts it.

The sensors the comparison actually uses are curated in code, per machine, and
`docs/SMC-RESEARCH.md` carries the measurement that separates the two populations — along
with a third, load-invariant population that is not a temperature at all and would latch the
override permanently on an idle machine.

**The 90 °C storage ceiling has no verified sensor on that machine.** The constant exists;
the key it would be compared against has not been identified, so no storage key is in the
curated set today and the storage half of this section is not yet mechanised. Said here
rather than left to be discovered, because a ceiling with nothing behind it reads exactly
like a ceiling that is being enforced.

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

*Tested by:* unit tests asserting that a request to raise a ceiling is rejected, and that a
NaN or an infinity falls back to the compiled ceiling rather than disabling the mechanism
(`ThermalCeilingTests`).

*Tested by (pending #102):* integration tests driving a mock SMC past each ceiling and
asserting the override engages, notifies, and releases. The ceiling constants and the
downward-only rule are built; the override that consumes them is not.

## 4. Sleep and wake supervision

The helper registers for system power notifications through `IORegisterForSystemPower` —
in the helper's own context, not the app's, because the app may not be running.

- Before sleep: release control and restore automatic mode.
- After wake: **nothing.** The helper does not re-assert.

**Release-before-sleep is the load-bearing half**; the continuous-clock TTL is the backstop,
for a sleep that arrives without a completed notification round trip. Whether
`ContinuousClock` advances across sleep is unverified on this machine and unverifiable
without sleeping it — if it does not, the backstop degrades to "the lease survives with its
remaining TTL", which bounds post-wake exposure rather than eliminating it, and makes
release-before-sleep matter more, not less.

**The helper never silently re-asserts manual control on wake.** This section instructed the
opposite until #119 — "re-acquire, and re-run the Apple Silicon unlock sequence", called not
optional — and that is a *write* the helper would perform unbidden, racing firmware that
resets `Ftst` across the sleep cycle for control it had just given up. A client that still
wants the fans asks for them again, through the ordinary acquisition path: the same
authorisation check, the same bounds gate, the same clamps, and a fresh lease. Exactly where
the unlock re-runs is E4's to settle — `Ftst` is machine-wide rather than per-fan — and all
that matters here is that the helper does not re-run it unprompted. Whether a client
re-acquires automatically on wake
or waits for the user is a client-side product decision; either way it is not a helper-side
write. That is what keeps "never claim control you do not have" a structural property rather
than a matter of re-assertion winning a race against the firmware. See
[ADR 0007](ADR/0007-safety-composition.md).

The stale-connection question — whether `io_connect_t` survives sleep/wake at all — is open
(#68), and reconnect-or-release is the answer either way: a helper that cannot read after
wake is the blindness case in § 5.

*Tested by (pending #103):* integration tests simulating the notification sequence,
asserting a restore before sleep and **no write at all** on wake; a manual hardware check
that closing the lid returns the fans to automatic and that reopening it leaves them there
until a client asks again.

## 5. Reclamation watchdog

**The primary signal is the target we wrote against the target the SMC reads back** —
`F<n>Tg` no longer holding what was put there, or the mode key no longer reading manual. A
persistent divergence means the system has taken the fans back despite our request.

**Actual RPM against target is a secondary signal, and only with a dwell time.** This
section named it the primary one until #119. As a primary signal it specifies the exact
defect the watchdog exists to avoid: `F<n>Ac` legitimately lags `F<n>Tg`, so an
actual-versus-target watchdog reads every ramp as a reclamation,
including the full-scale ramp § 3 performs during a thermal emergency, which is the one
moment it must not fire. A watchdog that reads another safety mechanism's work as an attack
on it is worse than no watchdog.

The evidence for the lag is thinner than the ruling needs, and that is an argument *for* the
ruling rather than against it. [SMC-RESEARCH.md](SMC-RESEARCH.md) records `F0Tg` and `F0Ac`
climbing together under a slow warm-up — 1350 → 2195 against 1343 → 2166, about 1% apart —
which shows the two are coupled, not that a commanded step is followed gradually. No write
has ever been performed on this machine, so no step response has been observed at all. A
primary signal that depends on fan dynamics would be resting on that; written-target versus
read-back target does not depend on them, which is the point.

**Being unable to read is divergence too.** Nothing here covers "the helper cannot see" — a
stale `io_connect_t` after wake (#68), a persistent read failure, an empty critical-sensor
set — and each of them blinds this section and § 3 while a lease keeps the fans pinned.
Persistent read failure is therefore treated as divergence: attempt a reconnect, then
restore automatic and report. § 3 having working telemetry is a precondition of § 1 granting
a lease at all.

When divergence is confirmed the helper either re-asserts control or falls back to automatic
— and either way **tells the user**. It never continues reporting a target speed the
hardware is ignoring.

**The re-assert branch exists only below § 3's ceiling**, with a bounded attempt budget,
after which it falls back and reports. Reclamation during a thermal emergency means a more
competent authority — one that can also throttle the SoC, which Aeolus never can — reached
the same destination first. Aeolus does not fight the system for the fans while any
temperature is above ceiling.

This is a correctness rule as much as a safety one. A UI that lies about fan state is
worse than a UI that reports an error, because the user acts on it.

*Tested by (pending #102):* integration tests where the mock SMC reverts a written value.
`ScriptedControlPlane` can express that today — `WriteBehaviour.reverted` — but there is no
watchdog yet to drive with it.

## 6. Restore on everything

Automatic control is restored on every exit path: app quit, helper `SIGTERM`, logout,
shutdown, uninstall, and crash. **Three mechanisms cover them, and which one covers which is
the whole content of this section.** It named a single mechanism until #119 — "a signal
handler plus `atexit`" — and that one is undefined behaviour on the path it was written for.

- **Orderly signals** — `SIGTERM`, `SIGINT`, `SIGHUP`, which is how launchd shuts the helper
  down. `DispatchSourceSignal` with the signal itself ignored, so the handler body runs in
  normal execution context and not in signal context. Full restore, then `exit(0)`.
- **Orderly exits** — explicit teardown. `atexit` may stay as a cheap belt, since it too
  runs in normal context, but nothing may be load-bearing on it.
- **Crash signals** — **no in-process restore at all.** `IOConnectCallStructMethod` is not
  async-signal-safe, and a crash is exactly when heap and lock state are unknown. A signal
  handler that calls into IOKit is undefined behaviour on the one path it exists to serve.

**Crash coverage is restart plus reconciliation**, uniformly, for every way the helper can
die — including the ones no handler could ever reach: `SIGKILL`, a kernel panic, a power
loss. On every start, before serving anything, the helper reads fan mode state and restores
to automatic any fan found in manual with no live lease. Lease state is in-memory only and
deliberately so: a lease that survives its enforcer's death is a setting wearing a lease's
name, and § 1's guarantee is a live supervised process, not a value written to disk.
Reconciliation is that sentence made mechanical, and at boot it also covers manual mode
persisting across a *reboot*, which nobody has verified cannot happen. See
[ADR 0007](ADR/0007-safety-composition.md).

**Restart is not configured yet.** `KeepAlive` and `RunAtLoad` were removed from the launch
daemon plist in #81 because they would have restarted a scaffold that always exits non-zero.
ADR 0007 reinstates them **in the same change that ships reconciliation, never before** —
#103 — because a restart policy without reconciliation restarts a helper that then serves
without checking what the SMC still holds. Until that lands, the paragraph above describes a
decision rather than a mechanism, which is what #86 exists to hold open.

The guarantee to match is Macs Fan Control's: quitting always returns the fans to Apple's
control. Anything less and users are right not to trust the software.

**The lease covers *client* death; reconciliation covers *helper* death.** Conflating the
two processes is what let this section claim a signal handler was the answer. § 1's lease
handles a crashed, killed, or hung app — `SIGKILL`, a kernel panic, a power loss on the
*client* side — because the enforcer outlives it. When the helper is the one that dies, the
enforcer is the casualty: the TTL is not counted by anything, the watchdog is not watching,
and the SMC keeps the last value written. Only a restart can notice.

*Tested by (pending #103):* integration tests per exit path, including a helper restarted
with a fan left in manual and no lease; a manual hardware checklist covering quit, kill,
logout, and restart.

## 7. Panic path

`fanctl reset --all` restores every fan to automatic, clears the force key, and drops all
leases. It must work when the helper's state is inconsistent and when the app will not
launch at all.

Handing the fans back to Apple's thermal management is always a valid state, so this
command is safe to run at any time, from anywhere, including over SSH.

[RECOVERY.md](RECOVERY.md) documents the procedure for when even that is unavailable,
including SMC reset key combinations by Mac family.

*Tested by (pending #104):* integration tests invoked against a deliberately corrupted
helper state; a manual hardware check. `fanctl reset --all` parses and is wired into the
command tree today, but its body exits with `Not implemented yet — see epic E10b`: the XPC
call behind it is #15 and the hardening is #104. Until both land, § 7 describes the panic
path rather than providing one — which matters more than the other pending lines here,
because this is the section the others fall back to.

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

**What exists is the constraint on the number, not a governor.** #101 shipped the
downward-only clamp, and nothing consumes the result: no code rate-limits a write, and
hysteresis has no evaluator — both are E8b (#17), as `FanCurve`'s own doc comment says. So
§ 8 today bounds a value a curve may carry and shapes no output, and the precedence ruling
above ("never delays a safety-actor write") is a rule about a mechanism that is not yet
there to break it. Which epic *should* own the governor is open — #121: E5's checklist
claims it, E8a is told to reuse it, and only E8b schedules it.

*Tested by:* unit tests asserting that neither a Swift-constructed nor a JSON-decoded curve
can hold a rate above the cap — `DownwardOnlyLimitTests`.

*Tested by (pending #17):* `FanKit` unit tests driving a temperature series across a curve
boundary and asserting no oscillation and no ramp faster than the cap. This line was
unqualified until #119; there is nothing to drive a series through yet.

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
