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

New behaviour for #9's A4 and A6 belongs in the `EngagementDriver` that
[ADR 0014](../ADR/0014-apple-silicon-unlock.md) specifies, and in value types beside `HeldFan`
— `HeldFan` is the pattern, a type that holds no state of the actor's and so can live in its
own file — and not in this actor's body, which should keep only what has to touch `held`.

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
by awaiting `LeaseAuthority.revokeEveryLease(because:)`, which restores through
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
`revokeEveryLease(because:)` runs takes the table entry itself, so the revocation finds nothing
and returns at once. The teardown's own release notice is then still on its way through
`HelperFanRestorer`, can arrive after the `defer` has closed the window, and clears the mark.
That is derived from the code, not reproduced: no seam lands a teardown in that gap.

**What still clears it, so it is not frozen.** `manualControlEngaged(_:)` clears
unconditionally, during the call as at any other time, because an engagement is a statement
about the world (`anEngagementDuringTheHandBackStillClears`). The guard is per fan, so the
revocation's notice still clears any other fan's mark the revoked lease covered
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
