# The handback ledger

How `LeaseAuthority` records a restore-to-automatic that is in flight, that was given up on,
or that nothing has answered for — and why every teardown path hands its whole sweep back in
one call.

This is a **records** document: reasoning that was written as doc comment in
`Sources/AeolusHelper/Lease/LeaseAuthority.swift`, relocated here whole and pointed at from
the declarations it belongs to. It is not a decision record — [ADR
0007](../ADR/0007-safety-composition.md) owns the decisions, and its 2026-09-06 amendment is
D33 — and it is not normative. [docs/SAFETY.md](../SAFETY.md) § 1, § 4 and § 7 remain the
contract; this explains the three registers that implement the parts of it a reader cannot
get from the code alone.

## Why it is a document rather than a doc comment

`LeaseAuthority.swift` crossed SwiftLint's **1000-line `file_length` error** when
[#271](https://github.com/blamechris/Aeolus/issues/271) took `main` to 997 lines and
[#273](https://github.com/blamechris/Aeolus/pull/273) added the rest. Neither crossed it
alone.

The measurement is the same one
[#242](https://github.com/blamechris/Aeolus/issues/242) made about `HelperClient.swift`:
of 1013 lines, **238 were code**. The rule counts comment lines, and what pushed this file
over was prose rather than logic.

Three escapes were available and all three were refused.

- **`swiftlint:disable file_length`**, or a per-file override in `.swiftlint.yml`.
  [#268](https://github.com/blamechris/Aeolus/pull/268) was offered exactly that for
  `HelperClient.swift` and declined it, on the argument that *"a file that grew by two hundred
  lines of logic should draw exactly the attention this one drew"*. Suppressing the rule here
  would retire that argument for the whole tree.
- **A split into a third file.** Swift `private` is file-scoped, so an extension in a sibling
  file cannot see a `private` member — which is why every seam available without widening
  state was already taken by [#128](https://github.com/blamechris/Aeolus/issues/128)
  (`LeaseAuthorityRefusals.swift`, the three refusals that consult a stateless query role and
  none of this actor's own state). Everything left either reads or writes `table`,
  `tombstones`, `releasing`, `restoreAbandoned`, `handbackUnconfirmed` or `sleepSeal`, so
  moving any of it means widening that state to the whole module. D36 forbids it,
  `LeaseAuthorityAccessTests` enforces it, and `ReclamationWatchdog` records the identical
  ruling for the identical reason.
- **Shaving the overage.** `main` sat three lines under a hard CI error, so a fix that landed
  at 999 would fail the next unrelated PR to touch the file.

What was done instead is the third option the split question always had and nobody had taken:
the rationale that had outgrown a doc comment moved into this document, and each declaration
kept a summary and a pointer to the section here. No reasoning was deleted, and none of it was
shortened into a claim a reader has to take on trust.

## The three registers

Three sets, and each is a **distinct fact about one fan**. They are not three views of the
same thing, and telling a client the wrong one of the three is the failure they exist to
prevent.

| Register | The fact | Ends when |
|---|---|---|
| `releasing` | a restore is on the wire right now | that restore returns |
| `handbackUnconfirmed` | a restore was issued, stopped being waited for, and has not come back | the restore returns, or is refused after the attempt budget |
| `restoreAbandoned` | the attempts are spent and the firmware never took the write | a later restore of the same fan comes back un-refused |

All three are excluded from foreign manual control by `fansAeolusIsAccountableFor`, and each
has a **more precise** refusal in `acquireLease` than "another program holds it" — see
[The grant gate's ordering](#the-grant-gates-ordering).

### `releasing` — the transient half

Fans whose restore-to-automatic write is in flight right now, **counted rather than
set-membership** because the panic path can overlap a teardown on the same fan.

Removing a lease from the table and completing its restore are not the same instant, and the
actor is reentrant across the `await` between them. Without this register, an emptied table is
exactly what lets the next `acquireLease` through — the table being empty is the *condition*
it checks — so a client could take a lease over a fan whose handback is still on the wire.

**That overlap is unreachable in this build, and the count is therefore not load-bearing
today.** `guard table.isEmpty` holds the table to a single entry, and every teardown path
removes its entry synchronously before restoring, so whichever path removes first is the only
one that restores. Replacing the count with set membership passes the whole suite. It is
written this way because the overlap becomes reachable the moment either of those two facts
changes — E5.3's control plane issuing a restore outside lease teardown, or the table holding
more than one lease — and both are cheaper to be already correct for than to retrofit.
Recorded rather than implied, so nobody simplifies it believing a test is watching.

### `restoreAbandoned` — the durable half

Fans a restorer gave up on: the attempts are spent and the firmware never took the write. See
`BoundedFanRestorer` for the bound, and
[#110](https://github.com/blamechris/Aeolus/issues/110) for why there is one.

**One producer, and it is a firmware refusal.** `restore(_:because:)` unions in whatever the
restorer reports it could not hand back. [docs/SAFETY.md](../SAFETY.md) § 4's acknowledgement
budget expiring is **not** a second producer and was one until [ADR
0007](../ADR/0007-safety-composition.md), amendment 2026-09-06
([#209](https://github.com/blamechris/Aeolus/issues/209)): a budget is evidence about time
rather than about the firmware, so it records `handbackUnconfirmed` instead, and a fan reaches
this set from there only when the outstanding restore comes back refused — through the union
in `restore(_:because:)`, which is the path that already exists.

**Not append-only since [#189](https://github.com/blamechris/Aeolus/issues/189), and the one
thing that clears it is a restore the restorer reports it did *not* give up on.** It was
append-only until then, on #110's argument that nothing in `Sources/` restored a fan outside
lease teardown, so a clearing path would be code no test could drive. That argument was sound
and its premise outlived it by less than it looks: #189 recorded § 7's panic pass as the first
path that would need the clear, and the panic pass **could not reach such a fan at all** —
`releaseEveryLease` restored the fans of dropped table entries, and this set refuses every
lease over a fan in it, so no entry covering one could exist. The refusal was self-sealing:
the register made the only route to its own exit unreachable. `releaseEveryLease` therefore
sweeps this set beside the table, which is what gives the clear something to clear.

**The standard for clearing is two signals since [#291](https://github.com/blamechris/Aeolus/issues/291).**
The first is the one `HelperFanRestorer` marks § 3's registry on: the fan is in
`fans.subtracting(abandoned)` — the restorer was asked, came back, and did not name it. A weaker
one — "the panic pass ran" — would clear a refusal three observed firmware refusals set, on
evidence about a call rather than about a fan. But the first signal is itself evidence about a
call: `FanRestoring` promises no read-back, and a write the firmware accepted is not a fan in
automatic — #204's finding on reconciliation's keystone. So the second signal is a **fresh read
reporting the fan automatic**, asked through `ForeignManualControlSensing.fansReadingAutomatic`
so that the lease core still reads no firmware of its own. A fan that reads manual, or will not
read, keeps the refusal it already had; nothing *new* is minted from a read, which is the
constraint #204 set on its own read-back.

### Accepted is not automatic

`handbackAcceptedUnconfirmed` is the register between the two signals: fans in `restoreAbandoned`
whose latest restore the firmware accepted. It is always a subset of `restoreAbandoned` — it gains
a fan only from that set, loses one whenever a later restore of it is refused, and
`confirmAcceptedHandbacks()` removes a fan from both at once.

**The read is not taken where the acceptance is seen.** `restore(_:because:)` is awaited by § 4's
sleep handback and by SIGTERM's teardown, and each issues the machine-wide keystone only after it
returns. A read there — queued behind the scheduler, with no bound — would hold the keystone, and
the `releasing` count of every fan in the sweep, for as long as it took: the wrong trade for
lifting a refusal nobody is waiting on. The #291 review caught the first draft doing exactly that.
So the read runs in `confirmAcceptedHandbacks()`, which only § 7's panic verb calls — the one
caller with nothing queued behind it, and the recovery verb a user reaches for when a fan is stuck.
A sleep that hands such a fan back therefore lifts nothing; the next § 7 pass does.

**A fan that reads manual, or will not read, keeps the refusal it already had**, and stays owed.
Nothing is newly minted from a read, so #204's constraint holds: a manual read-back after an
accepted write never becomes `.restoreToAutomaticFailed` for a fan that did not already carry it.
The set is re-read after the await, on `ReclamationWatchdog.cycle()`'s rule: a restore refused
while the read was out removed the fan from it, and that refusal is the newer fact.

§ 3's deregistration rested on the first signal alone until
[#295](https://github.com/blamechris/Aeolus/issues/295), where a wrong answer stops the thermal
bridge watching a still-manual fan. It now uses both, on the same placement rule: the restorer
only *marks* an accepted fan owed a read-back (`ThermalEmergency.handbackAccepted(fanAt:)`), and
§ 3 takes the read from its own cycle — on a sighted, unlatched cycle that did not fire — and
forgets the fan only when it reads automatic under the generation the read was asked for. § 3's
cycle is awaited by nothing on a keystone's path, which is what lets it read where
`restore(_:because:)` cannot. It reads through `HandbackReadingBack`, the non-logging sibling of
`fansReadingAutomatic`, because it asks at 1 Hz and logs transitions itself.

**A restore that never returns still leaves it standing**, as does one that comes back refused
again, and both are the fail-safe direction. What is gone is only the case #189 names: a fan
Aeolus put into manual, could not hand back, and later *did* hand back, refused for the life
of the process on the strength of the older failure.

### `handbackUnconfirmed` — D33

Fans whose restore-to-automatic was issued, stopped being waited for, and has not come back:
[docs/SAFETY.md](../SAFETY.md) § 4's acknowledgement budget expired with it still outstanding.
Decision D33 on [#209](https://github.com/blamechris/Aeolus/issues/209) — [ADR
0007](../ADR/0007-safety-composition.md), amendment 2026-09-06.

The third register, between the transient `releasing` and the durable `restoreAbandoned`, and
it is a distinct fact from either: the write is still in flight, nothing cancelled it, and
this process has no answer about the fan's mode.

**Invariant: it is always a subset of `releasing.keys`.** A fan enters only from
`releasing.keys`, in `recordUnconfirmedHandbacks()`, and leaves only when its `releasing`
count drops to `nil` in `restore(_:because:)`'s `defer` — the instant the restore that put it
there returns. Nothing else writes it.

That invariant is why `fansAeolusIsAccountableFor` needs no third union: this set is contained
in `releasing.keys`, which it already unions, so adding it would change nothing and would
invite a reader to believe the two registers can diverge. It is asserted rather than merely
stated: `UnconfirmedHandbackTests` reads `fansMidHandback` beside
`fansWithUnconfirmedHandbacks` and requires the subset.

**Not append-only, and that is the whole of D33.** A restore that lands clears the fan; a
restore that comes back refused after `RestoreLimits.attemptBudget` clears it here and lands
it in `restoreAbandoned` through the union `restore(_:because:)` already performs; a restore
that never returns leaves it standing for the life of the process, which is the fail-safe
direction.

### Why recording it belongs to the lease core

`recordUnconfirmedHandbacks()` is § 4's budget path, and the reason it is in `LeaseAuthority`
rather than in `SystemPowerResponder`: `releasing` is that actor's own, and the set of fans
whose restore has been *issued and has not come back* exists nowhere else. When § 4 gives up
its wait, those fans are in a mode nothing has confirmed, and a lease over one would be
`CLAUDE.md` rule 6.

**It records `handbackUnconfirmed`, not `restoreAbandoned`, and the difference is D33.** That
method used to write the durable set, and the argument for it was: the helper asked, was not
answered in the window it had, so treat the fan as one the handback failed on. That argument
does not hold, because **a budget expiring is evidence about time, not about the firmware.**
Nothing there observed a refused write; what was observed is that five seconds passed. Two
consequences followed from conflating them, and both are the reason it changed: a *healthy*
machine that merely slept slowly lost a fan to manual control permanently, with
[docs/RECOVERY.md](../RECOVERY.md) as the only route out; and the log said the firmware
refused a write nothing had yet reported on.

What survives from the old argument is the refusal itself. An unconfirmed fan is refused
exactly as hard as an abandoned one for as long as it stands. What differs is how it ends —
the three outcomes in the table above.

**Additive and idempotent.** It is called from inside `SleepAcknowledgement`'s once-only
guard, so it runs at most once per sleep; being safe to call twice is a property worth having
anyway, because the alternative is a set whose correctness depends on a caller elsewhere.

## What the snapshot is told

`fansAeolusIsAccountableFor` is the union of all three registers: every fan whose manual state
is Aeolus's own doing, and therefore not foreign. Each register is **excluded** from foreign
manual control rather than judged by it, because each has a more precise refusal further down
`acquireLease`. `F<n>Md` reads `1` for all three and names no owner, so without the union a
client would be told *"another program holds it"* about:

- a fan under a live lease (`.leaseHeldByAnotherClient` — another *client*, not another
  program);
- a fan mid-handback (`.releaseInProgress` — retry in a moment);
- a fan whose handback was given up on (`.restoreToAutomaticFailed` — Aeolus put it there and
  could not take it back, which is a considerably worse thing to be told is somebody else's
  fault).

**`handbackUnconfirmed` is deliberately not a fourth union.** It is a subset of
`releasing.keys` by its own invariant, so every fan in it is already accounted for by the third
register. Adding it would change no answer and would suggest the two can disagree.

**One definition, read by the snapshot as well as by the gate**, through `activeLeaseView()`.
Two would disagree the moment either moved — and the way they disagreed before was the snapshot
naming a fan Aeolus could not hand back as another program's, while the gate refused it
correctly.

### Why the view is one hop

`activeLeaseView()` returns the lease **and** the fan sets together because the fan set is not
on the wire — `Lease` carries no indices — and the snapshot needs it anyway, to tell a fan
Aeolus is holding from one somebody else is. Two calls would answer that question from two
views of the actor: a lease reported live beside an empty fan set, and therefore a fan under
Aeolus's own lease reported as foreign control. One hop cannot disagree with itself.

**It is `fansAeolusIsAccountableFor`, not the lease's own fans, and the two are not the same
set.** An earlier version returned `table.all.first`'s indices, which was wrong twice over: it
named only the *first* entry's fans, so a second table entry's fans read as foreign; and it
omitted the fans that are mid-handback or whose handback was abandoned. A fan Aeolus itself put
into manual and could not give back would then be reported to the user as another program's —
`CLAUDE.md` rule 6, in the direction above.

**Since [#187](https://github.com/blamechris/Aeolus/issues/187) it carries the three registers
apart**, not merely their union. The union answers *"is this fan somebody else's?"*; it cannot
answer *"why would a grant over it be refused?"*, and those were the same question only while
the snapshot had no way to say either. A fan mid-handback and a fan whose handback was
abandoned are both accountable, and `acquireLease` refuses them with different reasons — one
meaning *retry in a moment* and one meaning *this is over* — so a snapshot that had only the
union reported both as available. The registers are returned rather than exposed as three more
properties for the reason the method exists at all: three reads are three views of the actor.

### The read-only rule the accessors are allowed under

`fansWithUnconfirmedHandbacks`, `fansWithAbandonedHandbacks` and `fansMidHandback` are
`internal` while the state behind them stays `private`, on exactly the trade
`fansAeolusIsAccountableFor` is allowed on: a caller can see the set, and nothing it does with
the answer can put a fan into it or take one out. They are how a test says which of D33's three
outcomes a handback actually reached — cleared, converted to the durable set, or still standing
— and asserting that from the refusal alone cannot distinguish the first from a fan that was
never recorded. `fansMidHandback` in particular exists so that `handbackUnconfirmed ⊆
releasing.keys` is a fact a test asserts rather than a sentence a doc comment states: an
invariant nothing can observe is one a refactor can break with the suite green.
`LeaseAuthorityAccessTests` records which members are allowed to be `internal` and why.

## Where each register ends

All three exits are in `restore(_:because:)`, which is the one place a restore is issued and
therefore the one place the handback window can be held open. `releasing` is incremented
before the suspension and decremented after it, so `acquireLease` can see the window from
inside the actor.

### An unconfirmed handback

The `defer` is the one place `handbackUnconfirmed` is cleared, and both halves of where it
sits are load-bearing. It is **inside the same loop as the decrement**, after it, so the
removal sees the decremented count and fires exactly when the fan's last outstanding restore
returns rather than while another is still in flight. It is **in a `defer`**, so it happens
whether the restorer reported an empty abandoned set or a full one — a fan the firmware
refused leaves this set and lands in `restoreAbandoned` through the union below, which is
D33's *"converts to the durable set through the path that already exists"*.

A restore that never returns never reaches either statement, so the fan stays unconfirmed for
the life of the process. That is the fail-safe direction and is deliberately not guarded
against.

### An abandoned handback

Below the await, and it is the **only** place `restoreAbandoned` is cleared
([#189](https://github.com/blamechris/Aeolus/issues/189)). The clear is conditioned on the
restorer's own report — the fans it was given minus the fans it named — and not on the call
having been made, which is the whole of the issue's hard half: a refusal set by three observed
firmware refusals must not be lifted by evidence about a call. See
[`restoreAbandoned`](#restoreabandoned--the-durable-half) for why that report is only the first
of the two signals it now needs (#291), and why § 3's registry is held to the same two since
#295.

**Clearing makes that mutation of the register non-additive, and the reentrancy that made
additivity load-bearing is still handled — by `releasing`, not by the ordering.** Two restores
of the same fan overlapping would let the later completion overwrite the earlier one's verdict
either way round; what matters is that no *grant* can happen in between, and none can, because
the fan's `releasing` count is still non-`nil` until the last of them returns. A fan cleared
early is therefore refused `.releaseInProgress` rather than granted, and a sibling restore
that comes back refused re-enters it through the union above before the count ever drops.

The intersection is what keeps the clear from being a blanket subtraction: it names only fans
the register actually held, so the log line reports a refusal being lifted rather than firing
on every ordinary teardown.

## The grant gate's ordering

`acquireLease`'s straight-line region — everything below the
`// ---- No await below this line ----` marker — holds four refusals, and they are **ordered
by how long they last, most durable first.** A client told a transient refusal retries; if it
retries into a durable one in the end, the first answer wasted the round trip and told it
something less true than what was available.

1. **`restoreAbandoned` → `.restoreToAutomaticFailed`.** The most durable of the four: a fan
   whose handback was given up on is not coming back on its own, so a client told any of the
   others retries — past the other client's release, past the handback window — into this
   refusal in the end.

   It is not the first refusal in the method, and that is not an inconsistency.
   `refuseIfThermalEmergencyActive` and `refuseIfBlind` run above the marker, both transient,
   because both need a suspension point and everything in the region is below every await by
   construction — the same *"a consequence rather than a choice"* `refuseIfBlind` documents
   about its own position relative to `validateFanIndices`.

2. **`handbackUnconfirmed` → `.handbackUnconfirmed`.** A fan whose handback is unconfirmed is
   also mid-`releasing` by that set's own invariant, so without this check the
   `.releaseInProgress` guard at the bottom would answer for it — *"retry in a moment"* about a
   restore that has already outlived a five-second budget, which is the one thing a client
   must not be told here. It is checked *before* the seal for the same reason the durable
   refusal above is: the seal lifts on the next `.didWake` and this does not, so a client told
   `.systemSleeping` retries after the wake and has to land on the answer that is actually
   about this fan rather than on a window that has already closed.

   Below the durable check, because the two cannot overlap by construction — a fan leaves this
   set in the same `defer` that would put it in `restoreAbandoned` — and because durable-first
   is the region's documented ordering whether or not any particular pair can co-occur.

3. **`sleepSeal` → `.systemSleeping`.** By the same durability ordering: the seal lifts on the
   next `.didWake`, where an abandoned handback never lifts. A client told `.systemSleeping`
   retries after the wake — and if this fan's handback was also abandoned, that retry has to
   land on the durable answer rather than being told to wait for a wake that has already
   happened.

   Above both lease-table refusals, though, and that is not a durability judgement: neither of
   those is worth telling a client about a machine that is going to stop running this process
   before it can act on the answer.

4. **`table.isEmpty` → `.leaseHeldByAnotherClient`, then `releasing` →
   `.releaseInProgress`.** The durable one of the pair is checked first, deliberately. Both can
   apply at once — a dying holder's fan is mid-handback while a second client legitimately
   holds another — and `.releaseInProgress` documents itself as *"retry in a moment"*. A client
   told that, when the real answer is *"somebody else holds the fans and will for as long as
   they live"*, retries into a different refusal forever.

## One restore call per sweep

Every teardown path removes its entries **synchronously**, then hands the whole sweep back in
**one** `restore` call — never one entry at a time
([#188](https://github.com/blamechris/Aeolus/issues/188)).

`restore(_:because:)` registers every fan it is given in `releasing` *before* it awaits
anything, so one call puts the entire sweep inside the handback window. A loop puts entry 1
inside it and leaves entries 2..n outside for the whole duration of entry 1's restore, which
is the window `.releaseInProgress` exists to close, reopened for every entry but the first. It
is also the shape `BoundedFanRestorer`'s per-fan attempt budget is already built for.

Removing entries before the restore is awaited is what makes a call interleaving during the
restore find an empty table, so it cannot restore the same fans twice.

**That is the whole of what it buys, and the empty table cuts both ways.** An emptied table is
exactly what makes `acquireLease`'s liveness check pass, so a new lease **can** be granted
over a fan whose restore is still parked inside `FanRestoring`. Demonstrated against this
code, not theorised. #163 built the restorer an earlier version of this warning said did not
exist — `HelperFanRestorer`, constructed by `HelperComposition` over the daemon's own plane —
so the remaining reason it is harmless is narrower and worth stating exactly:
`SMCFanControlPlane` still answers `.notBuilt`, so its restore verb throws before touching the
firmware and no lease can be granted to race in the first place. The window is real code now
and is held shut by the capability gate alone. Once
[#102](https://github.com/blamechris/Aeolus/issues/102) wires the control plane, the losing
order is: A's connection dies, A's restore is enqueued, B acquires and writes a target, A's
restore lands and returns the fan to automatic. B then holds a live lease over a fan nothing
is honouring, which is `CLAUDE.md` rule 6 arriving through a door that comment used to claim
was shut. **#102 owns the interlock**, and the reclamation watchdog is a backstop for it
rather than a substitute.

**Four of the five sweeps cannot reach #188's hazard today** — `guard table.isEmpty` holds the
table to a single entry — and that is an invariant enforced somewhere else entirely, by a guard
whose subject is concurrent-lease refusal rather than handback safety, so nothing links the
two. The panic path reaches it through a second *source* of fans rather than a second entry.
All five sweeps are written the one way so the reachable one is not a special case whose
reason nobody can see, and `TeardownSweepTripwireTests` is what makes a return to the
per-entry shape fail.

**The log line stays per entry on the revocation paths, and only the restore is unified.** A
revocation is a claim being taken from a named client, so `log show` has to carry one line per
client — that is `revokeLeases`' own argument for owning a distinct `FanRestoreCause`, and a
single line naming a union of fans would undo it. The two loops were one until #188; what was
shared between them was never the logging.

## The panic sweep has two sources

`releaseEveryLease()` sweeps the table **and** `restoreAbandoned`
([#189](https://github.com/blamechris/Aeolus/issues/189)), and the reason is not a widening of
scope for its own sake: an abandoned fan was **unreachable by every restore the lease core
issues.** Every other teardown path derives its fans from table entries, an entry exists only
because `acquireLease` granted one, and `acquireLease` refuses every fan in
`restoreAbandoned` — so the register sealed off the only route to its own exit, and a fan that
entered it could never be handed back again by this process. #189 named that method as the
first path that would need the clearing rule and described it as already restoring every fan
on the machine; it did not.

It is that verb rather than another because that verb is the recovery one. § 7 is what a user
reaches for when the fans are stuck, [docs/RECOVERY.md](../RECOVERY.md) is the step after it,
and a fan Aeolus itself put into manual and could not take back is the case most in need of
it.

**It touches nothing foreign, so [ADR
0011](../ADR/0011-reconciliation-and-foreign-manual-control.md) is intact.**
`restoreAbandoned` is fans that were under an Aeolus lease and whose handback this process
observed the firmware refuse — `fansAeolusIsAccountableFor` counts them as Aeolus's for
exactly that reason. A fan another tool pinned, and one § 6's reconciliation recorded in its
own `handbackRefused` set, are still outside what it touches;
[docs/SAFETY.md](../SAFETY.md) § 7 itemises what remains.

**One `restore` call for the whole sweep, and here it is load-bearing rather than uniform.**
The sweep has two sources, so the per-source shape would put one of them outside `releasing`
while the other's restore was on the wire — and in the order that reads most naturally, the
abandoned fans first, a fan whose lease the method has just dropped becomes grantable while
its own handback is in flight. That is #188's hazard reached without concurrent leases, which
its acceptance criteria assumed was the only way to reach it.
`AbandonedHandbackRecoveryTests.everyFanInThePanicSweepIsInsideTheHandbackWindow` is the
behavioural test of it.

### Why `revokeEveryLease` is not given the same sweep

§ 3's revocation **is lease-scoped and stays lease-scoped**. § 3 is a mechanism *taking* fans
in order to cool the machine, not a recovery verb: a fan whose handback was abandoned is one §
3's own registry deliberately keeps — `HelperFanRestorer` drops only the fans the firmware
took — so the emergency can bridge it to maximum RPM. Sweeping it there would have § 3 hand
back, on the way into an emergency, the one fan it may need to command hardest.
`PanicPathScopeTripwireTests` holds the two verbs apart.

## Pairing a sleep with its own wake

`docs/SAFETY.md` § 4's seal is set on `.willSleep` and cleared on `.didWake`, and until #202
those two calls were assumed to arrive in that order. They need not.
`SystemPowerObserver.deliver(_:acknowledging:)` hands each event to an unstructured `Task`, so
IOKit's serial queue orders the **spawns** and nothing orders the bodies. A `.willSleep` body
starved past the kernel's ~30 s acknowledgement window means the machine sleeps and wakes
regardless, and on wake the `.didWake` body can reach the lease core first. The seal then
arrives after its own wake and, if set, refuses every lease on a machine that is awake in
front of its user until the next sleep and wake.

**The first fix counted, and it latched.** It banked a credit per early wake and spent one per
seal. Two things were wrong with it, and the second is the one that mattered:

1. Credits are **fungible**. They carry no episode, so counting bounds *how many* seals are
   declined without determining *which*. With two episodes in flight, episode 2's timely seal
   is as likely to be the declined one as episode 1's late seal — the exact failure the design
   was justified by rejecting ("a flag would let the first wake's credit cancel the second
   episode's seal").
2. A *declined* seal leaves `sleepSeal` false. So the next ordinary `.didWake` took the
   no-seal branch and banked a **fresh** credit: the count never returned to zero, and the
   table was never sealed again for the life of the process. One unpaired wake — a helper that
   restarted inside a sleep window hears exactly one — disabled § 4's seal permanently.

That is a fail-safe defect (over-refusal, self-clearing at the next sleep) replaced by a
fail-dangerous one (a lease granted, and its fan pinned, across every subsequent sleep, until
the process restarts). Recorded here rather than deleted, because "count the anomalies" is the
obvious fix and this is the evidence that it is not the right one.

**What replaced it stamps rather than counts.** The order is not missing — it is discarded.
`IOKitSystemPowerObserver` delivers on a serial queue by construction, so
`SystemPowerRegistration.received(messageType:)` knows the sequence at the moment it runs, and
a monotonic number minted there survives into the `Task` body. `sealForSleep(generation:)`
declines only when a **strictly later** wake has been seen; `unsealAfterWake(generation:)`
clears only a seal **older** than itself, so a stale wake cannot reopen a table a newer sleep
has closed. Nothing accumulates and nothing is spent, so there is no reachable state in which
the seal stops being set and stays that way.

Stamping is deliberately much weaker than making the bodies run in order, which would reshape
the seam. It lets a *reader* of two events tell which came first, whatever order their bodies
ran in, which is all the seal needs.

**What it does not fix**, stated because the fix is easy to over-read: the starved `.willSleep`
body still runs `releaseEveryLease()` and the keystone after the wake, so a lease taken in
between is dropped and its fan handed back at a moment nothing asked for. The fan goes back to
**automatic** — the safe direction — and what the client is never told is that it lost the
lease, since there is no revocation callback. That is `CLAUDE.md` rule 6, bounded and honest
rather than thermal.

`SleepOrderingTests` pins all of it, including the sequence the counting version could not
survive: `.didWake`, `.willSleep`, `.didWake`, `.willSleep`, with the second ordinary sleep
required to seal.
