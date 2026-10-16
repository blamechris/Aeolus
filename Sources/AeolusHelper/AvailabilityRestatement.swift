import FanKit

// The re-statements `SupervisedFanAuthority.snapshot()` makes over the read path's answer,
// lifted out of `ReadOnlyFanReport.swift` by
// [#187](https://github.com/blamechris/Aeolus/issues/187) — which added one of them and put
// that file over the 400-line threshold #128 split it out to hold.
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
// detail. The whole order lives here, and its rule is: **the snapshot agrees with
// `LeaseAuthority.acquireLease` on whether a grant over the fan is refused, wherever the refusal
// is one a snapshot states per fan; and on the reason, except that a machine-wide refusal
// `fanctl auto` reads as silent is never stated over a fan's own durable or pending reason**
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #128/#270/#269 amendment). Two
// refusals are not stated per fan, so a fan nothing else refuses reads `.available` beside them:
// another client's lease (`.leaseHeldByAnotherClient`, last paragraph below) and § 3's latch,
// which the snapshot states machine-wide as `isThermalEmergencyActive`. Anything else is
// `CLAUDE.md` rule 6 — a screen offering control that the click cannot get, or refusing control
// the helper would in fact grant.
//
// **The rule has a corollary, and it binds both sides** (ADR 0014's 2026-10-15 amendment): a
// grant refusal, and the availability that mirrors it, is computed from **current evidence the
// grant path consults**. A diagnosis of something that already happened is a fact, and is
// reported as one. § 5's ledger is that kind of fact — `FanState.isReclaimedBySystem`, the fault
// log, the lease it ended — and is never a rung here
// ([#355](https://github.com/blamechris/Aeolus/issues/355)). A refusal that no read can clear
// seals its own exit: the only events that clear the ledger need the lease it would refuse. On
// the grant side the same rule is why `.boundsImplausible`, current evidence re-read on every
// snapshot, is in the grant ([#270](https://github.com/blamechris/Aeolus/issues/270)).
//
// **It is one first-match function, statement for statement against `acquireLease`**
// ([#269](https://github.com/blamechris/Aeolus/issues/269)): the first rung that refuses
// answers, and nothing below it is asked. It replaced re-statements layered over one another,
// each keyed on what the one before had left; a rung written as "overwrite `.available`" breaks
// silently the day a rung above it starts producing what it overwrites. In the grant's order:
//
// | # | Reason | What it mirrors in `acquireLease` |
// |---|---|---|
// | 6 | `.writePathNotBuilt`, with only step 5's manual arm over it | `refuseIfWritePathNotBuilt` |
// | 5 | § 6's durable refusal, `.supervisorBlind`, § 3's kept set, foreign | the foreign read |
// | 8 | `.boundsImplausible`, for a fan Aeolus is not accountable for | the bounds read |
// | 1 | `.restoreToAutomaticFailed`, from `abandonedHandbacks` | the region's first guard |
// | 2 | `.handbackUnconfirmed`, from `unconfirmedHandbacks` | its second |
// | 11 | `.systemSleeping`, from `sleepSealed` | its third |
// | 10 | `.releaseInProgress`, from `machineWideRestoreInFlight` | its fourth |
// | 3 | `.releaseInProgress`, from `handbacksInFlight` | `releasing`, after the table |
// | 9 | `.available`, or step 8's answer for a fan under lease | the grant |
// | 12 | `.noThermalTelemetry`, over `.available` and `.boundsImplausible` | `refuseIfBlind` |
//
// **Step numbers are names, not places.** Steps 4 and 7 were § 5's ledger — `.supervisorBlind`
// and `.reclaimedBySystem` — until #355 removed them, and stay retired so that every reference to
// a step still names the same rung; 10, 11 and 12 are numbered in the order they were added.
//
// **Step 8 speaks only for fans Aeolus is not accountable for**, the fans the grant's bounds read
// covers: it subtracts what the foreign-control read exempted. An accountable fan is answered by
// the register that holds it, or, under a lease, by step 9, which then states the read path's
// answer, step 8's if the bounds are bad: the grant answers that fan `.leaseHeldByAnotherClient`,
// which a snapshot cannot state (below), and both refuse.
//
// **Steps 1, 2, 11, 10 and 3 are the straight-line region's guards in its order**, most durable
// first; the lease table sits between 10 and 3 there. Step 3 is below steps 11 and 10, so during
// a sealed teardown a fan mid-handback reads `.systemSleeping`, as the grant refuses it, and one
// whose handback outlived § 4's budget reads `.handbackUnconfirmed`, above both.
//
// **Step 11 follows the grant's order exactly**, because `SafeState` classes `.systemSleeping`
// pending, so the rule's exception does not reach it. If ADR 0013 ever classes it silent, it must
// drop below steps 3 and 10 in the same change: it would then be a silent machine-wide refusal
// stated over a fan's own pending reason, which is step 12's case.
//
// **Step 12 is the one rung out of the grant's order, and it is what the rule's exception is
// for.** The grant asks blindness before every per-fan step, because that check suspends. In
// that order the rung would state `.noThermalTelemetry` — silent: "the mode decides" — over
// step 5's answers, the registers and the seals, which `SafeState` classes pending or durable,
// and `fanctl auto` would exit 0 about a fan whose mode did not read, on a machine that cannot
// read: #360's defect, on the machine likeliest to produce it. So it re-states `.available` and
// `.boundsImplausible` and nothing else; where it does not, both sides refuse and the snapshot
// keeps the fan's own reason. Step 5's manual arm over step 6 is the exception's first instance.
// `blind` is one `sighting()` per snapshot, of the cache the grant asks, on a `.built` seam only
// (`SupervisedFanAuthority`): on `.notBuilt` step 6 masks steps 11 and 12 and nothing is asked.
//
// **Steps 1–3 and step 5 cannot both apply.** Every fan in one of the three handback registers is
// in `LeaseAuthority.fansAeolusIsAccountableFor`, and `reportingForeignControl` returns such a fan
// untouched — foreign control is by definition a fan Aeolus is *not* accountable for. So step 5,
// above the registers as the grant's foreign read is above its region, never speaks over one;
// `SnapshotAvailabilityTests` asserts the containment, because a change to either set would make
// step 5 start answering for a register's fan silently.
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
// untouched and would read `.available`. The steps-1–3 disjointness above is unchanged by it —
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
// the reader is the holder. `SystemSnapshot.activeLease` is how a client learns it.

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
    /// The ladder is `firstRefusal(of:observedMode:given:reconciliation:)`, then step 12 over
    /// what it answered; this file's header gives the order and why. `observedMode` is `F<n>Md`'s
    /// answer for this fan on the read it was built from, `nil` when it did not answer —
    /// `MachineObservation.modes`, never a second read (#360). `blind` is whether this snapshot's
    /// one `sighting()` failed, and is **required, with no default**, for `observedMode`'s reason:
    /// `false` would hide § 3's blindness and `true` would state it over every fan. It is `false`
    /// on a seam that cannot write, where nothing was asked.
    static func restatingAvailability(
        of fan: FanState, observedMode: FirmwareFanMode?, given leases: LeaseAccountability,
        reconciliation baseline: ReconciliationBaseline, blind: Bool
    ) -> FanState {
        let answer = firstRefusal(
            of: fan, observedMode: observedMode, given: leases, reconciliation: baseline)
        // Step 12, `refuseIfBlind`: first in the grant and last here, over a fan nothing else
        // refuses or one whose only refusal is step 8's, which `fanctl auto` reads as silent too.
        let silent = answer == .available || answer == .unavailable(.boundsImplausible)
        return restating(fan, as: blind && silent ? .unavailable(.noThermalTelemetry) : answer)
    }

    /// Every rung but step 12, first match, in `acquireLease`'s order.
    ///
    /// ## What [#187](https://github.com/blamechris/Aeolus/issues/187) was
    ///
    /// The three handback registers reached a client **only** as an `acquireLease` fault, so a
    /// fan whose handback was in flight — or, worse, one whose handback had been abandoned
    /// outright and never would complete — rendered as `.available` in the same instant a grant
    /// over it was refused: `CLAUDE.md` rule 6, in the read path. `.restoreToAutomaticFailed` is
    /// what made it a safety label rather than polish: `.releaseInProgress` resolves in
    /// milliseconds, while the durable refusal never does, so a permanently unleasable fan was
    /// permanently displayed as available.
    ///
    /// ## The order is `acquireLease`'s, not a fresh judgement
    ///
    /// Statement for statement, and that is not a coincidence to be preserved by care: it is the
    /// property the agreement suites assert, by putting a fan where a rung applies and requiring
    /// the snapshot's reason and the thrown fault's reason to be the *same value*.
    /// `.handbackUnconfirmed` sits above both `.releaseInProgress` rungs for the reason the grant
    /// path gives: an unconfirmed fan is mid-`releasing` too, by the lease core's own subset
    /// invariant, so without this order a client would be told *"retry in a moment"* about a
    /// restore that has already outlived a five-second budget.
    ///
    /// Step 5 is asked first and step 6 second only because step 5's manual arm is the one answer
    /// stated over step 6; every other arm defers to it inside `reportingForeignControl`. That
    /// function returns the fan untouched or states a reason the read path never gives, so an
    /// answer that changed is step 5's.
    private static func firstRefusal(
        of fan: FanState, observedMode: FirmwareFanMode?, given leases: LeaseAccountability,
        reconciliation baseline: ReconciliationBaseline
    ) -> ManualControlAvailability {
        let readPath = fan.manualControlAvailability
        let index = fan.index
        // Steps 5 and 6: `refuseIfWritePathNotBuilt`, with step 5's manual arm alone over it, and
        // `refuseIfForeignManualControl`.
        let judged = reportingForeignControl(
            of: fan, observedMode: observedMode, heldByAeolus: leases.accountableFans,
            awaitingConfirmation: leases.restoresAwaitingConfirmation, reconciliation: baseline
        ).manualControlAvailability
        if judged != readPath { return judged }
        if readPath == .unavailable(.writePathNotBuilt) { return readPath }
        // Step 8: `refuseIfBoundsImplausible`, over the fans step 5 did not exempt.
        let accountable = leases.accountableFans.contains(index)
        if !accountable, readPath == .unavailable(.boundsImplausible) { return readPath }
        // Steps 1, 2, 11, 10 and 3: the straight-line region's guards, in its order.
        if leases.abandonedHandbacks.contains(index) {
            return .unavailable(.restoreToAutomaticFailed)
        }
        if leases.unconfirmedHandbacks.contains(index) { return .unavailable(.handbackUnconfirmed) }
        if leases.sleepSealed { return .unavailable(.systemSleeping) }
        if leases.machineWideRestoreInFlight { return .unavailable(.releaseInProgress) }
        if leases.handbacksInFlight.contains(index) { return .unavailable(.releaseInProgress) }
        // Step 9: `.available`, or step 8's answer for a fan under lease.
        return readPath
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
