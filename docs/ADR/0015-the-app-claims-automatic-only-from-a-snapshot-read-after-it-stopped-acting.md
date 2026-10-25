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

**D2 — The mechanism.** The driver mints the floor, from #479's ticket epoch, inside
`transition(to:)`, the one place every state change passes through. The states that set it are
chosen by an exhaustive switch. The floor is published atomically with the state
(`LeaseDriverReport`). The snapshot source carries each reply's ticket to `Authority.fresh` and
`PollingViewModel`. The presentation compares the two. Nothing crosses the wire.

**D3 — Until D2 lands**, `released`, `lost` and `refused` never read Automatic, and `idle`
requires no lease listed. This fails closed on any helper.

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

## Assumptions

- A read sent on one connection after the reply to a release on another is processed by the
  helper after the release completed.
- A snapshot that lists no lease means the helper writes under none of the app's leases.
- There is at most one lease per machine.

**Revisit when** the protocol is bumped and can carry a helper-minted generation; when the
helper's lease-gated write proves leaky; or when PR 8 needs Automatic for a fan the app's own
held lease does not cover, which may relax the no-lease condition to "the listed lease is the
driver's own and does not cover this fan".
