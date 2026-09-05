# ADR 0006 — One continuous SMC reader: snapshot authority follows the helper

- **Status:** Proposed
- **Date:** 2026-08-01
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0005](0005-xpc-authorisation.md)'s E2/E5 seam)

## Context

E7 gave the app a direct, unprivileged SMC polling stack, because no helper existed and the `Monitor`
configuration never ships one. [#72](https://github.com/blamechris/Aeolus/issues/72) gives the root
helper its own SMC read path so it can serve `snapshot`.

Left unmanaged, that is **two independent continuous readers of the same firmware**: rendered state
composited from two sources on two clocks, and — once E4 exists — an unprivileged process issuing
IOKit calls into the SMC while the helper is mid-`Ftst` negotiation. Nothing in
[SMC-RESEARCH.md](../SMC-RESEARCH.md)'s observed section covers that interaction.

[CLAUDE.md](../../CLAUDE.md) rules 6 (never claim control you do not have) and 7 (the helper is the
authority) both bear on this. Multi-process read contention has been observed on the development
machine, but it is a secondary motivation, not the deciding one.

## Decision

**The app renders exclusively from helper snapshots whenever a handshaken helper connection is
healthy, and stops its own SMC polling entirely while it does.**

Direct reads are the fallback, never a parallel channel:

- `Monitor` builds, always — they ship no helper (`HelperBundleLayout` reports `.absent`).
- `Full` builds, only while the helper is absent, unapproved, refused, version-mismatched, or
  unreachable.

The invariant, stated so it survives every combination:

> A **control claim** — mode, target, lease, reclamation, availability, thermal emergency — may be
> rendered only from a helper snapshot within its staleness bound. Every other source, and every
> staleness overrun, renders the claim as **unknown** — never as last-known helper state, and never
> as a synthesised safe value.
>
> **Observations** — RPM, temperature — may come from either source, but are labelled with their
> provenance and capture time, and are never mixed with control claims from a different generation.
>
> Corollary: **at most one continuous SMC poller exists per machine** — the helper when present and
> healthy, the app only otherwise.

`fanctl` read commands stay direct-read in both provenances. A Homebrew-built `fanctl` can never pass
the signing requirement, and the two builds must not behave differently; transient, user-invoked
reads are the accepted exception to the corollary.

## Alternatives considered

### The app always reads directly; the helper is used only for control

Keeps the helper dormant during pure monitoring — a real benefit, and the strongest argument against
the decision above: **a root process that is not running is the smallest attack surface there is.**
It also needs no source-switching seam, no staleness bound, and no fallback policy: one code path,
always on, already shipped and tested in E7.

Rejected because it makes every fan row a composite of two sources on two clocks the moment E5
exists — RPM from the app's own read at one instant, mode/target/lease over XPC from another —
turning rule 6 from a structural property into a per-view discipline that must be re-argued in every
PR that touches a view. It also leaves an independent reader active during the M3+ unlock sequence,
whose sensitivity to concurrent SMC traffic is **unknown and untestable before E4**. Its reversal
cost is the highest of the three: unpicking composite rendering from every view after months of UI
work.

### Helper serves fan state, app reads sensors directly

Halves the snapshot payload and keeps the heavy sensor traffic out of the root process. Rejected:
both connections and both failure modes stay alive permanently, and the two panes of the main window
end up disagreeing about when "now" was.

## Consequences

- **The helper stays resident whenever the Full app runs.** On-demand launchd woken by snapshot
  polling, and the menu bar polls continuously. Accepted knowingly: the read-only authority is the
  smallest imaginable root workload, and E5 wants residency whenever anything is leased. This is the
  cost of the decision and it is a real one.
- **The E7 direct stack is retained forever** — `Monitor` requires it — so this ADR costs no code. It
  is a source-selection policy, not a deletion.
- **Snapshot cost at 1 Hz was accepted** per [ARCHITECTURE.md](../ARCHITECTURE.md)'s wire-format
  trade — and #72 has now measured it, so the acceptance should be re-read with the number in hand.
  On `Mac16,5` / macOS 26.5.2 the machine exposes **2929 readable sensor keys**. Discovery costs
  2.2 s against a warm SMC key cache and 5.9 s against a cold one, and is correctly paid once. A warm
  snapshot costs **~0.5 s** and carries 2929 samples. At 1 Hz that is half of every second spent in a
  root daemon reading firmware, plus a payload of that size crossing the boundary every tick.

  **That payload is ~138 KB**, so **~138 KB/s** across the XPC boundary at 1 Hz, sustained for as
  long as the app is open. Six runs on this machine have landed between 137,750 and 138,402 bytes of
  JSON, the last digits moving with how many significant figures the readings print to. Those are the
  values seen so far and not a bound — nothing asserts on them, and the run that produced 137,750 fell
  outside a narrower range quoted here previously. The approximate figure is the durable claim; the
  span is provenance for it. That number is arguably what
  settles the subset-request question, more than the 0.5 s does: half a second of a root daemon's
  time is a cost, but 138 KB/s of it is a client asking for 2929 values to render a window that shows
  a few dozen.

  This does not reverse the decision: the argument for it is rule 6 and rule 7 consistency, not
  cost. It does mean **"a full sensor set proves heavy" is now settled rather than hypothetical**, and
  the remedy this ADR already names — an additive subset-request capability within v1, **never** a
  second continuous reader — should be treated as required work for the app-side client rather than a
  contingency. `Tests/AeolusHelperTests/HelperHardwareTests` re-measures the figure on every hardware
  run so it cannot drift unnoticed.
- **One reader per machine still leaves two readers inside the helper**, and this ADR did not say
  who wins between them. E5's safety supervisor reads a curated handful of keys on a tight cycle
  over the same connection as the 1 Hz snapshot, and `SMCConnection.read(keys:)` has no suspension
  point in it — so a 2929-key request is one indivisible occupation and a supervisor read issued
  inside it waits for all of it, with no error and no log line to say so.
  [#127](https://github.com/blamechris/Aeolus/issues/127) settles it in `SMCReadScheduler`: access
  is granted in bounded turns, a supervisor turn is admitted ahead of a waiting snapshot turn, and
  the overtaking is capped so a client is not starved of snapshots in the other direction. That is
  arbitration *under* this decision, not a change to it — the corollary above is about continuous
  pollers per machine and remains exactly as written.
- **Contention between the two readers was then measured, and scheduled.**
  [#127](https://github.com/blamechris/Aeolus/issues/127) put both readers on
  `SMCReadScheduler`, which grants the connection in turns of at most 64 keys and admits a
  waiting safety-supervisor turn ahead of a waiting snapshot turn. On `Mac16,5`:

  | | Measured |
  |---|---|
  | 34 curated critical keys, uncontended | 7.0 ms |
  | Warm 2930-key snapshot, uncontended | 601 ms |
  | **Worst safety cycle against an in-flight snapshot** | **31.3 ms**, over 49 cycles |
  | That snapshot, under the load | 898 ms |

  31.3 ms against the ~601 ms a cycle would otherwise wait behind an unscheduled refresh.

  **On the key count.** The measurement above reads **2930** keys where the paragraph above
  says 2929. Both are right for their own run: #72 counted 2929 on macOS 26.5.2, and every
  run on 26.6.2 counts 2930. The count is a property of the firmware and the OS build, not a
  constant, which is the reason nothing in the code asserts on it and the reason
  `HelperHardwareTests` re-measures rather than hard-codes. `ceil(2930/64)` is 46, the same
  as `ceil(2929/64)`, so no figure downstream moves.

  **These are not worst-case numbers**, and two drafts of the source comment said they were.
  The measuring loop awaits each cycle before issuing the next, so at most one supervisor
  read is ever queued; when that lone turn ends a snapshot turn is still queued, so the
  scheduler admits the snapshot and resets its overtake counter. The quota never reaches its
  limit and never fires — deleting it outright leaves the hardware test passing with
  identical numbers, so that test guards the *latency*, never the starvation bound.

  The counts close exactly, which is the check that the model is right rather than merely
  plausible. A full `snapshot()` is **48** turns — 46 for the 2930-key sensor refresh, plus
  one for `FNum` and one for the fan keys — the serial cycle overtakes at one boundary each,
  and one further cycle is admitted before the snapshot takes the connection and one after it
  lets go. That is **49**, and the identity is `cycles == snapshotTurns + 1`. An earlier
  version of this reconciliation said "46 turns × one overtake each is exactly the 49 cycles
  observed", which is both the wrong turn count and not equal to 49.

- **The two readers became four, and only one of them was paced by the helper.**
  [#134](https://github.com/blamechris/Aeolus/issues/134) is the sequel to the bullet above:
  `SMCReadScheduler` is FIFO *within* `.supervisor`, and by E5.4 four mechanisms take
  supervisor turns — § 3's cycle, § 5's watchdog, startup reconciliation, and
  `LeaseAuthority.refuseIfBlind`, which issues one 34-key read per `acquireLease` at whatever
  rate a client asks. The single reader this ADR mandates was therefore consumable at will by
  an unprivileged client, with § 3's cycle queued behind it by pure FIFO.
  [ADR 0010](0010-coalesced-supervisor-reads.md) settles it: no third priority level — the
  connection would still be saturated, so the snapshot would starve and this ADR's rule 6
  argument would fail from the other side — and the grant-time read is coalesced and
  age-bounded against § 3's own most recent reading instead. Also arbitration *under* this
  decision rather than a change to it.
- The app-side client and source switching are **not** built in #72. #72 builds the helper side only;
  this ADR is recorded now because it shapes #72's snapshot semantics (pull-based, `capturedAt`
  stamped, cheap at 1 Hz).

## A latent rule-6 defect this exposes, outside #72

`FanPollingReading.mode` is hardcoded `.automatic` in the direct-read path. With no helper *in that
build*, that is still a claim about the hardware which a stray helper — or another vendor's fan tool
— can falsify. The honest fallback rendering is "mode: not tracked", or later an observation derived
from `F<n>Md` marked community-confidence. Filed with the app-side client work rather than fixed
here.

## Revisit when

Field evidence shows helper residency for read-only monitoring is unacceptable — which would motivate
"the app reads directly when and only when no lease is active", a mode-switch seam rejected here as a
standing source-selection bug; a measured snapshot cost that additive subsetting cannot fix; or E4
hardware work establishing that concurrent reads during the unlock sequence are provably harmless,
which would weaken but not remove the case, since rule 6/7 consistency carries the decision on its
own.
