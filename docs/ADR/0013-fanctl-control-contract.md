# ADR 0013 — `fanctl`'s control contract

- **Status:** Proposed
- **Date:** 2026-10-07
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (amends [#15](https://github.com/blamechris/Aeolus/issues/15)'s
  `auto [<fan>]` checkbox; extends [ADR 0011](0011-reconciliation-and-foreign-manual-control.md)'s
  asymmetry between moving toward and away from automatic control)

## Context

`fanctl` gains its first commands that move fans, and the question each one answers is the same:
what may a command-line process promise, to a script or to a person on an SSH session who cannot
see the machine?

Three facts frame it.

- **A manual hold is a lease.** `docs/SAFETY.md` makes manual control something a client keeps
  proving it still wants, and the helper ends it when it stops. A lease is no route back for a
  fan that has to be returned: it is granted only over a fan that is already automatic, and
  refused over one that is not.
- **Returning to automatic is the one request that is always valid.** `restoreAllToAutomatic` is
  exempt from the version handshake, consumes no bounds, clamp or sensor reading, and is safe to
  send at any time ([SAFETY.md § 7](../SAFETY.md#7-panic-path)). `fanctl reset --all` already
  sends it and reports what the helper *accepted*.
- **The snapshot can be wrong in one direction.** The helper reports a fan whose `F<n>Md` it could
  not read as `automatic`, because protocol version 1 has no way to say "not known"
  ([#178](https://github.com/blamechris/Aeolus/issues/178)), and on Intel the register does not
  exist, so every fan reads `automatic`. The field that does say "the helper has not cleared this
  fan" is `manualControlAvailability`, and the helper restates its reasons with no guard on the
  mode. So a fan can read `automatic` and carry `restoreToAutomaticFailed`, `handbackUnconfirmed`
  or `supervisorBlind` in the same snapshot.

`reset --all` answers "did the helper take the request". Nobody has yet answered "is it done", and
the obvious ways to build that answer each import a failure.

## Decision

### D2 — `auto` is machine-wide, never takes a lease, and sends at most one restore

`fanctl auto` (and `fanctl auto all`, the same command) asks the helper to return every fan to
automatic control and then checks what the helper reports.

1. **Sequence.** Handshake, then one snapshot. With no lease and every fan **cleared** (D3) it
   exits 0 having written nothing. Otherwise it sends `restoreAllToAutomatic` **once** and reads
   the snapshot every second for up to ten seconds, on `ContinuousClock`, until it reports no
   lease and every fan cleared. A fan the helper has not cleared is a reason to send the request
   whatever its mode reads: the request carries the `restoreAbandoned` sweep, which is a
   stranded fan's only route out ([#189](https://github.com/blamechris/Aeolus/issues/189)).
   **If the handshake succeeded and the first snapshot did not**, it sends the one request
   anyway and then reads again: the helper is identified and its state is inconsistent, which is
   what SAFETY.md § 7 says the panic verb must serve. If the snapshots keep failing it exits 8
   and names `fanctl reset --all`.
2. **At most one restore per run.** It is never re-sent, whatever the reply was and however the
   wait ends. Another writer on the same fans would otherwise be answered with a second write, and
   then a third: the standing fight [ADR 0011](0011-reconciliation-and-foreign-manual-control.md)
   D2 declines.
3. **It never acquires a lease.** Not to make a per-fan form possible and not briefly.
4. **It may end any Aeolus client's lease, and names the holder.** Commands that move *toward* the
   safe state may override another client; commands that move *away* from it may not (`set` gets
   exit 5). Refusing would fail exactly when a hold was orphaned or forgotten, which is when
   someone runs this. The client whose lease ended sees its lease lost, which is accurate. The
   output says only what it observed — the lease listed before the request is no longer listed —
   because it may also have expired inside the window.
5. **A fan pinned by another program is reported, and `auto` exits non-zero.** It is never
   touched beyond the single restore; what that request reaches is the helper's decision, and
   `auto` inherits any change to it with no CLI change.
6. **No index.** `fanctl auto <index>` exits 64. No request the helper accepts returns one fan on
   behalf of another process, so an index would either do nothing or quietly return other fans
   too. A per-fan form can be added later without breaking anyone; the reverse cannot.

The check that decides the ending — **0, 8 or 9 from a snapshot sequence** — is one function
(`SafeState`), shared with `fanctl set` when it ends. `auto` adds exit 5 on top of it, because a
lease present at the end is worth naming; `set` maps that case as its own contract says.

### D3 — exit 0 means "the helper reports", and 9 means "waiting will not help"

Exit 0 means **the helper reports every fan cleared and no lease**. It does not mean the fans are
automatic: the helper reports an unreadable mode as automatic (#178). Every string `auto` prints
for a confirmation names the helper as its source and the time it captured the snapshot, and no
run that did not end in the safe state says it did on either stream.

**A fan is cleared when its mode reads automatic and its availability does not say otherwise.**
The availability is read for every fan, whatever its mode, and each reason is classified once, in
one exhaustive switch (`SafeState.clearance(of:)`) with no `default:` arm, so a reason added to
the vocabulary is a compile error until it has been decided:

| Class | Reasons | Effect |
|---|---|---|
| **Durable** | `foreignManualControl`, `restoreToAutomaticFailed` | **9**, whatever the mode reads. Waiting will not change it: nothing in Aeolus put the first there, and the firmware refused every attempt at the second. |
| **Pending** | `releaseInProgress`, `handbackUnconfirmed`, `restoreToAutomaticUnconfirmed`, `supervisorBlind`, `systemSleeping`, `unknown(_)` | **8**, whatever the mode reads: the helper has not established the fan's mode, or a restore is outstanding. Keep waiting. |
| **Silent** | `writePathNotBuilt`, `boundsImplausible`, `leaseHeldByAnotherClient`, `selfRenewalNotBuilt`, `noThermalTelemetry`, `reclaimedBySystem` | The mode decides: automatic is cleared, anything else is 8. These are about manual control being *granted*, not about the fan. `writePathNotBuilt` is every fan on today's helper, and `auto` against it still exits 0; a lease is judged from `activeLease`, not from `leaseHeldByAnotherClient`. |

`.available` is silent. A fan whose mode reads manual is 8 unless its reason is durable.

**`supervisorBlind` is 8, not 9.** 9 asserts the fan is still held in a way retrying cannot
change. A blind fan's state is *unknown*, not manual — reconciliation can leave it blind for the
life of the process, but that is the helper not having looked, and the answer is the one 8
carries: the reason, its advice, and the helper restart that advice leads to.

A new code, **9, `cannotReturnToAutomatic`**: the helper reports a durable reason for a fan,
**whatever mode the fan reads**. That is the opposite of what 8 ("not yet") tells a script to do,
which is why it is its own number. The message carries the reason, its own summary and advice,
the mode the fan reads, and the `docs/RECOVERY.md` step.

| Code | Meaning for `auto` |
|---|---|
| 0 | The helper reports every fan cleared and no lease |
| 9 | A fan carries a durable reason (`foreignManualControl`, `restoreToAutomaticFailed`) |
| 5 | A lease is listed when the window ends |
| 8 | Not confirmed within the window, a pending reason, or the helper stopped answering after the request, or no snapshot could be read after a handshake |
| 3 | Helper unreachable |
| 7 | Version mismatch. The exempt restore is still sent once; the result cannot be verified across versions |
| 64 | Usage |

Precedence when several apply: **9, then 5, then 8.** 9 is judged at the end of the window rather
than on first sight, because a fan mid-handback can carry a transient reason that clears.

`--json` carries `capturedAt`, as `status --json` does, and `snapshotFollowsRestore`: whether
`fans` and `lease` were read after the request was sent, so a script need not parse prose to know
whether the document describes the helper before the request or after it.

### D1 — `set` is a bounded hold for the life of the process (decided; lands with #317)

Recorded here so the three decisions read as one contract. Nothing in this ADR's change
implements it.

`fanctl set` requires `--for`, from 10 seconds to 8 hours, and holds its lease for that long,
renewing it for the life of the process **and its parent**. It exits 6 on any loss the helper
reports: a renewal error, a snapshot without its lease ID, a covered fan reclaimed by the system,
or a thermal emergency. It never retries and never re-acquires. When it ends it releases and runs
D2's safe-state check. The reasoning and the output contract are
[#317](https://github.com/blamechris/Aeolus/issues/317)'s.

## Rationale

The cheapest correct answer to "make it automatic" is the one `reset --all` already sends. What
this ADR adds is not a new capability — `auto` can do nothing `reset --all` cannot — but an
*observation*, and the discipline to report only what was observed.

The asymmetry in D2.4 is what makes the command usable. A hold that cannot be dropped by the
person who needs the fans cool is not a safety feature; it is the failure SAFETY.md § 7 exists to
prevent. Overriding another client's lease costs that client its hold, which it is told about, and
which the lease's own expiry would have cost it anyway.

## Alternatives considered

### Per-fan: acquire a lease, apply `.automatic`, release

Rejected. It reaches only fans that are already automatic: a manual fan with no lease is refused
at acquire (`foreignManualControl`, `restoreToAutomatic{Unconfirmed,Failed}`,
`handbackUnconfirmed`, `releaseInProgress`), and a fan under another lease answers 5. Releasing an
automatic fan then writes a restore to every fan the lease covered, which can push it into
`restoreToAutomaticUnconfirmed` or the terminal `restoreToAutomaticFailed`. It is a command that
works exactly when it is not needed.

**Revisit if** the protocol gains a verb that returns one fan on behalf of another process.

### `auto <index>`

Rejected for now, by D2.6. **Revisit if** a per-fan verb exists on the wire; the exit-64 refusal
is what keeps that change compatible.

### Refuse with exit 5 when another client holds a lease

Rejected. `auto` would fail when a hold was orphaned or forgotten, and succeed only when no one
needed it. [SAFETY.md § 7](../SAFETY.md#7-panic-path) and the asymmetry in ADR 0011 D1 both put the
direction on the side of moving toward automatic control.

### Re-send the restore until the helper confirms

Rejected, by D2.2. A write repeated against a live writer is a fight, and the fight is over the
machine's cooling.

### Exit 0 on the mode alone

Rejected, and it was the first version. The mode is `automatic` for a fan nobody has read (#178)
and for every fan on Intel, while the availability says what the helper has not cleared; reading
the mode alone exits 0 about such a fan, and on the first snapshot sends no restore, which is
that fan's only route out. D3 reads both.

### Exit 0 only when the mode was actually read

Only partly buildable. The wire cannot say "not known" about a mode until #178 lands, but it does
say it about the fan in two places: `supervisorBlind` ("cannot read this fan's control state") and
the other pending reasons, which D3 reads. What remains unbuildable is a fan whose mode could not
be read with *no* reason beside it. **Revisit when** #178 changes the snapshot: exit 0 can then
be strengthened, and a fan whose mode could not be read can be given its own outcome.

### `supervisorBlind` as 9

Rejected. It can last the life of the process, but 9 asserts the fan is held in a way retrying
cannot change, and a blind fan's state is unknown. 8 with the reason, its advice and the restart
is the honest answer. **Revisit if** the helper gains a way to tell "blind for a moment" from
"blind until restart"; the latter might deserve 9.

### One code (8) for everything unconfirmed

Rejected. A script retries on 8. Retrying a fan that another program holds, or that the firmware
refused, is a loop that changes nothing; 9 is how a script learns to stop.

### A longer or open-ended window

Rejected. A command that waits for a helper which may never answer is one a caller has to
time-box from outside. Ten seconds covers the restore's expected latency. **Revisit when** E4
hardware rows measure the restore's real latency.

## Consequences

- **`reset --all` is unchanged**, including its exit codes (0 or 1) and its refusal to say the
  fans are restored. `auto` sends the same verb and then verifies; it adds no capability.
- **The client whose lease the request drops sees exit 6**, in `set`'s terms. That is accurate,
  and the holder's name is on the terminal of whoever sent the request.
- **A restore that lands late is reported as 8**, with the one request already sent. A script that
  wants to wait longer polls `fanctl status`.
- **`auto` and `set` cannot disagree about "confirmed"**, because there is one function.
- `AeolusXPCVersion` does not move, and nothing in `Sources/AeolusHelper` or `SMCCore` changes.
- Exit-code 9 is a public number from this ADR on, and is never reused.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| The helper ends every lease and attempts every fan it is accountable for when it takes `restoreAllToAutomatic` | `LeaseAuthority.releaseEveryLease` and SAFETY.md § 7, as built | `auto` reports what is left, as 5, 8 or 9. No CLI change. |
| Ten seconds covers the restore's visible latency | Not measured. No restore has been performed on hardware | Raise the window, or `auto` reports 8 for a restore that was working. |
| `foreignManualControl` and `restoreToAutomaticFailed` are the only durable reasons, and the pending and silent classes above are right | `ManualControlAvailability`'s own documentation, and the maintainer's ruling on review of #321 | A new reason is a compile error in `SafeState.clearance(of:)`, and has to be decided there. |
| The helper's `mode`, read beside the availability, is the best statement of a fan's state | `mode` alone is not (#178); the availability is the other field | #178 gives the wire a way to say "not known", and exit 0 is strengthened. |
| A snapshot that fails after a successful handshake is the helper's state being inconsistent, and the request is safe to send | SAFETY.md § 7; the request needs no snapshot | `auto` would send a request the helper cannot act on, and exit 8. |
| A snapshot that is never answered discards its connection, and with it the evidence that the handshake succeeded | `HelperClient.translate` (`helperNeverAnswered`) | That case sends nothing and exits 1, naming `fanctl reset --all`. Unchanged unless the client keeps the evidence. |
| Another client's lease may be ended by a command moving toward automatic | The maintainer's decision, D2.4 | `auto` would refuse with 5 and fail when a hold was orphaned. |

Every observation cited is from `Mac16,5` on macOS 26.6.2, and none of it is a fan write: no
restore has been sent to hardware by this command. Intel and M1/M2 are `untested`.
