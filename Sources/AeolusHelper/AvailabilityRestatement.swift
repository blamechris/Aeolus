import FanKit

// The re-statements `SupervisedFanAuthority.snapshot()` makes over the read path's answer,
// lifted out of `ReadOnlyFanReport.swift` by
// [#187](https://github.com/blamechris/Aeolus/issues/187) — which added one of them and put
// that file over the 400-line threshold #128 split it out to hold. There were two until
// [#350](https://github.com/blamechris/Aeolus/issues/350) added § 7's grant seal as a third.
//
// Same trade as `LeaseAuthorityRefusals.swift`, and cheaper: `ReadOnlyFanReport` is a
// namespace of pure functions with no state, so nothing widens with the move. The one member
// that stayed behind is `availability(writeCapabilityIs:bounds:)`, because
// `fanState(for:reclamation:mode:writeCapability:)` calls it and it is `private`.
//
// ## The availability ladder, in one place
//
// `FanState.manualControlAvailability` is the field a UI turns into an enabled or disabled
// control, so *which* refusal it states when several apply is a decision rather than a
// detail. The whole order lives here, and its rule is: **the snapshot answers with the same
// reason `LeaseAuthority.acquireLease` would throw for the same fan in the same instant.**
// Anything else is `CLAUDE.md` rule 6 — a screen offering control that the click cannot get,
// or refusing control the helper would in fact grant.
//
// **The rule has a corollary, and it binds both sides**
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s 2026-10-15 amendment): a grant
// refusal, and the availability that mirrors it, is computed from **current evidence the grant
// path consults**. A diagnosis of something that already happened is a fact, and is reported as
// one. § 5's ledger is that kind of fact — `FanState.isReclaimedBySystem`, the fault log, the
// lease it ended — and is never a rung here
// ([#355](https://github.com/blamechris/Aeolus/issues/355)). A refusal that no read can clear
// seals its own exit: the only events that clear the ledger need the lease it would refuse. On
// the grant side the same rule is why `.boundsImplausible`, current evidence re-read on every
// snapshot, is in the grant ([#270](https://github.com/blamechris/Aeolus/issues/270)).
//
// Highest first, with the step that produces each:
//
// | # | Reason | Produced by |
// |---|---|---|
// | 1 | `.restoreToAutomaticFailed` | `reportingHandbackState` — § 4/§ 5's durable register |
// | 2 | `.handbackUnconfirmed` | `reportingHandbackState` — § 4's budget expired |
// | 3 | `.releaseInProgress` | `reportingHandbackState` — a restore on the wire |
// | 5 | § 6's durable refusal (not over step 6), then `.foreignManualControl` | § 6's baseline |
// |   | … or `.supervisorBlind`, mode did not read (not over step 6; #360) | the read's `F<n>Md` |
// |   | … or `.restoreToAutomaticUnconfirmed`, for a fan § 3 keeps (#303) | § 3's kept set |
// | 6 | `.writePathNotBuilt` | `availability(writeCapabilityIs:bounds:)` — the seam |
// | 8 | `.boundsImplausible` | `availability(writeCapabilityIs:bounds:)` — § 2's gate |
// | 10 | `.releaseInProgress` | `reportingMachineWideRestore` — the machine-wide restore seal |
// | 9 | `.available` | nothing refused |
//
// **Steps 4 and 7 were § 5's ledger** — `.supervisorBlind` and `.reclaimedBySystem` — until
// #355 removed them. The numbers are kept so that every reference to steps 5, 6 and 8 still
// names the same rung, and neither is reused: step 10 is the next unused number, which is why
// it is listed above step 9, `.available`, whose number predates it.
//
// **Step 10 re-states `.available` and nothing else.** Every refusal ranked above it that the
// grant shares, the grant gives ahead of the seal — above the marker, or ahead of the seal's
// guard in the straight-line region — except step 3's, which is the same `.releaseInProgress`.
// So a fan another rung refuses keeps that rung's answer, which is also the one still true once
// the panic returns. Step 8 is among them since #270: the grant reads the bounds above the
// marker, after its foreign-control read, so step 5 outranks step 8 on both sides and both
// outrank the seal. Never widen this rung to overwrite a refusal: step 5's `.supervisorBlind`
// for a fan whose mode did not read (#360) rests on it, since the grant refuses that fan at its
// fresh read, above the seal's guard.
//
// **Steps 1–3 and step 5 cannot both apply, so their relative order is not load-bearing and
// is not relied on.** Every fan in one of the three handback registers is in
// `LeaseAuthority.fansAeolusIsAccountableFor`, and `reportingForeignControl` returns such a
// fan untouched — foreign control is by definition a fan Aeolus is *not* accountable for.
// That disjointness is what lets the two re-statements compose in either order; it is
// asserted by `SnapshotAvailabilityTests`, because a change to either set would make the
// composition order start mattering silently.
//
// **Step 5 answers four questions, in `StartupReconciliation.refusalForGrant`'s order.** First
// the durable refusals the one-shot pass left — `.supervisorBlind` for a fan whose mode it
// never established or confirmed, `.restoreToAutomaticFailed` for one it could not hand back
// — through the same `ReconciliationBaseline.durableRefusal(overFans:)` the grant path calls,
// so the two cannot drift ([#204](https://github.com/blamechris/Aeolus/issues/204)). The second
// and third judge the fan's mode from the snapshot's own `F<n>Md` read, where the grant path
// takes a fresh one. **The second is whether the mode read at all: no answer is
// `.supervisorBlind`**, the grant's own answer when its read throws
// ([#360](https://github.com/blamechris/Aeolus/issues/360)). The third is whether it reads
// manual: automatic is left to the rungs below, and manual is foreign control. Before #204 only
// the third was asked here, so on a seam that can write a fan reconciliation had refused read
// `.available`, or `.foreignManualControl`; before #360 a fan whose mode did not read was
// judged automatic, by #178's fold, and read `.available` while the grant refused it.
//
// **The second covers every fan Aeolus is not accountable for**, not only § 3's kept set:
// the grant refuses any candidate whose read throws. The read path hands the answer over beside
// the snapshot it was read for — `ReadOnlyFanAuthority.observe()`, one read and one dictionary —
// because `FanState.mode` cannot carry it: the wire has no way yet to say "not known" (#178).
//
// **The fourth is whose manual it is** ([#303](https://github.com/blamechris/Aeolus/issues/303)).
// A manual fan § 3 is keeping because Aeolus's own restore was issued and not confirmed is
// `.restoreToAutomaticUnconfirmed`, and only a fan outside that set is foreign. It is a
// reclassification of the foreign answer and never an exemption from step 5: § 3's set is
// carried beside `accountableFans`, not in it, because a fan in `accountableFans` is returned
// untouched and would read `.available`. The steps-1–3 disjointness below is unchanged by it —
// a fan in both § 3's set and a handback register is in `accountableFans`, so it is exempted
// before the fourth question is asked and answered by steps 1–3.
//
// **Neither the durable refusal nor the no-answer arm is stated over step 6's
// `.writePathNotBuilt`**, which is where both differ from foreign control. `acquireLease`
// refuses a seam that cannot write before it asks anything else, so on today's build a grant
// over every fan answers `.writePathNotBuilt` — and every reconciliation restore is refused by
// the *build*, which is not the firmware refusal `.restoreToAutomaticFailed` names. Answering
// either there would state a reason no grant returns: the durable one would blame firmware that
// was never written to, and `.supervisorBlind` would be stated, permanently, on every fan of
// every Mac without `F<n>Md`, which by the reported key map is every Intel Mac. Whether such a
// build can say "not known" is #178's. Foreign control keeps its pre-existing place above step
// 6: it is a fact about the machine, true on any build, and is what
// `HelperHardwareTests.expectHonestAvailability` holds this machine to.
//
// **`.leaseHeldByAnotherClient` is absent from the ladder and cannot be added.** See
// `LeaseAccountability`: a snapshot has no `ConnectionID`, so the helper cannot know whether
// the reader is the holder. `.systemSleeping` is absent for a weaker reason — § 4's seal is
// machine-wide state the snapshot does not read — and is
// [#269](https://github.com/blamechris/Aeolus/issues/269)'s. Its rung goes **below step 5 and
// above step 10**: `acquireLease` checks the sleep seal after its fresh read, so while the seal
// holds a fan whose mode did not read is still refused `.supervisorBlind`, and the two agree.
// `.noThermalTelemetry`, which the grant checks *before* that read, is #269's too.

extension ReadOnlyFanReport {

    /// Re-states one fan's availability once the lease core has been consulted: the whole of
    /// what `SupervisedFanAuthority.snapshot()` adds to the read path's answer.
    ///
    /// `ReadOnlyFanAuthority` cannot answer any of this. It reads the machine and knows
    /// nothing about leases, and `SupervisedFanAuthority.snapshot()` reads the lease **after**
    /// the machine on purpose — so the composition is: the read path produces the fan, this
    /// re-states one field of it, and the ordering that makes a lapsing lease honest is
    /// preserved.
    ///
    /// The first two are separate functions because they answer to different mechanisms —
    /// § 6's post-reconciliation baseline and the lease core's handback ledgers — and they
    /// compose in either order for the reason this file's header gives: the fans they speak
    /// about are disjoint by construction. The third, § 7's seal, is applied last and only to
    /// what the other two left `.available`.
    ///
    /// `observedMode` is `F<n>Md`'s answer for this fan on the read it was built from, `nil`
    /// when it did not answer — `MachineObservation.modes`, never a second read (#360).
    static func restatingAvailability(
        of fan: FanState, observedMode: FirmwareFanMode?, given leases: LeaseAccountability,
        reconciliation baseline: ReconciliationBaseline
    ) -> FanState {
        reportingMachineWideRestore(
            of: reportingHandbackState(
                of: reportingForeignControl(
                    of: fan, observedMode: observedMode, heldByAeolus: leases.accountableFans,
                    awaitingConfirmation: leases.restoresAwaitingConfirmation,
                    reconciliation: baseline),
                given: leases),
            given: leases)
    }

    /// Step 10 of the ladder: the machine-wide restore seal
    /// ([#350](https://github.com/blamechris/Aeolus/issues/350), #364), as one fan's availability.
    ///
    /// While § 7's panic verb or § 4's handback runs, a fan that would otherwise read `.available`
    /// reads `.unavailable(.releaseInProgress)`, the reason `acquireLease` throws for it. Every
    /// other answer passes through untouched; see this file's header for why that is the whole
    /// rule. During a sealed sleep the grant says `.systemSleeping` first, which this ladder does
    /// not state yet ([#269](https://github.com/blamechris/Aeolus/issues/269)); #269's rung goes
    /// above this one and below step 5, as this file's header says.
    static func reportingMachineWideRestore(
        of fan: FanState, given leases: LeaseAccountability
    ) -> FanState {
        guard leases.machineWideRestoreInFlight, fan.manualControlAvailability == .available
        else { return fan }
        return restating(fan, as: .unavailable(.releaseInProgress))
    }

    /// Steps 1–3 of the ladder: what the lease core would refuse a grant over this fan for.
    ///
    /// ## What [#187](https://github.com/blamechris/Aeolus/issues/187) was
    ///
    /// The three registers behind these reasons reached a client **only** as an `acquireLease`
    /// fault. Nothing put any of them into `SystemSnapshot`, so a fan whose handback was in
    /// flight — or, worse, one whose handback had been abandoned outright and never would
    /// complete — rendered as `.available` in the same instant a grant over it was refused. The
    /// user clicks, and the click fails for a reason the screen never showed: `CLAUDE.md`
    /// rule 6, in the read path rather than the write path.
    ///
    /// `.restoreToAutomaticFailed` is what made it worth a safety label rather than a polish
    /// issue. `.releaseInProgress` is transient and resolves in milliseconds, so a client that
    /// retried would get its lease; the durable refusal never resolves, so a permanently
    /// unleasable fan was permanently displayed as available.
    ///
    /// ## The order is `acquireLease`'s, not a fresh judgement
    ///
    /// Most durable first, matching the straight-line region of
    /// `LeaseAuthority.acquireLease` statement for statement: abandoned, then unconfirmed, then
    /// in flight. That is not a coincidence to be preserved by care — it is the property
    /// #187's acceptance asks for, and `SnapshotAvailabilityTests` asserts it by putting a fan
    /// into a register and requiring the snapshot's reason and the thrown fault's reason to be
    /// the *same value*.
    ///
    /// `.handbackUnconfirmed` sits above `.releaseInProgress` for the reason the grant path
    /// gives at length: an unconfirmed fan is mid-`releasing` too, by the lease core's own
    /// subset invariant, so without this ordering a client would be told *"retry in a moment"*
    /// about a restore that has already outlived a five-second budget.
    ///
    /// ## What it overwrites
    ///
    /// The read path's answer, which since [#355](https://github.com/blamechris/Aeolus/issues/355)
    /// is only ever the build, the bounds gate or `.available`. Before it, the read path said
    /// `.supervisorBlind` for a fan § 5 went blind on, and one whose restore then failed was in
    /// both the ledger and `restoreAbandoned`: this overwrote the blindness with
    /// `.restoreToAutomaticFailed`, the answer `acquireLease` gives, because the abandoned
    /// handback is the fact that the fan is still pinned. That fan reads the same today, with no
    /// diagnosis left beneath it to overwrite.
    static func reportingHandbackState(
        of fan: FanState, given leases: LeaseAccountability
    ) -> FanState {
        guard let reason = handbackRefusal(forFanAt: fan.index, given: leases) else { return fan }
        return restating(fan, as: .unavailable(reason))
    }

    /// The three registers, read in `acquireLease`'s own order. `nil` when none names this fan.
    private static func handbackRefusal(
        forFanAt index: Int, given leases: LeaseAccountability
    ) -> ManualControlAvailability.Reason? {
        if leases.abandonedHandbacks.contains(index) { return .restoreToAutomaticFailed }
        if leases.unconfirmedHandbacks.contains(index) { return .handbackUnconfirmed }
        if leases.handbacksInFlight.contains(index) { return .releaseInProgress }
        return nil
    }

    /// One fan with one field replaced, and every other field passed through untouched.
    ///
    /// `FanState.manualControlAvailability` is a `let` with no default — deliberately, so no
    /// producer can forget to state it — so a re-statement is a re-assembly. Written once here
    /// rather than at each call site: two copies of this initialiser call are two
    /// places a field can be dropped or transposed, and a transposed `minimumRPM`/`maximumRPM`
    /// would be a silent change to what the bounds gate judges.
    private static func restating(
        _ fan: FanState, as availability: ManualControlAvailability
    ) -> FanState {
        FanState(
            index: fan.index,
            firmwareName: fan.firmwareName,
            actualRPM: fan.actualRPM,
            minimumRPM: fan.minimumRPM,
            maximumRPM: fan.maximumRPM,
            targetRPM: fan.targetRPM,
            mode: fan.mode,
            isReclaimedBySystem: fan.isReclaimedBySystem,
            manualControlAvailability: availability
        )
    }

    /// Step 5 of the ladder: § 6's post-reconciliation baseline, as one fan's availability.
    ///
    /// ## The rule, and the one fan it leaves alone
    ///
    /// A fan whose firmware mode is not automatic, that no live lease covers, is under
    /// somebody else's control — startup reconciliation restored anything it found in manual
    /// before this process served a single client, so a fan in manual now was put there
    /// afterwards and not by Aeolus. See
    /// [ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md).
    ///
    /// The fan it leaves alone is one Aeolus is accountable for, `held`, which steps 1–3
    /// answer for more precisely. Everything else is judged, and in
    /// `StartupReconciliation.refusalForGrant`'s order, question for question: the `held`
    /// exemption, the durable reconciliation refusal, the mode three ways, § 3's kept set
    /// (#303), then `.foreignManualControl`.
    ///
    /// ## A mode that did not read is `.supervisorBlind`
    ///
    /// [#360](https://github.com/blamechris/Aeolus/issues/360). `observedMode` is what `F<n>Md`
    /// answered on the read this fan was built from, `nil` when it did not answer, and the grant
    /// refuses `.supervisorBlind` when its own read throws — so this does too, for every fan the
    /// guards above leave, not only § 3's kept set. Before #360 this judged `FanState.mode`,
    /// which folds an unread mode into automatic
    /// ([#178](https://github.com/blamechris/Aeolus/issues/178)), and such a fan read
    /// `.available` beside the grant's refusal; `fanctl auto` then read it as cleared.
    ///
    /// `observedMode` is **required, with no default**: `nil` would make every fan blind, and
    /// `.automatic` would put the fold back here. The `switch` is exhaustive, so a third
    /// `FirmwareFanMode` case — ADR 0014's U0 failing — is a compile error here rather than a fan
    /// silently judged one way. Not stated over `.writePathNotBuilt`, for the durable refusal's
    /// reason below and through the same `canWrite`.
    ///
    /// ## § 5's fans are judged like any other
    ///
    /// [#355](https://github.com/blamechris/Aeolus/issues/355). Until it, this step exempted a
    /// fan § 5 had given up: `!fan.isReclaimedBySystem` beside the `held` check, and an arm
    /// returning a fan the read path had called `.supervisorBlind` untouched, on the argument
    /// that a diagnosis outranks a guess. `refusalForGrant` makes no such exemption, so it was a
    /// second place for the two answers to part: a fan § 5 gave up, that another program took
    /// afterwards, read `.available` here while the grant refused it `.foreignManualControl`.
    /// That is the ladder's corollary in this file's header, a past diagnosis standing in for
    /// current evidence.
    ///
    /// The harm the exemption guarded against was blaming another program for the operating
    /// system's hold. It does not need guarding here: under ADR 0014's U0 the system's hold
    /// reads raw `F<n>Md = 0`, automatic, and never reaches the foreign answer, and Aeolus's own
    /// restore that has not been confirmed is § 3's kept set below,
    /// `.restoreToAutomaticUnconfirmed`. If U0 fails, the grant is already wrong the same way,
    /// and ADR 0014 re-decides the mode fold before its first run. `isReclaimedBySystem` stays
    /// set beside the answer, as history: it can go stale once another program takes the fan,
    /// and the availability is the field that is current.
    ///
    /// Everything else is overwritten, including `.available`. Writing the guard as "only
    /// when the read path said `.writePathNotBuilt`" would pass today and silently stop
    /// applying on the day E3 makes that answer something else.
    ///
    /// ## The durable refusal comes first, and applies whatever the fan's mode
    ///
    /// A fan reconciliation refused is refused whether it reads automatic now or not: the
    /// grant path asks the baseline *before* its fresh read, and answers from it without
    /// reading at all. So the mode is judged below it rather than above.
    ///
    /// **Except over `.writePathNotBuilt`**, which the grant path answers first — see this
    /// file's header. Keyed on the read path's own answer rather than on a capability passed
    /// in, and in the direction that cannot go quietly dead: the day E3 makes the seam
    /// `.built`, the read path stops saying `.writePathNotBuilt` and the durable refusal
    /// starts applying, with nothing here to change.
    ///
    /// ## A fan § 3 is keeping is not somebody else's
    ///
    /// `awaiting` is the fans § 3 is keeping because a restore-to-automatic Aeolus issued has not
    /// been confirmed by a read, and one of them in manual is refused
    /// `.restoreToAutomaticUnconfirmed` instead — `StartupReconciliation.refusalForGrant`'s
    /// reclassification, at the same step and keyed
    /// on the same mode, so the two answers agree (#303). **Inside the manual arm, never
    /// above the `switch`**: a kept fan reading automatic is available, and a membership test
    /// ahead of it would refuse every fan for up to a cycle after each ordinary handback. And
    /// not unioned into `held`, which would return the fan untouched — `.available` on a seam
    /// that can write, with the lease then granted.
    static func reportingForeignControl(
        of fan: FanState, observedMode: FirmwareFanMode?, heldByAeolus held: Set<Int>,
        awaitingConfirmation awaiting: Set<Int>, reconciliation baseline: ReconciliationBaseline
    ) -> FanState {
        guard !held.contains(fan.index) else { return fan }
        let canWrite = fan.manualControlAvailability != .unavailable(.writePathNotBuilt)
        if canWrite, let durable = baseline.durableRefusal(overFans: [fan.index]) {
            return restating(fan, as: .unavailable(durable))
        }
        switch observedMode {
        case .automatic:
            return fan
        case nil:
            guard canWrite else { return fan }
            return restating(fan, as: .unavailable(.supervisorBlind))
        case .manual:
            if awaiting.contains(fan.index) {
                return restating(fan, as: .unavailable(.restoreToAutomaticUnconfirmed))
            }
            return restating(fan, as: .unavailable(.foreignManualControl))
        }
    }
}
