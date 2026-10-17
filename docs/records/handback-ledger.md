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

## Where the registers live: two value types the actor holds (#128)

[#128](https://github.com/blamechris/Aeolus/issues/128)'s lease-core pass moved the registers out
of the actor's own stored properties, before [#269](https://github.com/blamechris/Aeolus/issues/269)
would have taken its body past the 320 code lines that change was gated on. `releasing`,
`restoreAbandoned`, `handbackAcceptedUnconfirmed` and `handbackUnconfirmed` are the private stores
of `LeaseAuthority.HandbackRegisters` (`LeaseAuthorityHandbackRegisters.swift`), and `sleepSeal`,
`latestWakeGeneration` and `sealGeneration` those of `LeaseAuthority.SleepSealPairing`
(`LeaseAuthoritySleepSealPairing.swift`). The actor holds one of each, as `private var registers`
and `private var sleep`, and an instance anywhere else governs nothing. It is § 5's
`ReclamationWatchdog.Registry` move ([reclamation-watchdog.md](reclamation-watchdog.md)), applied
to the lease core, and like that one it widens nothing.

**Every synchronous decision moved with its store; every `await`, every re-read after one and
every act stayed in the actor, in the order it had.** The acts are the log lines, the restore, and
resuming a `.gone` revocation's waiter. One statement for one transition:

| Before, in `LeaseAuthority` | Since #128's lease-core pass |
|---|---|
| `restore(_:because:)`'s `releasing[fan, default: 0] += 1` | `registers.beginHandback(ofFan:)`, per fan, in the same loop before the restorer's `await` |
| its `defer`: the decrement, and at zero `releasing[fan] = nil` and `handbackUnconfirmed.remove(fan)` | `registers.endHandback(ofFan:)`, per fan; when it answers `true` the actor resumes that fan's waiters, in the same iteration as before |
| its union into `restoreAbandoned`, the two `handbackAcceptedUnconfirmed` updates and the `accepted` intersection | `registers.recordRestore(of:abandoned:)`, after the `await`; it returns `accepted` for the actor to log |
| `recordUnconfirmedHandbacks()`'s body | `registers.recordUnconfirmedHandbacks()` |
| `confirmAcceptedHandbacks()`'s re-read and its two subtractions | `registers.liftRefusals(readingAutomatic:)`, after the `await`, after the still-unconfirmed log line |
| the three per-fan filters in `acquireLease` | `abandoned(among:)`, `unconfirmed(among:)` and `midHandback(among:)`, below the marker |
| `outwaitHandback(of:)`'s `releasing[fan] != nil` | `registers.isMidHandback(_:)`, still inside the continuation's synchronous body |
| `sealForSleep(generation:)`'s body | `sleep.seal(generation:)`, which answers `.declined`, `.metStanding` or `.sealed` for the actor to log |
| `unsealAfterWake(generation:)`'s body | `sleep.wake(generation:)`, which answers whether the seal cleared |
| `acquireLease`'s `!sleepSeal` | `!sleep.isSealed` |

`handbackWaiters` stays on the actor. A continuation is not a value, and the check-and-park is
atomic only because it runs in `withCheckedContinuation`'s synchronous body on the actor; resuming
from the `defer` keeps the resumption in the same synchronous region as the drain.

Three rules make the move safe, and `LeaseAuthorityRegistersAccessTests` holds each, since the
compiler holds only part of the first. **No `async` member**: a mutating `async` call on an actor's
stored struct is refused, a non-mutating one is not and would answer from a stale copy. **No
function-typed parameter**: a closure that reaches the actor's property while a transition is
mutating it traps at run time. **No whole-value use on the actor's side**: a copy taken before an
`await` and written back after it loses every transition in between. The same suite holds the
stores `private` and exactly listed, every internal property a view, and no alias or dotted
extension reaching either type; `LeaseAuthorityRegistersTests` asserts each decision as a value.

Measured under SwiftLint 0.65.1: the actor's body went from 308 code lines to 287, and
`LeaseAuthority.swift` from 956 lines to 851.

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
one that restores. It is written this way because the overlap becomes reachable the moment
either of those two facts changes — E5.3's control plane issuing a restore outside lease
teardown, or the table holding more than one lease — and both are cheaper to be already correct
for than to retrofit.

**Which form is watched.** Since #128's lease-core pass the count is a value's, and the value is
watched: `releasing[fan] = 1` in place of `+= 1` in `HandbackRegisters.beginHandback(ofFan:)`
fails `LeaseAuthorityRegistersTests.aFanLeavesOnlyWithItsLastRestore`. The **wiring** is not:
`restore(_:because:)` counting a fan only when it is not already mid-handback — `for fan in fans
where !registers.isMidHandback(fan)` — is set membership spelled at the call site, and passes the
whole suite, because no reachable sequence restores one fan twice at once. Recorded rather than
implied, so nobody simplifies the call site believing a test is watching it.

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
Since #104 § 7 issues its own machine-wide keystone on a plane that can write, and issues it
*before* this read, so the read still holds no restore behind it (ADR 0014 D5). Since #350 it
runs inside § 7's grant seal, so while it is out every grant is refused; that queues nothing, and
is the safe direction ([The machine-wide restore seal](#the-machine-wide-restore-seal)).
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

> **Corrected 2026-10-09 ([#208](https://github.com/blamechris/Aeolus/issues/208)).** "Reads `1`"
> above means reads non-zero. The `1` recorded in `docs/SMC-RESEARCH.md` is the decoded fold, and no
> raw `F<n>Md` byte other than `0x00` has been recorded on this machine. The argument does not
> depend on the value, only on the register naming no owner.

**`handbackUnconfirmed` is deliberately not a fourth union.** It is a subset of
`releasing.keys` by its own invariant, so every fan in it is already accounted for by the third
register. Adding it would change no answer and would suggest the two can disagree.

**Nor is § 3's kept set, for the opposite reason**
([#303](https://github.com/blamechris/Aeolus/issues/303)). A fan Aeolus issued a restore for
that no read has confirmed automatic — § 3's `handbackOwed` after a lease handback the firmware
*accepted*, or `restoredUnconfirmed` after § 3's own restore, whatever the firmware did with it
([#308](https://github.com/blamechris/Aeolus/issues/308)) — is in none of the three registers:
its `releasing` count, if it ever had one, returned to `nil` when the write came back. It reads manual, it is Aeolus's
own doing, and until #303 both paths called it foreign. The tempting fix is to union it in here,
and that fix grants the lease. The union is an **exemption**: the gate subtracts it before the
foreign-control read, the snapshot returns a fan in it untouched, and the three registers the
exemption normally defers to have nothing to say about this fan. So the fan would be shown
`.available` and granted — over a fan nothing has confirmed is automatic.

It is carried beside the union instead, as `LeaseAccountability.restoresAwaitingConfirmation`,
and it only **reclassifies** the foreign-control answer: a fan in it that reads manual is
`.restoreToAutomaticUnconfirmed`, and one that reads automatic is granted. It is § 3's state,
read from § 3 through `EmergencyRestoreConfirming` rather than mirrored into this actor — a
mirror would be one fact kept in two actors, where a missed clear leaves a fan unleasable
until restart. ADR 0011, amendment 2026-09-21 (#303).

**One definition, read by the snapshot as well as by the gate**, through `activeLeaseView()`.
Two would disagree the moment either moved — and the way they disagreed before was the snapshot
naming a fan Aeolus could not hand back as another program's, while the gate refused it
correctly.

**The view carries both seals as well**: the machine-wide restore seal since #350, and § 4's sleep
seal since [#269](https://github.com/blamechris/Aeolus/issues/269), as
`LeaseAccountability.sleepSealed` — `SleepSealPairing.isSealed`, read in the same straight-line
region as the registers, where `acquireLease` asks it. Neither has a per-fan meaning of its own; each
is carried because while it stands the grant refuses every fan nothing ranked above it refuses, so
the ladder states it per fan at the grant's own place.

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
`fansARevocationAwaits` ([#368](https://github.com/blamechris/Aeolus/issues/368)) is a fourth on
the same trade: `handbackWaiters`' keys and none of its continuations.
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
`// ---- No await below this line ----` marker — holds six refusals, and they are **ordered
by how long they last, most durable first.** A client told a transient refusal retries; if it
retries into a durable one in the end, the first answer wasted the round trip and told it
something less true than what was available.

1. **`restoreAbandoned` → `.restoreToAutomaticFailed`.** The most durable of them: a fan
   whose handback was given up on is not coming back on its own, so a client told any of the
   others retries — past the other client's release, past the handback window — into this
   refusal in the end.

   It is not the first refusal in the method, and that is not an inconsistency. Four refusals
   run above the marker — `refuseIfThermalEmergencyActive`, `refuseIfBlind`,
   `refuseIfForeignManualControl(_:wanting:)` and, since
   [#270](https://github.com/blamechris/Aeolus/issues/270), `refuseIfBoundsImplausible(_:wanting:)`
   — because each needs a suspension point and everything in the region is below every await by
   construction: the same *"a consequence rather than a choice"* `refuseIfBlind` documents about
   its own position relative to `validateFanIndices`. The first two are transient; § 6's durable
   refusals and § 2's bounds are not, and they are above the marker anyway, for the same
   reason. Durability orders the region, not the method.

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
   they live"*, retries into a different refusal forever. The machine-wide restore seal, item 6,
   is checked before both.

5. **An exemption that lapsed → `.releaseInProgress`**
   ([#311](https://github.com/blamechris/Aeolus/issues/311)). The foreign-control step above
   the marker exempts every fan in `fansAeolusIsAccountableFor` and never reads it, on the
   argument that one of the four refusals here answers for it. It then suspends — on the
   reconciliation actor, and once per fan it does read — and the bounds read after it suspends
   once per fan it reads too ([#270](https://github.com/blamechris/Aeolus/issues/270)), so a
   handback can land anywhere in that window.
   The fan's `releasing` entry clears, item 4 no longer sees it, and until #311 nothing refused
   it however it read: a lease over a fan in manual that nothing had read since its restore.
   `refuseIfExemptionLapsed(_:exempted:)` refuses a requested fan that was exempted and is no
   longer in the set. Least durable of the six, so last: the retry reads the fan fresh.
   `GrantExemptionLapseTests` scripts the interleaving.

6. **The machine-wide restore seal → `.releaseInProgress`**
   ([#350](https://github.com/blamechris/Aeolus/issues/350),
   [#364](https://github.com/blamechris/Aeolus/issues/364)). Numbered last because it was added
   last; it is **checked between items 3 and 4**, after `sleepSeal` and before `table.isEmpty`.
   [The machine-wide restore seal](#the-machine-wide-restore-seal) is the mechanism: § 7's panic
   verb and, since #364, § 4's handback hold it.

   - **Before the lease table**, and that is not an exception to the durability order. No lease
     is added while the seal is open, so a lease the table shows then is one the sealed sweep —
     § 7's or § 4's — is about to drop: it outlasts the seal by nothing. One can be seen only
     between the seal opening and the sweep's `removeAll` — the verb's closure leaves the lease
     core in between —
     and a grant there was told `.leaseHeldByAnotherClient`, which stops being true within
     moments, while the snapshot said `.releaseInProgress`. The review of
     [#363](https://github.com/blamechris/Aeolus/pull/363) found that; the guard sat after the
     table, on the argument that a lease outlasts the seal, which it cannot here.
     `PanicGrantSealTests.aGrantBetweenTheSealAndTheSweepIsRefusedByTheSeal` holds the order.
   - **After `sleepSeal`**, which lifts on the next `.didWake` and so outlasts the panic verb,
     and § 4's teardown on the ordinary path. When the wake came first — a declined seal — or
     during the teardown, this seal alone answers for the teardown still running (#364).
   - **Before `releasing`**, and the two give the same reason, so the order changes only the log
     line: a fan the sealed sweep is handing back is refused under the line that names the
     machine-wide restore, which is the cause, rather than under the ordinary handback's.
   - **In the straight-line region, and nowhere above the marker.** A grant parked on a
     suspension point when the panic begins has already passed anything checked above it, so the
     only check that can meet it is one below the last `await` — #95's argument. A duplicate above
     the marker would be worse than none: a test could stay green on the early refusal while the
     real check was deleted. `PanicGrantSealTests.aGrantInFlightWhenThePanicBeginsIsRefused` is
     red with the guard moved above the foreign-control read, while the test of a grant that
     arrives during the panic stays green.

**The snapshot evaluates the same order**
([#269](https://github.com/blamechris/Aeolus/issues/269)). `ReadOnlyFanReport.firstRefusal` is one
first-match function, statement for statement against this region and the refusals above it:
steps 6, 5 and 8 for the build, the foreign-control read and the bounds read; then steps 1, 2, 11,
10 and 3 for items 1, 2, 3, 6 and the second half of 4, in the order they are checked here. Item
4's first half, `.leaseHeldByAnotherClient`, is the one it cannot state, since a snapshot has no
`ConnectionID`, and item 5 is a race inside one request that no snapshot meets. `refuseIfBlind`,
above the marker, is the one refusal the ladder states out of order — last, over a fan nothing else
refuses — for the reason `AvailabilityRestatement.swift` gives: `fanctl auto` reads it as silent.

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
per-entry shape fail. `revokeLease(id:forFan:because:)`
([#353](https://github.com/blamechris/Aeolus/issues/353)) is not a sweep — it names one entry —
and is written the same way: the entry removed synchronously, then one `restore` call, so it is
the seventh path ADR 0009's "every lease-core teardown removes its table entry before it awaits
the restore" counts.

**The log line stays per entry on the revocation paths, and only the restore is unified.** A
revocation is a claim being taken from a named client, so `log show` has to carry one line per
client — that is `revokeLeases`' own argument for owning a distinct `FanRestoreCause`, and a
single line naming a union of fans would undo it. The two loops were one until #188; what was
shared between them was never the logging.

### What the one call buys § 4

*Moved here from `LeaseAuthority.releaseEveryLease()`'s doc comment by
[#303](https://github.com/blamechris/Aeolus/issues/303), which needed the lines under
`file_length`; the declaration keeps a one-line summary and a pointer to this section.*

**In `releaseEveryLease()`, one `restore` call over the union is what makes § 4's record
complete rather than partial** ([#202](https://github.com/blamechris/Aeolus/issues/202) item 4).
`restore(_:because:)` increments `releasing` for every fan in the set *before* its suspension
point, so the whole union is mid-handback the instant the sweep awaits — and
`recordUnconfirmedHandbacks()`, which reads `releasing.keys`, therefore sees all of it even if
the first fan's write wedges and nothing after it ever lands. Restoring per-lease or per-fan in
a loop would put each subsequent fan's increment *after* the previous one's suspension, so a
wedge on the first would leave the rest neither restored nor recorded: § 4 would acknowledge
the sleep having registered one fan out of however many crossed it under manual control.

**The set is the sweep's, not the lease table's**, and the difference is #189's second source:
the union is seeded from `restoreAbandoned`, so a sleep with *no lease held* still restores —
and still records — any fan the firmware refused earlier. A review caught `LeaseAuthority.swift`
about to claim the set was lease-scoped, which is wrong in both directions.

`SleepOrderingTests.aWedgeOnOneFanStillRecordsTheWholeLease` is what pins it, on a two-fan
machine — the smallest that can tell "every fan" from "the first fan".
`SleepCycleSurvivalTests` was cited here and cannot: its lease covers one fan, so a per-fan
loop over a one-element set is behaviourally identical and stays green.

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

## The machine-wide restore seal

*Added by [#350](https://github.com/blamechris/Aeolus/issues/350); not relocated from a doc
comment. [ADR 0014](../ADR/0014-apple-silicon-unlock.md)'s 2026-10-15 amendment is the decision,
and its #364/#347 amendment extends it to § 4.*

`machineWideRestoresInFlight` counts the machine-wide restores inside
`LeaseAuthority.sealingGrants(during:)`: § 7's panic verbs and, since
[#364](https://github.com/blamechris/Aeolus/issues/364), § 4's handbacks. While it is not zero,
`acquireLease` refuses every grant `.releaseInProgress` under
`LeaseLog.refusedDuringMachineWideRestore`. It has two callers.
`SupervisedFanAuthority.restoreAllToAutomatic` runs all three of § 7's acts inside it: the sweep,
the `.built`-gated `.everyFan`, and the read-back. `SystemPowerResponder.allowSleepAfterHandback`
runs § 4's teardown inside it — the sweep and the keystone — on every `.willSleep`; § *"§ 4's
handback runs inside it (#364)"* below is the argument. Most of this section is § 7's, and holds
for § 4 unless that subsection says otherwise.

**The defect it closes.** The panic verb ran `releaseEveryLease()`, then `.everyFan`, then
`confirmAcceptedHandbacks()`, and nothing refused a grant in between. From the moment the sweep
emptied the table, a grant over a fan the sweep did not cover went through; while `.everyFan` was
awaited, any grant did. After A6 a lease granted and applied there is undone by the restore and
survives it, so § 5 reads `.modeReclaimed` under a live lease, and either re-asserts — level 3
undoing level 1 — or gives the fan up blaming the operating system. ADR 0014 D4's epoch covers
the forward writes of an engagement already under way; it does not cover a lease granted into a
restore that will undo it. Unreachable on every build on `main`, where no lease is granted.

**It opens before the sweep empties the table**, which is § 4's rule for `sleepSeal`: no instant
at which the table is empty and the gate is open. Opened after the sweep, the sweep's own await —
its per-fan restores — would be a window for every fan the sweep does not cover.

**It closes after the read-back**, not after `.everyFan`, so the seal's extent is the verb rather
than one call in it. An edit that reorders the acts then cannot move one of them out from under
it without moving it out of the closure, which `PanicPathScopeTripwireTests` sees. The read-back
writes nothing, so holding grants across it costs one read's worth of `.releaseInProgress`. The
reply is sent after the seal closes, so a client polling after its own panic reply — `fanctl
auto`, `fanctl reset --all` — sees the seal only when another panic verb overlaps its own, or when
its 10 s `panicVerb` deadline expired before the reply arrived.

**Scoped, not a seal/unseal pair.** An explicit pair, like § 4's `sealForSleep`, is correct the
day it is written and leaks the first time an edit puts a `throw` between the two calls — and a
leaked seal refuses every grant for the life of the process under a reason that says
*milliseconds*. Here the decrement is a `defer` in the frame that increments, so the only way to
hold the seal open is a call that never returns. A hardware round trip that never returns ends
the helper ([ADR 0012](../ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)), and
until it does the failure is grants refused, the safe side.

**A count, not a flag.** Panic verbs are unsequenced — `HelperConnectionSession` dispatches the
message on arrival, from one connection or several — so two can overlap, and the first to
return must not reopen the gate under the second. Increment and decrement are paired in one
frame, so the count cannot underflow.

**What it does not change.** The keystone gains no input and waits on nothing: no restore reads
the seal, and no read is queued ahead of `.everyFan` (ADR 0007, 2026-09-20). The reply is v1's
*accepted*, and the refusal is a reason `acquireLease` already threw, so `AeolusXPCVersion` does
not move. § 4 keeps `sleepSeal`, § 6 its gate and second keystone, and reconciliation runs
before the listener resumes. That puts § 7, § 4 and bring-up behind an airtight interlock, and § 6
behind a narrower one: its gate refuses a grant on arrival but not in flight, with `apply` refused
by the same gate (docs/SAFETY.md § 1). § 4's was narrower too until #364 put its teardown inside
this seal: its `.everyFan` ran with the gate open whenever the episode's wake was answered before
that restore returned.

**What the snapshot says.** `activeLeaseView()` reads the count in the same hop as the registers,
as `LeaseAccountability.machineWideRestoreInFlight`, and the availability ladder's step 10 states
`.unavailable(.releaseInProgress)` for every fan no rung above it refuses. Since
[#269](https://github.com/blamechris/Aeolus/issues/269) the ladder is one first-match function in
the grant's order, so **step 10 sits where this guard sits**: below step 5, step 8, the abandoned
and unconfirmed registers and § 4's sleep seal, which the grant gives ahead of it, and above step
3. A fan another rung refuses keeps the answer that is still true once the panic returns. A rung
above them would replace `.foreignManualControl` with "retry in a moment" about a fan another
program holds, and would erase the `.supervisorBlind`
[#360](https://github.com/blamechris/Aeolus/issues/360) states for a fan whose mode did not read.

**Where the guard sits** is item 6 of [The grant gate's ordering](#the-grant-gates-ordering).

**What remains.**

- **The seal does not tie a § 5 registration to the lease that made it.** An `apply` whose lease
  ends between the driver's after-check and its § 5 registration leaves an entry that ADR 0009 D2
  judges under whichever lease covers the fan next. That is
  [#357](https://github.com/blamechris/Aeolus/issues/357)'s, and an A6 precondition.
- **§ 7's round trip on hardware is unmeasured** (row 18 of the hardware checklist; ADR 0014 D8).
  "Retry in a moment" rests on it, and a long one would make that sentence untrue.

**Tested by** `PanicGrantSealTests`: a grant during the machine-wide restore, a grant parked
above the marker when the panic begins, a grant between the seal opening and the sweep, a grant
over a fan the sweep does not cover, overlapping panics, and a refusal the seal must not
overwrite — each with the mutation it kills recorded on it. `PanicPathScopeTripwireTests` holds
the three acts inside the closure, and today it alone holds the read-back's place:
`ControlStateGatePlane` parks every mode read, so a grant asked while the read-back is parked
parks on its own foreign-control read too. A per-fan mode park could hold it behaviourally. The
same suite holds that each runtime machine-wide restore is issued after its interlock is called,
and § 7's and § 4's inside this seal.

### § 4's handback runs inside it (#364)

*[ADR 0014](../ADR/0014-apple-silicon-unlock.md)'s #364/#347 amendment is the decision.*

`SystemPowerResponder.allowSleepAfterHandback` runs `handBackEveryFan(reportingTo:)` —
`releaseEveryLease()`, then the `.everyFan` keystone — inside `sealingGrants(during:)` on every
`.willSleep`, whatever `sealForSleep(generation:)` decided and whatever the wake does.
`sealForSleep` still runs first and decides only the sleep seal. `.didWake` still writes nothing
and never touches the count. `handBackEveryFan` itself is unchanged, so the keystone is still
issued whatever the sweep did.

**Two seals, because they are two facts.** `sleepSeal` belongs to the episode — the machine is
going to sleep — set before the teardown and cleared by a wake newer than every sleep that met it
([Pairing a sleep with its own wake](#pairing-a-sleep-with-its-own-wake)). The count belongs to
the teardown: a restore that would undo a grant is in flight. They agree only when the teardown
starts after the seal and ends before the wake, and three routes break that:

- **A declined seal.** A strictly later wake has been seen, so `sealForSleep` declines, and the
  starved body's sweep and keystone run on an awake machine. The review of
  [#363](https://github.com/blamechris/Aeolus/pull/363) confirmed with a test that a grant during
  that `.everyFan` was granted and outlived it.
- **A keystone that outlives its wake.** With no lease, `.everyFan` is issued at once, the budget
  acknowledges, the machine sleeps and wakes, and `.didWake` lifts the seal with the keystone
  still pending.
- **A sweep that outlives its wake.** A lease's per-fan restore outlasts the budget. After the wake
  a grant over another fan went through, and § 4 issued `.everyFan` once the sweep returned.

After A6 each is #350's harm on § 4's path: § 5 reads `.modeReclaimed` under a live lease. All
three are unreachable on every build on `main`, where a `.notBuilt` plane grants no lease.

**Which reason a client gets.** `acquireLease`'s guard, its position and its reason do not move.
While `sleepSeal` stands the gate answers `.systemSleeping`, which it checks first. After a
declined seal, or after a wake the teardown outlived, the count alone answers `.releaseInProgress`.
A fan the sweep covered answers `.handbackUnconfirmed` once the budget has expired, which is
checked above both. Item 6 of [The grant gate's ordering](#the-grant-gates-ordering) is where the
guard sits.

**What the declined teardown is for.** The later wake proves the sleep is over, not what it left
behind. The starved body is still the only act in that episode that ends a lease which crossed the
sleep: ADR 0007's sleep ruling has the client re-acquire deliberately, and otherwise only the TTL
ends it, whose advance across a sleep is unmeasured
([#210](https://github.com/blamechris/Aeolus/issues/210)). It is also the episode's only
`.everyFan`, which returns the plane's engaged set and force-key flag to the state ADR 0014 D6's
post-wake re-acquire assumes, on firmware that may have reset `Ftst` during the sleep (U12,
reported only). So it keeps running, and the gate is shut while it does. Skipping it, or skipping
only its `.everyFan`, would trade a refusal for a lease nothing hands back, or for a plane that
disagrees with the firmware.

**What it does not change.** The keystone gains no input and waits on nothing new: the count is
raised on the lease actor before the sweep, no restore reads it, and no read is queued ahead of
`.everyFan` (ADR 0007, 2026-09-20). `.everyFan` is not made conditional on the episode's seal still
standing, which would make the keystone depend on lease-core state. Seal, release, keystone and
acknowledge keep their order, and the budget its bound. On the handed-back path the count closes
before the acknowledgement; behind a budget acknowledgement it stays open until the teardown
returns.

**What it costs.** A teardown that never returns holds the count, so every grant is refused after
the wake as well as before it — `.systemSleeping` while the sleep seal stands, which the gate checks
first, then `.releaseInProgress` once the wake lifts it — until the teardown returns or
[ADR 0012](../ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md) ends the helper. That
is § 7's cost on the same terms, and the safe side: a lease granted there is one the pending
`.everyFan` undoes when the wedge clears.

**After a wake the teardown outlived, "retry in a moment" is wrong by construction**, not merely
possibly. The machine slept only once the sleep was acknowledged, and with the teardown still
running that acknowledgement came from the five-second budget or the kernel's own timeout, so the
restore has already outlived the budget. A fan the sweep covered is told `.handbackUnconfirmed`,
which says so. A fan only the keystone covers cannot be — that would give D33's register a second
producer, which #202 item 2 refused — so `.releaseInProgress`'s recovery advice carries the
escalation instead: if it does not clear within a few seconds, a restore has not returned, and
`docs/RECOVERY.md` sends the user to step 5.

**What the snapshot says.** Step 10 states `.releaseInProgress` while the count is above zero.
After a declined seal, and after a wake the teardown outlived, the snapshot and the grant both say
`.releaseInProgress`. During a sealed teardown before the wake both say `.systemSleeping`, since
[#269](https://github.com/blamechris/Aeolus/issues/269) gave the sleep seal its rung, step 11, in
the grant's order: below step 8, and so below step 5, because `acquireLease` checks the sleep seal
after its fresh read, which step 5 mirrors, and after its bounds read since #270, which step 8
mirrors; and above step 10 and step 3, because it checks the sleep seal before this seal and
before `releasing`. Until #269 the snapshot said `.releaseInProgress` there, and `.available` once
the teardown had returned and the seal still stood. A fan the sweep covered reads
`.handbackUnconfirmed` once the budget has expired, above both seals, as the grant refuses it.

**Why two tests were inverted.** `UnconfirmedHandbackTests.aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed`
and `SleepCycleSurvivalTests.aHandbackThatNeverReturnsIsStillRefusedAfterASecondWake` granted fan 1
after the wake, with the sweep parked and the keystone still to come, and asserted it as correct;
the second's own probe recorded cycle 1's keystone arriving after that grant. Both now assert fan 1
refused `.releaseInProgress` and grant it once the teardown returns. The separator they used it for
is now a reason: `.releaseInProgress` tells the running teardown apart from fan 0's
`.handbackUnconfirmed` and from a stuck seal's `.systemSleeping`.

**Airtight, and narrower.** § 7's, § 4's and bring-up's machine-wide restores now run behind
airtight grant interlocks. § 6's is narrower, and harmless: its gate refuses a grant on arrival
rather than in flight, and `apply` is refused by the same gate, so a grant that lands never engages
and its keystone has nothing to undo. An `apply` already in flight when the gate closes was another
matter, and not harmless on a plane that can write (ADR 0014's A6 PR-3 amendment); it is closed by
the [#410](https://github.com/blamechris/Aeolus/issues/410) amendment. The engagement's ticket,
taken before its entitlement, refuses its first step once the teardown's restores are requested,
and the exit's `.forExit` seals the plane against every later step and target command.

**Tested by** `SleepGrantSealTests`: a grant during a declined seal's teardown, with the keystone
or the sweep parked; a keystone parked across its wake; and a sweep parked across its wake — each
with the mutations it kills recorded on it. `PanicPathScopeTripwireTests` holds every call of
`handBackEveryFan(` inside the one `sealingGrants` closure in `allowSleepAfterHandback`.
`SleepCycleAccumulationTests`' fan-1 `.systemSleeping` expectation inside a parked, sealed window
now also holds the sleep seal's guard above the count's.

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

**A sleep that meets the seal still records its generation**
([#347](https://github.com/blamechris/Aeolus/issues/347)). Until #347 `sealForSleep(generation:)`
returned at `guard !sleepSeal` without writing `sealGeneration`, so a `.willSleep` that found
episode 1's seal still standing left the generation at episode 1's. Episode 1's starved
`.didWake` — newer than that seal, older than the sleep that met it — then cleared the seal while
the newer episode's machine was going to sleep. Every `.willSleep` that is not declined now sets
`sealGeneration` to the larger of its own generation and the one standing, whether or not it sets
the seal. **The larger, not its own:** a starved older `.willSleep` that runs after a newer one
sealed, before any wake has been seen, is not declined, and assigning its generation would lower
the seal below a stale wake. It still cannot latch, for the reason above: nothing is counted or
spent. A sleep that sets the seal from open is newer than every wake seen, and so newer than the
generation standing, which makes the larger its own; the wake that follows the newest sleep is
newer than every sleep that met the seal. `SleepOrderingTests` holds both sequences. The second is
green on the code before #347 and red under plain assignment: it pins the form of the fix.

**What it does not fix**, stated because the fix is easy to over-read: the starved `.willSleep`
body still runs `releaseEveryLease()` and the keystone after the wake, so a lease taken in
between is dropped and its fan handed back at a moment nothing asked for. The fan goes back to
**automatic** — the safe direction — and what the client is never told is that it lost the
lease, since there is no revocation callback. That is `CLAUDE.md` rule 6, bounded and honest
rather than thermal. Since [#364](https://github.com/blamechris/Aeolus/issues/364) no lease can be
taken *during* the starved teardown: it runs inside the machine-wide restore seal, so a grant while
it runs is refused `.releaseInProgress` rather than granted and undone by its `.everyFan`. A lease
taken before the teardown enters that seal is still dropped by it, and not only after a declined
seal: a sealed episode whose body is starved between `sealForSleep` and the `sealingGrants` hop,
until the budget has acknowledged and the wake has lifted the sleep seal, drops a lease granted in
that gap the same way.

`SleepOrderingTests` pins all of it, including the sequence the counting version could not
survive: `.didWake`, `.willSleep`, `.didWake`, `.willSleep`, with the second ordinary sleep
required to seal.

## Prose relocated from `LeaseAuthority.swift` by #128's second pass

Everything above argues the three registers. [#271](https://github.com/blamechris/Aeolus/issues/271)
and [#273](https://github.com/blamechris/Aeolus/pull/273) relocated that argument, and the file
has since grown back to 999 lines: one under the 1000-line `file_length` **error**, with 270
lines of code, 670 of comment and 59 blank. ADR 0014's slices A4 and A6
([#9](https://github.com/blamechris/Aeolus/issues/9)) both edit this file, so a file one line
from a failing CI had no room for either.

The three escapes are the same and are still refused. The one that was tried again is the split:
a throwaway extension in another file that moved `sealForSleep(generation:)` and
`expireLapsedLeases()` verbatim failed to compile with `'sleepSeal' is inaccessible due to
'private' protection level`, and the same for `latestWakeGeneration`, `sealGeneration`,
`table`, `clock` and `restore`. Every code member left reads or writes at least one of the
registers `LeaseAuthorityAccessTests` holds `private`, so moving any of it means widening that
state to the whole module, and D36 forbids it.

What was done is what the first section above records, applied a second time: the rationale
that had outgrown a doc comment moved here, and each declaration kept a summary and a pointer
to the section by its heading. No reasoning was deleted or reworded, and no line of code
changed — the diff of `Sources/` for that change is comment lines only. Each section below is
the text of a doc comment, unchanged apart from the two edits any relocation needs: a `##`
heading inside it is pushed down two levels, and a link is re-pointed at the same target from
this directory. Each names the declaration it came from. These sections are not about the
three registers, which is why they sit apart from the ones above.

The same change re-attached a doc paragraph that had come loose from `latestWakeGeneration`
(a `///` block followed by a blank line and then by the doc comment of `sealGeneration`, so it
was attached to neither); it is unchanged and sits under that declaration again.

### The limit prose cannot relieve: the type body

`type_body_length` counts **code** lines only. At the time of the relocation this actor's body
spans 265 of them against a warning at 250 and an **error at 350**: about 85 lines of headroom,
and relocating prose cannot make more. [#350](https://github.com/blamechris/Aeolus/issues/350)'s
grant seal took it to 278, leaving 72, and the file to 885 lines of its 1000.
[#357](https://github.com/blamechris/Aeolus/issues/357)'s identity query and
`revokeLease` took it to 290, leaving 60, and the file to 912.
[#368](https://github.com/blamechris/Aeolus/issues/368)'s outwait took it to 304, leaving 46, and
the file to 948. [#270](https://github.com/blamechris/Aeolus/issues/270)'s bounds gate took it to
308, leaving 42, and the file to 956; the refusal itself and its prose went to
`LeaseAuthorityRefusals.swift`. `file_length` has not gone away either. At this file's present
density, about 3.1 lines per code line, it would error after roughly 14 new code lines, so which
of the two limits is reached first depends on how much comment the new code carries.

#128's lease-core pass relieved both without relocating anything: the registers and § 4's seal,
with every decision made over them, moved into the two value types
[above](#where-the-registers-live-two-value-types-the-actor-holds-128), which the actor holds
`private`. That took the body to 287, leaving 63, and the file to 851.
[#269](https://github.com/blamechris/Aeolus/issues/269)'s one line, the sleep seal carried in
`activeLeaseView()`, took it to 288, leaving 62, and the file to 853.

New behaviour for #9's A4 and A6 belongs in the `EngagementDriver` that
[ADR 0014](../ADR/0014-apple-silicon-unlock.md) specifies, and in value types beside
`LeaseTable` and `ConnectionTombstones` — which hold the table and the tombstones as values, so
that no reference escapes and the actor decides in one straight-line region — and not in this
actor's body, which should keep only what has to touch the registers. The same limit and the
same advice are recorded for `ReclamationWatchdog` in
[reclamation-watchdog.md](reclamation-watchdog.md).

### Where this sits: the third role, and the swap from #134

*From the documentation of the type.*

The third arrived with #124 and was, when it arrived, the only one that read. It is no
longer the only one: `foreignControl` reads each requested fan's mode afresh, and since
[#270](https://github.com/blamechris/Aeolus/issues/270) `envelopes` reads its bounds, and the
type asks six things of the machine in all. It is worth stating plainly
here, because `acquireLease`'s `// ---- No await below this line ----` marker can only be
reasoned about correctly by somebody who knows how many suspension points that method
has: an earlier version of this paragraph said the type "cannot enumerate a fan, read a
sensor, or write a value" and named only two dependencies, which would have hidden the
slowest of the three from exactly that analysis. `LeaseBindingRaceTests` now holds the
marker to its word in source, so a suspension added below it fails a test.

It was `CriticalTemperatureSensing` until #134, and the swap is not a rename. A read is
still what happens when there is no fresh evidence; what changed is that the grant path
asks *"can § 3 see"* rather than *"read the curated set now"*, and § 3's own cycle is the
authoritative answer to the first.
[ADR 0010](../ADR/0010-coalesced-supervisor-reads.md) records why, and
`SightednessProving` explains why handing this type the cycle's telemetry no longer
compiles.

### Where this sits: what the lease suite runs against

*From the documentation of the type.*

The split keeps this fully testable with no hardware. It no longer keeps it free of the
mock SMC: `LeaseFixture.authority` defaults `telemetry:` to a `CriticalTemperatureCache`
over a `CuratedCriticalTemperatures` over `ScriptedControlPlane`, so every lease test now
runs against the scripted firmware through the shipped cache.
That is deliberate — a hand-rolled telemetry double would answer "sighted" without the
curated key list or the plausibility gate ever running — and it means emptying
`CriticalSensorSet.mac16x5` turns the lease suite red, which is a coupling worth knowing
about before it surprises somebody.

### One lease at a time, and why the contract settles it

*From the documentation of the type.*

`FanAuthority.snapshot()` takes **no `ConnectionID`**, and `SystemSnapshot.activeLease`
is a single optional `Lease`. So the lease a snapshot reports is a global fact, identical
for every client, and there is exactly one slot for it. Two simultaneous leases — even
over disjoint fans — would be unreportable: one of them would be invisible to every
client including its own holder, and a client that cannot see who holds the fans cannot
tell "nothing is holding this" from "somebody else is". That is `CLAUDE.md` rule 6
arriving one step earlier than usual.

The wire shape is frozen at v1 and shipped, so the choice is between refusing the second
lease and misreporting it. This refuses it, with
`.manualControlUnavailable(reason: .leaseHeldByAnotherClient)`.

### `sleepSeal` — why the table is closed for a sleep

*From the doc comment of `sleepSeal`. Its closing paragraph, on hearing the two notifications out of order, stays in the source.*

§ 4 empties the table and hands every fan back in the window `.willSleep` opens, and
nothing in that sequence stops a *new* lease being taken while it runs. The hazard is
the one `acquireLease` already documents about its own straight-line region, arriving
from outside: a request parked on `refuseIfBlind`'s 34-key read resumes after § 4 has
emptied the table and restored, finds an empty table and no fan mid-handback, and
engages manual control as the machine stops running this process. The lease then
crosses the sleep with nothing having handed its fan back, which is the exact failure
§ 4 exists to prevent, reached through the one door it does not close.

**Set before the teardown and cleared on `.didWake`.** Clearing it is not a write —
§ 4's "after wake: nothing" is about the firmware, and this touches no fan — so the
wake branch stays the absence it is documented to be.

A helper that hears `.willSleep` and never hears the wake refuses every lease for the
life of the process. That is the fail-safe direction and is deliberately not guarded
against: refusing manual control is safe, and a lease taken on a machine this process
believes is asleep is not.

### The order of `acquireLease`'s steps

*From the doc comment of `acquireLease(_:from:)`, steps 0 to 3 of its numbered list. Step 4 and the paragraph on the absent earlier liveness check stay in the source.*

0. **The build's own write capability is refused before anything else**, because it
   is the only refusal here that is a fact about the *executable* rather than about
   the request or the machine. Nothing a client sends and nothing the SMC says can
   change it, so every other answer given ahead of it invites a retry that can never
   succeed — and one of those answers, `noThermalTelemetry`, can cost a real 34-key
   hardware read to produce. See `refuseIfWritePathNotBuilt`.
1. **Self-renewal is refused next**, before any work is done for a request that
   cannot be granted whatever the machine says.
2. The TTL is re-validated here although the listener already checked it. Sharing
   `AeolusXPCValidation` is not the same as the listener doing the checking
   (`CLAUDE.md` rule 7), and this method is reachable from the control plane as well
   as from a message.
3. The suspension points: enumerating the machine's fans, then sweeping anything
   already lapsed — so the single-lease check below is made against live leases only,
   and a previous lease's fans are back on automatic before new ones are taken — then
   refusing if § 3 is latched, then proving the helper can still see a temperature at
   all, then asking § 6's baseline whether anything outside Aeolus is holding a
   requested fan, and finally — since [#270](https://github.com/blamechris/Aeolus/issues/270)
   — reading both bounds of every requested fan that question did not exempt as Aeolus's
   own, and refusing `.boundsImplausible` for one `docs/SAFETY.md` § 2's gate rejects. The
   sweep runs **before** all of those deliberately: a lapsed lease's fans go back to
   automatic whether or not this machine is blind and whether or not it is too hot, and
   neither is a machine on which to skip a restore. The foreign-control question and the
   bounds read come last of the five things suspended on — the enumeration, § 3's latch, the
   telemetry read, it and the bounds read, four of which are refusals — because they are the
   only ones whose cost scales with the number of fans asked for. The bounds read is after the
   foreign-control question, so a fan whose mode will not read is told `.supervisorBlind`, as
   the snapshot's step 5 tells it, and so an accountable fan is answered by its register below
   the marker, never by its bounds. See `refuseIfForeignManualControl(_:wanting:)` and
   `refuseIfBoundsImplausible(_:wanting:)`.

### `expireLapsedLeases`: no instant, and no shared path

*From the doc comment of `expireLapsedLeases()`.*

**Takes no instant.** A caller cannot supply one, so no caller can supply a
wall-clock-derived one — ADR 0005's monotonic rule made inexpressible rather than
merely documented, which is the argument `AeolusXPCProtocol` makes for the messages
it does not have.

**Nothing on the connection-invalidation path calls this, and it calls nothing on
that path.** That is the independence ADR 0005 requires: *"Either mechanism alone
suffices; both must fail for the fans to stay pinned; they share no code path."* The
one thing the two paths do share is their terminal action, and that is deliberate —
ADR 0007's keystone is that restore-to-automatic is a single bounds-free verb every
safety mechanism ends in.

### The warning on `expireLapsedLeases`

*From the doc comment of `expireLapsedLeases()`. "The same section of that document" is "One restore call per sweep", above.*

- Warning: Removing before restoring is the whole of what that buys, and the empty
  table cuts both ways. An emptied table is exactly what makes `acquireLease`'s
  liveness check pass, so a new lease **can** be granted over a fan whose restore is
  still parked inside `FanRestoring`. Demonstrated against this code, not theorised.
  What holds it shut today is the capability gate alone — `SMCFanControlPlane` answers
  `.notBuilt`, so `HelperFanRestorer`'s restore verb throws before touching the
  firmware and no lease can be granted to race in the first place. **#102 owns the
  interlock** for when that stops being true, and the reclamation watchdog is a
  backstop for it rather than a substitute. The losing order, and why #163 narrowed
  this warning rather than closing it, are in the same section of that document.

### `revokeLeases` is a claim being taken, not a lease ending

*From the doc comment of `revokeLeases(coveringFan:because:)`.*

`docs/SAFETY.md` § 3's revocation, and the only teardown path here that is not a
lease *ending*: the TTL, connection death and a voluntary release are all a holder
running out of claim, while this is a claim being taken from a client that did
nothing wrong. That is why it carries its own `FanRestoreCause` rather than reusing
one — an operator reading `log show` must be able to tell "the client went away"
from "the machine got too hot", and a cause that cannot be named is a mechanism that
cannot be audited.

### `revokeLease(id:forFan:because:)`: the one lease § 5 held the fan for

*Added by [#353](https://github.com/blamechris/Aeolus/issues/353); not relocated from a doc
comment. ADR 0009's 2026-10-15 amendment is the decision.*

§ 5's terminal action used to call `revokeEveryLease(because:)`, for § 3's reason: a lease is a
claim over a set of fans. Once a lease can end and another be granted over the same fan inside
one § 5 cycle, "every lease" includes one granted after the episode § 5 is giving up, and a
release and re-grant during § 5's refused command write revoked the new client's lease and told
it the system had reclaimed a fan it never held. So § 5 now names the lease it was holding the
fan for — the one the fan was registered under — and this revokes that lease and no other.

- **Whole**, for the same reason `revokeLeases(coveringFan:because:)` is: trimming a fan out of
  a lease would leave a client holding a subset it can no longer command.
- **Revoked only while it is live.** An ID the table does not hold is a lease that already ended,
  and answers `.gone` and restores nothing. A lease past its deadline and not yet swept is ended
  inside the call and restored as `.leaseExpired` — it answers `.expired` — rather than left to
  the TTL sweep, whose release notice would otherwise arrive after § 5's terminal action returned
  and erase the mark it keeps (#361's panel). That covers a lease still in the table when the
  call arrives; one a sweep or teardown removed first answers `.gone`, and only once that path's
  handback of the fan has returned ([#368](https://github.com/blamechris/Aeolus/issues/368),
  below). Neither is logged as revoked, so `LeaseLog.revoked` — the `.fault` that tells a client
  the system took control — is emitted only for a lease actually taken.
- **Removed synchronously, restored in one call**, as every teardown here is, so the fans enter
  `releasing` before anything suspends and no grant can race in over them.
- **Strictly narrower than `revokeEveryLease(because:)`**, which is already `internal`, and that
  is the whole of `LeaseAuthorityAccessTests`' argument for acknowledging it: the worst a caller
  elsewhere in the module can do with a lease's ID is what it can already do to every lease.

§ 3 keeps `revokeEveryLease(because:)`: it takes back every claim on the machine in order to
cool it, which is not § 5's question.

### Outwaiting another path's handback

*Added by [#368](https://github.com/blamechris/Aeolus/issues/368); not relocated from a doc
comment. ADR 0014's #368 amendment is the decision.*

§ 5's terminal action keeps its reclamation mark by holding the fan in `finalising` until
`revokeLease(id:forFan:because:)` returns (#346, #361). A teardown that takes the lease out of
the table first — the TTL sweep, a connection dying, any of the seven paths — leaves the
revocation nothing to end, and until #368 it answered `.gone` at once, while that teardown's
release notice was still inside `HelperFanRestorer`. Arriving after `finalising` had closed, the
notice cleared the mark. So `.gone` now waits, once, for the fan the caller names to leave
`releasing`: `outwaitHandback(of:)` parks a continuation in `handbackWaiters`, in the
straight-line region that found the lease gone, and `restore(_:because:)`'s `defer` resumes it.

- **While the ending's handback is under way, the drain is that teardown's notice.** Three facts the
  ledger already rests on. Every lease-core teardown takes its entries out of the table and counts
  their fans into `releasing` with no suspension between (ADR 0009's assumption table).
  `TeardownCountTripwireTests` holds that over the whole interval: no `await` between the removal
  and the `restore(_:because:)` call, no argument to that call but values the function already
  holds, and no `await` in `restore`'s body before its counting loop. `HelperFanRestorer` awaits
  each § 5 notice before its write, and `releasing` drops only in the `defer`, after the restorer
  returns. And while `releasing[fan]` is held `acquireLease` refuses the fan — and a fan in
  `restoreAbandoned` before that, which a fan under a granted lease cannot be in — so no newer lease
  and no panic sweep of the register can begin a second handback of it until the first returns. When
  the count reaches zero, the notice has reached § 5 and found `finalising` holding the fan.
  `.revoked` and `.expired` need no wait: by the same facts their own restore is the fan's only
  handback.
- **Not always the ending's, though** ([#377](https://github.com/blamechris/Aeolus/issues/377),
  found by #375's review). § 5's hand-back is the driver's write, which `releasing` does not count,
  so the ending's handback can return during it and leave the fan to a later lease-core handback by
  the time the revocation arrives. Two routes, each with the whole hand-back as its window: a newer
  lease granted over the fan once the hand-back lands, and released; or the ending's restore refused
  for the fan, which puts it in `restoreAbandoned`, and a `releaseEveryLease()` — § 7's panic verb,
  § 4's sleep handback or SIGTERM's teardown — sweeping it before § 5 reaches the revocation. A
  revocation arriving while that later handback is in flight outwaits it instead, and `finalising`
  absorbs its notice. One more bounded wait, the whole sweep's on the second route, and a mark kept
  rather than lost. Keying the wait on the lease as well as the fan is the exact fix; #377 tracks
  both routes.
- **Once, not in a loop.** A handback begun after the drain is a newer lease's, and its notice
  must clear the mark: a fan a client took and released after § 5 gave it up is not a fan the
  system took. Re-checking — `while releasing[fan] != nil` — would absorb that notice too.
  **Nothing in the suite tells the two apart**: no test lands a grant in the one resumption
  between the drain and the waiter running, so replacing the single wait with that loop survives
  every test (M7 in [#375](https://github.com/blamechris/Aeolus/pull/375)'s mutation table). This
  paragraph is what stands against that edit.
- **Checked inside the continuation.** `releasing[fan]` is read — through
  `registers.isMidHandback(_:)` since #128's lease-core pass — in `withCheckedContinuation`'s
  synchronous body, which parks the waiter or resumes it at once, so no `await` can be written
  between the check and the park. One there would let the count drain unseen, orphan the waiter,
  and leave § 5 parked, watching nothing, for the life of the process (#375's review).
- **Resumed in the `defer`**, in the branch that sets `releasing[fan] = nil`, beside
  `handbackUnconfirmed`'s clear — the branch `registers.endHandback(ofFan:)` answers `true` from
  since #128's lease-core pass. Not in the body: it returns early through
  `guard !accepted.isEmpty else { return }` whenever no abandoned refusal is being lifted, which
  is the ordinary handback, so a resumption there is skipped and the revocation never returns.
- **Not cancellable**, because the restore it outwaits is not (#110). A revocation that gave up
  its wait on cancellation would answer before the notice it exists to wait for, so no
  cancellation handler is installed.
- **Bounded, and usually no longer than `.revoked`.** The wait is one restore call —
  `RestoreLimits.attemptBudget` attempts for each fan that call hands back, each bounded by
  `FanRestoreAttempting`'s contract (#168) and, failing that, by ADR 0012. For most teardowns those
  are the ended lease's fans, which is what `.revoked` has always cost § 5's cycle while it awaits
  its own restore. When the ending is `releaseEveryLease()` — § 7's panic verb, § 4's sleep handback
  or SIGTERM's teardown — the call also sweeps `restoreAbandoned`, so the wait spans every abandoned
  fan's attempt budget as well: longer than `.revoked`, and still bounded. A handback that never
  returns parks § 5 no longer than it would park `.revoked`. It cannot deadlock: § 5's actor can be
  re-entered while it is parked, so the teardown's notice still runs on it, and no teardown waits on
  § 5. No restore waits on anything. It waits on the named fan alone, so a client granting and
  releasing another fan cannot hold § 5 parked.
- **The waiters live with `releasing`.** `handbackWaiters` is resolved in the same synchronous
  region as the count it waits on, which is a constraint on #128's split of this actor: if the
  count moves into a value type, the waiters move with it and are handed back to the actor to
  resume, so the instant a fan's count reaches zero and the instant its waiters are released stay
  one instant.

**What remains.** Two notices can still be absorbed in the one continuation resumption between the
drain and § 5 resuming: the same two shapes as the routes above, begun after the drain rather than
before it. One is a newer lease's, granted over the fan and ended with no engagement between. The
other comes when the ended lease's restore was refused for the fan and a `releaseEveryLease()` from
§ 7, § 4 or SIGTERM starting in that window hands it back again. Here either needs a second
lease-core handback to begin inside the resumption and its notice to cross `HelperFanRestorer`
before § 5 resumes — a grant through five suspensions and then the lease's ending, or a sweep. The
guard had a window of the same shape before; it is neither widened nor removed, and either notice
absorbed keeps a mark rather than losing one. A notice that reaches § 5 before the terminal action
begins still clears the mark, by design: § 5 learns that a lease ended when its notice arrives, and
one that arrives first is a release that came first.

`fansARevocationAwaits` reads the waiters' keys and none of their continuations, under the
read-only rule above, so a test can wait for a parked revocation as a state rather than a yield
count. `LeaseRevocationOutwaitTests` holds the lease core's half, and
`TerminalActionTeardownRaceTests` lands each teardown between § 5's hand-back and its revocation
in a graph built from the real lease core, restorer and § 5; each names the mutations it kills.

### Why § 3 revokes every lease, and why it is not `releaseEveryLease()`

*From the doc comment of `revokeEveryLease(because:)`.*

`docs/SAFETY.md` § 3 selects on this rather than on the emergency's own registry of
engaged fans, and the difference is a defect an adversarial review found rather than
a preference. A client can hold a live lease **without having engaged manual control
yet** — acquisition and the first write are separate messages — and such a fan is
still on automatic, so it appears in no registry of engaged fans. An emergency that
revoked only what it had bridged would latch, take back nothing, and leave that
lease live; the client's next write would then engage a fan into an emergency that
has already fired.

It also closes a window the lease core cannot close from its own side. The latch is
a *different actor*, so `refuseIfThermalEmergencyActive` reads it across a hop and
then awaits `refuseIfBlind`'s sightedness proof before the straight-line region
begins — the emergency can engage during that hop, and the grant proceeds. #134
narrowed the window without closing it: the proof is usually served from § 3's own
last reading now rather than from a fresh 34-key read, so it is an actor hop rather
than a hardware round trip, and a hop is still a window. No
re-check below the marker can fix that, because the hop back is itself a window
([#95](https://github.com/blamechris/Aeolus/issues/95) is the same shape). What
closes it is the emergency taking back whatever it finds, every cycle it holds.

**"Every cycle" includes the cycles that can see nothing**, which is the half that
was not true when this paragraph was written. `ThermalEmergency.cycle()` used to
return on a failed read before reaching any revocation, so a lease granted in the
window survived for as long as the SMC stayed quiet — and `renewLease` consults
neither the latch nor telemetry, so its holder renewed indefinitely. See
`ThermalEmergency.cycleSawNothing(_:)`, which is where the claim above is now
honoured, and [#152](https://github.com/blamechris/Aeolus/issues/152) for the rest.
The releasing branch reaches no revocation either, and needs none: it is the branch
on which § 3 has stopped holding.

Deliberately **not** shared with `releaseEveryLease()`, which drops the same table
for § 7's panic verb. They are different actors — levels 1 and 2 — and
`LeaseTable`'s own selectors are written out for exactly this reason: a shared
predicate remover is the first step towards one mechanism wearing several names, and
an operator reading `log show` must be able to tell the panic path from § 3.
**It is lease-scoped and stays lease-scoped**, which is a decision worth writing down
now that `releaseEveryLease()` is not: § 3 is a mechanism *taking* fans in order to
cool the machine, not a recovery verb, and a fan whose handback was abandoned is one
it may need to command hardest. handback-ledger.md § *"Why `revokeEveryLease` is not
given the same sweep"*; `PanicPathScopeTripwireTests` holds the two verbs apart.

### `releaseEveryLease()`: what the sweep is, and what it is not

*From the doc comment of `releaseEveryLease()`, after the paragraphs that state its scope, which stay in the source. Its heading, "The sweep is the table and `restoreAbandoned`", stays in the source too and is the first thing this section answers.*

[#189](https://github.com/blamechris/Aeolus/issues/189) is why, and the reason is not a
widening of scope for its own sake: an abandoned fan was **unreachable by every restore
this actor issues**, because every other teardown path derives its fans from table
entries and `acquireLease` refuses every fan in `restoreAbandoned`. It is this verb
rather than another because this verb is the recovery one — § 7 is what a user reaches
for when the fans are stuck, and `docs/RECOVERY.md` is the step after it.
`revokeEveryLease(because:)` is deliberately not given the same sweep — see there.

**It touches nothing foreign, so ADR 0011 is intact**, and **one `restore` call for the
whole sweep is load-bearing here rather than uniform** — the sweep has two sources, so
a per-source shape would leave one of them outside `releasing` while the other's
restore was on the wire. Both, with the losing order spelled out:
handback-ledger.md § *"The panic sweep has two sources"*.

**It does not make the message fail**: `restore(_:because:)` cannot throw, and a firmware
that refuses again simply leaves the refusal standing. So a v1 message that succeeds keeps
succeeding, and the contract does not move. That was also the reason the *machine-wide*
restore was declined here (#159), and it is the reason the restore is not here now: since
#104 the handler issues it after this returns, only on a plane that can write, and catches
its refusal for the same end (ADR 0014 D5, `SupervisedFanAuthority.restoreAllToAutomatic`).
This sweep still issues one `restoreToAutomatic(.fan(index))` per fan, never `.everyFan`.

**Consults no per-`ConnectionID` state**, which is the precondition
`HelperConnectionSession` documents for exempting that message from its teardown
gate: `connection` is attribution only, so both post-invalidation orderings converge
on the same safe state. Making this consult per-connection state would invalidate the
exemption and needs revisiting alongside it —
[#95](https://github.com/blamechris/Aeolus/issues/95).
**One `restore` call over the union is what makes § 4's record complete rather than
partial** (#202 item 4): handback-ledger.md § *"What the one call buys § 4"*.

### `sealForSleep`: declining a seal its wake already answered

*From the doc comment of `sealForSleep(generation:)`.*

A seal whose own wake has already been answered is **not** set: see
`latestWakeGeneration` for the ordering that produces one, and for why declining is
the safe direction here even though sealing is the safe direction everywhere else.

Declining leaves any *newer* seal standing untouched, which is what makes overlapping
episodes safe: a late `.willSleep` from episode 1 cannot reopen the table that episode
2 has already closed.

A sleep that is not declined and finds the seal already standing still records its
generation, the larger of its own and the one there (#347): see
[Pairing a sleep with its own wake](#pairing-a-sleep-with-its-own-wake).

### `activeLeaseView()`: one hop, and three registers apart

*From the doc comment of `activeLeaseView()`. Its second paragraph, which points at "What the snapshot is told", stays in the source.*

One hop rather than two, because two would answer from two views of this actor: a lease
reported live beside an empty fan set, and therefore a fan under Aeolus's own lease
reported as foreign control. It is `fansAeolusIsAccountableFor` rather than the lease's
own fans, and **since [#187](https://github.com/blamechris/Aeolus/issues/187) it carries
the three registers apart** as well as their union — the union cannot answer *"why would
a grant over this fan be refused?"*, and a snapshot that had only it reported a
mid-handback fan and an abandoned one alike as available.

### `refuseIfThermalEmergencyActive`: a revoked holder is not silently re-granted

*From the doc comment of `refuseIfThermalEmergencyActive(_:)`.*

**A revoked holder is not silently re-granted.** The emergency revokes the whole
lease covering a fan it fired on, and the client's ordinary response to losing a
lease is to acquire another one — so without this, the mechanism would hand the fans
straight back to the workload that overheated the machine, on a cycle bounded only
by how fast the client retries. Resuming is a fresh `acquireLease`, and it is
refused until a fresh reading falls a hysteresis margin below the ceiling.

`.thermalEmergencyActive` already exists in `AeolusXPCFault` — E2 built the
vocabulary before the mechanism, so this consumes a fault case rather than adding
one, and `AeolusXPCVersion` does not move.

### Why the thermal refusal sits above the blindness check

*From the doc comment of `refuseIfThermalEmergencyActive(_:)`, under the heading "Why it sits above the blindness check", which stays in the source.*

Both are refusals and both are true when both apply, so the question is which fact
the client is told. This one, for two reasons. It is the more consequential — a
machine above its thermal ceiling is a worse thing to grant a lease on than a machine
whose sensors went quiet — and it is the only one of the two that costs no hardware
round trip, so a latched machine refuses without spending an SMC read it does not
need. The same reasoning `refuseIfBlind` gives for sitting above the concurrent-lease
refusal, one step further up.

### `fansAeolusIsAccountableFor`: why these three are exempt

*From the doc comment of `fansAeolusIsAccountableFor`. The "three registers" here are the lease `table`, `restoreAbandoned` and `releasing`; elsewhere in this document "the three registers" are `releasing`, `handbackUnconfirmed` and `restoreAbandoned`.*

Three registers, and each one has a **more precise** refusal further down the grant
path — which is the whole reason they are excluded rather than judged. `F<n>Md` reads
`1` for all three and names no owner, so without this a client would be told "another
program holds it" about a fan another *client* legitimately leases, one that is
mid-handback, and one Aeolus put into manual and could not take back.
`handbackUnconfirmed` is deliberately not a fourth union: it is a subset of
`releasing.keys` by its own invariant, so adding it would change no answer.

### `fansAeolusIsAccountableFor` is `internal`, and why that exposes nothing

*From the doc comment of `fansAeolusIsAccountableFor`.*

`internal` since #128 moved `refuseIfForeignManualControl(_:wanting:)` out. It is
**derived and read-only**, and `activeLeaseView()` — `internal`, and what the control
plane calls — already returns exactly this set, so the widening exposes nothing new.
The three registers it unions stay `private`: this is the union, not a way to reach
them.
