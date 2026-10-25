# ADR 0015 — The app claims Automatic only from a snapshot read after it stopped acting

- **Status:** Proposed
- **Date:** 2026-10-24
- **Deciders:** Project maintainer
- **Supersedes:** —

## Context

#497 gives the app its first control: Auto, 50, 75 and 100 % for every fan. Its selection is a
function of the lease driver's state and the snapshot on screen. Two review rounds each found a
path that drew **Auto selected** after a lease ended while the helper could still hold the fans.

Three facts make "Automatic" different from every other claim the control makes:

1. **Its evidence is an absence.** Custom is backed by the snapshot listing *this* lease's
   identifier with a held target, which a snapshot from before the grant cannot do. Automatic is
   backed by "no lease, fan cleared", which looks the same before the grant and after the release.
2. **A successful release does not say the fans are automatic.** `LeaseAuthority.releaseLease`
   removes the lease and awaits a restore that does not throw. A handback the firmware refuses is
   recorded and reported only in later snapshots, as `.restoreToAutomaticFailed`. The reply means
   "accepted", not "done", as ADR 0013 says of `restoreAllToAutomatic`.
3. **A recent snapshot that lists a lease is not evidence either.** A fan under a live lease whose
   `apply` has not landed reads `.available` and automatic, because the helper cannot state
   `.leaseHeldByAnotherClient` per fan.

ADR 0013 already defines "back to automatic" for `fanctl auto`: a snapshot read after the
request, with no lease and every fan cleared (`SafeState.verdict`).

## Decision

**D1 — The rule.** A fan reads Automatic only when the driver holds nothing and is not acquiring
or releasing; a licensed snapshot is on screen whose read began after the driver last entered
`released`, `lost` or `refused`; that snapshot lists no lease; and it reports the fan
`isClearedToAutomatic`. `idle` sets no read-timing floor.

*As built (#498):* the read must also begin after every `apply` the driver sent has answered.
While one is unanswered, no snapshot is evidence (D2's "the floor waits for every `apply`").

**D2 — The mechanism.** The driver mints the floor, from #479's ticket epoch, inside
`transition(to:)`, the one place every state change passes through. The states that set it are
chosen by an exhaustive switch. The floor is published atomically with the state
(`LeaseDriverReport`). The snapshot source carries each reply's ticket to `Authority.fresh` and
`PollingViewModel`. The presentation compares the two. Nothing crosses the wire.

As built (#498), the report's evidence (`LeaseDriverReport.AutomaticEvidence`) has three values
rather than an optional floor, because of the case below:

- `anyRead` while the driver has never acted (`idle`);
- `readFrom(ticket)`, a read ticketed at or after the floor;
- `noRead`, when the driver stopped acting while an `apply` it sent was still unanswered.

**The floor waits for every `apply` to answer.** Auto during an `apply` releases at once and
leaves the `apply` to answer (#419), so the driver can be `released` with that `apply` still at
the helper.

On the write plane, such an `apply` can land one write after the release's restore. It is never
a mode write: an engagement step admitted after a restore was requested is refused by the step
ticket (`PlaneWriteLedger.admitStep`). It can be a target write. `LeaseApplier.step` asks the
lease (`EngagementDriver.requireEntitlement`) and then awaits the target write, and
`PlaneWriteLedger.admitCommand()` refuses a target command only once the plane is sealed for exit.
That write is `F<n>Tg` on an automatic fan. ADR 0014's ticket-and-seal amendment calls it
"reported harmless on Apple Silicon, and untested on Intel" (its "Commands" bullet).

This is not a helper defect: every ordinary restore accepts it by design. It is a hardware claim
nobody has observed. So the app does not take the claim on trust where it can wait instead: a stop
with an `apply` unanswered publishes `noRead`, and the floor is minted when the last `apply`
answers, as a new report with the state unchanged. That puts the evidence's read after the write,
and it covers no more than that. If firmware honoured a `Tg` written to a fan it still reports
automatic and cleared, no read would show it, and the claim would still be wrong; only the
hardware can settle that. The `apply` is counted from the turn that schedules it, not from when its task
starts.

`LeaseStateModel` follows `reportUpdates()`; `stateUpdates()` stays, for consumers that need the
state alone. Each new floor asks the source to read soon (`HelperSnapshotSource.readSoon()`): an
ordinary pause is cut by the path a settled interval change takes, a request in flight is left
alone and the pause after it skipped once, and a backoff and the interval's debounce are left as
they were. So the user's own Auto reads selected within about one round trip, when no `apply` is
unanswered and the read connection is not backing off: while an `apply` is unanswered nothing is
evidence until it answers, up to its deadline, and a backoff's pause runs out first.

**D3 — Until D2 lands**, `released`, `lost` and `refused` never read Automatic, and `idle`
requires no lease listed. This fails closed on any helper. *(Replaced by D2 in #498.)*

**D4 — One definition.** "Nothing leased and fan cleared" is one predicate, shared by
`SafeState` and the app.

**D5 — A fan the driver's held lease does not cover (#154, PR 8; amendment 2026-10-25).** While
the driver is `held` over fans F, a fan f outside F reads Automatic only when: (1) a licensed
snapshot is on screen that lists exactly the driver's held lease, compared by identifier, and
reports no thermal emergency (`controlLoss(leaseID:covering: [])` is `nil`); (2) that read's
ticket is admitted by the driver's evidence; and (3) the snapshot reports f
`isClearedToAutomatic`. Conditions 1 and 3 are one predicate beside D4's,
`SystemSnapshot.showsAutomatic(_:besideLease:covering:)`, which also refuses any fan in
`covering`. In `acquiring` and `releasing`, a fan outside the request still reads `.unknown`. D1 is
unchanged for a driver that holds nothing.

**The floor marks the driver's last let-go, not only its last stop.** D2 gains a mint site: when a
release answers ahead of an acquisition (a change of which fans are held), the driver mints a
floor, or publishes `noRead` while an `apply` is unanswered, before it starts the acquisition. The
floor that waits for applies is minted when the last one answers in any state. Every fan outside
the held lease either was never under one of this driver's leases since the last mint, or left
coverage at a release that answered at or before it. So one driver-wide floor at the latest
let-go admits only reads taken after every uncovered fan's last handback and after every `apply`
then unanswered had answered. It may also wait for the new lease's first `apply`, which cannot
write f; that is accepted as failing closed.

*Identity.* A listed lease that is the driver's own was granted over exactly `HeldLease.fans`.
`LeaseAuthority` stores the request's indices, and `LeaseRecord.fanIndices` is a `let`. Level 6
refuses an `apply` naming a fan its lease does not cover (`LeaseApplyRules.goals`,
`Detail.uncovered`). So no write under that lease reaches f, and the listing proves the read was
served after the grant, when the table held no other lease. A snapshot listing no lease beside a
held one predates the grant or shows a loss not yet judged. One listing another lease is the
affordance's rule 4. Neither is evidence about f. *No emergency:* between § 3 firing and its
revocation the lease is still listed, and § 3, not Apple's management, decides what f does. *Read
timing:* fact 1 holds for f as for every fan, and an `apply` under the lease that last covered f
can land one `F<n>Tg` on it after its restore (D2). *Clearance:* a fan whose handback is in flight
reads `.releaseInProgress`, and a refused or unconfirmed one reads `.restoreToAutomaticFailed` or
`.handbackUnconfirmed`; none is cleared.

## Rationale

Deciding by driver state asks which paths could have produced a state. The paths multiply, and
the question can never be closed. Deciding by read timing asks whether the evidence on screen
was read after the event it is about. That question has one answer, minted in one place. The
no-lease condition covers what read timing cannot: a lease the helper may still hold after an
unconfirmed release, an unanswered acquire, or a loss.

## Alternatives considered

### A driver taint: remember an unconfirmed release until the next grant

Rejected. Every present and future path into `released` must consult it. It cannot fix a
confirmed release whose handback the firmware refused. And `refused`, while tainted, either
hides the new refusal's reason or claims Automatic.

### Withdraw every claim on screen when the driver stops acting

Rejected. It is sound, but it blanks every row's mode and the emergency banner on each Auto
click, and it makes the snapshot source depend on the lease state.

### A helper-minted lease-table generation in `SystemSnapshot`

Rejected for now. It puts the read timing in the content and makes the helper the single
authority, but it changes the XPC shape and bumps the version for a claim the client can make
soundly with tickets.

### Trust a successful release

Rejected: the reply does not report the handback's outcome.

### Trust the helper's lease-gated write: mint the floor when the driver stops, whatever is in flight

Rejected for now. An `apply` in flight under a released lease cannot move a fan's mode, but it can
still land a target write after the restore, and that write is harmless only by a hardware claim
nobody has observed: ADR 0014 calls it reported harmless on Apple Silicon and untested on Intel.
Waiting for every `apply` to answer costs at most an `apply`'s deadline of Auto shown unselected,
and it fails closed.

### For D5 (#154, PR 8)

- Keep D1, never Automatic beside a held lease: sound, but the commonest per-fan state then never
  shows the Auto fans' selection; reverting D5 means deleting one arm.
- A floor per fan, with apply counts per fan: rejected, per-fan state to save at most one apply's
  duration in a rare ordering.
- Trust the listing alone: rejected on D2's grounds.
- Narrow the lease instead of releasing it: not expressible (`LeaseRecord.fanIndices` is a `let`;
  an apply naming fewer fans leaves the omitted ones held).

## Assumptions

- A read sent on one connection after the reply to a release on another is processed by the
  helper after the release completed. The same is assumed of a read sent after an `apply`'s
  answer.
- A snapshot that lists no lease, read after every `apply` the app sent has answered, means the
  helper writes under none of the app's leases.
- An `apply` the client stopped waiting for at its deadline counts as answered. The basis is the
  same as for a release: the step ticket refuses any engagement after the restore, and ADR 0014
  reports a later target write harmless. The seal refuses every forward write once the exit
  begins, but an ordinary deadline cut-off involves no exit, so the seal adds nothing there.
  The cut-off discards the connection, and the helper's `connectionDidInvalidate` ends its leases
  and restores the fans the same way a release does. That ending is not itself proof that the
  `apply` stopped writing.
- There is at most one lease per machine.
- **A relaunch starts `idle`.** A new process starts a new driver, which has never acted and sets
  no floor. While the helper still lists the old process's lease, the no-lease condition refuses
  Automatic. Once the helper drops it, the claim rests on the lease's absence and the fan's
  clearance alone, read at any time. That is D1's "`idle` sets no floor", accepted: the old
  process's applies are not this driver's to wait for, and the helper ends a connection's leases
  when the connection goes.
- **U7 (ADR 0014): `Ftst = 1` does not change the behaviour of a fan Aeolus did not engage.**
  Unobserved; only `Mac16,5` can test it. D5 is true on M3+ only if it holds. If run 1 contradicts
  it, ADR 0014 makes engagement all-fans-or-nothing, and the helper must refuse a lease that does
  not cover every fan, which makes D5 unreachable. Until that refusal exists, D5 reverts to
  `.unknown`. On M1/M2 and Intel, the independence of `F<n>Md` and of `FS!` bit *n* is documented
  and untested.
- D5 does not rely on the helper's sequencer ordering a grant after earlier applies on the same
  connection; the read timing is the driver's.

**Revisit when** the protocol is bumped and can carry a helper-minted generation; when the
helper's lease-gated write proves leaky; when a target write on an automatic fan is observed
harmless on hardware, or `admitCommand` refuses after an ordinary restore, so the floor need not
wait for applies; or when PR 8 needs Automatic for a fan the app's own held lease does not cover —
done, D5. Revisit D5 when U7 is observed either way, when a lease-narrowing verb exists, or when
the observed gap makes floors per fan worth their state.
