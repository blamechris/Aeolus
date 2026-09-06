# ADR 0007 — Safety-mechanism precedence, helper-death recovery, and sleep semantics

- **Status:** Proposed
- **Date:** 2026-08-03
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0005](0005-xpc-authorisation.md)'s lease design)

## Context

[SAFETY.md](../SAFETY.md) specifies eight safety mechanisms. It specifies them as if they were
independent, and they are not: several act on the same fan at the same instant, and the document
never states which one wins.

Design review before E5 ([#7](https://github.com/blamechris/Aeolus/issues/7)) asked the only question
worth asking of that document — do the eight mechanisms compose into the guarantee they claim, that a
user's fans always come back to automatic control? **They do not.** Three holes, one unresolved
conflict, and one mechanism that cannot be implemented as written:

1. **Helper death defeats everything at once.** Every mechanism runs inside the helper. If it dies
   while any fan is manual, the TTL enforcer, the reclamation watchdog, the thermal override and the
   sleep supervisor die with it; the SMC retains the last written state; and the launch daemon plist
   restarts nothing. §1's "the lease covers what signal handlers cannot" is true only of **client**
   death — for helper death, the lease's enforcer is the casualty. §1 and §6 conflate the two
   crashing processes throughout.
2. **Supervisor blindness.** Nothing covers "the helper cannot read". A stale `io_connect_t` after
   wake (not seen on a read-only handle in one lid close,
   [#68](https://github.com/blamechris/Aeolus/issues/68); open for the helper's own handle), a
   persistent read failure, or an
   empty critical-sensor set silently blinds §3 and §5 while a lease keeps fans pinned. §5 covers
   divergence of *values*, not inability to obtain them.

   **The grant-time half of this hole is answered, and the answer had a cost of its own.**
   [#124](https://github.com/blamechris/Aeolus/issues/124) added `LeaseAuthority.refuseIfBlind`:
   a lease is refused while the helper cannot read a critical temperature. It paid for that with
   one 34-key `.supervisor` read per `acquireLease`, unpaced — which made a retrying client the
   fastest supervisor-priority reader on the machine and put §3's own cycle behind it in FIFO
   order ([#134](https://github.com/blamechris/Aeolus/issues/134)).
   [ADR 0010](0010-coalesced-supervisor-reads.md) keeps the refusal and removes the cost: the
   grant path proves sightedness from §3's own most recent reading, coalesced and bounded by one
   cycle period, and reads for itself only when there is nothing fresh to serve.
3. **The lease-binding race** ([#95](https://github.com/blamechris/Aeolus/issues/95)): connection
   death releases immediately, but a message already in flight can bind a lease to a dead
   `ConnectionID` afterwards, leaving only the TTL where ADR 0005 promises two independent paths.
4. **§8 throttles §3.** The ramp cap is 200 RPM/s and this machine's fans span 1350–5777 RPM, so a
   full-scale emergency ramp takes **22 seconds** — a comfort mechanism rate-limiting a safety
   mechanism while a CPU sits above its ceiling.
5. **§6's crash mechanism is undefined behaviour.** It specifies "a signal handler plus `atexit`",
   but `IOConnectCallStructMethod` is not async-signal-safe, and the crash path is exactly when heap
   and lock state are unknown.

## Decision

### The keystone

Every ruling below rests on one principle `SAFETY.md` never states:

> **Restore-to-automatic is a mode write, and must never depend on trusted data.** It needs no
> bounds, no clamp, no sensor reading, no lease lookup and no ramp budget — `F0Md = 0` (plus
> `Ftst = 0`) on Apple Silicon, clearing the `FS!` bit on Intel.

Every safety mechanism's terminal action must be expressible as that verb, because it is the only
action that stays available when the data every other action depends on is untrustworthy.

### Precedence

Two classes. Conflating them is what produced conflict 4.

**Constraints** bind every write, with no exceptions, ever: §2's firmware bounds, and the 0-RPM
floor.

**Actors** command fans, higher pre-empting lower:

1. panic / restore verbs (§6, §7)
2. thermal emergency (§3)
3. reclamation watchdog (§5)
4. sleep/wake (§4)
5. lease expiry (§1)
6. the control loop under a lease

**§8 is not a peer of these.** Ramp limiting and hysteresis shape the control loop's output only, and
**never delay a safety-actor write.**

### Helper death

`KeepAlive = { SuccessfulExit = false }` — which implies `RunAtLoad` — is reinstated in the launch
daemon plist, **in the same change that ships unconditional startup reconciliation, never before.**
[#81](https://github.com/blamechris/Aeolus/pull/81) removed those keys because they would have
restarted a scaffold that always exits non-zero; the plist's own `TODO(#72)` defers the decision to
E5's actual semantics, and this is that decision.

On every start, before serving anything, the helper reads fan mode state and restores to automatic
any fan found in manual with no live lease. **Lease state is in-memory only, deliberately** — a lease
that survives its enforcer's death is a setting wearing a lease's name, and §1 already says the
guarantee is "a live supervised process, not a value written to disk". Reconciliation is that
sentence made mechanical.

Boot-start becomes a feature rather than a cost: reconciliation at boot also covers manual mode
persisting across a reboot, which nobody has verified cannot happen.

### Self-renewing leases are refused in E5 v1

Persist-across-quit ships as a follow-on, once restart and reconciliation are hardware-verified. Its
entire safety story *is* restart plus reconciliation, so shipping it before that mechanism is proven
would be asserting the guarantee rather than holding it.

This also simplifies the rest: with no helper-renewed leases, **the TTL backstops everything**, which
is what makes bounded tombstone eviction safe in #95's fix. Enabling self-renewal must revisit that
eviction in the same change — it is the one configuration where the TTL does not backstop.

### §6, rewritten

- **Orderly signals** (`SIGTERM`, `SIGINT`, `SIGHUP`, covering launchd shutdown): `DispatchSourceSignal`
  with the signal ignored, so delivery happens in normal execution context. Full restore, then
  `exit(0)`.
- **Orderly exits:** explicit teardown. `atexit` may stay as a cheap belt — it runs in normal context
  — but is never load-bearing.
- **Crash signals:** **no in-process restore at all.** Crash coverage is restart plus reconciliation,
  uniformly, for every way the helper can die.

#### Amendment, 2026-09-05 (E5.4d, [#166](https://github.com/blamechris/Aeolus/issues/166)) — the
`atexit` belt is removed, not merely made optional

The "orderly exits" bullet above permits `atexit` as a cheap belt on the grounds that *"it runs in
normal context"*. That grounds is correct and it is not the whole test. **An `atexit` body is
synchronous, and every step of the teardown it would back up is `async`** — the gate, the lease
core's `releaseEveryLease()`, the keystone `restoreToAutomatic(.everyFan)` and the supervisor stops
are all actor-isolated. The only way to reach them from an `atexit` handler is to spawn a `Task` and
block the exiting process on a semaphore, which converts a belt into a mechanism that can hang the
shutdown it was added to insure — and it would do so at exactly the moment launchd is counting down
to `SIGKILL`, so the failure it introduces is *worse* than the one it covers.

Nor is there anything left for it to cover. The belt was imagined as insurance against the signal
path not running. The signal path is now the process's only exit, asserted at the source: `exit(0)`
is written once in `Sources/AeolusHelper`, on that path
(`SignalTeardownTests.theOrderlyPathIsTheOnlyExit`). A helper that ends any other way ended by
`SIGKILL`, a panic or a power loss, and no `atexit` handler runs for any of those either.

So the rule is: **no `atexit`, no crash-signal handler, and no mach exception port anywhere in
`Sources/AeolusHelper`** — a tripwire, not a convention. The `atexit` half is ruled out for the
reason above; the crash-signal half stays ruled out for the original one, and the two must not be
collapsed into "signal handling is unsafe", because they fail differently.

This amendment corrects a clause of a Proposed ADR rather than the decision it sits under. **Status
stays Proposed.** `docs/SAFETY.md` §6's own bullet is corrected in place by the same PR;
[#104](https://github.com/blamechris/Aeolus/issues/104) carries it into that section's rewrite.

### Sleep

Release-before-sleep is **load-bearing**; the continuous-clock TTL is the **backstop**, for a sleep
that arrives without a completed notification round trip. Wake never silently re-asserts manual
control — the client re-acquires deliberately, which keeps rule 6 structural rather than a matter of
re-assertion racing the firmware.

The composition tolerates either answer to the unverified clock question: if `ContinuousClock` turns
out not to advance across sleep, the backstop degrades to "the lease survives with its remaining
TTL", bounding post-wake exposure at the TTL rather than eliminating it.

#### Amendment, 2026-09-06 ([#209](https://github.com/blamechris/Aeolus/issues/209)) — a budget
expiry is not a firmware refusal

§ 4's handback runs **once per sleep cycle, not once per lid close**. The
[#68](https://github.com/blamechris/Aeolus/issues/68) capture recorded one clamshell sleep plus six
maintenance sleeps inside 1 h 29 min (`SMC-RESEARCH.md`, "Sleep/wake and the read connection —
observed"), so the whole of § 4 — seal, release, keystone, acknowledge — executes several times an
hour with nobody present. The exposure is narrower than that cadence suggests:
`abandonOutstandingHandbacks()` reads `releasing`, which only a lease teardown populates, so a cycle
with no live lease records nothing. Whether cycles 2..N carry a lease is
[#211](https://github.com/blamechris/Aeolus/issues/211)'s client policy, undecided.

**Decision D17 is amended** (`SystemPowerResponder.swift`; `docs/SAFETY.md` § 4). A handback the
acknowledgement budget gave up waiting for no longer earns the durable `.restoreToAutomaticFailed`
refusal. It records a distinct *handback unconfirmed* state, which refuses a lease exactly as hard
while it stands and is resolved by the outstanding restore's own completion: a success clears it, a
refusal after `RestoreLimits.attemptBudget` converts it to the durable set through the path that
already exists, and a restore that never returns leaves it standing for the life of the process.
**A firmware refusal remains durable and is untouched.** The state is client-visible as an additive
`ManualControlAvailability.Reason` case, with no `AeolusXPCVersion` bump, on the Consequences
bullet below.

The reason is that the two producers are evidence about different things. A five-second timeout is
evidence about *time* — a wedged `io_connect_t`,
[#68](https://github.com/blamechris/Aeolus/issues/68)'s case — and says nothing about whether the
firmware would take the write; three refused attempts are evidence about the firmware. Collapsing
them let the cheapest and most frequent event in the system mint its most durable state, and in the
case where that state is *deserved* the restore's own return value already recorded it. The
abandonment therefore added nothing except when it was wrong.

**Rejected: clearing the refusal instead of not earning it.** Clearing on a later confirmed
successful restore ([#189](https://github.com/blamechris/Aeolus/issues/189)'s shape) puts a
read-back on or beside the keystone verb, which this ADR requires to depend on no trusted data;
clearing is a move toward granting and so must be gated on positive evidence, which means new
branches on the restore path for the case where the read-back itself fails. Clearing on the next
full wake is refused twice over: § 4 forbids any firmware contact on wake, and
`kIOMessageSystemHasPoweredOn` is delivered identically for dark and full wakes, so the predicate
cannot be written. Leaving it durable as today was rejected on its honest cost — a healthy
machine's five-second timeout permanently removing a fan from manual control, with
`fanctl reset --all` no route out because the ledger is the helper's own state and launchd
restarts only on a non-zero exit.

**Assumption table, new row:** *"one lid close delivers N `.willSleep`/`.didWake` pairs to a
registered process"* — **unmeasured**; the [#68](https://github.com/blamechris/Aeolus/issues/68)
capture ran no registered process. Basis: `pmset` cadence only. If maintenance sleeps deliver no
`kIOMessageSystemWillSleep`, the per-night exposure is one cycle rather than thirty; this amendment
is unaffected either way, which is why it rests on the evidence argument rather than on the
cadence.

**Revisit when:** E3/E4 hardware shows `BoundedFanRestorer` returning success for a write the
firmware did not take; or [#211](https://github.com/blamechris/Aeolus/issues/211) decides clients
re-acquire on every dark wake, which raises the frequency without changing the reasoning.

This amendment corrects a clause of a Proposed ADR rather than the decision it sits under.
**Status stays Proposed.**

## Alternatives considered

**In-process crash restore.** A signal handler calling IOKit is undefined behaviour on the one path
it serves. A mach-exception handler on a dedicated thread is technically sound but is
crash-reporter-grade machinery inside a root process, with failure modes we cannot quantify — and it
still covers nothing that `SIGKILL`, a kernel panic, or power loss also need. Restart plus
reconciliation covers all of those uniformly.

**Persisted lease state**, so a restarted helper could resume a lease. Rejected: that is a setting
wearing a lease's name, and it inverts §1's central claim.

**Ramp-capping the emergency.** Rejected on the arithmetic — 22 seconds above ceiling on this
machine's span — and on principle: a comfort mechanism does not throttle a safety mechanism. The
mechanical worry is also weaker than it appears, since the cap shapes the *target* while the fan's
own controller governs actual acceleration, and [SMC-RESEARCH.md](../SMC-RESEARCH.md) records `F0Ac`
slewing toward `F0Tg` rather than stepping.

**Re-asserting against reclamation during an emergency.** Rejected: reclamation mid-emergency means a
more competent authority — one that can also throttle the SoC, which Aeolus never can — reached the
same destination first. Aeolus never fights the system for the fans while any temperature is above
ceiling.

**A `connectionDidAdmit` live-set** as an alternative fix for #95, refusing any unknown
`ConnectionID`. Rejected: the delegate is synchronous and the authority is an actor, so the admit
notification and the connection's first message race into the actor's queue — you would either refuse
legitimate first messages or build ordering machinery to avoid it. Tombstones need no ordering: every
interleaving except "invalidation already ran" converges safe on its own, and the tombstone catches
exactly that one.

## Consequences

- **A root daemon that starts at boot and restarts on crash.** Accepted knowingly, and it is a
  reversal of #81 — justified because the thing being restarted is no longer a scaffold, and because
  the alternative leaves every safety mechanism defeated by a single crash.
- **Persist-across-quit is absent from the first release with manual control.** A feature the
  category leader has. Traded for shipping it on a proven mechanism rather than an assumed one.
- **No XPC version bump.** Every refusal E5 raises is an existing fault case or an additive,
  forward-tolerant `Reason`. E2's pre-built vocabulary is what makes that true.
- **Some of E5 cannot be hardware-verified before a write path exists**, because verifying "restore
  works" requires first being in manual. E5 therefore merges fully unit- and mock-tested with the
  hardware checklist *written*, and the gate on E3/E4 becomes: every E5 checklist row for that
  platform executes on hardware before that epic's PR merges.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| Restore-to-automatic mode writes work on real firmware | Community-reported; E3/E4 verify per platform | Firmware that leaves fans manual *and* refuses the restore write defeats everything here — a return-to-architect event and a `RECOVERY.md` headline |
| `ContinuousClock` advances across sleep | Swift documentation; **unverified on this machine and unverifiable without sleeping it** | Backstop degrades to ≤ TTL exposure post-wake; §4 remains load-bearing; nothing breaks |
| `SMAppService` accepts `KeepAlive`/`RunAtLoad` in a daemon plist | Documented-plausible; unverifiable until a signing identity exists | Restart policy needs another mechanism — escalate before shipping self-renewal |
| `F0Md`/`Ftst` are readable for reconciliation | Observed readable on `Mac16,5` | Reconciliation falls back to unconditional restore-to-automatic at startup — safe either way |
| `io_connect_t` survives sleep/wake | **Observed for the read path only**, on `Mac16,5` / macOS 26.6.2 across seven Deep Idle sleep/wake transitions with zero read errors ([#68](https://github.com/blamechris/Aeolus/issues/68), `SMC-RESEARCH.md` § "Sleep/wake and the read connection — observed"). A write-authorised handle, hibernate/standby, and every other machine remain open | The reconnect-or-release rule is the answer either way, and stays: the helper's handle carries write authority and its reconnect path was not exercised |
| One lid close delivers N `.willSleep`/`.didWake` pairs to a registered process | **Unmeasured** — the [#68](https://github.com/blamechris/Aeolus/issues/68) capture ran no registered process; basis is `pmset` cadence only | If maintenance sleeps deliver no `kIOMessageSystemWillSleep`, per-night exposure is one cycle rather than thirty; the [#209](https://github.com/blamechris/Aeolus/issues/209) amendment is unaffected either way |

Every hardware observation above is `Mac16,5`. A row that names no build was taken on macOS
26.5.2; a row that names its own build (the `io_connect_t` row, 26.6.2) was taken on that build.
Intel and M1/M2 ship `untested`.

**Revisit when:** self-renewal ships (tombstone eviction coupling); the lid-close session contradicts
the clock assumption; `SMAppService` rejects the restart keys; or any firmware is found to refuse a
restore write while leaving a fan manual; or the #209 delivery count is measured.
