# ADR 0014 — The Apple Silicon unlock: the plane owns the force key, any restore supersedes an engagement, and the first write runs in the shipping daemon

- **Status:** Proposed
- **Date:** 2026-10-09
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** — (extends [ADR 0007](0007-safety-composition.md)'s keystone to the force key's
  lifetime, [ADR 0009](0009-precedence-at-the-write.md) D2 to an engagement of many writes, and
  [ADR 0011](0011-reconciliation-and-foreign-manual-control.md) D3 to every start; supplies the
  procedure for [ADR 0012](0012-a-round-trip-that-does-not-return-ends-the-helper.md) H3 and H6)

## Context

E4 ([#9](https://github.com/blamechris/Aeolus/issues/9)) is the first epic that takes a fan off
Apple's thermal management. Everything beneath it is built and running in the installed Developer
ID helper on `Mac16,5` since [#82](https://github.com/blamechris/Aeolus/issues/82) (2026-10-09):
the lease, the clamp and the permit (ADR 0008), § 3, § 5, § 4, § 6's reconciliation and signal
teardown, and ADR 0012's watchdog. The production plane answers `writeCapability == .notBuilt`,
`SMCConnection.write(_:to:)` throws, and no write selector exists under `Sources/`.

What is known about the write path here is almost nothing, and the gap between known and reported
decides most of this ADR:

| Observed on `Mac16,5`, read selectors only | Reported by community sources, unverified here |
|---|---|
| `F0Md`, `F1Md`, `Ftst` exist: `ui8`, 1 byte, attributes `0xD0`, reading `0` when nothing holds the fans (26.5.2, 26.6.2, 27.0.1) | A naive `F<n>Md = 1` is refused with `0x82` while the thermal manager holds the fans |
| `F<n>Md` read `1` on both fans while a third-party tool held them, and `0` again with it still running (26.6.2, 2026-09-05). Manual mode is reachable on this hardware, by a route this project has not seen and will not inspect | `Ftst = 1` makes the thermal manager yield in about 3 s; retry budgets of about 300 × 100 ms |
| `F<n>Tg` is `flt`, attributes `0xD4`: bit `0x04` set, little-endian under ADR 0004 | The thermal manager "holds the fans in mode 3" — **already contradicted**: `F<n>Md` has read only `0` or `1` here, so "poll until the mode leaves 3" is not a condition this machine offers |
| Worst read round trip 11.45 ms over 912,000 reads (27.0.1) | Release must restore the mode **and** clear `Ftst`; sleep resets `Ftst` |
| A competing fan-control tool with its own privileged helper was running in every capture | — |

Nothing has ever been written. The unlock is a hypothesis and the first write is an experiment —
but it is also the first time the safety subsystem acts on real firmware. Two choices have to be
made before any of it is coded, and both are expensive to reverse: **what code path the experiment
runs through**, which decides whether its findings describe the code that ships and whether a
failure mid-run is covered by restart and reconciliation; and **who owns the force key**, which
decides the keystone's shape on M3+, where `Ftst` is machine-wide and every lease, permit and
restore is per fan.

Four facts about the tree constrain both:

1. `SupervisedFanAuthority.apply` refuses unconditionally, and actor level 6 does not exist:
   `GovernedFanWriter` has no caller and no engage verb, and `engageManualControl(of:)` has one
   caller, § 5's re-assert.
2. `renewLease` and `releaseLease` are dispatched on arrival
   ([#229](https://github.com/blamechris/Aeolus/issues/229)), so a release can arrive while a
   multi-second `apply` is still unlocking, and ADR 0009 D2 — a lease checked at the write — is
   unbuilt ([#180](https://github.com/blamechris/Aeolus/issues/180)).
3. `fanctl`'s `gatedVerb` deadline is 5 s, unmeasured
   ([#325](https://github.com/blamechris/Aeolus/issues/325)); the reported yield is about 3 s.
4. The installed helper cannot write. A process that dies holding a fan is covered by restart and
   a reconciliation that can write **only if that process is the launchd-managed daemon**.

## Decision

### D1 — The experiment is the production path, in the installed daemon, built from an unmerged branch. There is no bring-up mode

The first write and every hardware row after it run through the code that will ship —
`SMCConnection.write`'s body, the plane's three write verbs, the level-6 `apply` path, the lease,
§ 3, § 5, § 4, ADR 0009's checks and ADR 0012's watchdog — inside the launchd-managed helper,
built `Full Release` by the maintainer from the head of `e4/bring-up`, installed over the current
one, and driven by the signed `fanctl` embedded in that build through the ordinary `acquireLease`
and `apply` (`fanctl set`, [#324](https://github.com/blamechris/Aeolus/issues/324), carried on the
branch).

- **No mode, no flag, no environment variable.** What an experiment varies — fan, target,
  duration — is a `fanctl set` argument. What it measures is permanent instrumentation: every write
  round trip logs its key, selector, SMC result byte and duration (ADR 0012's stamp already
  brackets the call), and every engagement logs each step. There is nothing for a client to enable,
  so rule 5 is met by absence rather than by a guard.
- **What stops it shipping is the merge, and the merge is visible.** On `main`,
  `WritePathAbsenceTests` keeps the selector allowlist at `{5, 8, 9}` and the production plane
  answers `.notBuilt`. Rule 1's line is therefore exactly: `SMCConnection.write`'s body, any write
  selector under `Sources/`, and a production plane answering `.built`. Code above that line may
  merge once E5 closes; nothing at or below it merges before the E4 gate.
- **Reviewed before hardware, merged after it.** The branch gets its full review, panel and Codex
  pass, before run 1; the merge waits for the checklist.
- **One permitted build-time variation.** Checklist row 8 runs on a throwaway commit that lowers
  § 3's ceiling through `ThermalEmergency`'s existing `requestedCeilingCelsius`, clamped downward
  only by `ThermalCeiling.effective`, so the emergency fires a few degrees above idle rather than at
  95 °C. It can only make § 3 fire earlier, no client reaches it, it is dropped before the merge,
  and a source tripwire on `main` holds that `HelperComposition.production` passes no ceiling.

### D2 — The unlock lives inside `SMCFanControlPlane.engageManualControl`, and nothing above the seam names `Ftst`

The M3+ sequence is conformer-internal, as `readControlState`'s documentation already anticipates.
The lease core, § 3, § 5, § 4, reconciliation and `apply` see one verb that engages a permitted fan
and one that restores a scope. The platform split is keyed on what the SMC declares and how it
answers, never on the chip (rule 9): the force key is used only if `Ftst` is in the key table read
at bring-up, and only after the firmware has refused a naive mode write. A machine whose firmware
accepts the naive write runs the same code and never touches `Ftst` — M1/M2, untested, shipped
`untested`.

The verb gains the entitlement it is checked against (D4) and still takes a permit, never an index
(ADR 0008): `engageManualControl(of: CommandableFan, while entitled: @Sendable () async -> Bool)`.

### D3 — The engagement sequence, which is the hypothesis under test

For one `CommandableFan` *n*, every step logged with its key, value, result byte, round-trip
duration and attempt number. The budgets are named constants, `UnlockLimits`, beside
`RestoreLimits`.

1. Ask the entitlement. Take a turn; inside it, check the restore epoch (D4), resolve `F<n>Md`'s
   type and byte order from a fresh `READ_KEYINFO` (ADR 0004), and write `F<n>Md = 1`.
2. **`0x00`** → read `F<n>Md` back in the same turn. `1` → step 5, the force key untouched, and the
   result recorded as **disagreeing** with the report. Anything else → undo and refuse: accepted is
   not applied ([#291](https://github.com/blamechris/Aeolus/issues/291)).
3. **`0x82`, and `Ftst` is in the key table** → ask the entitlement and write `Ftst = 1`; anything
   but `0x00` → undo and refuse. **Any first result other than `0x00` or `0x82`** — including the
   other codes this machine has returned to reads, `0x89`, `0xc7`, `0xcb` and `0xd8` — → no force
   key, no retry, undo and refuse.
4. **Poll by retrying the mode write**, the only yield signal this machine offers. Every
   `UnlockLimits.pollInterval` (100 ms): ask the entitlement, check the epoch inside the turn, write
   `F<n>Md = 1`. The first `0x00` is the yield; read back as in step 2. `0x82` → continue. Any
   other code → undo and refuse. `UnlockLimits.yieldBudget` elapsed — 3.5 s, 35 attempts, for
   run 1 — → undo and refuse. **No turn is held between attempts.** Recorded: time from `Ftst`'s
   acceptance to the first accepted mode write, and the count.
5. Return. The caller registers the fan with § 3 and § 5, then commands its target through the
   permit and reads `F<n>Tg` back.

The budget is sized to the client rather than to the report: 3.5 s leaves `gatedVerb`'s 5 s room
for the target write and its read-back. A budget that proves too short fails safe. New refusals —
the firmware refused the unlock; the yield did not arrive — are additive
`ManualControlAvailability.Reason` cases under `AeolusXPCVersion`'s bump policy.

### D4 — Every write away from the safe state is checked before, inside and after: any restore supersedes an engagement

An engagement is seconds of writes away from the safe state, and a release, § 4's handback, a § 3
latch or a § 5 fallback can arrive at any point in it. ADR 0009 D2 applies to every one of those
writes, and its residual is closed here rather than narrowed, because both halves are in one
conformer:

- **Before each forward write** the plane asks the caller's entitlement: for level 6, that a live
  lease covers fan *n* (#180's per-fan query) and that `SafetyArbiter` permits the control loop
  against § 3's latch; for § 5, its existing `currentRuling()` and `held` re-fetch.
- **Inside the write's own turn** the plane checks a restore epoch: a counter every
  `restoreToAutomatic` call increments **synchronously, when called, before it waits for a turn**.
  An engagement records the epoch when it starts and writes nothing once it has moved. A turn is one
  indivisible occupation of the connection, so no forward write lands after a restore that was
  *requested* before that write's turn began.
- **After each accepted forward write** the entitlement is asked again; if it has gone, the
  engagement undoes what it set.

The undo is the plane's own restore of what the engagement touched, in D5's order. A forward write
that lands just ahead of a restore's turn is undone by that restore, which runs after it — the
correct order. The keystone gains no input: incrementing a counter is not reading trusted data, and
no restore waits on an engagement. The state is lock-guarded, under the discipline
`SMCRoundTripMonitor` already uses, and held by the one production plane.

### D5 — The force key is the plane's, reference-counted by what the plane engaged, cleared last, and cleared at every start

- **An engaged set.** A fan joins when its mode write is accepted *and* reads back `1`, inside the
  turn that wrote it; it leaves when any restore covering it is **issued**, whatever the firmware
  answers.
- **Restore is the unlock reversed: every `F<n>Md = 0` in scope, then `Ftst = 0`.** Each write is
  issued in the force-key state in which its forward write was accepted. Clearing the key first
  would issue the mode writes in exactly the state the report says refuses them, and a refusal
  there mints a durable `restoreToAutomaticFailed` for a fan with nothing wrong with it.
- **Every write in a restore is attempted regardless of the others.** A refused mode write is still
  followed by the force-key clear, the strongest remaining lever to bring the thermal manager back;
  the restore throws only after all were attempted.
- **`.fan(n)` clears the force key when the set is empty after it; `.everyFan` clears it
  unconditionally** and empties the set. A per-lease teardown clears `Ftst` exactly when it hands
  back the last fan the plane engaged, and never while another engaged fan depends on it.
  `KeystoneRestoreAttempt` still issues `.fan(index)` only; the decision sits with the conformer,
  where the knowledge is.
- **`BoundedFanRestorer`'s retry tests the other order for free.** A first attempt whose mode write
  is refused has already cleared the key, because the set emptied when the restore was issued, so
  the second attempt writes `F<n>Md = 0` with `Ftst = 0`.
- **Startup reconciliation issues `.everyFan` once, on a plane that can write,** after its per-fan
  pass and inside its budget, amending ADR 0011 D3, which issued it only where the pass could not
  see. Otherwise a helper that died holding the key with every fan back in automatic leaves
  `Ftst = 1` that nothing clears, because the pass finds nothing in manual. The cost is ADR 0011
  D1's one-time discourtesy, extended to a force key another tool may hold.

**The keystone holds, and its one data-dependent branch is named.** No restore write consumes
bounds, a reading, a lease or a permit. The fan set comes from bring-up enumeration and `Ftst`'s
presence from the bring-up key table, unknown counting as present; nothing is read at restore time.
The engaged set decides only whether `.fan(n)` *also* clears the key, and it can err only toward
leaving the key set — which every `.everyFan` removes: § 4 before sleep, § 6's teardown,
reconciliation at the next start, and § 7 once its handler issues one. Whether a key left set with
every fan automatic is harmless is U6, and if it is not, the gate goes.

### D6 — Engagement happens at the first `apply`, never at grant, and an `apply` is all or nothing

`LeaseAuthority` stays hardware-free; a grant writes nothing. The first `apply` engages the fans
its settings name (D3, D4), registers each with § 3 and § 5 at the landing, commands each target
through `GovernedFanWriter` — which gains an engage verb, acknowledged by
`WriteVerbAllowlistTests` — and reads it back. If any fan's engagement fails, every fan that
`apply` engaged is restored and the call is refused. A lease that is never applied never takes a
fan off automatic control. A post-wake re-acquire re-runs the unlock with no special case, because
§ 4's `.everyFan` emptied the engaged set before the sleep.

The level-6 body is built in E4, though `apply`'s comment attributes it to E3: E3
([#8](https://github.com/blamechris/Aeolus/issues/8)) lists no such item, and E4 is the only write
path this project can verify.

### D7 — Each write takes one supervisor turn, and the unlock holds none between attempts

Each plane write verb takes one `.supervisor` turn covering its `READ_KEYINFO`, the write and its
read-back, through the one stamped `IOConnectCallStructMethod` site, with the community-documented
`WRITE_BYTES` selector (6). An engagement adds one outstanding supervisor reader to ADR 0012's N
while it waits for a turn and none while it sleeps. The slice that adds write turns re-runs ADR
0012's allowance and `theBoundsAreDerivedAndConstant`, as ADR 0012 requires, and a scripted test
holds that § 3 keeps completing cycles while an engagement is mid-poll.

### D8 — The first supervised write

**Preconditions. Any one failing means no write.**

- On `main`: the slices marked *before run 1* in the plan, including the end of
  [#104](https://github.com/blamechris/Aeolus/issues/104) (E5 closed) and #180.
- The branch's suite green, with a recorded mutation for each of: the epoch check, the
  entitlement check, the LIFO order, both restore writes attempted after a refusal, the clear on an
  empty set, the unknown-code abort and the budget abort.
- The installed helper reports the branch build, and its reconciliation log for this start shows
  the startup `.everyFan` accepted and read back.
- D9's exclusion, census and quiescence passed.
- AC power, lid open, no build or agent session running on the machine (concurrent builds distort
  SMC timing, [#227](https://github.com/blamechris/Aeolus/issues/227)), `pmset -g therm` clean,
  package below 50 °C, the app quit.
- The maintainer at the machine with `fanctl reset --all` and
  `sudo launchctl bootout system/com.blamechris.Aeolus.Helper` ready. A recorder running:
  `smc-sampler` at 10 Hz on `F0Md`, `F1Md`, `Ftst`, `F0Tg`, `F1Tg`, `F0Ac`, `F1Ac` and the curated
  package keys, and `log stream` on the helper's subsystem at debug.

**The run.** Sixty seconds of baseline, then `fanctl set 0 50% --for 60s --json`: **fan 0 only, at
3,564 RPM, above what Apple's controller runs at idle here (about 1,350 to 1,580 RPM).** The target
direction is the safety argument. Run 1 asks for *more* cooling than the system would, so every
stuck state it can produce — an unlock that will not undo, a restore the firmware refuses — is a
loud fan, not a hot one. Fan 1 is left alone on purpose: its behaviour under `Ftst = 1` is U7.

When `--for` ends the hold releases (D5's restore). Then `fanctl auto` (ADR 0013's check). Then
120 s of observation including a 20 s twelve-way load, which must move `F0Tg` and `F0Ac`: the fan
following load is the only proof that Apple's management came back. A second, 30 s hold is ended
from an SSH session with `fanctl reset --all` (row 18).

**Recorded** in `docs/SMC-RESEARCH.md`'s observed section, with machine state and build:

- every write's key, value, result byte and round-trip duration, the teardown restore's included
  (ADR 0012 H6);
- whether the naive mode write was refused, and with what;
- time-to-yield and the attempt count, and both read-backs;
- the 10 Hz trace of all seven fan keys through engage, hold, restore and load;
- whether `F0Tg` held the written value on every § 5 cycle;
- `F0Ac`'s step response (row 9);
- fan 1 under the force key (U7), and the force key's state at every point;
- `apply`'s and each heartbeat's client round trip (#325);
- that no third-party SMC client was present.

**Abort.** The maintainer runs `fanctl reset --all` at once on any of:

1. A curated temperature 10 °C above baseline, or above 85 °C. The target is above automatic, so
   a rise means the fan is not doing what was written.
2. `F0Ac` or `F1Ac` more than 20 % below its automatic speed for 10 s.
3. Any change to `F0Md`, `F1Md`, `Ftst`, `F0Tg` or `F1Tg` with no helper write logged to explain
   it.
4. A result outside D3's cases, or the budget expiring. The helper undoes on its own; the
   maintainer verifies.
5. Any write round trip over 1 s.
6. Thermal pressure above nominal.
7. The helper exiting or restarting during the hold.
8. Five minutes from engage without a verified restore.

**If the restore does not land.** Go in order, each step only if `F0Md`, `F1Md` and `Ftst` are
not all `0` on the recorder 10 s after the previous one:

1. `fanctl reset --all` (`.everyFan`: every mode, then the key, each attempted).
2. `sudo launchctl bootout` (§ 6's teardown, two more `.everyFan`; launchd will not restart it).
3. `pmset sleepnow` and wake (U12, reported).
4. Shut down, wait 30 s, power on (U11).

A refused restore after a target *above* automatic is a recoverable nuisance, which is why run 1
aims there.

**Decided on the result, before anything else runs.**

- Write latency: every round trip at or under 50 ms (D/100) → D stands for writes. Any between
  50 ms and 1 s → D is raised to 100× the worst in the merge PR and ADR 0012's derived bounds are
  re-run. Any over 1 s → stop and return to the architect.
- Yield: not arriving in 3.5 s → raise `yieldBudget` and `fanctl`'s apply deadline together on
  the branch, and repeat. A yield beyond about 4 s at all → asynchronous engagement before E4 may
  merge.
- Any contradiction of U1 to U7 → `docs/SMC-RESEARCH.md` first, then the architect, per
  `CLAUDE.md`.

### D9 — Another SMC writer is excluded by the operator, gated read-only, and never detected by the helper

**Every run before run 4 refuses to start while another SMC writer could be active, and the
refusal is the maintainer's act.**

- **Exclusion, product-agnostic.** Quit every third-party fan or SMC utility, switch its
  background item off in System Settings → General → Login Items & Extensions, and reboot, so no
  process survives. Re-enable afterwards; under ADR 0011 D1 that tool loses its settings once per
  Aeolus helper start.
- **Census, read-only.** Before the first write, the IORegistry's `AppleSMC` user clients must be
  only the Aeolus helper and the runbook's own sampler. That `ioreg` exposes each with its creating
  process is U10, checked in slice 0 before it is relied on. It counts clients, names no product,
  and nothing in the helper reads it.
- **Quiescence, read-only.** 120 s at 2 Hz in which `F0Md`, `F1Md` and `Ftst` read `0` on every
  sample. This sees a writer that is holding, not one that is idle — on 2026-09-05 those were
  minutes apart on this machine — so it backs the exclusion rather than replacing it.
- **In-run tripwire:** abort 3.

**The helper detects nothing, and ADR 0011 D1 stands.** What ADR 0011 already gives is protection
for the machine, not for the measurement. Reconciliation hands a held fan back once; a grant
re-reads the mode and refuses `.foreignManualControl`; § 5 never adopts a foreign fan. It does
**not** cover a foreign writer taking a fan Aeolus already holds. § 5 reads that as
`reclaimedBySystem`, a diagnosis that would be false, and re-asserts up to
`ReclamationLimits.reassertAttemptBudget` (3) before falling back — a bounded fight, and a trace
nobody could interpret. A foreign `Ftst` write would read as a yield or a reclamation. So the tool
is tested once, deliberately, last, to settle ADR 0011's unverified re-assert assumption and #300's
revisit condition.

### D10 — Runs are ordered by thermal risk

1. **Run 1:** above automatic, one fan, idle, 60 s (D8).
2. **Run 2:** both fans, below automatic (the declared minimum), under a moderate load for 5 min,
   with § 3 armed. Kill `fanctl` with SIGKILL. Kill the helper with SIGKILL mid-hold and confirm
   restart and reconciliation (ADR 0012 H3). Run row 8 on D1's lowered-ceiling commit.
3. **Run 3:** lifecycle with a hold — logout, restart, shutdown, and a lid close during a hold.
4. **Run 4:** the competing tool re-enabled, holding at helper start, then taking a fan Aeolus
   holds.

Each run's findings are recorded, and the branch revised, before the next.

## Consequences

- Rule 1's line is explicit (D1), and `main` keeps every write tripwire until the merge.
- `docs/SAFETY.md` § 1's statement that a per-lease teardown leaves `Ftst` untouched becomes false
  at the merge and is corrected there. § 6 and § 7 gain `.everyFan` sites, and
  `PanicPathScopeTripwireTests`' count rises with them.
- ADR 0011 D3 is amended by D5's startup clear.
- E4's "post-wake re-assertion" bullet and row 10's "does sleep reset `Ftst`" are restated: § 4's
  handback leaves `F<n>Md = 0` and `Ftst = 0` at wake, and a post-wake acquire re-runs the unlock.
  Whether firmware also resets the key no longer bears on correctness. It cannot be observed through
  the helper without disabling § 4, which no message and no build may do, and it matters only as a
  backstop for one residual: a § 4 keystone never issued before the sleep.
- `fanctl set` (#324) is the bring-up client and merges with E4.
- If U7 fails, per-fan manual control is not an honest product on such firmware, and the lease
  shape returns to the maintainer.

## Alternatives considered

### A standalone write probe, before any helper code

The strongest alternative, and the one an implementer will reach for first. A few hundred lines —
open the SMC, write `F0Md`, read the code, write `Ftst`, retry, write `F0Tg`, restore in a `defer`
— would answer U1 to U5 in an afternoon. It would need no lease, no signing, no XPC, and no review
of a helper change the answers might overturn. Isolating the firmware from the safety layer is a
real virtue for a measurement.

Rejected on how it fails:

- **A probe that dies holding a fan leaves it to nothing.** A Ctrl-C between the forward writes and
  the `defer`, a crash, or a synchronous IOKit call that never returns (ADR 0012's case, which no
  `defer` survives) leaves `F0Md = 1` and `Ftst = 1`. Nothing counts a lease, nothing watches, and
  no reconciliation can write — the installed helper answers `.notBuilt`. What is left is sleep
  (U12, reported) and a power cycle (U11, asserted and unverified).
- **It needs the write seam outside the helper:** `@_spi(FanWrite) import SMCCore` under `Tools/`.
  `WriteSeamAccessTests.spiImportAppearsOnlyInTheHelper` exists to refuse that, and `CLAUDE.md`
  calls a new member of that audience a safety review.
- **Its findings describe a code path that never ships:** no turns, no epoch, no entitlement, no
  § 3 beside it, no teardown restore through the path ADR 0012 bounds. Run 1 would still be owed,
  and it is the run that matters.
- **Reversal cost:** low in code, high in precedent — the second probe is easier than the first.

Revisit only if the signed helper cannot be built from a branch for an extended period, **and** the
maintainer accepts manual recovery as the only cover.

### The production graph composed inside `swift test`, under `sudo`

A close second. `HelperHardwareTests` already composes helper types over the real SMC, and
composing `HelperComposition.production` there would exercise every mechanism above the seam with
no signing and no install.

Rejected:

- The test runner is not a launchd job, so helper death — a crash, or the watchdog's own `exit(2)`
  — has no restart and no reconciliation.
- § 6's teardown cannot be installed in a test runner, because it applies `SIG_IGN` to the runner
  permanently. A Ctrl-C during a hold then ends the process with the fan pinned.
- The whole test target runs as root, and a write from a test process is a kind of writer the
  sole-writer rule has never had to consider.

Revisit if a test host can run as a launchd job with the teardown installed — at which point it is
the daemon.

### The unlock above the seam

An `UnlockCoordinator` sequencing raw primitives — `writeMode(_:ofFan:)`, `writeForceKey(_:)` —
would reach the lease and latch with no entitlement threaded into the plane. Rejected:

- The primitives take an index rather than a permit, reopening what ADR 0008 closed.
- Everything that holds the plane could write the force key.
- Platform differences leak above the seam (rule 9).
- The write-verb surface `WriteVerbAllowlistTests` polices doubles.

Moving the unlock up later is a widening; moving it down is a narrowing. Start narrow.

### Engage at grant

Rejected: it puts firmware writes into `LeaseAuthority`, which owns no hardware by design; a lease
never applied pins a fan at whatever target the thermal manager left; and a multi-second grant
meets the same 5 s deadline for nothing.

### Hold the force key for the helper's life, or set it at bring-up

Rejected: it tells the thermal manager to yield with nobody holding a fan, and whether that is
harmless is U6, unknown.

### Clear the force key on every per-fan restore

The near miss, and the fallback if U6 fails. Rejected for now: inside a two-fan teardown sweep,
clearing the key after the first fan puts the second fan's mode write into the state the report
says refuses mode writes.

### Clear the force key first

Rejected for the same reason, applied to every fan rather than the second.
`BoundedFanRestorer`'s second attempt runs this order after a refused first one, so it is observed
without being depended on.

### Detect the other writer in the helper

Rejected by ADR 0011 D1 and the clean room. The census is legitimate as an operator's read-only
pre-flight only because it counts clients, names nothing and changes no product behaviour.

### First write with the competing tool present, relying on ADR 0011

Rejected: ADR 0011 bounds what that tool can do to the machine, not to the measurement (D9).

### Asynchronous engagement

`apply` answers at once and the snapshot reports progress. Deferred, not rejected. It is needed
only if U3 fails beyond about 4 s, and it changes what `apply`'s reply means, so it needs a version
bump.

## Assumptions and what would invalidate them

| # | Assumption | Basis | If it fails |
|---|---|---|---|
| U1 | A naive `F<n>Md = 1` is refused `0x82` while the thermal manager holds the fans | Reported. `0x82` seen here only on reads of function keys | **Accepted and applied:** D3 proceeds with no force key; the disagreement is recorded. **Accepted then taken back within § 5's cycles:** write `Ftst` before the mode write, a conformer-internal change. **Another code:** treated as "held" only after architect review |
| U2 | `Ftst = 1` is accepted, and the mode write after it | Reported | No unlock by this route: E4 stops, the snapshot says manual control is unavailable and why, the matrix says so, and it goes back to the architect. Never coded around |
| U3 | The yield arrives within 3.5 s | Reported about 3 s; budgets of about 30 s suggest a tail | Raise the budget and the apply deadline together; beyond about 4 s, asynchronous engagement before merge |
| U4 | Accepted `F<n>Md` reads back `1`; `F<n>Tg` reads back exactly what was written | Unobserved; § 5's primary signal rests on the second | **Mode:** D3 refuses, correctly. **Target:** if quantised, § 5 needs a read-back tolerance before merge, or every cycle reports a reclamation |
| U5 | The reverse-order restore is accepted | Unobserved | The retry already runs the other order; if only that one lands, D5's order flips in one place |
| U6 | With `Ftst = 1` and every `F<n>Md = 0`, Apple's management drives the fans | Unknown | D5's gate goes: every restore clears the key and every engagement re-sets it; § 4's never-issued keystone becomes a priority residual |
| U7 | `Ftst = 1` does not change a fan Aeolus did not engage | Unknown | A one-fan lease takes the others off Apple's management while the snapshot calls them automatic (rule 6). Engagement becomes all-fans-or-nothing on such firmware; the lease shape is the maintainer's call |
| U8 | Every write round trip, the teardown restore's included, stays under 50 ms (D/100) | Reads 11.45 ms worst; writes unmeasured | D8's decision rule |
| U9 | Manual mode and the key persist after the writer dies (ADR 0012 H3) | Reported | If they revert on close, ADR 0012 and D5's startup clear get cheaper; nothing changes |
| U10 | `ioreg` lists every `AppleSMC` user client with its creating process | Hypothesis | D9's census gate is dropped |
| U11 | A power cycle returns `F<n>Md` and `Ftst` to `0` | Asserted by `RECOVERY.md` step 7; unverified | D8's ladder ends in a loud fan and `RECOVERY.md` § 8; run 1's target direction is what makes that acceptable |
| U12 | Sleep resets `Ftst` | Reported; not depended on (D5) | Only the never-issued-keystone residual widens |
| — | One lease-table entry, one production plane | True today | Concurrent leases or a second plane: re-check D4's epoch scope and D5's gate |

Every observation above is `Mac16,5`; the write-path rows are hypotheses until D8 runs. Intel and
M1/M2 ship `untested`.

## Revisit when

Any of U1 to U7 is contradicted by a run — the expected case, so amend this ADR and do not code
around it. Also revisit when: a write round trip exceeds 50 ms; the yield does not fit a
synchronous `apply`; concurrent leases or self-renewing leases are proposed; a second production
plane exists; or a report arrives from M1/M2 or another M3+ machine.

The ruling is the architect's E4 consult, run on Opus.
