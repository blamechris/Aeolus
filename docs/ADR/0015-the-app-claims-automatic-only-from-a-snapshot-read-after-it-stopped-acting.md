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

**Revisit when** the protocol is bumped and can carry a helper-minted generation; when the
helper's lease-gated write proves leaky; when a target write on an automatic fan is observed
harmless on hardware, or `admitCommand` refuses after an ordinary restore, so the floor need not
wait for applies; or when PR 8 needs
Automatic for a fan the app's own held lease does not cover, which may relax the no-lease
condition to "the listed lease is the driver's own and does not cover this fan".
