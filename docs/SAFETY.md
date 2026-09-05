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
driven against in-memory doubles. § 3's override, § 5's reclamation watchdog and § 8's ramp
governor are in `Sources/AeolusHelper/Safety` and `Sources/FanKit/RampGovernor.swift`, with
the precedence engine that composes them, driven against the scripted SMC. § 4's sleep and
wake supervision is in `Sources/AeolusHelper/Lifecycle`, behind a `SystemPowerObserving` seam
so everything above the IOKit registration is driven with no hardware. **§ 5 was in the
not-built list until it merged, and this line was stale for one wave; § 4 was listed there in
the very PR that built it, which is the same failure caught one wave earlier** — both
sentences are corrected in place rather than quietly rewritten, because a status paragraph
nobody re-reads is how a coverage claim outlives its subject. **§ 6's startup reconciliation
left that list in #164**, along with the launchd restart policy ADR 0007 made conditional on
it, and the same correction-in-place rule applies here as above. Not built: § 6's signal
teardown, § 7's body, and § 8's hysteresis. All of it is tracked as epic E5, and E5 blocks
the write-path epics E3 and E4. No code that writes to the SMC merges before the safety
subsystem exists and is tested.

**Built does not mean writing, and since #163 it does mean running.** This paragraph said
*"the helper still serves `ReadOnlyFanAuthority`, which grants no lease at all"*, and it was
stale for one wave — the same failure the § 5 sentence above records, in the same block,
recorded again rather than quietly rewritten, because a status paragraph nobody re-reads is
how a coverage claim outlives its subject. What is true now: `AeolusHelperMain` builds
`HelperComposition` and serves `SupervisedFanAuthority`, so the lease table, both teardown
paths, § 3, § 5 and § 1's TTL loop are **running in the daemon**. What has not changed is
that nothing can write: every mechanism below writes through `FanControlPlane`, whose
production conformer answers `controlPathNotBuilt` until E3 and E4 exist, and it reports that
as `FanWriteCapability.notBuilt` — which `LeaseAuthority.acquireLease` reads first, so every
lease request on real hardware is refused before anything else is attempted. The refusal is
now a gate on the seam rather than a literal in the type serving clients. So § 3 is a
complete, tested mechanism that runs every second with nothing yet to protect —
deliberately, because E5 is what gates the epics that give it something.

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
it. ADR 0007 is still `Proposed`, as are ADR 0006, ADR 0008 and
[ADR 0009](ADR/0009-precedence-at-the-write.md) — the middle one implemented and merged, the
last one implemented in half — so that field lags practice here rather than signalling doubt.

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

The launchd job named in the paragraph above now exists — `KeepAlive = { SuccessfulExit =
false }` and an explicit `RunAtLoad = true`, added in #165 alongside § 6's reconciliation and
never before it, which closes #86. What is still unverified is whether `SMAppService` accepts
either key in a daemon plist, and that needs the signing identity.

**The handback is bounded, and a handback that fails is terminal** (#110). "Restores every
affected fan" above is what the helper *attempts*; what it guarantees is that it stops
attempting. A restorer makes `RestoreLimits.attemptBudget` attempts per fan — three, § 5's
number — and then returns, naming the fans whose mode write was refused every time. It may
not retry forever: `LeaseAuthority` awaits the restore from every teardown path, and since
#136 one of those is `ReclamationWatchdog.cycle()`, so a restorer parked in a retry loop
parks a safety supervisor's loop for the life of the process, for every fan.

The fan it gave up on then enters a **permanent terminal state**, and it is the only one in
this document:

- Manual control over it is refused with `.restoreToAutomaticFailed` — durable, and
  deliberately distinct from the transient `.releaseInProgress`, so a client can tell
  *retrying* from *gave up*. `CLAUDE.md` rule 6 is the whole of it: the helper asked for
  automatic, was refused, and stopped asking, so it does not know what mode the fan is in.
- **Nothing watches it.** Every path that reaches this state has already cleared § 5's
  registry, so § 5 has no entry left to cycle over — see § 5 and #181, which owns
  re-registration.
- **Nothing clears it.** The ledger is append-only for the life of the helper process, so a
  later restore the firmware *does* accept leaves the refusal standing. #189 owns the
  clearing path; § 7's panic restore is the first caller that will need it.

A helper restart is the route out, and § 6's reconciliation is what makes it safe: the next
process reads `F<n>Md` before it serves anything and hands back whatever it finds in manual,
so the fan this refusal named is no longer one whose mode nothing has read. Built in #164,
and **still not a route out on today's build** — the restore it issues is refused with
`.controlPathNotBuilt` until E3/E4 ship a write path, so the fan is carried into the new
process as `.foreignManualControl` instead. That is a more accurate refusal, not a recovery.
`docs/RECOVERY.md` is the user-facing version.

*Tested by:* unit tests on expiry arithmetic, including a wall clock moved in either
direction and a monotonic jump (`LeaseExpiryTests`); tests on the supervisor's *schedule* as
distinct from that arithmetic — no sleep outruns the shortest TTL the helper will grant, so a
lease taken while a pass is parked is still swept at its own deadline rather than at the
stale one the pass went to sleep on (`LeaseExpirySupervisorScheduleTests`, #151); tests
against a recording restorer double covering connection death, an invalidation that never
arrives at all, and a repeated one (`LeaseTeardownTests`); the bound above
(`HandbackBoundTests`); and, since #163, the whole lease core **through the composed daemon
graph** over the scripted SMC — `HelperRestorerTests` acquires and tears down a real lease
against the real `LeaseAuthority` and asserts on both safety registries, and
`SupervisedFanAuthorityTests` does the same reaching the core only through the type the
listener is handed, covering acquisition, renewal, release, connection death and § 7's panic
verb. **The line above these two used to read "Not against the scripted mock control plane
for the first three", and that is no longer true**; it is corrected here rather than deleted,
because it was accurate when written and the change is what #163 was for. What those suites
still cannot do is write to a fan: the composed plane can, the real one cannot, and § 4's and
§ 6's pending lines below are where the remaining fidelity is owed.

`HandbackBoundTests` is split across two fidelities, and which property gets which is worth
naming rather than averaging. **Through the shipped `ScriptedControlPlane`** (bridged to the
attempt seam, and wrapped in `CeilingedRefusal` so a lost bound fails red instead of hanging):
that the call comes back at all after a firmware that refuses every mode write, that a
firmware which takes the write abandons nothing, and that a fan the restorer gave up on is
then refused durably through the lease core. **Against bespoke in-memory doubles**, because
the scripted plane's `WriteBehaviour` is a property of the stage and cannot express these:
that the budget is spent per fan (`PartiallyRefusingRestore` — one fan refused, its sibling
not), that a fan the firmware takes back on a later attempt is not abandoned
(`RefusesThenSucceeds`), and that a cancelled teardown still lands the write
(`CancellationSensitiveRestore` — a seam that fails only because the task was cancelled). The
durable refusal's ordering against a concurrent lease uses the in-memory double too.

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
automatic, revokes any lease that covered it, and reports — on the snapshot and in the log.
**Not a user notification**: a root daemon cannot post one, and this sentence said it did
until the mechanism was built. See "what the user is actually told" below.

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

**A client retrying `acquireLease` cannot delay this cycle without bound.** While the
override is latched a retry is refused from the latch alone, before any sensor is read;
while it is not, every grant-time sightedness check within one cycle period is served from
that cycle's own reading, and concurrent checks share a single read — so at most one
grant-time read is ever outstanding, and this cycle reaches the SMC connection within four
turns of asking. The mechanism is
[ADR 0010](ADR/0010-coalesced-supervisor-reads.md); the arithmetic that made it necessary,
and the third priority level that was rejected instead, are recorded there.

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
and the reporting below exists so that the override is never silent — a user whose machine
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

*Tested by:* `ThermalEmergencyTests` drives the scripted SMC to **exactly** the ceiling, to
the next representable value above it, into the hysteresis band, and to exactly the release
threshold — boundaries rather than "well above" and "well below" — and asserts that the
override engages, writes maximum in one step, restores, revokes the whole lease, and
refuses the next `acquireLease` while latched. `ThermalSupervisorTests` drives the same
mechanism through its own loop.

*Tested by:* `ThermalEmergencyStalenessTests` covers the same mechanism across a suspension
point, where the facts a cycle gathered stop being true before it acts on them: the latch is
never released against a temperature report older than the episode holding, the qualifying
key set that arms the degraded-view guard belongs to the episode that is holding rather than
one that has ended, a release clears the episode it was judged against and no other, and a
cycle that could not read at all still revokes whatever lease it finds.

The compare-and-clear is additionally asserted against the **source tree**, because under a
single supervisor no runtime scenario separates it from a bare release: the same suite checks
that nothing in `Sources/` clears the latch except the supervised cycle, and that the cycle
names the episode it judged when it does.

**What the user is actually told.** `isThermalEmergencyActive` on the snapshot, which the
app renders at 1 Hz, and a `.fault` line in the log. That is the whole of it: a root daemon
cannot post a user notification, so a `fanctl`-held lease with no app running gets no visual
signal at all — the machine getting loud is the physical one, and the next `fanctl`
invocation reports.

This section promised a notification in three places until #125 built the mechanism and an
adversarial review found the promise still standing two paragraphs above its own retraction.
Both have been corrected in place rather than deleted, because a safety document that
quietly stops claiming something is indistinguishable from one that never claimed it. The
as-built rewrite of this document is
[#104](https://github.com/blamechris/Aeolus/issues/104)'s.

*Tested by (pending #104):* the hardware rows — a real fan actually reaching maximum, and
the override releasing on a real cool-down — which cannot run until E3 or E4 builds a write
path.

## 4. Sleep and wake supervision

The helper registers for system power notifications through `IORegisterForSystemPower` —
in the helper's own context, not the app's, because the app may not be running. Callbacks
are delivered with `IONotificationPortSetDispatchQueue` and **never** through a CFRunLoop
source: `AeolusHelper`'s `main()` ends in `dispatchMain()`, which parks the main thread
rather than running a run loop, so a run-loop source there is added to a loop nothing will
ever run. That failure is silent — registration succeeds, the daemon looks healthy, and no
notification ever arrives.

- Before sleep, in this order: **seal acquisition** so no new lease can be granted until the
  machine wakes, **release every lease**, **restore `.everyFan`** through the keystone verb
  (which also clears the Apple Silicon force key), and only **then** acknowledge the power
  change.
- After wake: **nothing** written. The helper does not re-assert, and does not reconcile
  either. It clears the seal, which touches no fan.

**The seal is what closes the door the other three leave open.** Without it, a request
already parked on the helper's 34-key telemetry read when `.willSleep` arrived resumes after
the table has been emptied and every fan restored, finds no lease and no fan mid-handback,
and engages manual control on a machine that is about to stop running the helper — a fan
pinned across a sleep by the one path the ordering above does not cover. A client that asks
in the window is refused `ManualControlAvailability.Reason.systemSleeping` and told to ask
again after the wake. A helper that hears a sleep and never hears the wake refuses manual
control for the rest of its life, which is the fail-safe direction and is deliberately not
guarded against.

**Release-before-sleep is the load-bearing half**; the continuous-clock TTL is the backstop,
for a sleep that arrives without a completed notification round trip. Whether
`ContinuousClock` advances across sleep is unverified on this machine and unverifiable
without sleeping it — if it does not, the backstop degrades to "the lease survives with its
remaining TTL", which bounds post-wake exposure rather than eliminating it, and makes
release-before-sleep matter more, not less. What that bound *is*, exactly: the lease's own
remaining TTL, so at most `AeolusXPCValidation.leaseTTLRange.upperBound` — 120 s — and 30 s
for a client taking `Lease.defaultTimeToLive`. Composition either way, as ADR 0007 requires:
nothing in the helper changes on the answer, and #68's lid-close row records the measured
delta.

**The handback is bounded, and overrunning the bound is not a safety failure.** The
acknowledgement waits at most `SystemPowerLimits.acknowledgementBudget` — 5 s — after which
the helper allows the sleep anyway and logs at `.fault`. The case it exists for is a wedged
`io_connect_t` (#68) where a synchronous IOKit write never returns at all: `FanRestoreAttempting`
records that no attempt budget can bound that, and `BoundedFanRestorer` deliberately makes
each attempt uncancellable. Holding the sleep open instead would buy nothing — the kernel
sleeps the machine on its own timeout regardless.

**This paragraph named the TTL as what covers the fan that did not come back, and that was
wrong.** It is corrected in place rather than quietly rewritten, for the same reason the
status block above records its own staleness. The bullet list is the order of events: the
handback drops every lease *before* it restores, so by the instant the budget can fire there
is no lease left to expire and § 1 has nothing to be the backstop of. What actually covers
the fan, in the order it can act:

- **The parked restore may still land.** Nothing cancels it; § 4 stops waiting, and
  `BoundedFanRestorer` keeps attempting inside a task that does not inherit cancellation.
- **Every fan still outstanding is recorded as an abandoned handback before the sleep is
  acknowledged** (`LeaseAuthority.abandonOutstandingHandbacks()`, decision D17). That is the
  durable `restoreToAutomaticFailed` refusal of § 1, so no client can take a lease over a fan
  the helper never saw return to automatic control.
- **§ 3 still acts on it above the ceiling.** The thermal override's registry entry is
  deliberately retained across the handback, so such a fan coming back hot is taken to full
  scale. Above the ceiling only — that is an override, not a restore.
- **Startup reconciliation at the next helper start** (#164) is what actually returns it to
  automatic, and it is not built yet. Until it is, a fan in this state stays manual until
  something else moves it, and [RECOVERY.md](RECOVERY.md) is the user's route out.

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

*Tested by:* `SystemPowerTests`, which drives `.willSleep` and `.didWake` through the
composed helper against a scripted `SystemPowerObserving` — asserting the restore is on the
wire **before** the acknowledgement (observed from inside the acknowledgement, because
afterwards the two orders are indistinguishable), **no firmware call at all** on wake, that
the budget releases the system when the handback does not return, and that neither event
stops a supervisor. Four further properties, each with a mutation named against it: on a
wedged connection the lease table is empty at the acknowledgement (so the keystone cannot
precede the teardown), the outstanding fan is durably refused a new lease afterwards, a
refused restore still lets the machine sleep and says at `.fault` that it did not land, and a
lease request arriving inside the sleep window is refused `systemSleeping` until the wake
clears it. `HelperCompositionTests` asserts that the shipped `production(log:)` graph is the
one that carries an `IOKitSystemPowerObserver`.

*Not tested by anything automated, and cannot be:* `IOKitSystemPowerObserver` itself. No test
can register with a real power management root and then sleep the machine. The hardware rows
are what prove it — closing the lid returns the fans to automatic, reopening leaves them there
until a client asks again, the `ContinuousClock` delta across a real sleep, and whether
`io_connect_t` survives (#68).

## 5. Reclamation watchdog

**The primary signal is the target we wrote against the target the SMC reads back** —
`F<n>Tg` no longer holding what was put there, or the mode key no longer reading manual. A
persistent divergence means the system has taken the fans back despite our request.

**Actual RPM against target is a secondary signal, it is only read behind a dwell time, and
it reports without acting.** This section named it the primary one until #119. As a primary
signal it specifies the exact defect the watchdog exists to avoid: `F<n>Ac` legitimately lags
`F<n>Tg`, so an actual-versus-target watchdog reads every ramp as a reclamation, including
the full-scale ramp § 3 performs during a thermal emergency, which is the one
moment it must not fire. A watchdog that reads another safety mechanism's work as an attack
on it is worse than no watchdog.

**"Reports without acting" was added after an adversarial review**, and it is a correction to
this document as much as to the code. The secondary signal is only ever *reached* when the
primary has converged — the mode reads manual and `F<n>Tg` reads back exactly what was
written — so by construction it fires only on fans the firmware is faithfully holding for us.
A fan that cannot reach a target the firmware **is** holding has not been reclaimed: it is
obstructed, or failing, or declaring a maximum it cannot achieve. Re-asserting rewrites a
number that is already correct, restoring hands the fan to Apple's thermal management against
the same obstruction, and reporting it as reclaimed is a false statement about who holds it.
So the secondary signal tells the user and changes nothing else. Only the primary signal
reaches the re-assert and the fallback below.

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

**One window is graced, and only one.** A fan is registered as under manual control at the
moment the `F<n>Md` write lands, which is before anything has been commanded on it. In that
window the primary signal's target comparison cannot be made at all, and the two answers that
*are* reachable — the mode still reading automatic, or `F<n>Tg` not reading — are exactly
what the lag between a mode write and a read reflecting it looks like. Confirming divergence
there costs the client every lease on the machine milliseconds after it was granted one, with
a fault line blaming the operating system for it. So divergence on a fan with **nothing
commanded** is tolerated for `blindCyclesBeforeDivergence` cycles — three, so three seconds —
before it reaches the fallback above; for those cycles the user is told nothing beyond a
single notice-level line, and the paragraph above is true only from the cycle the grace ends
on. The first commanded target ends the grace outright, and a commanded fan is judged as
strictly as ever. The budget belongs to **one registration and is spent rather than reset**:
a converged cycle in the middle of it does not refill it, and neither does registering the
same fan again, so a fan whose firmware never agrees it is Aeolus's still ends up on
automatic control with the user told.

**The re-assert branch exists only below § 3's ceiling**, with a bounded attempt budget,
after which it falls back and reports. Reclamation during a thermal emergency means a more
competent authority — one that can also throttle the SoC, which Aeolus never can — reached
the same destination first. Aeolus does not fight the system for the fans while any
temperature is above ceiling.

**That rule is asked before the write path, and again after the writes land — with one
supervisor SMC turn still inside that window** —
[ADR 0009](ADR/0009-precedence-at-the-write.md). The re-assert is the first ordinary safety
write in this project that moves a fan **away** from the safe state, so the question of when
precedence is read stopped being academic with it. An answer obtained once per sweep and
spent several SMC turns later authorised a write § 3 had already forbidden, and the failure
was permanent: a re-pinned fan reads as converged on both of this section's own signals
forever, so nothing revisits it.

The window is narrowed rather than shut, and the bolded sentence above is worded to say so
rather than to reassure. ADR 0009 prescribes a second precedence read after the envelope read
and before manual control is re-engaged; **that read did not ship**, so § 3 can still latch
during the envelope read and both writes will land above the ceiling. What corrects it is the
check *after* the writes, which restores the fan in the safe direction — acting and then
checking, because the check cannot be made atomic with the act across two actors. The residual
that leaves is disclosed rather than rounded off: the undo is itself a restore, a restore can
be refused, and a refused undo leaves the fan pinned with a log line and no mechanism watching
it — § 3's registry is not told about the re-assert either.
[#181](https://github.com/blamechris/Aeolus/issues/181) carries all three — the missing read,
the § 3 registration, and the refused undo — and ADR 0009's "As built, and what did not land"
section is the audit of which parts of that ruling are in the tree.

**A write away from the safe state requires a live lease, checked at the write.** ADR 0009's
second ruling: this section's registry of held fans is a hint, and the lease table is the
authority. A held fan with no live lease is its own divergence class, restored and forgotten,
and never reported as a system reclamation — nobody took that fan, Aeolus simply stopped
being entitled to it. **That half is decided and not yet built**
([#180](https://github.com/blamechris/Aeolus/issues/180)), and the line is written this way
deliberately: until it exists, § 1's guarantee that manual control is a lease rather than a
setting rests on the control plane remembering to say when a lease ended, which is a
discipline that has already been forgotten twice in shipped code.

This is a correctness rule as much as a safety one. A UI that lies about fan state is
worse than a UI that reports an error, because the user acts on it.

*Tested by:* `Tests/AeolusHelperTests/ReclamationWatchdogTests.swift`,
`ReclamationWatchdogRecoveryTests.swift`, `ReclamationWatchdogStalenessTests.swift`,
`ReclamationRegistrationWindowTests.swift`, `ReclamationLimitsTests.swift` and
`ReclamationSupervisorTests.swift` — mostly through `ScriptedControlPlane`, with four bespoke
read seams in `ReclamationWatchdogFixture.swift` for what its stages cannot express: a refused
envelope, a read held open so overlapping reads would be visible, a read that runs a side
effect while it is suspended, and a control-state read answered from a scripted sequence so a
`F<n>Tg` can be readable on one cycle and not the next. § 1's line makes the same distinction
for the same reason, and it is drawn rather than rounded off because "entirely through the
scripted plane" is a claim about how much of the mechanism one shared double can reach. The
registration grace above is the fourth suite, one test per answer the primary signal can give
inside that window plus the two ways the budget must not be refilled.
Several of these tests are mutation checks rather than examples, and each names the mutation
it kills; every one was run against its mutant in an isolated worktree.
`ReclamationLimitsTests` is the exception to "driven, not asserted against the constant": it
bounds three constants from **above** with literals, because a test that derives its own loop
bound from the constant it exercises moves with that constant and catches nothing. The floors
are open, and #185 owns them.

Four of them exist because an adversarial review found that nothing in the original suite
could see a value read before an `await` and acted on after it — the watchdog is a reentrant
actor, and a lease can end, or § 3 can latch, in the middle of any SMC read it suspends in.
Those interleavings are scripted rather than raced, via a read seam that runs a side effect
*inside* one read, because a concurrency test that starts all its work at once cannot see a
bug that needs work to **arrive**.

The re-assert budget and the blind-cycle threshold are **driven to exhaustion** by their
tests rather than compared against their constants, so changing a constant changes what the
test observes without changing whether it passes.

*Not tested on hardware, and cannot be:* no write has ever been performed on this project's
development machine, so real reclamation behaviour, `Ftst` semantics, and a fan's actual step
response are unobserved. `ReclamationLimits.actualToleranceFraction` is set against a
warm-up measurement rather than a commanded step for that reason, and the whole mechanism
rests on the primary signal, which does not depend on fan dynamics at all. Hardware rows
belong to [#104](https://github.com/blamechris/Aeolus/issues/104).

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

**Restart is configured.** `KeepAlive = { SuccessfulExit = false }` and an explicit
`RunAtLoad = true` are in the launch daemon plist. #81 had removed them because they would
have restarted a scaffold that always exits non-zero; ADR 0007 required them back **in the
same change that ships reconciliation, never before** — a restart policy without
reconciliation restarts a helper that then serves without checking what the SMC still holds —
and #164/#165 is that change. `RunAtLoad` is written out rather than left to `KeepAlive`'s
documented implication, because boot-start is what covers manual mode persisting across a
*reboot*.

`SuccessfulExit = false` makes the exit code a contract: a zero exit means "the fans are back
and nobody needs to check", so it belongs on the orderly-teardown path and nowhere else, and
anything that dies another way is restarted and reconciles.
`LaunchDaemonPlistTests.theOrderlyExitIsCountedNotAssumed` counts `exit(0)` across
`Sources/AeolusHelper` — **zero today**, because `AeolusHelperMain` ends in `dispatchMain()`
and the teardown that restores and then exits is E5.4d (#166), which raises the expected count
to one in the same change that adds the path.

The plist's key set is an allowlist of exactly six with an exact-member count, so a seventh —
`StartInterval` (#84's named gap), `WatchPaths`, `StartCalendarInterval` — fails the suite
before it starts a root process nobody argued for.

**Whether `SMAppService` accepts either key in a daemon plist is unverified**, and cannot be
until a signing identity exists. ADR 0007 carries it as an assumption and the hardware
checklist carries the row. If it is rejected, reconciliation still runs — but only when a
client connects, not at boot and not after a crash.

**"On every exit path" is a guarantee about *attempting*, not about the firmware agreeing.**
Every mechanism in this section ends in the same mode write, and the firmware can refuse it.
When it does, § 1's bounded handback (#110) is what happens next: attempts are spent, the fan
is named in a `.fault` line, and manual control over it is refused for the life of the helper
process. The honest statement of this section's guarantee is therefore *every exit path
attempts a restore, stops attempting, and says which fans it could not put back* — a fan may
still be pinned at a speed Aeolus is no longer tracking, and no in-process mechanism will
take it back. That is not a weakening of the intent below; it is the same reason § 5 logs
`reclamationFanMayStillBePinned` rather than asserting a destination it did not reach.

Restart plus reconciliation is the cover for that case as much as for a crash: on the next
start the helper reads fan mode state and restores anything found in manual, which is the one
path that can clear a fan the previous process gave up on. Built in #164 —
`Sources/AeolusHelper/Safety/StartupReconciliation.swift`, run by
`HelperComposition.bringUp()` after the safety registries are bound and before any supervisor
starts. **It cannot land a write on today's build**: `SMCFanControlPlane` answers
`FanWriteCapability.notBuilt` and every write verb throws `.controlPathNotBuilt`, so the pass
reads the machine, says what it found, and is refused. E3/E4 make the restore real; the
reading, the ordering and the refusals are here now.

**A fan found in manual *after* that one pass is foreign control, and is refused rather than
restored** — [ADR 0011](ADR/0011-reconciliation-and-foreign-manual-control.md). The pass is
unconditional because `F<n>Md` names no owner and the failure directions are not symmetric:
restoring another program's fan hands it to Apple's thermal management, which is safe,
visible, and one click to undo, while declining leaves a fan possibly pinned low by Aeolus's
own dead helper with nothing counting a TTL. Restoring it a *second* time is different — it
is the beginning of a contest in which two programs undo each other's mode write over a
machine's cooling — so instead the fan is reported as
`ManualControlAvailability.Reason.foreignManualControl`, refused a lease after a fresh
`readControlState`, and never named to § 5, whose registry is fans **Aeolus** engaged.

The pass runs on a bounded budget (`ReconciliationLimits.budget`). If it runs out, the helper
serves clients anyway and refuses manual control of the fans it never reached, as
`.supervisorBlind` — nobody has looked at them, and nothing will, because reconciliation is
one-shot. **Wherever the pass cannot see, the machine-wide restore is issued anyway**: on a
failed mode read, on a failed fan enumeration, and on that budget expiry. The keystone needs
no data, which is the whole reason ADR 0007 makes it the keystone, and a fan nobody looked at
is not less pinned than one whose read threw (ADR 0011 D3). Being one-shot is enforced rather
than assumed — a second `reconcile()` is declined, because it would discard those refusals
and hand a fan back a second time.

**A fan the firmware refuses to hand back is refused a lease durably**, as
`.restoreToAutomaticFailed` — this process asked for automatic, spent #110's attempts, and
stopped asking. It is watched by nothing, § 3 included, because it was never in either
registry: reconciliation engaged nothing, so there is no entry for the emergency bridge to
find. That gap is deliberate rather than overlooked — registering a possibly-foreign fan with
§ 3 means writing to another program's fan during an emergency — and
[#201](https://github.com/blamechris/Aeolus/issues/201) holds it open against E3/E4 bring-up.

The guarantee to match is Macs Fan Control's: quitting always returns the fans to Apple's
control. Anything less and users are right not to trust the software.

**The lease covers *client* death; reconciliation covers *helper* death.** Conflating the
two processes is what let this section claim a signal handler was the answer. § 1's lease
handles a crashed, killed, or hung app — `SIGKILL`, a kernel panic, a power loss on the
*client* side — because the enforcer outlives it. When the helper is the one that dies, the
enforcer is the casualty: the TTL is not counted by anything, the watchdog is not watching,
and the SMC keeps the last value written. Only a restart can notice.

*Tested by:* `StartupReconciliationTests` drives the composed helper over scripted firmware —
a fan starting in manual is restored exactly once, a failed mode read and a failed
enumeration both fall back to the machine-wide verb, a second pass is declined, a fan taken
afterwards is refused and not restored, a fan the firmware would not hand back is refused
`.restoreToAutomaticFailed`, an exhausted budget takes the keystone and still refuses
durably, and the snapshot reports the firmware's own mode.
`ForeignManualControlReportingTests` covers the three fans the snapshot must **not** call
somebody else's: one under a live lease, one whose handback was abandoned, and one § 5
diagnosed as reclaimed by the system.
`HelperCompositionTests.reconciliationSitsBetweenTheBindAndTheSupervisors` holds the pass in
its position. `LaunchDaemonPlistTests` holds the restart keys and the exit-code contract.
*Pending #166:* an integration test per orderly exit path. *Pending hardware:* the checklist
rows for a helper restarted with a fan left in manual, boot-start, `kill -9`, and
`SMAppService` accepting the two keys — all of which need the signing identity and E3/E4's
write path.

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

**The ramp governor is built; hysteresis is not.** #121 recorded that three places named
three different owners for the governor, that #101 had shipped only the constraint on the
*number* — a curve could not hold a rate above the cap, and nothing consumed the result —
and that the precedence ruling above was therefore *a rule about a mechanism that did not
exist to break it*. #125 resolved that as #121's first option: **the governor is an E5
mechanism**, `FanKit.RampGovernor`, built in the change that states the ruling so the
exclusion is checkable by mutation rather than asserted. Hysteresis stays with #17 — it is
a property of evaluating a curve, and there is no curve evaluator yet.

The exclusion is **structural, not a runtime check**. Safety actors write through
`SafetyActorWriter`, which holds no governor and has no property one could be assigned to;
the control loop writes through `GovernedFanWriter`, the only holder of one. The two share
no protocol, so no code can be generic over "a writer" and hand a safety actor the governed
one. `SafetyActorLevel.Ungoverned` carries the five levels that bypass § 8 as a type, and a
test asserts it is exactly `allCases` minus the control loop — so adding a seventh safety
actor and forgetting it turns the suite red instead of silently governing a new safety
mechanism.

*Tested by:* `DownwardOnlyLimitTests` — neither a Swift-constructed nor a JSON-decoded curve
can hold a rate above the cap. `RampGovernorTests` — the governor caps a step in both
directions, lands exactly on the goal rather than overshooting, refuses to be made faster
than the compiled cap, and computes the 22.135-second full-scale ramp ADR 0007 rests its
refusal on. `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite` is the other end of
that argument — the emergency's bridge is asserted to reach the fan's declared maximum, so
injecting a governor into the safety writer fails it on the commanded RPM. The stronger half
is compile-time: `GovernedFanWriter` declares neither of the verbs a safety actor calls, so
handing one to the emergency does not build.

*Tested by (pending #17):* `FanKit` unit tests driving a temperature series across a curve
boundary and asserting no oscillation. The ramp half of that line is now covered above; the
hysteresis half still has nothing to drive a series through.

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
