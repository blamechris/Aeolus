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

  **That payload is ~138 KB** — 137,764 to 138,307 bytes of JSON across measured runs, the last
  digits moving with how many significant figures the readings print to — so **~138 KB/s** across the
  XPC boundary at 1 Hz, sustained for as long as the app is open. That number is arguably what
  settles the subset-request question, more than the 0.5 s does: half a second of a root daemon's
  time is a cost, but 138 KB/s of it is a client asking for 2929 values to render a window that shows
  a few dozen.

  This does not reverse the decision: the argument for it is rule 6 and rule 7 consistency, not
  cost. It does mean **"a full sensor set proves heavy" is now settled rather than hypothetical**, and
  the remedy this ADR already names — an additive subset-request capability within v1, **never** a
  second continuous reader — should be treated as required work for the app-side client rather than a
  contingency. `Tests/AeolusHelperTests/HelperHardwareTests` re-measures the figure on every hardware
  run so it cannot drift unnoticed.
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
