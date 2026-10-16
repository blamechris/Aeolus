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
  another file that moved `reportShortfall(_:fanAt:)` (now part of `HeldFan.judge(_:)`)
  verbatim failed to compile with `'held'
  is inaccessible due to 'private' protection level`, and the same for `log`. D36 is that
  stored state stays `private`, and `held` is exactly what makes `examine(fanAt:)`'s
  read-then-mutate reasoning checkable.

  *That was the whole of the actor when it was written, and it is now true only of what the
  actor does.* [#128](https://github.com/blamechris/Aeolus/issues/128)'s third pass moved `held`
  itself — with `finalising`, `registrations` and every synchronous decision over them — into a
  value type the actor holds `private`, and `reportShortfall(_:fanAt:)` into `HeldFan.judge(_:)`
  ([the limit below](#the-limit-prose-cannot-relieve-the-type-body)). That widened nothing,
  because the state moved *inside* a value rather than being reached from another file. What is
  left in the actor awaits, re-fetches after an `await`, or acts, over `registry`, `log`,
  `ledger`, `writer`, `sensing`, `leases` or `latch`; moving any of it to another file would
  still widen that state, and moving it into a helper would add a suspension point.
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

**#128's third pass moved `held`, `finalising` and `registrations` themselves into
`ReclamationWatchdog.Registry`, a value type held `private`: 301 code lines, file 867**
(SwiftLint 0.65.1), from 346 and 977. #365, #366 and #368 each need § 5 code, and four lines
were not room for any of them. The registry's transitions are synchronous, named and
closure-free, and `HeldFan.judge(_:)` moves one record's counters for one readable cycle; the
actor keeps every `await`, every re-fetch after one and every act, in the order it had.
`ReclamationWatchdogAccessTests` and `ReclamationRegistryAccessTests` hold the trade, and
`ReclamationRegistryTests` tests the registry as a value.

About 49 lines of headroom is the honest floor rather than a step towards the 250 warning. What
is left is the reentrancy-sensitive orchestration — each `await`, the re-fetch after it, and the
act it guards — and none of it can leave the actor without widening its state to the module or
adding a suspension point between a check and its act, which is the defect class this file's
re-fetch rule exists to prevent. The gain is where the next state goes: #366's episode mark, and
#368's token if it lands here, go into `Registry` as pure state tested as a value, at a cost to
the actor of a few lines each. Three other routes were weighed and refused:

- **Extensions in the same file.** SwiftLint since 0.57 excludes `extension` from
  `type_body_length` by default (`excluded_types: [extension, protocol]`), and CI installs it
  unpinned, so code moved into an extension is not bounded at all — the rule is retired rather
  than met — and `file_length` is untouched.
- **A helper holding the ledger, the log and the driver.** Every call into it becomes a hop of
  its own, so scheduling moves and the suites that stagger work by suspension could flip.
- **Pushing the re-fetches out through callbacks.** Adds a suspension point between each check
  and the act it guards.

**#366 spent five: 306 code lines, and about 44 left; file 883** (SwiftLint 0.65.1). It added a
fourth store to `Registry`, `givenUp`, and put the reclamation episode on the record
(`HeldFan.episodeInFlight`) rather than in a store keyed by fan: four transitions end a record
(`register` replacing it, `release`, `forget` and `dropLease`), and each would have had to remember
to end the episode too. The actor's share is the binding of `mayClearTheMark` and its guard in
`manualControlEngaged`, and the `.short` clears in `examine`. `examine(fanAt:)` is now exactly 50
code lines, `function_body_length`'s warning, so the next line it needs takes a split first.

**#381 spent seventeen: 323 code lines, and about 27 left; file 947** (SwiftLint 0.65.1). The
stamp, the re-fetch of the target and the comparison before recording are three `Registry` members,
and a field on `HeldFan` stamped by its own method so that #383 can add to the stamp, all tested as
values. The actor's share is the stamp in `examine`'s first line, which replaced the line that read
the lease, so `examine` stays at 50 with no split; the two re-fetches before the command write; and
three private helpers for where they stop — `reassertStopped`, `reassertStoppedAfterItsFirstStep`,
and `reengageRefused` for a first step refused because a same-lease engagement took the fan first
— which keep `reassert`'s cyclomatic complexity at 10 where inline guards would have made it 13.

**#383 spent four: 327 code lines, and about 23 left; file 961** (SwiftLint 0.65.1). The verb
`commandAnnounced(_:under:)` is the actor's whole share. The stamp's target rides on #381's stamp,
inside `HeldFan.beginExamination(atGeneration:)`, and the excuse lives in `HeldFan.judge(_:)`, so
`examine(fanAt:)` stays at exactly 50 code lines with no split and `reassert`'s cyclomatic
complexity stays at 10. Its reasoning is in this document, under *"Judged against what the fan
could have been holding"*, rather than in the actor's file, which stays clear of `file_length`'s
error.

**#390 spent none: 327 code lines; `examine(fanAt:)` 50; file 961.** `commandAnnounced(_:under:)`
changed its parameter, not its length, and `.held` joined the pattern `.graced, nil` already had.
The credit and the held judgement live in `HeldFan` (struct body 65 → 78).

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
finds it not live, and hands the fan back as `.leaseLapsed`. The shipping route here is a lapse:
the TTL passes and the sweep has not run, so nothing moves the generation. A teardown sends a
release notice, so a lease ended by one is this case only if the notice was lost. Both routes
are held by `ReclamationLeaseIdentityTests.aRegistrationAcceptedAfterAnUnannouncedLeaseEndIsHandedBack`
(#365), which asserts the acceptance as well as the hand-back, so closing the residual turns it
red and this record gets updated with it.

**After the terminal action, a registration under the lease it gave up is refused.** A re-apply
under the lease being given up that began during the hand-back is refused on whichever side of
the revocation it resumes, by `givenUp`: the terminal action's entry records the lease there and
nothing clears it (#366). The same call ends that lease, and an ended lease is never live again,
so any answer about it is stale whenever the registration began. In the shipping composition the
revocation's notice refuses it too: the restorer (`HelperFanRestorer`) sends § 5
`manualControlReleased(fanAt:)` for every fan before every lease-core restore, which moves the
generation (`aReapplyThatBeganInTheHandBackIsRefusedAfterTheRevocationsNotice`, which delivers the
notice inside the revocation as the restorer does). The mark the terminal action keeps (#346)
stays. `givenUp` is per fan: a re-apply of a sibling fan under the same lease is refused by that
notice, and with the notice lost it is accepted and handed back as `.leaseLapsed` on the next
cycle.

**Without the notice it was accepted, and cleared the mark — closed by #366.** A notice is a hint
(ADR 0009 D2), and `RecordingFanRestorer` sends none. With it lost, a registration that began
during the hand-back and resumed after the terminal action returned found nothing had moved the
generation and `finalising` closed, so it was accepted: it recorded the fan under the lease the
terminal action had revoked and erased the `.systemReclaimed` mark the terminal action kept, and
the next examination handed the fan back as `.leaseLapsed`. Keeping the clear alone would not
have been enough, because that hand-back's `restoreAndForget` clears the mark as well; the
registration has to be refused. `givenUp` refuses it whatever notice was sent or lost, and the
mark stays. `aRegistrationResumingAfterTheTerminalActionIsRefusedAndKeepsTheMark` asserted the
acceptance until #366 turned it red, and now asserts the refusal.

**The terminal action moves it too** (the same review, its C3). The generation did not move when
§ 5 itself began giving the fan up. A registration under the same lease — a re-apply — told its
lease was live before the terminal action and resuming inside its hand-back, before the
revocation, was accepted and cleared the `.systemReclaimed` mark the terminal action keeps
(#346): the fan handed back, its lease revoked, and the user told the system no longer holds it.
`finaliseRelease` now moves the generation in the same straight-line region as
`finalising[index] = lease`, before its first suspension, so such a registration resumes refused and
touches nothing, and the terminal action completes as it would have — it revokes that lease
anyway. Since #366 `givenUp` refuses a same-lease registration from the entry on as well, so the
bump stays for another lease's registration in flight across the entry, and the hop test's recipe
is the pair of mutations.

**A registration that begins during the hand-back, under the lease being given up, is refused
too.** `givenUp` records the lease the terminal action gave each fan up for, set at its entry
beside `finalising` and never cleared (#366; until then the refusal was `finalising`'s, and closed
with the call), and a registration under that lease is refused from the entry on, and keeps the
mark. This reverses what #346 pinned — that such an engagement clears the mark — and the reversal
is deliberate, decided in #361. The reason is rule 6 and consistency with C3, not identity: the
terminal action revoked
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
unconditional, whatever this registry held, except a re-apply mid-episode (the next paragraph).

**A re-apply mid-episode leaves the mark to the episode** (#366, from #361's § 5 reviewer, demo A).
§ 5 marks a fan reclaimed when its primary signal diverges, then re-asserts. A registration under
the same lease during the re-assert's envelope read was accepted — the lease was live and nothing
had moved the generation — and cleared the mark; the envelope then failed, and the terminal action
gave the fan up as `.systemReclaimed` with no mark left. `HeldFan.judge(_:)` now opens an episode
on every `.diverged`, before `diverged(_:fanAt:heldUnder:)` reaches the ledger, and the next
readable cycle whose primary converges closes it. While it is open, a registration under the
record's own lease is accepted, keeps the record and moves the generation, but answers
`mayClearTheMark: false`, and `manualControlEngaged` logs a notice and clears nothing. For one
lease the cases split cleanly:

| When the registration lands | What happens to it |
|---|---|
| Before the diverging judgement | Accepted, and it clears the mark |
| From that judgement to the terminal action's entry | Accepted, and it clears nothing |
| From the entry onwards | Refused (`givenUp`) |

The second row holds only while the episode is open: once a cycle that reads the target held has
closed it, a registration behaves as in the first. None of it relies on a release notice. A
registration under any other lease still clears: one live lease covers a fan, so it means a newer
engagement holds the fan. Three alternatives were refused. Stopping § 5 whenever the generation
moves lets a client that re-applies every cycle postpone the terminal action indefinitely, the
contest the budget bounds. Refusing a same-lease registration for the whole episode makes A6 hand
the refused engagement back, which supersedes § 5's own re-assert (ADR 0014 D4), and § 5 then reads
its own client's hand-back as a reclamation. A rule in the ledger learns of the episode after a hop
that nothing orders against the registration's clear, and gives the snapshot a second definition of
"reclaimed". `ReclamationEpisodeMarkTests` holds the actor's half and `ReclamationRegistryTests` the
value's, in `ReclamationRegistryEpisodeTests.swift`. What stays open:

1. A same-lease re-apply that engages the fan mid-episode leaves `isReclaimedBySystem` true until
   the next readable cycle: one cycle, or at most `blindCyclesBeforeDivergence` if reads fail,
   after which blindness takes over.
2. A clear queued just before the judgement can land after the mark if the actor runs jobs out of
   order by priority, which Swift's actors do not promise against. The window is one latch hop
   plus one ledger hop, and `main` had it unchanged.
3. The blind path opens no episode. A same-lease registration inside `cycleCouldNotSee`'s
   `markSupervisorBlind` hop clears the `.supervisorBlind` entry: one ledger hop with no seam to
   test it, and the entry is not on the wire (#355). Closing it costs an actor line no
   deterministic test can kill.
4. A client write issued during § 5's own command write can land first: one cycle, one more
   attempt ([#381](https://github.com/blamechris/Aeolus/issues/381)).
5. A same-lease re-apply that registers without engaging a fan the system has taken back to
   automatic stands that cycle's re-assert down, as does one landing just before a genuine
   re-reclamation. The fan stays on automatic until the next cycle re-engages it: one cycle and
   one attempt, in the direction of giving the fan up sooner (#381).
6. Two engagements of one fan under one lease can overlap. One that completes during § 5's yield
   wait re-admits § 5's next step as a first step, which is refused `.notAutomatic` after § 5's
   driver has written; the driver hands the fan back, and `reengageRefused`, which routes on the
   error type, logs the stand-down, whose line says nothing was written. The fan ends on automatic
   control and the mark is kept, so the snapshot is truthful and the log line is not. An A6
   precondition, tracked as [#389](https://github.com/blamechris/Aeolus/issues/389).

Until #381 the re-assert acted on the target and mode it judged before its envelope read, so a
re-apply inside that read was overwritten — for a diverged target the old number was re-commanded
over the client's, and for a reclaimed mode the re-assert logged a failed re-engage and spent an
attempt. #381 closed it: the examination stamps the record, a same-lease registration since the
stamp stands the re-assert down with its attempt spent, at either re-fetch or, while one engagement
of a fan runs at a time, at a first step refused because that engagement took the fan first, the
target is re-fetched before the write,
and the write is recorded only over the target it was decided on (ADR 0014's #381 amendment).

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
through `LeaseAuthority.revokeLease(id:forFan:because:)`, whole: revoked if it is live, and
ended as `.leaseExpired` inside the call if it has lapsed and is still unswept — the sweep, left
to it, ended the lease after `finalising` had closed, and its release notice erased the mark
(#361's panel). A lease a sweep or teardown removes after the hand-back and before the revocation
is not exposed to that either: the revocation answers `.gone` only once that teardown's handback
has returned ([#368](https://github.com/blamechris/Aeolus/issues/368)). It drops that
lease's records — the siblings, and a same-lease re-engagement made during the hand-back, which
the revocation restores (#307's same-lease form) — and keeps every other lease's. If the lease
has already ended the hand-back still runs and nothing is revoked, with one `.notice`, so
`LeaseLog`'s "revoked" fault is emitted only for a lease actually revoked. The fault line that
led there — budget spent, half-landed, no envelope, undone after the emergency, blind — stays: it
describes the firmware or the sensing, and that is still true. With one lease at a time a live
registering lease is every lease, so the ordinary case does not change. § 3 keeps
`revokeEveryLease`.

**What identity does not close (residual C2).** A stale actor's restore — § 5's hand-back owed
to an ended lease's record, or the undo of an engagement that outlived its lease — can land after
a newer lease's engagement and before that lease registers the fan. On its first cycle the
newer record reads `.modeReclaimed` and re-asserts its own target: one false "Reclamation
detected" line and a false `isReclaimedBySystem`. The re-assert takes one cycle and fails safe,
and escalates to revoking the newer lease only if the firmware refuses three re-asserts, when the
blame on the system is true. The mark lasts one cycle too: the next readable cycle reads the
re-asserted target held and clears it, `.short` included, because the mark follows the primary
signal ([#366](https://github.com/blamechris/Aeolus/issues/366)). Until #366 only a cycle
converged on both signals cleared it, so it stood while the fan ramped, and indefinitely if the
fan could not reach the target. Blind cycles clear nothing, and after
`blindCyclesBeforeDivergence` of them blindness takes over.

**What the re-fetch rule has a test for, and what it does not (#365, #344).** Every re-fetch
after an `await` has a test that lands a registration under a newer lease in that suspension
and goes red when the re-fetch asks about presence rather than identity, except two. The
header of `ReclamationRefetchIdentityTests.swift` lists each re-fetch against its test: the
read, the lease hop (#344, held open by `ParkableHeldLeases`), the envelope read, the first
write, the command write, a refused command write and the reconnect. The terminal action's
envelope-failure branch has no re-fetch of its own and needs none: `finaliseRelease`'s entry
guard covers it, and `aTerminalActionEnteredForAnEndedLeaseLeavesTheNewerLeasesFanAlone` holds
that guard.

The first write is built rather than found, and the difference is stated where it is. The
engagement driver asks the real lease core about the old lease after its mode write, so a lease
that had really ended is refused there before § 5's re-fetch is reached. That write is therefore
tested with a newer lease that `ParkableHeldLeases.vouch(for:)` makes § 5's own role accept
while the old lease stays live in the core: the state the instant between the driver's last
answer and § 5 resuming leaves, which no seam holds open. The envelope read is tested both ways,
for the same reason. The identity re-fetch after the control-state read is caught one hop later
by the lease hop's, so only its log line tells it from a presence check. The lease hop's is
caught by `restoreAndForget`'s own identity check when the parked answer is `false`, so there
too only the log line tells them apart; when the parked answer is `true` nothing masks it, and a
presence-only re-fetch lets the stale examination judge the newer lease's record and spend its
registration grace, which the third case of
`aRecordChangedDuringTheLeaseCheckStopsTheExamination` catches on behaviour.

**The two without a test: the precedence check and the ledger hop in `diverged`.** They are
suspensions on `ThermalEmergencyLatch` and `ReclamationLedger`, which the actor holds as
concrete actors, so there is no double to park their answers in and a registration cannot be
landed in either by a suspending seam. Racing one in is #109's flakiness, and blocking a pool
thread to hold the hop open is what a CI runner stall fails. No earlier re-fetch can stand in
for them: a registration that lands before the latch hop is stopped by the lease hop's
re-fetch, and one in the latch or ledger hop is stopped only by these two. They are kept by the
rule alone until a role over each exists, as `HeldLeaseRole` is over the lease core. Presence
only at the first would let `markReclaimed` put a `.systemReclaimed` mark on a newer lease's fan;
at the second, the old lease's copy of the record would go on to book its attempt count onto the
newer lease's record, which can send that lease's first real divergence straight to the terminal
action. The re-assert itself is stopped before any write, by the envelope read's re-fetch.

## Judged against what the fan could have been holding

*Added by [#383](https://github.com/blamechris/Aeolus/issues/383); not relocated from a doc
comment. `HeldFan.judge(_:)` cites it, and ADR 0014's #383 amendment is the ruling.*

`examine(fanAt:)` reads a fan, then suspends on the lease check, and judges the reading only after
it. The record's target moves only on a report, and a report comes after its write, so the reading
and the record can describe different instants, in either order. *Forward:* the read samples the
fan before a same-lease step lands and the step's report arrives during the lease check, so an
ordinary 2,400 → 2,000 step read as `.targetDiverged`. *Reverse:* the step lands before the read
and its report arrives after the judgement, so the reading is newer than the record; § 5 marked the
fan and re-asserted the old target over the new one, and the report then made the next cycle
diverge too. A first step reported during an examination did the same, outside the registration
grace. A curve loop on the supervisor's 1 Hz cadence keeps its phase against § 5's sweep, so a
window one cycle falls into, every cycle can.

Nothing that sees only after-the-write reports can reach the reverse order: the reading is newer
than every report and every stamp, so something has to reach § 5 before the write. Level 6
therefore announces a step before it writes it, with `commandAnnounced(_:under:)`, which sets
`HeldFan.announced`, and still reports it after the write returns, with `commandedTarget(_:under:)`,
which closes it. The examination's stamp, `HeldFan.beginExamination(atGeneration:)`, records the
target last reported (`HeldFan.examinedCommanded`) beside #381's generation, before the read.
`HeldFan.holds(_:readFrom:)` asks whether a reading reads back either of the two, through
`primaryDivergence(of:against:)` per candidate so that there is no second tolerance rule, and
`judge(_:)` answers `.held` for a `.targetDiverged` reading that does, which the actor acts on by
doing nothing. An examination that began with nothing commanded judges no target, as a cycle with
nothing commanded judges none, and a judgement with no examination's stamp holds nothing.

| The step's write lands | Its report arrives | The read sees | § 5 judges it |
|---|---|---|---|
| Before the stamp | Before the stamp | The step | Held, against the record |
| After the read | During the examination | The old target | Held, against the stamp's target |
| Before the read | During the examination | The step | Held, against the record |
| Before the read | After the judgement | The step | Held, against the announced step, once until its report |
| Never: discarded | During the examination | The old target | Held this cycle; the next cycle diverges |
| Never: the write threw | Never | A system target equal to the step | Held once; diverges on every cycle after, until an announced step is reported |

**Why it does not reopen the contest #180 and #366 bounded.** Nothing but a `.targetDiverged` is
held: a reclaimed mode, an unreadable target and any other target diverge as before. As #383 first
wrote it, a held cycle was a converged one, and an announced step held a reading on every
examination until a report closed it. #390's review found what that left open: a step announced is
not a step landed, and one whose write threw stays announced until the next report, so where the
system held the fan at that step, most plausibly at the envelope's bounds, every cycle was excused,
the mark cleared and the terminal action never came. Two rules close it. **A held cycle concludes
nothing** (`Judgement.held`): no counter moves, no episode opens or closes, nothing is spent or
refilled, and the actor leaves the ledger's mark as it stands, so a held cycle can neither clear a
mark nor refill the budget. **An announcement holds one reading on credit**
(`HeldFan.announcementSpent`): holding a reading at the announced step spends it, and only a report
of that same step, within `targetToleranceRPM`, gives it back; a fresh announcement does not, and a
report of another target closes the announcement without giving it back. The target reported when
the examination began spends nothing: it was reported, so its write returned. A coincidence with a
step that never lands therefore postpones the terminal action by one cycle and never clears a mark,
however often the step is announced again, and a client stepping inside every examination while the
firmware discards every write still meets the terminal action when the budget runs out. An
announcement moves no registration generation, so it never stands a re-assert down; one that did
would let a loop announcing every cycle stand § 5 down on every one.

**Rejected,** each for a reason ADR 0014's #383 amendment gives in full. Reporting before the write
makes the record lead the firmware for the write's latency, and leaves a client write § 5's own
re-assert overwrote with nothing to correct it. Judging against the target captured with the read
covers the forward order only, and judged against the capture alone a step reported before the
read's sample reads as a reclamation. A report epoch that stands the judgement down covers the
forward order only, and a client reporting inside every examination then postpones the terminal
action indefinitely. A second-cycle confirmation is either the same contest or fires under a
phase-locked loop, and delays every genuine target reclamation by a cycle. A re-read before marking
shrinks the reverse window without closing it. The plane's own last-written target, returned with
the read in one scheduler turn, is exact, but it changes `FanControlState` and the read verb across
every conformer and fixes a design for E4's unbuilt write plane; it is kept for if a residual below
is observed, or A6 cannot announce. #390's review rejected three more, for reasons the same
amendment gives: ageing an announcement by one stamp, which every fresh announcement resets; a
withdrawal verb, which would rest § 5's bound on level 6 reaching it on every throwing and cancelled
path; and judging a held cycle's secondary signal against the target that held it, which keeps a
refill route open through whatever holds the reading.

What stays open:

1. Two steps of one fan completed inside one examination: the read can sample the first while the
   record holds the second and the stamp the one before both. It needs a client stepping faster
   than one examination's read and lease check, a few milliseconds, and the cost falls on that
   lease, in the safe direction: a false mark, an attempt, and at the budget the terminal action.
2. A write that was not announced is covered in the forward order and not the reverse. Only
   level 6 commands a fan under a lease while § 5 examines it, and ADR 0014 A6 item 3 binds it.
3. A step the firmware discards is held for the cycle its report lands in, and diverges on the
   next.
4. A system-written target within 1 RPM of the stamp's target, or of an announced step whose credit
   is unspent, is held for that cycle, and nothing is concluded from it: a mark already set stays
   set and the terminal action comes one cycle later. The announced step's case is the one a write
   that never lands can reach, at most once between confirming reports.
5. A report delayed past a whole sweep after its step landed, or a plane whose report differs from
   the target it was handed by more than 1 RPM, leaves the credit spent, so a later step read before
   its report is marked and re-asserted over, in the safe direction. The second rests on E4's plane
   returning the target it was handed, which `ScriptedControlPlane` does and E4's write plane is not
   yet built to do.
6. A write that lands and then throws leaves the fan at a target nothing reports. It is held once
   and then diverges: § 5 marks the fan, blames the system and re-asserts the record, which restores
   agreement within two cycles. The fault line misattributes Aeolus's own write, in the safe
   direction; E4's plane should throw only for a write that did not land.
7. A held cycle concludes nothing, so an episode stays open and marked while every examination reads
   a step not yet reported, as a ramp phase-locked to the sweep can, until the first cycle that
   reads the record. A false fault, in the safe direction.

`ReclamationJudgementViewTests` holds the actor's half, each step landed around a real read,
`ReclamationAnnouncementCreditTests` the announcement's credit and the held cycle at the actor, and
`ReclamationJudgementViewValueTests` the record's.

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
>   the registration grace (`HeldFan.judge(_:)` since #128) exists to bound, refillable on
>   demand by the very caller it is meant to bound.
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

*Added by #128's third pass; not relocated from a doc comment.* Two more were taken after that
note was written, and the first is the only split of this file to move state:

- **`Registry`, in `ReclamationRegistry.swift`**: `held`, `finalising` and `registrations`, and
  `givenUp` since #366, each `private` to it, and every synchronous decision over them as a named
  transition — `register`,
  `release`, `forget`, `beginFinalising`, `endFinalising`, `dropLease`, and the per-record
  `beginExamination` (#381's stamp, which carries #383's target), `command`, `announce` (#383),
  `recordReassertedTarget`, `resetReadFailures`,
  `recordReadFailure`, `judge`, `spendReassertAttempt` and `refundReassertAttempt` — and the
  queries over them, among them #381's re-fetch `reassertTarget`. The actor holds one, `private`,
  and reaches it only through those members. It widens no state, because the state moved inside a
  value rather than being reached from another file: a `Registry` constructed anywhere else
  governs nothing.
- **`HeldFan.judge(_:)`**, in `ReclamationHeldFan.swift`: what were `gracedBeforeItsFirstCommand`
  and `reportShortfall`, and the converged branch's reset, as one mutating method on the record.
  The actor acts on its answer.

What keeps that safe is held by `ReclamationWatchdogAccessTests` and
`ReclamationRegistryAccessTests` rather than by this paragraph: the actor's state stays private
and its internal surface is exactly what it was; its internal properties, and the registry's,
are get-only views; no other file reaches the registry by a `typealias` or a dotted extension;
no declaration binds two names past the scan; the registry's
stores stay private and are exactly the acknowledged four (#366 added `givenUp`); nothing in
`ReclamationRegistry.swift` is `async` or `await`s, because the compiler refuses a mutating
`async` call on an actor's stored struct and
not a non-mutating one, which would answer from a stale copy; no registry method takes a
closure, because one that reaches the actor's `registry` while a transition is mutating it traps
at run time; and the actor never uses `registry` as a whole value, because a copy taken before an
`await` and written back after it loses every transition in between.

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

`HeldFan.judge(_:)`'s registration grace closes that window — #147's second remedy,
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

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`, which is
`HeldFan.judge(_:)`'s since #128's third pass.*

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

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`, which is
`HeldFan.judge(_:)`'s since #128's third pass.*

This file's rule is that over-firing is the safe direction: handing a fan back to
Apple's thermal management costs cooling nobody chose, while under-firing leaves a
fan pinned at a speed nothing honours, which is `CLAUDE.md` rule 6. **On a fan with
no commanded target there is no such speed.** Nothing Aeolus picked is on the wire,
so the pinned-fan hazard the asymmetry is built around does not exist, and what
over-firing costs instead is the whole-machine revocation above — losing control that
is in fact still held, which is rule 6 in the direction people forget.
`HeldFan.judge(_:)`'s `.short` answer declines the terminal action on the same grounds.

So the tolerance is granted **only while `commanded` is `nil`**. The first
`commandedTarget(_:)` ends it for the rest of that registration, and a commanded fan
is judged exactly as strictly as before — including on the very next cycle.

## Bounded by `blindCyclesBeforeDivergence`, and not by a fourth constant

*From the doc comment of `gracedBeforeItsFirstCommand(_:of:fanAt:)`, which is
`HeldFan.judge(_:)`'s since #128's third pass.*

The same number, because it is the same question: how many 1 Hz cycles may pass
without this mechanism being able to confirm a fan is ours before that becomes
divergence. Three cycles is three seconds — long against any plausible firmware
read-back lag and short against anything a user would notice — and a genuine
reclamation of an uncommanded fan is still restored and reported, just on the third
cycle rather than the first. `ReclamationLimitsTests` already holds that constant
under a literal ceiling, so this window cannot be widened into minutes either.

## Why this no longer reaches the terminal action

*From the doc comment of `reportShortfall(_:fanAt:)`, which is `HeldFan.judge(_:)`'s since
#128's third pass.*

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
`revokeLease(id:forFan:because:)` since #353 — which restores through
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

**A lease another teardown took first, since
[#368](https://github.com/blamechris/Aeolus/issues/368).** A teardown — the TTL sweep, or the
holder's connection dying — that reaches `LeaseAuthority` after the hand-back has returned but
before `revokeLease` runs takes the table entry itself, so the revocation finds nothing. Until #368
it returned at once, the `defer` closed the window, and the teardown's own notice, still on its way
through `HelperFanRestorer`, cleared the mark: reproduced under load at 4–6 marks in 1,200 runs, 5–9
in 2,000 and 15 in 1,200, about 2.5–12.5 per 1,000, and never in 1,200 run alone.
`revokeLease(id:forFan:because:)` now answers `.gone` only once `releasing` no longer holds the fan,
and the restorer delivers its notices before it returns, so the notice lands while `finalising`
holds the fan and skips its clear. `TerminalActionTeardownRaceTests` parks the teardown between the
lease core and the restorer and lands it between the hand-back and the revocation;
handback-ledger.md § *"Outwaiting another path's handback"* has why the drain is that teardown's
while its handback is under way, and the two routes by which it is a later handback's instead — a
newer lease's release, or a sweep of a fan whose restore was refused — with a mark kept rather than
lost ([#377](https://github.com/blamechris/Aeolus/issues/377)).

**A lease that ended before the revocation, since #353.** `revokeLease(id:forFan:because:)` then
revokes nothing and sends no release notice of its own, so the mark is kept with nothing to clear it
on the way out; the release that ended the lease sent its notice while `finalising` held the fan,
and that notice skipped its clear as any other during the call does.
`FinaliseReleaseLedgerTests.theTerminalActionRevokesOnlyTheLeaseItHeldTheFanFor` releases and
re-grants inside the hand-back.

**A lease that lapsed during the call and is still unswept, since #361's panel.** `revokeLease`
used to decline such a lease, `finalising` closed, and the TTL sweep then ended it and its notice
cleared the mark — #346's defect again, which `main` never had because `revokeEveryLease`'s
`removeAll()` took lapsed entries too. `revokeLease` now ends a lapsed lease still in the table
inside the call, as `.leaseExpired`, so its notice lands while `finalising` holds the fan.
`FinaliseReleaseLedgerTests.aLeaseLapsingDuringTheHandBackKeepsTheMarkThroughItsExpiry` lapses
the lease inside the hand-back. That is all #361 closes here; a lapsed lease the supervisor
sweeps in the tail between the hand-back and the revocation is the case the #368 paragraph above
closes.

**What still clears it, so it is not frozen.** An accepted `manualControlEngaged(_:under:)`
clears, because an engagement is a statement about the world. #346 pinned that it also clears
during the call (`anEngagementDuringTheHandBackStillClears`); #361 reversed that for a
registration under the lease the call is giving up, which is now refused and keeps the mark, and
#366 kept it refused after the call returns —
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
