# ADR 0011 — Startup reconciliation is unconditional and one-shot, and a fan found in manual afterwards is foreign control

- **Status:** Proposed
- **Date:** 2026-09-05
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (implements [ADR 0007](0007-safety-composition.md)'s helper-death
  recovery, and adds the case ADR 0007 does not consider)

## Context

[ADR 0007](0007-safety-composition.md)'s first hole is that **helper death defeats every
safety mechanism at once**. All eight live inside the helper: when it dies, the TTL is
counted by nothing, the reclamation watchdog is not watching, the SMC keeps the last mode
written to it, and the fans stay wherever they were left. Lease state is deliberately in
memory only — *"a lease that survives its enforcer's death is a setting wearing a lease's
name"* — so nothing on disk can be consulted either. The answer ADR 0007 records is **restart
plus reconciliation**: launchd brings a new helper up, and before it serves anybody it reads
fan mode state and returns to automatic anything found in manual with no live lease.

That answer was written as though Aeolus were the only program that can write `F<n>Md`, and
it is not. The 2026-09-04 triage on [#103](https://github.com/blamechris/Aeolus/issues/103)
recorded the case plainly:

> Macs Fan Control is installed and running on the development machine. Startup
> reconciliation as specified here restores "any fan in manual with no live lease" to
> automatic — so the helper's first act would be to silently undo another running tool, and
> the reclamation watchdog would then read that tool's re-assertion as a system reclamation
> and contest it.

Two distinct defects hide in that sentence. The first is a **one-time** discourtesy: Aeolus
undoes somebody else's setting at startup. The second is a **standing fight**: § 5's registry
would gain a fan Aeolus never engaged, its cycle would read the other tool's re-assertion as
divergence, and two programs would take turns writing the mode register of a machine's
cooling several times a second — each perfectly correct by its own lights.

Nothing in #103 or #102 mentioned a third-party writer at all, and until it is settled no
live fan-state observation on this machine means anything.

## Decision

### D1 — The pass is unconditional. The helper does not try to work out who left a fan in manual

`F<n>Md` reads `1` whether the fan was pinned by an Aeolus helper that died thirty seconds
ago or by another vendor's tool that is running right now. **The register carries no owner**,
and there is no second register that does.

Everything that *could* distinguish them was rejected:

- **A breadcrumb on disk** — the helper writes "I hold fans 0 and 1" at engage time and reads
  it back at startup. This makes a safety action defeasible by a file. A crash between the
  write and the engage, a full disk, a user emptying a cache directory, or simply a stale
  file from an uninstalled version, and the helper declines to restore a fan it is holding.
  It also reintroduces exactly what ADR 0007 refused: lease state that outlives its enforcer.
- **A process scan** — look for another fan-control tool by process name or bundle
  identifier. `CLAUDE.md`'s clean-room rules forbid naming any commercial tool in this
  category, and the check would be defeated by a rename, would miss every tool nobody
  thought of, and would produce a *false negative* in the direction that matters: a tool that
  is running under an unexpected name is read as "nobody is here" and its fan is taken.
- **A heuristic on the target value** — `F<n>Tg` sitting at a round number, or outside what
  Aeolus's curve would produce. Guesswork, unfalsifiable, and wrong the first time a user
  picks the same RPM Aeolus would have.

What decides it instead is the **asymmetry of the two failure directions**, which is not
close:

| If the helper restores and should not have | If the helper declines and should not have |
|---|---|
| Another tool's fan goes to Apple's thermal management | Aeolus's own dead helper has left a fan possibly pinned **low** |
| A safe state, by definition — it is the state the machine ships in | Nothing is counting a TTL, nothing is watching, and no mechanism will act |
| Visible: the other tool's UI shows it immediately | Invisible until the machine overheats |
| One click in that tool to undo | Recoverable only by a reboot or `docs/RECOVERY.md` |

`docs/SAFETY.md` opens with the second failure. So the pass restores, every time, and the
cost is a one-time discourtesy to a program that can undo it in a click.

### D2 — It is one-shot, and a fan found in manual afterwards is **foreign control**

The restore happens **once per process**, before `listener.resume()`. After it, a fan
observed in manual that Aeolus did not engage is reported as
`ManualControlAvailability.Reason.foreignManualControl` — a new, additive reason —
**refused a lease, and never restored a second time**.

A second restore is where the *standing fight* begins, and the fight is the thing worth
avoiding rather than the discourtesy. Two programs undoing each other's mode write over a
machine's cooling, at whatever rate each one's loop runs, is strictly worse than either
program winning: the fans oscillate, both logs fill with correct-looking entries, and no
user can diagnose it from either side.

Three consequences follow, and each is implemented:

1. **Reported on the snapshot.** A fan in manual that no live lease covers carries
   `.foreignManualControl`, so a client can tell the user another program has the fan rather
   than showing an inert slider. It does not name the program, because `F<n>Md` cannot.
2. **Refused at grant time, after a fresh `readControlState`.** Not on the mode observed at
   startup: that reading is minutes or days old by the time a client asks, and a fan taken in
   the meantime would otherwise be granted. A read that throws refuses too, as
   `.supervisorBlind` — the helper cannot say what it would be granting.
3. **§ 5 is told nothing, by design.** `ReclamationWatchdog`'s registry is fans **Aeolus
   engaged**; a foreign fan is structurally invisible to it, so the re-assertion contest the
   triage predicted cannot start. This is not an omission to be corrected later — putting a
   foreign fan in that registry is precisely the defect.

### D3 — Wherever the pass cannot see, the machine-wide restore is issued

**Three branches, one rule** (ruling D24, 2026-09-05). If a mode read throws, if the fan
*enumeration* throws, or if the budget runs out with fans still unread, the per-fan pass
stops and one unconditional `restoreToAutomatic(.everyFan)` is issued. ADR 0007's assumption
table already decided the first — *"`F0Md`/`Ftst` are readable for reconciliation … If it
fails: reconciliation falls back to unconditional restore-to-automatic at startup — safe
either way"* — and the keystone is what makes it available: the machine-wide verb needs no
bounds, no sensor, no lease and no data of any kind, which is the entire reason ADR 0007
elevates it.

The rule is applied **uniformly**, and an earlier draft of this ADR did not apply it that
way. An enumeration failure abandoned the pass and restored nothing — no per-fan restore, no
keystone, and no fan recorded as unreconciled, because no index existed to record. The
argument offered for it was that nothing was lost, since `acquireLease` enumerates through
the same seam and throws before it could grant anything. That is an argument about *grants*,
and this pass is not about grants: a fan the previous helper left pinned stays pinned, and
refusing a lease over it does not spin it back down. It is also the branch most likely to be
taken on exactly the cold restart § 6 exists to cover.

Since no fan index is knowable on that branch, "nothing was established" is recorded as a
flag rather than as a set of indices, and every grant is refused `.supervisorBlind` until a
keystone write lands. A budget expiry gets the keystone for the same reason: a fan nobody
looked at and a fan whose read threw are the same state, and there is no fact one has that
the other lacks.

It is issued through a `SafetyActorWriter` at `.panicRestore`, not through
`HelperFanRestorer`, which documents at length why it emits `.fan(n)` and never `.everyFan`.
Issuing it over fans the pass *did* reach and found automatic costs nothing: the verb is
idempotent over them.

### D4 — The pass is bounded, and the listener resumes either way

`ReconciliationLimits.budget` (5 s) is checked between fans. When it runs out, the fans not
yet read go into a durable set, the keystone is issued for them (D3), and the pass returns;
the helper serves clients, and refuses a lease over any of those fans for the life of the
process as `.supervisorBlind` — unless that machine-wide write lands, in which case no fan is
in an unknown mode and there is nothing left to refuse over.

**`.supervisorBlind` rather than a second new reason**, and the fit is exact rather than
convenient. That reason's own contract is *"nobody has been able to look"*, written to
distinguish it from `.reclaimedBySystem`'s diagnosis; a fan the budget never reached is a fan
nobody has looked at, arrived at by a different route. It is durable here for a reason
peculiar to this mechanism: reconciliation is one-shot, so nothing ever revises the answer.

It is a **budget, not a timeout**: it bounds how many reads the pass will start, not how long
any one of them may take. A single read that never returns still hangs the bring-up, and that
is the fail-safe direction `HelperComposition.bringUp()` already records for itself — a
daemon that answers no connections is safe; one serving over unreconciled fans is not.
Cancelling a read mid-flight would mean abandoning a `.supervisor` turn, which is the
scheduler's invariant to keep.

### D5 — The restart policy ships in the same change

`KeepAlive = { SuccessfulExit = false }` and an explicit `RunAtLoad = true`
([#165](https://github.com/blamechris/Aeolus/issues/165)) land in the same pull request and
never before it. ADR 0007 states the reason in one line: a restart policy without
reconciliation restarts a helper that then serves without checking what the SMC still holds.
`RunAtLoad` is written out rather than left to `KeepAlive`'s documented implication, because
boot-time reconciliation covers manual mode persisting across a *reboot* — a case nobody has
verified cannot happen — and that is too load-bearing to rest on a manual page.

## As built

- `Sources/AeolusHelper/Safety/StartupReconciliation.swift` — the pass and the baseline, one
  actor. It outlives the bring-up because the baseline is asked for the life of the process.
- `HelperComposition.bringUp()` runs it **after** the safety registries are bound and
  **before** any supervisor starts. Both edges are asserted at the source by
  `HelperCompositionTests.reconciliationSitsBetweenTheBindAndTheSupervisors`, because the
  property is statement order in a function reached once in a process that never returns.
- The per-fan restore goes through the same `HelperFanRestorer` the lease core's teardown
  uses, so it inherits [#110](https://github.com/blamechris/Aeolus/issues/110)'s bounded
  attempts and both registries are told. A new `FanRestoreCause.startupReconciliation` names
  it in the log — the one cause that names no lease.
- `LeaseAuthority` gains one narrow seam, `ForeignManualControlSensing`, asked immediately
  after the blindness gate and last of the four things `acquireLease` suspends on — the fan
  enumeration, § 3's latch, the telemetry read and it, three of which are refusals — because
  it is the only one whose cost scales with the number of fans requested. Fans Aeolus is
  accountable for — under a live lease, mid-handback, or abandoned — are excluded rather than
  judged, because each already has a more precise refusal further down the method.
- **The snapshot judges "foreign" against that same set**, `fansAeolusIsAccountableFor`, read
  in one hop with the lease through `LeaseAuthority.activeLeaseView()`. Two definitions of
  "Aeolus's own fan" would disagree the moment either moved, and the way they disagreed
  before was the snapshot naming a fan Aeolus had pinned and could not hand back as another
  program's — which sends a user to quit software that is not holding their fan.
- **A system reclamation outranks the baseline, keyed on § 5's ledger cause** rather than on
  an availability value. `.reclaimedBySystem` is deliberately never published as an
  availability in this build (#140), so a guard looking for one matched nothing; the check is
  on `FanState.isReclaimedBySystem`, which comes straight from the ledger.

**On today's helper none of the restores can land.** `SMCFanControlPlane` answers
`FanWriteCapability.notBuilt` and every write verb throws `.controlPathNotBuilt`, so the pass
reads, finds nothing to do on a healthy machine, and would be refused if it did. That refusal
logs at notice rather than fault: it is the build's expected state, and a fault per fan per
start would train a reader to skip the line that matters when E3/E4 make it real.

## Alternatives considered

**Restore only fans a previous Aeolus helper is known to have held.** Rejected in D1: every
implementation of "known to have held" is a file or a guess, and both fail in the direction
that leaves a fan pinned.

**Detect the competing writer and decline.** Rejected in D1, and separately forbidden by
`CLAUDE.md`'s clean-room rules — no process-name or bundle-identifier detection of any other
vendor's tool, ever.

**Restore repeatedly, so Aeolus always wins.** This is the fight, stated as a policy. It is
worse than losing: neither program can diagnose it, and the fans oscillate while both logs
look correct.

**Report a foreign fan as `.reclaimedBySystem`.** Rejected: that reason says the operating
system took the fan, which is a diagnosis, and a third-party write is not it. The same
conflation [#140](https://github.com/blamechris/Aeolus/issues/140) removed from
`isReclaimedBySystem`.

**Bump `AeolusXPCVersion` for the new reason.** Unnecessary: `ManualControlAvailability`'s
decode is total, an unrecognised wire value lands in `.unknown(_)`, and that policy exists so
new reasons can be added within a version. The bump is reserved for a change that alters what
an existing field *means*.

**Refuse every lease until reconciliation has run.** Considered, and the ordering is the
guarantee instead: `bringUp()` completes before `listener.resume()`, asserted by five separate
expectations in `HelperCompositionTests.theServiceIsAdvertisedOnlyAfterBringUp` including the
bring-up semaphore's initial value. A second runtime gate would add a state no client can
reach and would force every lease test through three 1 Hz supervisor loops it does not want.

## Consequences

- **A user running another fan-control tool loses its settings once**, at Aeolus's first
  start and at every helper restart. The tool re-applies them; Aeolus does not fight back.
  This needs to be in the release notes rather than discovered.
- **A fan another program holds is permanently uncontrollable by Aeolus** until that program
  hands it back. That is the intended outcome, and the snapshot says so.
- **A fan whose reconciliation restore the firmware refuses is watched by nothing — § 3
  included — and that is stated here rather than left to be discovered** (ruling D23,
  2026-09-05). It is in neither safety registry: § 5's holds fans *Aeolus engaged*, and
  reconciliation engaged nothing, so the restorer's deregistration steps find no entry to
  remove and there is none to leave behind either. A thermal emergency will therefore not
  bridge that fan to maximum, and the pass is one-shot so nothing retries the write. The
  fan may be pinned at a speed nothing is tracking, and `docs/RECOVERY.md` is the user's
  route out.

  It is **not** fixed by registering the fan with § 3. That needs a `CommandableFan` — an
  envelope read and a permit reconciliation does not hold — and minting one for a fan that
  may belong to another program means writing to that program's fan during an emergency,
  which is the contest D1 and D2 exist to decline. What happens instead is the honest
  half: the fan goes into a durable set and every later grant over it is refused
  `.restoreToAutomaticFailed` — *"it asked for automatic, was refused, and stopped asking"*,
  the reason's own words — so nothing is *claimed* over a fan nothing is watching.
  [#201](https://github.com/blamechris/Aeolus/issues/201) holds the gap open against E3/E4
  bring-up, where #168's reconnect-then-retry is the likely closer.

  **The snapshot answers differently, and the difference is deliberate.** A client reading
  that fan sees `.foreignManualControl`, because the snapshot judges by what `F<n>Md` says
  and who Aeolus is accountable for, and reconciliation's own set is not the lease core's.
  That is a misattribution when the previous holder was in fact a dead Aeolus helper, and it
  is accepted: the helper genuinely cannot tell, which is D1 all over again. The grant path
  can be more precise because it knows one thing the report does not — that *this* process
  asked for the fan back and was refused — and it says so.
- **§ 5 will never watch a foreign fan**, so nothing notices if that fan is later pinned at a
  dangerous speed by the other program. Aeolus is not that machine's only fan authority and
  does not claim to be; § 3's thermal override still fires on temperature, and its bridge
  covers fans Aeolus engaged.
- **The pass refuses to run twice.** One-shot is the property every durable refusal above
  rests on, so it is enforced in the mechanism rather than assumed of the one call site that
  exists today: a second `reconcile()` logs and returns, because running it again would
  discard what the first established and hand a fan back a second time — the first move of
  the contest D2 declines.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| `F<n>Md` is readable at helper start | Observed on `Mac16,5`, both fans, 2026-09-05 — reading `0` at ~16:40, `1` at ~17:06, `0` again at ~17:50 | D3's machine-wide fallback, which needs no read |
| `F<n>Md` actually takes the value `1` on this hardware | **Observed 2026-09-05, first sighting**: both fans read `1` with a competing tool holding them, then `0` again with that tool still running. Read-only, through the production scheduler; nothing in this build can write. See `docs/SMC-RESEARCH.md` | Nothing — the mechanisms keyed on it were resting on a value nobody had witnessed, and now one has been |
| A foreign tool does not re-assert within one cycle of the startup restore | **Unverified** — needs E3/E4 bring-up with the tool actually holding a fan | The one-time restore becomes a visible flap; the decision does not change, because the alternative is the standing fight |
| `F<n>Md == 1` means somebody is holding the fan | Community-reported, and the basis of every mechanism here. Consistent with the 2026-09-05 pair of readings, which moved with a competing tool's behaviour and with nothing else | Reconciliation restores fans nobody held — harmless, and indistinguishable from the healthy case |
| Whether a fan reads manual is a property of the *machine at that instant*, not of the machine | **Observed 2026-09-05**: the same two fans read `1` and then `0` within an hour, with the same tool running throughout | Nothing here; but a hardware test pinning either value is a report about the reviewer's desktop, which is why `HelperHardwareTests` now asserts the pair |
| `SMAppService` accepts `KeepAlive`/`RunAtLoad` in a daemon plist | Documented-plausible; unverifiable until a signing identity exists | Restart policy needs another mechanism, and reconciliation only runs when a client connects — escalate before shipping self-renewal |

Every hardware observation above is `Mac16,5` on macOS 26.6.2. Intel and M1/M2 ship
`untested`.

**Revisit when:** E3/E4 bring-up is run with a competing tool actually holding a fan; a
firmware is found that refuses a restore while leaving a fan manual; or self-renewing leases
are proposed, whose entire safety story is this mechanism plus the restart policy.
