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
   wake ([#68](https://github.com/blamechris/Aeolus/issues/68)), a persistent read failure, or an
   empty critical-sensor set silently blinds §3 and §5 while a lease keeps fans pinned. §5 covers
   divergence of *values*, not inability to obtain them.
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

### Sleep

Release-before-sleep is **load-bearing**; the continuous-clock TTL is the **backstop**, for a sleep
that arrives without a completed notification round trip. Wake never silently re-asserts manual
control — the client re-acquires deliberately, which keeps rule 6 structural rather than a matter of
re-assertion racing the firmware.

The composition tolerates either answer to the unverified clock question: if `ContinuousClock` turns
out not to advance across sleep, the backstop degrades to "the lease survives with its remaining
TTL", bounding post-wake exposure at the TTL rather than eliminating it.

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
| `io_connect_t` survives sleep/wake | Open ([#68](https://github.com/blamechris/Aeolus/issues/68)) | The reconnect-or-release rule is the answer either way |

Every hardware observation above is `Mac16,5` on macOS 26.5.2. Intel and M1/M2 ship `untested`.

**Revisit when:** self-renewal ships (tombstone eviction coupling); the lid-close session contradicts
the clock assumption; `SMAppService` rejects the restart keys; or any firmware is found to refuse a
restore write while leaving a fan manual.
