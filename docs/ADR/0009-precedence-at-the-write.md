# ADR 0009 — Precedence is read at the write, and the lease table is the authority

- **Status:** Proposed
- **Date:** 2026-09-05
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s precedence order and
  [ADR 0008](0008-write-authorisation.md)'s write authorisation)

## Context

[ADR 0007](0007-safety-composition.md) ordered the safety actors and said which one wins.
[ADR 0008](0008-write-authorisation.md) said what a write must carry. Neither said **when**
the precedence question is asked, or **what makes a fan's manual control legitimate at the
moment a level-3 actor writes to it**. Both questions were theoretical while §3 was the only
implemented actor. [#136](https://github.com/blamechris/Aeolus/pull/136) shipped the second
one — §5's reclamation watchdog — and made them concrete.

The watchdog is the first mechanism whose ordinary action moves a fan **away** from the safe
state: `SafetyActorWriter.engageManualControl(of:)` takes a fan off Apple's thermal
management to re-assert a target the firmware stopped honouring. Every other safety write in
the tree is a restore, which ADR 0007's keystone makes unconditional and total. A verb that
un-restores has to answer to something.

Adversarial review of #136 found that it answered to two things, and both were stale by the
time the write landed. Reproduced against the code rather than argued:

1. **The arbiter ruling was computed once per sweep and spent several suspensions later.**
   `cycle()` read `ThermalEmergencyLatch.isActive` once and carried the resulting
   `SafetyRuling` by value through `examine` → `diverged` → `reassert`, where it authorised
   two writes three suspension points — two of them scheduled `.supervisor` SMC turns — after
   the answer was obtained. §3 runs on an independent 1 Hz detached loop and can latch
   anywhere inside that window. The result: §5 re-engages manual control and writes a user's
   comfort target onto a machine §3 has just handed to Apple's thermal management, above
   ceiling.

   It does not self-correct. `ThermalEmergency.fire(_:from:)` empties `engagedFans` as it
   goes, and `ThermalEmergency.manualControlEngaged(_:)`
   (`Sources/AeolusHelper/Safety/ThermalEmergency.swift:164`) had **no caller in `Sources/`**,
   so the re-engaged fan is in no registry §3 consults; and §5's own next cycle reads manual
   mode and its own target read back correctly — convergence — so it does nothing either. The
   fan stays pinned for the whole emergency and after it.

2. **A stale `held` entry authorised manual control for a fan whose lease had ended.**
   `manualControlReleased(fanAt:)` had zero callers, `LeaseAuthority` holds no reference to
   either safety registry, and every teardown path restores through `FanRestoring` without
   deregistering. One second later the watchdog re-engages `F<n>Md` and re-commands the old
   speed — with no lease counting a TTL, no registry entry so no later cycle examines it, and
   no §3 entry so no emergency bridges it. That is `docs/SAFETY.md`'s opening scenario,
   produced by the mechanism written to prevent it, and it inverts `CLAUDE.md` hard rule 2:
   manual control surviving as a setting.

The shape underneath both is one this repository has already named. `LeaseAuthority`'s
doctrine — **a check separated from the act it guards is not a check** — was written for the
lease-binding race and applies verbatim here. `ThermalEmergency.fire(_:from:)` obeys it by
moving the decision inside the latch actor; §5 had no equivalent.

The second failure has a further property that decides its answer: §5's registry is
maintained by *notification discipline*, and that discipline has already failed twice in
shipped code — both `manualControlReleased` methods went in with no caller anywhere. A safety
mechanism whose central invariant depends on somebody remembering to call a method is a
mechanism that has already been shown, twice, to lose.

## Decision

### D1 — the ruling is read at the write, and the residual window must not be permanent

**Ask `SafetyArbiter` immediately before the write it guards, never once per sweep.** Delete
the `ruling:` threading through `cycle()` → `examine` → `diverged`; take a fresh latch read in
`diverged(_:fanAt:)` before the `permitsWrite` guard, and again after `readEnvelope` returns,
before `engageManualControl`.

The consistency argument for the single read — *"§3 is machine-wide, so reading it once means
a sweep cannot act on two different views of who holds the fans"* — is backwards. When §3
fires mid-sweep the world genuinely **does** have two states, and acting on the older one at a
write is the harm. A sweep makes *N* independent decisions, not one joint decision. The latch
is an in-process actor hop, so per-write rulings cost nothing against
[#134](https://github.com/blamechris/Aeolus/issues/134)'s read budget — worth stating in the
code, because #134 is the reason a future editor would re-hoist it.

**Per-write rulings alone are not sufficient**, and this is the half that is easy to skip.
They narrow the window to the suspensions between the ruling and the write; they do not close
it, because the check cannot be made atomic with the act across two actors. What makes the
residual unacceptable rather than merely small is that its failure is **permanent**: a
re-pinned fan reads as converged to both of §5's own signals forever, so nothing in the
process ever revisits it.

**So the residual is discharged by a second mechanism, not by shrinking the window further.**
Two discharge it, and either satisfies this decision provided the mechanism chosen is the one
documented:

- **Register the re-assert with §3** — call `ThermalEmergency.manualControlEngaged(_:)` on a
  successful engage, and deregister in `finaliseRelease`. §3's idempotent
  `takeBackAnythingEngagedSinceFiring()` exists verbatim for *"a fan engaged under a lease
  that raced the latch"*; the re-assert is exactly that race, and is invisible to it only
  because it performs `engageManualControl` without honouring the obligation the codebase
  already documents on whoever performs that verb.
- **Verify after acting, and undo in the safe direction** — re-read the ruling after the
  writes land and restore the fan if §3 latched underneath them. This depends on no registry
  and no other mechanism's cooperation, which is its advantage; its cost is that the undo is
  itself a write that can be refused, and a refused undo leaves the fan pinned with only a
  log line saying so.

Acting and then checking is the only sound pattern available when the check cannot be made
atomic with the act. Claiming the window is closed would be the more dangerous spelling.

### D2 — the lease table is the authority; the registries are hints, verified at the write

**A write away from the safe state requires a live lease, checked at the write.**

- A held fan with no live lease is a **new divergence class, `.leaseLapsed`**, checked in
  every `examine` *before* the firmware signals, whose only permitted action is
  **restore-and-forget**.
- It does **not** mark the ledger. The system did not take this fan; Aeolus stopped being
  entitled to it. Reporting `isReclaimedBySystem` here would be `CLAUDE.md` rule 6 in the
  direction people forget — claiming to have lost control that nobody took.
- `reassert` additionally re-checks `held[index] != nil` after the envelope suspension, for
  the same reason at the other end of the same window.
- `LeaseAuthority` gains a per-fan liveness query. It already exposes `activeLease()`; what
  this needs is the narrower question, asked about one fan. The watchdog already holds
  `leases`, so this adds no dependency edge and no reference cycle.

`CLAUDE.md` rule 7 states the principle — validation on the side that acts is the control,
everything else is courtesy — and it applies to a safety actor with more force than to any
XPC client, because a client's bad input is refused while a safety actor's stale belief is
executed.

The bonus that decides the tie between this and the alternatives below: `.leaseLapsed` makes
§5 the backstop for a **failed restore at lease end** — a fan that reads as converged on both
firmware signals forever, which today literally nothing covers until a helper restart
([#103](https://github.com/blamechris/Aeolus/issues/103), unbuilt).

### §3 is deliberately exempt

§3 acquires no lease-table dependency and no liveness check. This is stated because its
absence looks like an oversight and is not:

> A stale `engagedFans` entry authorises a redundant, idempotent write **toward** the safe
> state. A stale `held` entry authorises a write **away** from it.

The asymmetry is the whole argument. §3's worst case from a stale registry is restoring a fan
that was already automatic; §5's is pinning a fan nobody is entitled to hold. Adding a lease
lookup to the mechanism that runs while the machine is above its ceiling would make the one
write that must never be blocked depend on one more thing that can be unavailable — the
opposite of ADR 0007's keystone.

## As built in `c913448`, and what did not land

Stated in full rather than left to be inferred, because this ADR is being written after the
mechanism merged and a reader will otherwise assume the decision and the tree agree.

**Landed.** D1's first half is built and tested. `currentRuling()`
(`Sources/AeolusHelper/Safety/ReclamationWatchdog.swift:289`) reads the latch and asks
`SafetyArbiter.ruling(for:incumbent:)` (`Sources/AeolusHelper/Safety/SafetyPrecedence.swift:200`)
per write; the `ruling:` threading is gone; the guard sits immediately before the write path at
`:403`; the post-`readEnvelope` re-fetch is at `:501`; and the file states the general rule
once, at `:243` — *"re-fetch `held[index]` after every `await`, and treat its absence as an
instruction to stop rather than as a no-op"*.

D1's residual is discharged by the **second** of the two mechanisms above: `reassert` re-reads
the ruling after its writes and calls `finaliseRelease` if §3 latched underneath them
(`:544`). The re-assert does **not** register with §3 —
`ThermalEmergency.manualControlEngaged(_:)` still has no caller in `Sources/`. That satisfies
this decision, with one named residual: the undo is a restore that can be refused, and a
refused undo emits `reclamationFanMayStillBePinned` and nothing more. Registration would have
given §3 a second, independent chance at the same fan —
[#181](https://github.com/blamechris/Aeolus/issues/181).

**Did not land.** D2 is unbuilt in every part: there is no `.leaseLapsed` case, no liveness
query on `LeaseAuthority`, and `leases` is still referenced from exactly one place in the
watchdog — `revokeEveryLease` at `:666`. Hard rule 2 therefore still rests on notification
discipline in the tree as it stands, which is the condition D2 exists to remove.
[#180](https://github.com/blamechris/Aeolus/issues/180) carries it.

Also unbuilt: `FanRestoring`'s contract still reads *"must log it and keep trying"*
(`Sources/AeolusHelper/Lease/FanRestoring.swift:31`). That sentence is load-bearing for this
mechanism in a way it was not before — a keep-trying conformer awaited from `cycle()` parks
`ReclamationSupervisor` permanently and silently, for every fan, not just the one being
restored. [#110](https://github.com/blamechris/Aeolus/issues/110) owns the rewrite.

## Alternatives considered

**The lease core gains references to the safety registries**, deregistering each fan as it
restores. Rejected. It inverts the documented decoupling `ThermalEmergencyLatch` was extracted
to create — its own doc says three things need the bit *"and they must not need each other"* —
and forms a reference cycle between the lease core and the mechanisms that revoke leases. It
is also the most expensive reversal on the table: every teardown path in `LeaseAuthority`
would acquire knowledge of §5's existence.

**`FanRestoring` acquires deregistration as the control** rather than as a courtesy, which is
where [#110](https://github.com/blamechris/Aeolus/issues/110) argues such sentences belong.
Rejected, and this is the near miss. It keeps the registries authoritative and merely
relocates the same forgettable call — and it misses precisely the orderings it would exist
for: `revokeEveryLease` over an empty table calls the restorer **zero** times, so the racy
release that started this has no restore to hang the deregistration on.

**Shrinking the window further** — hoisting the latch read closer to the write, or reading a
temperature of §5's own instead of the latch. Rejected on both counts. No arrangement of
in-process code makes a cross-actor check atomic with the act, so the residual survives every
version of this; and a temperature read of §5's own would be a second copy of §3's ceiling
arithmetic in the file least able to keep it in step, plus a supervisor-priority read per
cycle against #134's budget, for a window §3 closes within one cycle by latching.

**Leaving §5's re-assert to §3's next cycle to correct.** Rejected because it is not true, and
an earlier version of the watchdog's own documentation claimed it was. `fire(_:from:)` empties
its registry as it goes and nothing re-registers, so §3's next cycle bridges nothing. Relying
on another mechanism to clean up after this one is the wrong shape regardless of whether the
mechanism exists: the correction belongs to the actor that performed the write.

## Consequences

- **Every level-3 write is preceded and followed by a precedence question**, so the cost of
  the mechanism is two latch hops per re-assert rather than one per sweep. That is deliberate
  and is worth restating wherever #134's read budget is discussed: these are in-process actor
  hops, not SMC turns, and they do not enter that budget.
- **`SafetyArbiter` is load-bearing rather than decorative.** Replacing
  `SafetyArbiter.ruling`'s body with `return .commands` now fails
  `ReclamationWatchdogTests.itNeverReassertsWhileTheThermalLatchHolds` *and*
  `itUndoesAReassertWhenTheEmergencyLatchesMidWrite`, because the ruling is consulted twice
  per re-assert.
- **A safety actor's registry is documentation, not authority.** Any future mechanism that
  writes away from the safe state inherits D2: it must ask the lease table at the write, and
  the registry entry that got it there proves only that somebody once thought the fan was
  held. This is the sentence to quote at E3 when the control plane is written.
- **`.leaseLapsed` is owed** ([#180](https://github.com/blamechris/Aeolus/issues/180)). Until
  it exists, the tree satisfies D1 and not D2, and hard rule 2 depends on a notification that
  has been forgotten twice.
- **No XPC version bump.** Nothing here crosses the boundary. The eventual durable
  per-fan-unavailability wire reason belongs to #102 and is expected to be an additive,
  forward-tolerant `Reason` — ADR 0007 consequence 3.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| A latch read costs an actor hop, not an SMC turn | `ThermalEmergencyLatch` is an actor over one `Bool`, read with no I/O | Per-write rulings acquire a real cost and #134's budget has to price them; the ruling still may not be hoisted, so the answer would be fewer writes rather than a staler check |
| §3 latches within one cycle of a temperature crossing the ceiling | `ThermalSupervisor` polls at 1 Hz and `fire(_:from:)` engages the latch as it goes | §5's one-cycle blind window widens; the undo at `:544` is what still bounds the damage, and it becomes the only thing that does |
| A restore refused once may still succeed later | ADR 0007's keystone — the restore depends on no trusted data | The undo path's residual becomes unbounded, and D1's registration half stops being optional |
| The lease table is cheap to interrogate per fan per cycle | `LeaseAuthority` is an actor over an in-memory table capped at one entry today | D2's liveness query needs a cache with its own staleness story, which is the problem it was written to remove — escalate rather than caching |
| Restore-and-forget is the right action for `.leaseLapsed` | ADR 0007: the terminal action is the one that depends on nothing | Unchanged — there is no weaker action available, and no stronger one is legitimate for a fan nobody holds |

Every hardware observation this rests on is `Mac16,5` on macOS 26.6.2. No write has ever been
performed on this machine, so the timing of a real reclamation — and therefore the true width
of the window this decision bounds — is unobserved. Intel and M1/M2 ship `untested`.

**Revisit when:** `.leaseLapsed` lands (this ADR's "did not land" section retires); §3 ever
gains a caller of `manualControlEngaged(_:)`, which would make registration available as the
discharge for D1's residual; concurrent leases ship, since D2's liveness question becomes
per-fan-per-lease rather than per-fan; or a fourth safety actor is added that writes away from
the safe state, which is the case this ADR's rules were generalised for.
