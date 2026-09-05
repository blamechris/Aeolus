# ADR 0010 — Client-driven supervisor reads are coalesced, not prioritised

- **Status:** Proposed
- **Date:** 2026-09-05
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (fills [ADR 0007](0007-safety-composition.md)'s hole 2 on the grant path,
  and settles the third-level question [ADR 0006](0006-single-smc-reader.md) left to
  `SMCReadPriority`)

## Context

[ADR 0006](0006-single-smc-reader.md) puts **one** continuous SMC reader on the machine,
inside the helper. [#127](https://github.com/blamechris/Aeolus/issues/127) built
`SMCReadScheduler` to arbitrate it between two priorities — `.supervisor` and `.snapshot` —
with a starvation quota so neither can shut the other out.

Within `.supervisor` the scheduler is plain FIFO, and
[#134](https://github.com/blamechris/Aeolus/issues/134) is what that costs once several
supervisor-priority readers exist at once. With *N* outstanding, the last is admitted

```
N + (N - 1) / SMCReadScheduler.maxConsecutiveOvertakes
```

turns after it queues — 4 turns at N=3, measured by
`SchedulerTurnLifecycleTests.theSupervisorBoundIsPerOutstandingRead`; 17 at N=12, derived.
The turns are not equal-cost: a supervisor turn is the read's own handful of keys (~0.5 ms),
while the quota-forced turn it drags along once every `maxConsecutiveOvertakes` is a
**snapshot** turn of up to `maxKeysPerTurn` = 64 keys (~11 ms). So at N=12 the delay is
~59 ms, roughly 93 % of it the forced snapshot turns. **What hurts `docs/SAFETY.md` § 3 is
the number of simultaneously outstanding supervisor reads**, not the length of any one.

Four readers take `.supervisor` turns:

| Reader | Pacing | Outstanding at once |
|---|---|---|
| § 3's cycle (`ThermalEmergency.cycle()`) | 1 Hz, `ThermalSupervisor` | 1 |
| § 5's reclamation watchdog | 1 Hz, and **sequential by construction** ([#126](https://github.com/blamechris/Aeolus/issues/126)) | 1, whatever the fan count |
| Startup reconciliation | boot-only, before `listener.resume()` | not concurrent with a served client |
| `LeaseAuthority.refuseIfBlind` | **none** — one 34-key read per `acquireLease`, each in its own `Task` | unbounded |

The last is the problem, and it is adversarial rather than theoretical.
`LeaseAuthority`'s own documentation predicts the shape: a revoked client's *"ordinary
response to losing a lease is to acquire another one … on a cycle bounded only by how fast
the client retries"*. Each retry is an unpaced `.supervisor` read queued ahead of § 3's
cycle by pure FIFO — so a client in a tight retry loop delays the one mechanism that would
take its fans back, while looking to the scheduler exactly like the safety cycle it is
delaying. `CLAUDE.md` rule 6 is the consequence: the helper reports a mechanism as watching
while a client is pacing it.

Three questions were open, and the third is what this ADR is mostly about.

1. Does § 3's cycle need to outrank other supervisor reads at all?
2. If so — a third priority level, or a "never queues behind more than one other supervisor
   turn" rule?
3. Should grant-time `refuseIfBlind` reads be coalesced, rate-limited, or served from the
   cycle's most recent report?

`CriticalTemperatureSensing`'s own doc left question 3 open in as many words: *"Freshness
here is policy held by review, not by the type."* This is that policy written down.

## Decision

### D1 — FIFO among supervisor readers stands, once the only unbounded reader is bounded

On `Mac16,5` the watchdog contributes at most one outstanding read, § 3's cycle one per
second, and reconciliation runs before the listener serves. Bound the grant path and *N* is
2 or 3 rather than unbounded. At N=3 the pinned formula gives 4 turns ≈ 29 ms derived,
against **31.3 ms already measured** for a cycle contending with a full snapshot refresh —
so the residual contention is inside a cost the mechanism already absorbs.

`refuseIfThermalEmergencyActive` sits *above* `refuseIfBlind` in `acquireLease` and costs no
round trip, so a storm arriving during a latched emergency issues zero SMC reads: it delays
detection of a *new* condition, never the response to the one that is holding.

### D2 — No third priority level, and no head-of-queue rule

Both were rejected, and the reason is not the one written at `SMCReadPriority` before this.

Both fix the cycle's **place in line** under an unbounded *N* and leave the single connection
**saturated by an unprivileged client**. The snapshot then starves — `CLAUDE.md` rule 6, a
client rendering state nothing is refreshing — § 5's sweep stretches, and
[#133](https://github.com/blamechris/Aeolus/issues/133)'s blind spot widens. A third level
therefore makes read amplification *survivable* rather than *impossible*, and the
amplification is the defect.

A head-of-queue rule fails the same way with an extra cost: it is a rule about the queue's
*shape* that every future reader must be checked against, where a level is at least
declarative.

`SMCReadPriority` is named at every call site, so a third case is effectively permanent once
added. The old argument — *"a numeric level invites a third one to be slipped in between"* —
still holds; this is the stronger one, and it is now recorded at the type.

**The rejected level, in full, so it need not be re-derived:**

- *What it would buy.* One case, `.safetyCycle`, admitted ahead of `.supervisor`, plus a
  quota so it cannot starve the other two. § 3's cycle would then wait at most one turn
  behind whatever is in flight, whatever a client does — a strictly tighter bound on the
  cycle's own latency than D3 gives, and it needs no cache, no age bound, and no second
  protocol.
- *What it leaves broken.* Everything downstream of the cycle. The connection is still
  saturated: the snapshot still starves, § 5's sweep still stretches, and every one of those
  reads still costs a quota-forced snapshot turn. It also does not help unless the **quota**
  changes too, because the expensive turn is the quota's doing rather than FIFO's — so the
  minimal version of this alternative is not one new case but a new case *and* a re-derived
  starvation bound across three levels.
- *Why it is not kept as a belt.* An unused level is a level somebody will use. The pair
  `SMCReadScheduler` arbitrates is exactly two, and its starvation proof is written for two.

**Revisit trigger:** a supervisor-priority reader that can be neither coalesced nor paced.
E3's per-command `readEnvelope(ofFan:)` is the named candidate — one read per client message,
over a value the client is about to act on, which cannot be served from a cycle's own
reading and cannot be rate-limited without rate-limiting the client's command. If that
lands, D2 is reopened rather than worked around.

### D3 — The grant-time check is coalesced and age-bounded, served from § 3's own reading

`refuseIfBlind` asks *"can § 3 see?"*. § 3's cycle is the authoritative answer to that
question, so sharing its reading is **semantically exact rather than an approximation**.
Staleness is bounded by one cycle period, which is already the granularity at which
blindness is detected — nothing is given up that was ever promised.

Failures are recorded too. Serving a remembered failure **refuses**, which is the safe
direction, so a storm arriving during blindness costs one read rather than one per retry and
every retry is still refused. A cache written only on success would put the amplification
back on precisely the machine that can least afford it, with every one of those reads
failing.

The mechanism:

- **One `CriticalTemperatureCache` actor**, constructed by `HelperComposition` and handed to
  both consumers. `HelperCompositionTests` asserts the count at the source, because `main()`
  ends in `dispatchMain()` and there is nothing to observe it from at runtime.
- **Single-flight.** Concurrent callers join the read already running rather than issuing
  their own, so at most one grant-time read is ever outstanding — including on a cold cache.
  `ReadOnlyFanAuthority.discoverSensorKeys()`'s pattern.
- **`maxAge` derived from `ThermalSupervisor.defaultInterval`, never a second constant.** A
  staleness bound that disagreed with the cadence it describes would look correct from either
  side.
- **Written by every real cycle read, successes and failures**, by `ThermalEmergency.cycle()`
  on its way past.
- **Read through a different protocol.** The grant path holds `SightednessProving` (one
  method, `sighting()`); the cycle holds `CriticalTemperatureSensing`
  (`readCriticalTemperatures()`). `CriticalTemperatureCache` conforms only to the first and
  `CuratedCriticalTemperatures` only to the second, so **handing the cycle the cache does not
  compile, and neither does handing the lease core the raw telemetry**. That is
  `FanStateSensing`'s trick applied to a read: what a consumer may be given is expressed as a
  type, so the exclusion is a thing the compiler refuses rather than a thing a future edit
  must remember.
- **Written through a third.** `ThermalEmergency` has to hold the cache in order to record
  into it, and while it held the concrete type `sighting()` was one line away from the cycle —
  which is the staleness this ADR accepts on the grant path arriving on the decision path by a
  route the trick above does not cover. `CriticalTemperatureRecording` has one method,
  `record(_:)`, so the cycle can write to the cache and **cannot read from it**.
- **A flight never overwrites what landed while it was away.** `sighting()` stamps its outcome
  when the caller *resumes*, not when its read finished, and nothing orders a resumed
  continuation against a fresh `record(_:)` on the same actor — so without a guard a flight
  that began before § 3's cycle can stamp the older of two readings as the newer one, and a
  sighting can replace a blindness the cycle recorded in the interval. The recorded stamp is
  compared against the flight's own start instead, which is the only instant the actor knows
  the flight to be no fresher than. Dropping the flight's reading costs one later read; keeping
  it would serve a reading for a full `maxAge` measured from a moment it was never taken at,
  which is outside the bound below rather than at its edge.
- **A cold cache, or a stopped supervisor, degrades to one real read per grant** — still
  single-flight. Nothing here can answer "sighted" without evidence.

**A cancellation is not recorded.** `LeaseAuthority.refuseIfBlind` already argues that
`CancellationError` is the one error that is not a statement about the machine. Remembering
one would be strictly worse in the cache than at the seam: it would be replayed as a
cancellation to *other* clients, none of whom was cancelled, for up to a cycle. Not
recording it costs one real read on the next grant, which is the fail-safe direction.

The single-flight join is the **residual case** of that same argument, and it is named here so
the next reader need not re-derive it: a joiner waits on the starter's task, so if the flight
throws `CancellationError` every joiner is handed one it did not cause. It cannot fire today —
the flight is an unstructured `Task`, so a cancelled grant does not cancel it, and nothing
under `source` throws a cancellation of its own, `SMCReadScheduler`'s wait for a turn being
deliberately uncancellable. It is bounded even if it does: one flight rather than a cycle, and
nothing is recorded, so the next caller reads. Pinned by
`CriticalTemperatureCacheFlightTests.aJoinerReceivesTheFlightsCancellation`, which will go red
the day a conformer beneath `source` starts throwing one.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Third priority level for § 3's cycle** | D2, recorded in full above. |
| **"Never queues behind more than one other supervisor turn"** | Same failure as a third level, plus it is a property of the queue's shape that every future reader must be re-checked against. |
| **Rate-limit `refuseIfBlind` per connection** | A rate limit refuses a *legitimate* first request from a second client, and a per-connection limit is defeated by a client that reconnects — which is what a revoked client does. It also still issues a read per admitted attempt. |
| **Drop the grant-time check** | It is ADR 0007 hole 2's whole answer on the grant path: a lease granted to a blind helper pins fans with only the TTL left. |
| **Batch the storm's reads into one turn** | The reads are already one turn each; the count of *outstanding* reads is what costs, and batching does not reduce it. |
| **Have § 3's cycle push its report into `LeaseAuthority`** | The lease core would then hold safety state it cannot refresh, and a stopped supervisor would leave it holding a reading with nothing to age it out. The cache owns the age bound and the fallback read; the lease core owns neither. |

## Consequences

- **A grant can be refused on a reading up to one cycle period old**, and a machine that goes
  blind is detected at the grant path up to one cycle later than before. Accepted explicitly:
  that is the granularity at which blindness is detected at all, and the refusal is
  fail-safe in the interval where it differs (a *remembered failure* keeps refusing; a
  remembered sighting can be at most one cycle stale).
- **`LeaseAuthority` no longer accepts a `CriticalTemperatureSensing`.** Every construction
  site supplies a `SightednessProving`. That is a compile error rather than a behaviour
  change, which is the point of the split.
- **`ThermalEmergency` takes a required `CriticalTemperatureRecording`.** Required rather than
  defaulted, for the reason `LeaseAuthority` gives about its latch: a defaulted one would
  record into something no grant reads, and every test would still pass. The parameter is the
  narrow protocol rather than the cache, so the cycle cannot read what it writes.
- **No XPC version bump.** Nothing here crosses the boundary; `AeolusXPCVersion` stays 1.
- **The counter for #133 exists but is not surfaced.** `CriticalTemperatureCache` counts
  coalesced sightings and reads issued; E5.4f's `SchedulerObserving` hook is where they
  should be reported from.
- **[ADR 0006](0006-single-smc-reader.md)'s single reader is now the *scarce* resource it was
  always described as**, rather than one an unprivileged client could consume at will.
- **[ADR 0007](0007-safety-composition.md)'s hole 2 keeps its grant-time answer** — the
  blindness refusal — at a bounded cost.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| § 3's cycle runs at 1 Hz whenever a lease can be held | `ThermalSupervisor.defaultInterval`; `HelperComposition.bringUp()` starts it before `listener.resume()` | The cache is cold or stale at most grants and degrades to today's behaviour — one read per grant, still single-flight. Safe, and the coalescing simply stops buying anything |
| A cycle's reading answers "can § 3 see" for the next second | The cycle is the mechanism whose sightedness is being asked about | If § 3's own read could succeed while a *different* read of the same keys fails, the grant path would be told "sighted" about a read it never performed — they are the same conformer and the same key set, which is what makes this hold |
| Blindness persists for at least one cycle | `docs/SMC-RESEARCH.md`: read failure on this machine is a stale `io_connect_t` or a powered-down cluster, not a single-sample glitch | A sub-cycle blindness flicker is missed by the grant path. Fail-safe direction only if the flicker is *toward* sighted; a flicker toward blind is now recorded and refuses |
| Outstanding supervisor reads, not read length, is the cost | Derived from `SMCReadScheduler`'s ~0.17 ms/key and the 64-key turn, same basis as #134's N=12 figure | Unchanged conclusion — coalescing reduces both |
| At most one watchdog read is outstanding | #126 made the sweep sequential, pinned by `ReclamationWatchdogTests` | *N* grows again and D1's arithmetic needs redoing; D3 is unaffected |
| `ContinuousClock` advances across system sleep | [ADR 0007](0007-safety-composition.md), documented but **unverified** on `Mac16,5` | A sighting taken before sleep reads as unexpired on wake, so the bound degrades from one cycle period to one cycle period *of awake time*. Mitigated by the supervisor's first post-wake cycle overwriting it, and the direction is the unsafe one only while that cycle has not yet run. ADR 0007 records the same assumption for the lease TTL; this ADR is the first to rest a **safety** bound on it. [#103](https://github.com/blamechris/Aeolus/issues/103) owns sleep/wake |

Every hardware observation here is `Mac16,5` on macOS 26.6.2, and the 31.3 ms contention
figure is the only measured one — the 29 ms at N=3 is derived from the pinned formula. No
storm has been driven against real firmware, because no write path exists to make a lease
worth retrying for. Intel and M1/M2 ship `untested`.

**Revisit when:** a supervisor-priority reader lands that can be neither coalesced nor paced
(E3's per-command `readEnvelope`); § 3's cadence stops being a single compiled-in interval;
concurrent leases ship, which multiplies the grant path by the number of holders; or
[#133](https://github.com/blamechris/Aeolus/issues/133) measures a real storm and contradicts
the arithmetic above.
