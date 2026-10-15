# The reclamation watchdog

The reasoning behind `ReclamationWatchdog` — [docs/SAFETY.md](../SAFETY.md) § 5's mechanism for
noticing that the system has taken back a fan Aeolus is holding — that was written as doc
comment in `Sources/AeolusHelper/Safety/ReclamationWatchdog.swift`, relocated here whole and
pointed at from the declarations it belongs to.

This is a **records** document, of the kind [the handback ledger](handback-ledger.md) is: it
is not a decision record — [ADR 0007](../ADR/0007-safety-composition.md),
[ADR 0009](../ADR/0009-precedence-at-the-write.md) and
[ADR 0010](../ADR/0010-coalesced-supervisor-reads.md) own the decisions — and it is not
normative. `docs/SAFETY.md` § 5 remains the contract; this explains the parts of the
mechanism a reader cannot get from the code alone. Each section below is the text of a doc
comment, unchanged apart from the two edits any relocation needs: a `##` heading inside it is
pushed down one level, and a link is re-pointed at the same target from this directory. Each
section names the declaration it came from, and that declaration keeps a summary and cites the
section by its heading.

## Why it is a document rather than a doc comment

`ReclamationWatchdog.swift` stood at 992 lines against SwiftLint's 1000-line `file_length`
**error**. Of those, 287 were code, 639 were comment and 66 were blank. The rule counts
comment lines, so what stood between the file and a failing CI was prose rather than logic —
the measurement [#242](https://github.com/blamechris/Aeolus/issues/242) made about
`HelperClient.swift`, and [the handback ledger](handback-ledger.md) records for
`LeaseAuthority.swift`.

ADR 0014's slices A4 and A6 ([#9](https://github.com/blamechris/Aeolus/issues/9)) both edit
this file, so the headroom was needed before either could land.

Three escapes were available and all three were refused.

- **`swiftlint:disable file_length`**, or a per-file override in `.swiftlint.yml`.
  [#268](https://github.com/blamechris/Aeolus/pull/268) was offered exactly that for
  `HelperClient.swift` and declined it, and
  [the handback ledger](handback-ledger.md#why-it-is-a-document-rather-than-a-doc-comment)
  records the argument: suppressing the rule would retire it for the whole tree.
- **A split into another file.** Swift `private` is file-scoped, so an extension in a sibling
  file cannot see a `private` member. Every seam available without widening state was already
  taken ([#128](https://github.com/blamechris/Aeolus/issues/128)): `ReclamationLimits.swift`,
  `ReclamationSignals.swift` and `ReclamationHeldFan.swift`, listed in
  [The splits already taken](#the-splits-already-taken). Everything left reads or writes
  `held`, `log`, `ledger`, `writer`, `sensing`, `leases` or `latch`. A throwaway extension in
  another file that moved `reportShortfall(_:fanAt:)` verbatim failed to compile with `'held'
  is inaccessible due to 'private' protection level`, and the same for `log`. D36 is that
  stored state stays `private`, and `held` is exactly what makes `examine(fanAt:)`'s
  read-then-mutate reasoning checkable.
- **Shaving the overage.** `main` sat eight lines under a hard CI error, so a fix that landed
  just under it would fail the next unrelated PR to touch the file.

What was done instead is what [#271](https://github.com/blamechris/Aeolus/issues/271) and
[#273](https://github.com/blamechris/Aeolus/pull/273) did for `LeaseAuthority.swift`: the
rationale that had outgrown a doc comment moved into a document, and each declaration kept a
summary and a pointer to the section here. No reasoning was deleted or reworded, and no line
of code changed — the diff of `Sources/` for that change is comment lines only.

## The limit prose cannot relieve: the type body

`type_body_length` counts **code** lines only. At the time of the relocation this actor's body
spans 284 of them against a warning at 250 and an **error at 350**: about 66 lines of headroom,
and relocating prose cannot make more. [#181](https://github.com/blamechris/Aeolus/issues/181)
spent ten of them routing the re-assert and every hand-back through ADR 0014's
`EngagementDriver`, which holds the rest of that behaviour: 294, and about 56 left.
[#346](https://github.com/blamechris/Aeolus/issues/346)'s guard on the terminal action's ledger
entry spent four more: 298, and about 52 left. `file_length` has not gone away either, and since
#346 it binds first: the file is 895 lines over 301 code lines, about 3.0 lines per code line,
so at that density it errors after roughly 35 new code lines, well before the body's 52. The
body's limit is reached first only by new code written at under about two lines per code line.

[#353](https://github.com/blamechris/Aeolus/issues/353) and
[#357](https://github.com/blamechris/Aeolus/issues/357) spent 44 code lines threading the lease
a record was registered under through every judgement (the section below): **342, and about 8
left before the error at 350.** This is now the binding limit, ahead of `file_length`, and the
estimate made before the change was 323 — the identity re-fetches cost no lines, but the
registration's decision, the two other-lease guards, `isHeld(_:under:)`, the lease parameter on
five signatures and `commandWriteFailed(fanAt:heldUnder:detail:)` (moved out of `reassert` for
its cyclomatic complexity) did. The next behaviour that has to touch `held` needs #128's split
decided first. The review of #361 spent five more on the registration's generation and the
terminal action's lease: 347. The panel's lapse fix gave one back: **346, and about 4 left.**

New behaviour for #9's A4 and A6 belongs in the `EngagementDriver` that
[ADR 0014](../ADR/0014-apple-silicon-unlock.md) specifies, and in value types beside `HeldFan`
— `HeldFan` is the pattern, a type that holds no state of the actor's and so can live in its
own file — and not in this actor's body, which should keep only what has to touch `held`.

## Every act is for the lease the fan was registered under

*Added by [#353](https://github.com/blamechris/Aeolus/issues/353) and
[#357](https://github.com/blamechris/Aeolus/issues/357); not relocated from a doc comment. ADR
0009's 2026-10-15 amendment is the decision; this is how the file carries it.*

Each `HeldFan` records the lease it was registered under — the `LeaseRecord.id` that `apply`
authorised, the wire `Lease.id` — and every judgement this file makes asks about that lease and
no other. `hasLiveLease(coveringFan:)` is gone, so the coverage question cannot be asked.

**Why coverage was the defect.** Once a lease ends, `acquireLease` can grant another over the
same fan as soon as the first lease's restore returns — inside one § 5 cycle. A record left by
the first lease, which no release notice cleared, was then judged under the second: § 5
re-asserted the old target for a holder that never applied, or spent the old budget, gave the fan
up and revoked the new lease blaming the operating system (#357). The same shape was in seven
places, not one:

1. D2's question in `examine(fanAt:)`;
2. every re-fetch of `held[index]` after an `await` — presence passed a record a newer lease
   registered during the `await`;
3. `restoreAndForget`'s forget;
4. `finaliseRelease`'s drop and its whole-machine revocation (#353);
5. registration's keep-if-present rule;
6. `commandedTarget(_:)`, which wrote into whatever record was there;
7. the engagement driver's entitlement (ADR 0014's amendment of the same date).

**The re-fetch rule, restated.** *Re-fetch after every `await`; an absent record, or one under
another lease, means stop.* `isHeld(_:under:)` is the re-fetch. An absent record after one of
the re-assert's writes is restored before stopping, as it always was: the write may have landed
after the release's own restore. A record under another lease is left alone — not restored, not
forgotten, not commanded — and that is the one new non-restore branch. It is safe for three
reasons: such a record exists only after that lease's engagement landed, and an engagement's
first step requires raw mode `0`; the newer record watches the fan from then on; and anything
the stale episode left is judged under the newer lease's own target within one cycle.

**`.leaseLapsed` changes which records count, not what is done with them.** A record whose own
lease is not live is restored and forgotten whatever lease covers the fan now; "covered by
another lease" and "covered by none" are one case with one action. The restore can supersede an
engagement the newer lease has in progress (ADR 0014 D4); that `apply` is refused once, in the
safe direction, and not again, because the stale record is gone after the hand-back. The
keystone gains no input: identity decides whether § 5 hands a fan back, exactly as coverage did,
and a lease that is live and owns the record also covers the fan, so every fan coverage handed
back is still handed back.

**Registration is the arbiter.** `manualControlEngaged(_:under:)` asks the lease core once and
decides in a straight line: a lease that is not live, or does not cover the fan, is refused with
`.leaseNotLive` and records nothing; a live one keeps a record of its own and replaces one an
ended lease left. At most one live lease covers a fan, so the replaced record is always stale,
and a late registration under an ended lease cannot evict a live one.

**The answer has to still describe the fan when the registration resumes** (the review of #361,
its C1). The lease hop is a suspension, and the actor is reentrant across it: L1's registration
could be told L1 was live, and resume after L1 ended, its release notice ran, and L2 was granted,
engaged and registered the fan. Holding a true answer about an instant that had passed, it took
L2's record for an ended lease's and replaced it, and the next cycle handed back the fan L2
holds. So each fan carries a generation, bumped by every release notice and every accepted
registration, captured before the hop and compared after it; a registration that finds it
moved is refused and touches nothing. Both bumps are needed: the notice is a hint (D2), so a
lease can end with § 5 never told, and then only L2's registration moves the generation. A
lease that answered not live never becomes live again, so a `false` cannot be stale.

**What the generation still lets through, and why that is safe.** A lease that lapses or ends
with no notice and no other registration leaves the generation where it was, so a stale `true`
is accepted and records the fan under a lease that has ended. Nothing is overwritten — only the
same lease's record, or none, can be in the slot, because any other lease's registration would
have moved the generation — and the next examination asks D2 about that record's own lease,
finds it not live, and hands the fan back as `.leaseLapsed`. That holds with the terminal
action's bump below: a registration accepted after a terminal action returned finds no record
and no live lease, and is handed back the same way.

**The terminal action moves it too** (the same review, its C3). The generation did not move when
§ 5 itself began giving the fan up. A registration under the same lease — a re-apply — told its
lease was live before the terminal action and resuming inside its hand-back, before the
revocation, was accepted and cleared the `.systemReclaimed` mark the terminal action keeps
(#346): the fan handed back, its lease revoked, and the user told the system no longer holds it.
`finaliseRelease` now moves the generation in the same straight-line region as
`finalising[index] = lease`, before its first suspension, so such a registration resumes refused and
touches nothing, and the terminal action completes as it would have — it revokes that lease
anyway.

**A registration that begins during the hand-back, under the lease being given up, is refused
too.** `finalising` records the lease the terminal action is giving each fan up for, and a
registration under that lease is refused while it does, and keeps the mark. This reverses what
#346 pinned — that such an engagement clears the mark — and the reversal is deliberate, decided
in #361. The reason is rule 6 and consistency with C3, not identity: the terminal action revoked
that lease before identity too (`revokeEveryLease` included it), so the revocation in the same
call has always undone such an engagement and dropped its record, and clearing the mark has
always told the user the system no longer holds a fan it did reclaim. C3 is that outcome by
another route, and refusing one but not the other would be inconsistent. The refusal is A6's
engagement failure, so `apply` hands the fan back as well, which matches the revocation. A
registration under any other lease is accepted, as identity requires
(`aTerminalActionLeavesANewerLeasesRecordAlone`).
`FinaliseReleaseLedgerTests.aSameLeaseRegistrationDuringTheHandBackIsRefusedAndKeepsTheMark`
holds it.

**A refused registration clears nothing** (the same review, its C2). The ledger clear used to be
"unconditional, because it is a statement about the world": something had just taken the fan
off automatic control. That was true only of a registration § 5 accepted. A refused one is
evidence of no engagement § 5 can stand behind, and clearing on it erased a `.systemReclaimed`
mark the terminal action had kept, so the snapshot told the user the system no longer held a
fan nothing had taken back. The clear now follows acceptance; on an accepted registration it is
still unconditional, whatever this registry held.

**Why a refusal never leaves a fan off automatic control with nothing watching it.** A
registration follows its engagement, and the driver returned only after its after-check found
the lease live, so every one of that engagement's writes landed while the lease was live. A
refusal means either the lease is not live — it ended after that after-check, and every lease
end restores its fans with a restore requested after those writes, so it lands after them — or
the fan's generation moved, which is a release notice (a lease-core restore of the fan, issued
after the lease ended) or another accepted registration, whose record watches the fan from then
on. A6's contract adds its own hand-back of every fan the refused `apply` engaged, and a restore
the firmware refuses leaves the fan in § 3's registry, where the driver put it. One case is A6's
to prevent, not this method's: two registrations of one fan under one live lease at once — the
second is refused, and A6's hand-back would then contest § 5's record of the first. That is the
existing precondition that engagements of one fan are serialised.

**Forgotten before the restore, and why identity does not make that redundant.**
`restoreAndForget` used to say that forgetting first "needs no identity `HeldFan` does not
carry". `HeldFan` carries one now, and forget-first stays anyway: it also keeps a re-engagement
under the **same** lease made during the restore, which an identity check after the restore
could not tell from the record it was forgetting.

**The terminal action.** `finaliseRelease` ends only the lease it was holding the fan for,
through `LeaseAuthority.revokeLease(id:because:)`, whole: revoked if it is live, and ended as
`.leaseExpired` inside the call if it has lapsed unswept — the sweep, left to it, ended the lease
after `finalising` had closed, and its release notice erased the mark (#361's panel). It drops
that lease's records
— the siblings, and a same-lease re-engagement made during the hand-back, which the revocation
restores (#307's same-lease form) — and keeps every other lease's. If the lease has already
ended the hand-back still runs and nothing is revoked, with one `.notice`, so `LeaseLog`'s
"revoked" fault is emitted only for a lease actually revoked. The fault line that led there —
budget spent, half-landed, no envelope, undone after the emergency, blind — stays: it describes
the firmware or the sensing, and that is still true. With one lease at a time a live registering
lease is every lease, so the ordinary case does not change. § 3 keeps `revokeEveryLease`.

**What identity does not close (residual C2).** A stale actor's restore — § 5's hand-back owed
to an ended lease's record, or the undo of an engagement that outlived its lease — can land after
a newer lease's engagement and before that lease registers the fan. On its first cycle the
newer record reads `.modeReclaimed` and re-asserts its own target: one false "Reclamation
detected" line and a false `isReclaimedBySystem`. The re-assert takes one cycle and fails safe,
and escalates to revoking the newer lease only if the firmware refuses three re-asserts, when the
blame on the system is true. The mark lasts longer: only a cycle converged on both signals clears
it, and a fan still short of its new target takes the shortfall branch, which returns before that
clear — so it stands while the fan ramps, and indefinitely if the fan cannot reach the target
([#366](https://github.com/blamechris/Aeolus/issues/366)).

**What is untested, and kept by the rule.** The re-fetch across the lease hop in
`examine(fanAt:)` has no test landing an event inside it (#344). `HeldLeaseRole` — § 5's role over
the lease core, which narrows it to the two calls it makes — is now the seam that can, without
blocking a pool thread; `ParkableHeldLeases` uses it for the registration's hop. The identity
re-fetch after the control-state read is caught one hop later by that same lease-hop re-fetch,
so only its log line tells it from a presence check;
`ReclamationLeaseIdentityTests.aRecordRegisteredUnderANewLeaseDuringTheReadStopsTheExamination`
asserts that line.

## Built once per registration, per lease

*From the doc comment of `HeldFan`, relocated by #357, with the per-lease rule added. The
original text follows the rule.*

`HeldFan.registering(_:over:)` keeps an existing entry only when it was registered under the
same lease, and builds a fresh one otherwise. A new lease starts fresh because the old lease's
end restored the fan to automatic control, so its target is not the new lease's and its spent
counters were spent against a fan that has since been handed back: keeping them would hand the
new lease the old target and the old budget, and this is not a rearm loophole, because the only
caller who can rearm this way is one granted a new lease, which a release must precede.
`ReclamationLeaseIdentityTests.aRegistrationUnderANewLeaseStartsAFreshRecord` holds it.

> Moved here from `manualControlEngaged(_:)` with #180, for the line budget this file's
> header describes. That method creates an entry only when there is not one already, so
> registering a fan twice without an intervening release keeps its `commanded` target,
> its grace counter, its re-assert attempts and its blind-cycle count. It used to build a
> fresh `HeldFan` unconditionally, and that was two defects rather than one:
>
> - **The grace was rearmed.** `uncommandedDivergentCycles` went back to zero, so a
>   caller re-registering a fan every other cycle held it off automatic control
>   indefinitely and the terminal action was never reached — twenty registrations bought
>   forty divergent cycles, no restore, and a lease still live. That is the budget
>   `gracedBeforeItsFirstCommand(_:of:fanAt:)` exists to bound, refillable on demand by
>   the very caller it is meant to bound.
> - **`commanded` was wiped.** `primaryDivergence(of:against:)` reaches
>   `.targetDiverged` only behind `guard let commanded`, so a re-registered fan Aeolus
>   *had* commanded became unjudgeable on that case until the next `commandedTarget(_:)`
>   — a fan pinned at a number this mechanism had just forgotten it wrote, which is
>   `CLAUDE.md` rule 6.
>
> The refill point is a genuine release, and each one drops the entry:
> `manualControlReleased(fanAt:)` for a lease that ended, `finaliseRelease(fanAt:because:)`
> for a fan § 5 gave up, and `restoreAndForget(fanAt:)` for a fan § 3 holds or no live
> lease covers. A registration after any of them starts fresh, which is the case a fresh
> `HeldFan` is actually for.
>
> `ReclamationRegistrationWindowTests.reRegisteringMidGraceDoesNotRefillIt` and
> `.reRegisteringKeepsWhatWasCommanded` are the two halves.

## The above-ceiling rule is the arbiter, not an `if`

*From the documentation of the type. It continues the opening paragraph, which stays in the source: "§ 5 never fights the system for the fans while any temperature is above ceiling", because reclamation mid-emergency means a more competent authority reached the same destination first.*

That rule is enforced by asking `SafetyArbiter.ruling(for:incumbent:)` whether level 3
may write while level 2 holds the fans, and the answer is no because ADR 0007 orders
them that way. It is deliberately **not** a second `if temperature > ceiling` here: a
bespoke comparison would be a second copy of § 3's own ceiling arithmetic, in the file
least able to keep it in step, and `ThermalEmergency` already documents that a margin
subtracted in two places is a margin that can disagree with itself.

`ThermalEmergency`'s own doc names this moment: the arbiter *"still has no production
caller"* with one actor implemented, and *"that half becomes load-bearing when the
reclamation watchdog (#126) and sleep/wake (#103) arrive to contend with it"*. This is
that arrival. Replacing `SafetyArbiter.ruling`'s body with `return .commands` now fails
`ReclamationWatchdogTests.itNeverReassertsWhileTheThermalLatchHolds` as well as the
arbiter's own tests — and, because the ruling is consulted twice per re-assert, also
`itUndoesAReassertWhenTheEmergencyLatchesMidWrite`.

**What the latch buys, stated exactly.** The incumbent is read from
`ThermalEmergencyLatch`, which is engaged from the cycle § 3 fires on until a fresh
reading falls a hysteresis margin below the ceiling — so this refuses to re-assert
through the whole band down to `ceiling − 5 °C`, which is *longer* than "above ceiling"
strictly requires. Over-refusing is the safe direction: the fan is on Apple's thermal
management throughout.

The gap in the other direction is one cycle. A temperature crossing the ceiling is not
visible here until § 3's next cycle engages the latch, so a re-assert can be issued into
the first second of an emergency. Making this read a temperature of its own to close that
window would add a supervisor-priority read per cycle — see
[#134](https://github.com/blamechris/Aeolus/issues/134) — for a window § 3 closes within
one cycle by latching, after which this mechanism refuses.

**What does not close it is § 3 correcting the re-assert, and an earlier version of this
paragraph claimed exactly that.** It said § 3's next cycle "bridges the fan to maximum and
restores it, which overrides the re-assert rather than racing it". That is false, and
checkably so: `ThermalEmergency.fire(_:from:)` empties `engagedFans` as it goes, and
`ThermalEmergency.manualControlEngaged(_:)` has **no caller anywhere in `Sources/`** — so
a fan this mechanism re-engaged is in no registry § 3 consults, and § 3's next cycle
would leave it off automatic control indefinitely. Relying on another mechanism to clean
up after this one was the wrong shape regardless; the correction belongs here, and
`reassert(_:fanAt:attempt:)` performs it by re-checking the ruling **after** its writes
and restoring if the latch engaged underneath them.

> **Corrected 2026-10-11 ([#345](https://github.com/blamechris/Aeolus/pull/345)).** "Indefinitely" above is false.
> `ThermalEmergency.fire(_:from:)` ends in `leases.revokeEveryLease(because: .thermalEmergency)`,
> which drops every live lease and restores the fans they covered, and a fan this mechanism
> re-engages is under a live lease: `examine(fanAt:)` hands back any fan that none covers
> (ADR 0009 D2). So the cycle that fires hands such a fan back even though no registry § 3
> bridges holds it. What stands is the rest of the paragraph: relying on another mechanism to
> clean up after this one was the wrong shape, and `reassert(_:fanAt:attempt:)` still performs
> its own undo after the writes.
>
> **Superseded by [#181](https://github.com/blamechris/Aeolus/issues/181).** The re-assert now
> engages through ADR 0014's `EngagementDriver`, which calls `ThermalEmergency.manualControlEngaged(_:)`
> when the mode write reads back engaged — so a fan this mechanism re-engaged *is* in the registry
> § 3 bridges, and stays there when the undo is refused. The undo after the writes is still this
> mechanism's own; the registration is the second chance ADR 0009 D1 names.

## Reads are strictly sequential, and that is #134's answer for this issue

*From the documentation of the type.*

One fan is examined at a time, `await`ed to completion before the next begins.
`SMCReadScheduler` is FIFO within `.supervisor`, and the starvation quota forces a
snapshot turn after every `maxConsecutiveOvertakes`, so *N* concurrently outstanding
supervisor reads delay § 3's cycle by *N* supervisor turns **plus** roughly `N/2`
quota-forced snapshot turns — and a snapshot turn is 64 keys where a control-state read
is three. The forced turns, not the watchdog's own reads, are what would hurt.

Sequential examination means this actor contributes **at most one** supervisor waiter at
any instant however many fans the machine has, so § 3's cycle queues behind at most one
other supervisor read and `SMCReadScheduler`'s "at most two turns" bound very nearly
holds. The cost is borne here — a full sweep takes N times one read's latency — and this
mechanism runs at 1 Hz against N of 1 or 2 on real hardware, so there is nothing to buy
by parallelising it.

#134's remaining questions are untouched by this: whether § 3's cycle should outrank
other supervisor reads at all, whether grant-time `refuseIfBlind` reads should be
coalesced, and whether a third priority level is warranted. This issue only declines to
make them worse.

## The splits already taken

*From the `- Note:` that closed the documentation of the type. It is replaced in the source by a shorter note that points here.*

- Note: this file is over SwiftLint's 400-line warning, and it has crossed the 1000-line
  **error** twice: when #169/#170/#172 landed beside the registration grace, and with ADR
  0009 D2 (#180). Each split taken widened no state: `ReclamationDivergence` and
  `ReclamationLimits` are values and live in `ReclamationLimits.swift`;
  `primaryDivergence(of:against:)` and `actualShortfall(of:against:)` are `static` and
  pure and live in `ReclamationSignals.swift`; and `HeldFan` is a type, not state, and
  lives in `ReclamationHeldFan.swift`. Every remaining member reads or writes `held`, so
  moving any of it into another file would widen that state to the whole module. That
  state is exactly what makes `examine(fanAt:ruling:)`'s read-then-mutate reasoning
  checkable, and [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest of
  this space — including what to do when the next paragraph pushes this over again.

## The ordering is normative: call this **after** the `F<n>Md` write has landed

*From the doc comment of `manualControlEngaged(_:)`.*

"At the same point" says nothing about which side, and only one of the two sides
works. E3 will be written against this comment, so the constraint is stated here
rather than discovered later.

Registering *before* the mode write is not a harmless reordering. This mechanism runs
on its own 1 Hz loop, so a `cycle()` can land in the window between the registration
and the write. What it reads there is `mode == .automatic` on a fan with nothing
commanded, which is `.modeReclaimed` — the strongest primary signal there is — and
it reaches `diverged(_:fanAt:)`'s "nothing to re-assert" branch and
`finaliseRelease(fanAt:because:)` with `.systemReclaimed`: the fan restored, **every
lease on the machine revoked**, and a `.fault` line blaming the operating system —
milliseconds after a client was granted control it never got to use.
`ReclamationWatchdogRecoveryTests.aFanWithNoCommandedTargetIsRestored` and
`fallingBackClearsTheWholeRegistry` are that path, arrived at on purpose.

> **Corrected 2026-10-11 ([#345](https://github.com/blamechris/Aeolus/pull/345)).** "Milliseconds after" predates the registration
> grace, which the next section describes: a cycle landing in this window is graced for
> `ReclamationLimits.blindCyclesBeforeDivergence` (three) cycles, so the restore and the
> revocation arrive on the third divergent cycle rather than the first.
>
> **Corrected 2026-10-15 ([#353](https://github.com/blamechris/Aeolus/issues/353)).** "Every
> lease on the machine" is now the lease the fan was registered under: the terminal action
> revokes that lease alone. With one lease at a time it is the same client's lease.

## The far side of the write is not free either, and the grace is what pays for it

*From the doc comment of `manualControlEngaged(_:)`.*

An earlier version of this comment said the window after the mode write was safe, and
that a grace flag on `HeldFan` was therefore unnecessary. That was true of the
`.targetDiverged` case and of nothing else: both `.modeReclaimed` and
`.targetUnreadable` are decided *before* `primaryDivergence(of:against:)` consults
`commanded` at all, so a cycle landing in the `F<n>Md` write-to-read-back lag, or on
one unreadable `F<n>Tg`, reached the same whole-machine revocation from the ordering
this comment mandates. A write returning successfully and a read reflecting it are
different facts, and the lag between them is unmeasured on Apple Silicon.

`gracedBeforeItsFirstCommand(_:of:fanAt:)` closes that window — #147's second remedy,
implemented rather than declined — by giving a fan with nothing commanded on it
`ReclamationLimits.blindCyclesBeforeDivergence` cycles before the primary signal
reaches the terminal action. So the ordering above is what this method requires, and
the grace is what makes obeying it survivable rather than merely correct on paper.
The two sides are not symmetrical after it: registering early still costs the client
its lease, three cycles later instead of one.

`ReclamationRegistrationWindowTests` is the whole window, one test per answer
`primaryDivergence(of:against:)` can give inside it, so this comment claims no more
than the suite shows.

## The parameter stays a `CommandableFan`

*From the doc comment of `manualControlEngaged(_:)`.*

Only `fan.index` is read, and with `HeldFan.permit` gone there is nothing else it is
stored into — so tidying this to `manualControlEngaged(fanAt index: Int)` looks free.
It is not: a `CommandableFan` can only be minted from a `FanEnvelope` that passed its
bounds gate, so the type is what makes registration lawful only from a caller that
was actually authorised to write to the fan. Widening it would let anything put a fan
into a registry whose entries this mechanism will later re-engage manual control on.
`ThermalEmergency.manualControlEngaged(_:)` takes the same parameter for the same
reason.

## The window this closes

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`.*

`manualControlEngaged(_:)` mandates registration **after** the `F<n>Md` write lands,
and an earlier version of that comment claimed the far side of the write was
therefore safe without any grace. It is not, and the claim covered exactly one of the
three ways `primaryDivergence(of:against:)` can answer for a fan on which nothing has
been commanded yet:

- `.targetDiverged` — unreachable, because that case is behind
  `guard let commanded else { return nil }`. This is the only case the old claim
  analysed, and it is the one that never needed a grace.
- `.modeReclaimed` — reached **before** `commanded` is consulted at all. A write that
  has returned successfully is not the same fact as a read that reflects it, and the
  `F<n>Md` write-to-read-back latency on Apple Silicon is unmeasured — `docs/SMC-
  RESEARCH.md`'s observed section is empty on this point. One cycle landing inside
  that lag reads automatic.
- `.targetUnreadable` — reached before `commanded` as well. A single unreadable
  `F<n>Tg` on a fan nothing has been commanded on took the terminal action on the
  spot, with none of the tolerance `cycleCouldNotSee(fanAt:detail:)` gives a fan that
  could not be read at all.

Both of the latter two ended at `diverged(_:fanAt:)`'s "nothing to re-assert" branch:
the fan restored, **every lease on the machine revoked**, and a `.fault` line blaming
the operating system — milliseconds after a client was granted control it never got
to use. That is the defect [#147](https://github.com/blamechris/Aeolus/issues/147)
names, arrived at from the ordering it mandates rather than from the one it forbids.

## Why the failure asymmetry inverts here, and only here

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`.*

This file's rule is that over-firing is the safe direction: handing a fan back to
Apple's thermal management costs cooling nobody chose, while under-firing leaves a
fan pinned at a speed nothing honours, which is `CLAUDE.md` rule 6. **On a fan with
no commanded target there is no such speed.** Nothing Aeolus picked is on the wire,
so the pinned-fan hazard the asymmetry is built around does not exist, and what
over-firing costs instead is the whole-machine revocation above — losing control that
is in fact still held, which is rule 6 in the direction people forget.
`reportShortfall(_:fanAt:)` declines the terminal action on the same grounds.

So the tolerance is granted **only while `commanded` is `nil`**. The first
`commandedTarget(_:)` ends it for the rest of that registration, and a commanded fan
is judged exactly as strictly as before — including on the very next cycle.

## Bounded by `blindCyclesBeforeDivergence`, and not by a fourth constant

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`.*

The same number, because it is the same question: how many 1 Hz cycles may pass
without this mechanism being able to confirm a fan is ours before that becomes
divergence. Three cycles is three seconds — long against any plausible firmware
read-back lag and short against anything a user would notice — and a genuine
reclamation of an uncommanded fan is still restored and reported, just on the third
cycle rather than the first. `ReclamationLimitsTests` already holds that constant
under a literal ceiling, so this window cannot be widened into minutes either.

## Why this no longer reaches the terminal action

*From the doc comment of `reportShortfall(_:fanAt:)`.*

It used to, and that was the most consequential defect in this file. The secondary
signal is only ever *evaluated* when the primary has converged — `examine` returns
early on primary divergence — so reaching this function means `F<n>Md` reads manual
and `F<n>Tg` reads back exactly what Aeolus commanded. **The firmware is holding our
target.** Nothing has been reclaimed.

A fan that is not reaching a target the firmware is faithfully holding is a fan that
*cannot* reach it: an obstruction, a failing bearing, a declared `F<n>Mx` the part
cannot actually achieve. The three things the mechanism could do about that are all
wrong. Re-asserting rewrites the number that is already correct. Restoring to
automatic makes it worse — Apple's thermal management will spin the same fan against
the same obstruction. And marking `isReclaimedBySystem` tells the user the system
took a fan it did not take, which is `CLAUDE.md` rule 6 in the direction people
forget: claiming to have *lost* control that is in fact still held.

So it reports. The user is told, which is what `docs/SAFETY.md` § 5 asks for — *"and
either way tells the user"* — and the fan stays under the control it is genuinely
still under.

## It reads a fresh envelope, and that is deliberate

*From the doc comment of `reassert(_:fanAt:attempt:)`.*

Not the permit taken when the fan came off automatic control — and `HeldFan` keeps no
permit at all, so there is not one to reach for. Permits do not expire
— `FanWriteAuthorisation.swift` is explicit that freshness is *"policy held by
review, not by the type"* — and § 3 depends on that, because its maximum write has
to be available while the machine is above ceiling and reading may be what has
failed. This branch is the opposite case: it runs below the ceiling, and it has just
successfully read this fan's control state, so reading works. A mechanism that can
read has no excuse to command a fan against bounds nobody has checked since the
system took it back.

That is also what `CommandedTarget` withholding an `AuthorisedFanTarget` is for: it
makes the re-assert explicitly fallible rather than free, and this is where the
fallibility is spent.

A re-assert that cannot obtain an envelope **restores rather than commanding** —
#126's acceptance criterion, and `FanControlPlane`'s §2 rule that the only action a
fan with untrusted bounds is subject to is the bounds-free restore verb.

## The two writes are not one step, and are not caught together

*From the doc comment of `reassert(_:fanAt:attempt:)`.*

`engageManualControl` then `command` were wrapped in a single `do`/`catch`, which
made a firmware that accepted the first and refused the second indistinguishable from
one that refused both. Those are opposite states: the second leaves the fan on
Apple's thermal management, which is safe, and the first leaves it **off** automatic
control holding whatever `F<n>Tg` the system last wrote — a fan pinned at a speed
nobody chose, which is the worst reachable state in this project. They are caught
separately, and the half-landed case restores immediately rather than waiting for a
budget to run out.

## The ledger entry `finaliseRelease` keeps

*From the doc comment of `finaliseRelease(fanAt:because:)`.*

The restore is attempted whatever else failed, and consumes nothing a failing
machine might be unable to supply — ADR 0007's keystone. The ledger entry for `index`
is **kept**, and what it says depends on which caller got here, because since #140
the two are no longer one bit:

- `.systemReclaimed` — the system does hold this fan now, that is what the user
  should be told, and it stays true until something deliberately takes it off
  automatic control again.
- `.supervisorBlind` — the helper could not read the fan, so this entry asserts
  **nothing** about who holds it. It records that § 5 gave the fan up and why, which
  the fault log and the lease's ending report and `FanState.isReclaimedBySystem`
  deliberately does not. Until #355 the snapshot also published it as
  `ManualControlAvailability.Reason.supervisorBlind`; it is history, not a refusal.

Either way it is kept rather than cleared, for the reason `clearReclaimed(fanAt:)`
states: a fan this mechanism has just handed back is not a fan known to be fine.

### Kept through its own revocation

*Added by [#346](https://github.com/blamechris/Aeolus/issues/346); not relocated from a doc comment.*

Until #346 the entry was not kept in the composition the daemon runs. `finaliseRelease` ends
by awaiting the revocation — `LeaseAuthority.revokeEveryLease(because:)` then, and
`revokeLease(id:because:)` since #353 — which restores through
`HelperFanRestorer`, which calls `manualControlReleased(fanAt:)` for every fan it hands back
— this one included — before its write. That call ran while `finaliseRelease` was suspended
inside the revocation, cleared the entry the caller had just written, and logged it resolved,
so `FanState.isReclaimedBySystem` reported a fan the system had taken as one it had not:
`CLAUDE.md` rule 6, in the direction that hides a loss. No watchdog suite could see it,
because `ReclamationMachine`'s `RecordingFanRestorer` never calls back.
`FinaliseReleaseLedgerTests` drives the composed graph instead.

`finaliseRelease` now puts the fan in `finalising` before its first suspension and takes it
out when it returns, and `manualControlReleased(fanAt:)` still drops the registry entry for
such a fan but skips its ledger clear. The clear is dropped, not postponed: the mark stays
until a later release notice or an engagement clears it. Nothing on the restore path changed: the
hand-back and the revocation's restore are issued exactly as before, and the guard consumes
nothing a restore depends on.

**Why not re-mark after the revocation returns.** The clear and its "resolved" line would
still happen in between, so a snapshot taken during the revocation would report the fan not
reclaimed and the log would say the reclamation ended when it had not. Re-marking would also
act after a suspension on a judgement made before it, which `cycle()`'s rule forbids: an
engagement landing during the revocation clears the entry because something deliberately
took the fan off automatic control, and marking it again afterwards would report a fan as
lost that a client had just taken.

**Why not have the restorer say which releases are § 5's own.** Passing the
`FanRestoreCause` through `manualControlReleased` would let the watchdog skip the clear for
`.systemReclaimed` and `.supervisorBlind`, but it infers ownership from a label any later
revocation could carry, changes the lease side's notification for a fact only the watchdog
holds, and misses a lease teardown that lands during the hand-back, which sends the same
notice under its own cause.

**Why the whole call, and not the revocation alone.** A lease ending during the hand-back —
the TTL sweep, or the holder's connection dying — notifies § 5 about a fan it has already
judged and is already giving up. The entry describes that judgement, so it is kept too —
`FinaliseReleaseLedgerTests.aTeardownDuringTheHandBackKeepsTheEntry`, which goes red when the
guard is opened around the revocation alone.

**What it does not close.** A lease teardown — the TTL sweep, or the holder's connection dying —
that reaches `LeaseAuthority` after the hand-back has returned but before
`revokeLease(id:because:)` runs takes the table entry itself, so the revocation finds nothing
and returns at once. The teardown's own release notice is then still on its way through
`HelperFanRestorer`, can arrive after the `defer` has closed the window, and clears the mark.
That is derived from the code, not reproduced: no seam lands a teardown in that gap.

**A lease that ended before the revocation, since #353.** `revokeLease(id:because:)` then revokes
nothing and sends no release notice of its own, so the mark is kept with nothing to clear it on
the way out; the release that ended the lease sent its notice while `finalising` held the fan,
and that notice skipped its clear as any other during the call does.
`FinaliseReleaseLedgerTests.theTerminalActionRevokesOnlyTheLeaseItHeldTheFanFor` releases and
re-grants inside the hand-back.

**A lease that lapsed during the call, since #361's panel.** It used to be the gap the paragraph
above names, by another route: `revokeLease` declined a lapsed lease, `finalising` closed, and the
TTL sweep then ended it and its notice cleared the mark — #346's defect again, which `main` never
had because `revokeEveryLease`'s `removeAll()` took lapsed entries too. `revokeLease` now ends a
lapsed lease inside the call, as `.leaseExpired`, so its notice lands while `finalising` holds the
fan. `FinaliseReleaseLedgerTests.aLeaseLapsingDuringTheHandBackKeepsTheMarkThroughItsExpiry`
lapses the lease inside the hand-back.

**What still clears it, so it is not frozen.** An accepted `manualControlEngaged(_:under:)`
clears, because an engagement is a statement about the world. #346 pinned that it also clears
during the call (`anEngagementDuringTheHandBackStillClears`); #361 reversed that for a
registration under the lease the call is giving up, which is now refused and keeps the mark —
"Every act is for the lease the fan was registered under" above has why. The guard is per fan,
so the revocation's notice still clears any other fan's mark the revoked lease covered
(`anotherFansMarkIsClearedByTheRevocation`). Once `finaliseRelease` returns, every release
notification clears as it always has: a later lease ending is a fan Aeolus stopped asking for,
which is not a fan the system took. That is one place the first list above overstates — a lease
granted and released without an engagement in between clears a `.systemReclaimed` entry
although nothing took the fan off automatic control. It is the behaviour
`manualControlReleased(fanAt:)` has always had, kept deliberately, and
`FinaliseReleaseLedgerTests.anOrdinaryReleaseAfterwardsStillClearsTheEntry` holds it.

All of that holds at the actor level: these are the events that clear the mark. At the system
level nothing guarantees one arrives, and since
[#355](https://github.com/blamechris/Aeolus/issues/355) nothing needs to. Until it, the snapshot
published the mark as an availability that refused the fan while `acquireLease` would grant it,
and both clearing events needed a lease the snapshot told a compliant client not to ask for.
Resolved by #355: the snapshot reports the mark as a fact — `isReclaimedBySystem` for a
reclamation, the fault log and the lease's ending for blindness — and never as an availability,
so the snapshot answers what the grant answers and a client may ask for the fan again.
