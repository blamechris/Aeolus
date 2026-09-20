import FanKit

// The two re-statements `SupervisedFanAuthority.snapshot()` makes over the read path's
// answer, lifted out of `ReadOnlyFanReport.swift` by
// [#187](https://github.com/blamechris/Aeolus/issues/187) — which added one of them and put
// that file over the 400-line threshold #128 split it out to hold.
//
// Same trade as `LeaseAuthorityRefusals.swift`, and cheaper: `ReadOnlyFanReport` is a
// namespace of pure functions with no state, so nothing widens with the move. The one member
// that stayed behind is `availability(whenLedgerSays:writeCapabilityIs:bounds:)`, because
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
// Highest first, with the step that produces each:
//
// | # | Reason | Produced by |
// |---|---|---|
// | 1 | `.restoreToAutomaticFailed` | `reportingHandbackState` — § 4/§ 5's durable register |
// | 2 | `.handbackUnconfirmed` | `reportingHandbackState` — § 4's budget expired |
// | 3 | `.releaseInProgress` | `reportingHandbackState` — a restore on the wire |
// | 4 | `.supervisorBlind` | `availability(whenLedgerSays:…)` — § 5's ledger |
// | 5 | `.foreignManualControl` | `reportingForeignControl` — § 6's baseline |
// | 6 | `.writePathNotBuilt` | `availability(whenLedgerSays:…)` — the seam's capability |
// | 7 | `.reclaimedBySystem` | `availability(whenLedgerSays:…)` — § 5's ledger |
// | 8 | `.boundsImplausible` | `availability(whenLedgerSays:…)` — § 2's gate |
// | 9 | `.available` | nothing refused |
//
// **Steps 1–3 and step 5 cannot both apply, so their relative order is not load-bearing and
// is not relied on.** Every fan in one of the three handback registers is in
// `LeaseAuthority.fansAeolusIsAccountableFor`, and `reportingForeignControl` returns such a
// fan untouched — foreign control is by definition a fan Aeolus is *not* accountable for.
// That disjointness is what lets the two re-statements compose in either order; it is
// asserted by `SnapshotAvailabilityTests`, because a change to either set would make the
// composition order start mattering silently.
//
// **`.leaseHeldByAnotherClient` is absent from the ladder and cannot be added.** See
// `LeaseAccountability`: a snapshot has no `ConnectionID`, so the helper cannot know whether
// the reader is the holder. `.systemSleeping` is absent for a weaker reason — § 4's seal is
// machine-wide state the snapshot does not read — and is
// [#269](https://github.com/blamechris/Aeolus/issues/269)'s.

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
    /// The two halves are separate functions because they answer to different mechanisms —
    /// § 6's post-reconciliation baseline and the lease core's handback ledgers — and they
    /// compose in either order for the reason this type's own documentation gives: the fans
    /// they speak about are disjoint by construction.
    static func restatingAvailability(
        of fan: FanState, given leases: LeaseAccountability
    ) -> FanState {
        reportingHandbackState(
            of: reportingForeignControl(of: fan, heldByAeolus: leases.accountableFans),
            given: leases)
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
    /// ## It overwrites `.supervisorBlind`, and that is the one precedence this changes
    ///
    /// A fan § 5 went blind on, whose restore then failed, is in both the ledger and
    /// `restoreAbandoned` — and `acquireLease` answers `.restoreToAutomaticFailed` for it. The
    /// blindness is the diagnosis of how the fan was lost; the abandoned handback is the fact
    /// that it is still pinned and Aeolus cannot take it back, which is both the more
    /// consequential statement and the one the grant path makes. Agreement decides it.
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
    /// rather than at each of the two call sites: two copies of this initialiser call are two
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
    /// ## The rule, and the two fans it leaves alone
    ///
    /// A fan whose firmware mode is not automatic, that no live lease covers, is under
    /// somebody else's control — startup reconciliation restored anything it found in manual
    /// before this process served a single client, so a fan in manual now was put there
    /// afterwards and not by Aeolus. See
    /// [ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md).
    ///
    /// It is **not** applied over § 5's two causes. `.supervisorBlind` and a system
    /// reclamation are statements about a fan Aeolus *engaged* — the ledger's registry holds
    /// nothing else — and both are more specific than this one. Overwriting either would
    /// replace a diagnosis with a guess, and in the reclamation case would blame a third
    /// party for the operating system's act.
    ///
    /// **The two causes are asked for differently, and that is the correction rather than a
    /// quirk.** Blindness is read off the availability, because `availability(whenLedgerSays:
    /// writeCapabilityIs:bounds:)` publishes it there. A reclamation is read off
    /// `isReclaimedBySystem`, because on every build that has shipped that method deliberately
    /// does *not* publish `.reclaimedBySystem` as an availability — #140's rule is that a
    /// reclaimed fan is still `.writePathNotBuilt` in this build — so a switch looking for
    /// `.unavailable(.reclaimedBySystem)` matched nothing at all. That arm was dead code, and
    /// its deletion is not a loosening: the guard it promised is the `isReclaimedBySystem`
    /// check that replaces it, which is keyed on the ledger's own cause and therefore cannot
    /// be made dead by a change to what the availability says.
    ///
    /// That last sentence is the load-bearing one, and #194 is what proved it. A `.built` seam
    /// now *does* make that method publish `.reclaimedBySystem`, so a switch-based guard would
    /// have silently come back to life — with a reachability nothing here would have had to
    /// argue for. The `isReclaimedBySystem` check is indifferent to the change.
    ///
    /// Everything else is overwritten, including `.available`. Writing the guard as "only
    /// when the read path said `.writePathNotBuilt`" would pass today and silently stop
    /// applying on the day E3 makes that answer something else.
    static func reportingForeignControl(
        of fan: FanState, heldByAeolus held: Set<Int>
    ) -> FanState {
        guard fan.mode != .automatic, !held.contains(fan.index), !fan.isReclaimedBySystem
        else { return fan }
        switch fan.manualControlAvailability {
        case .unavailable(.supervisorBlind): return fan
        default: break
        }
        return restating(fan, as: .unavailable(.foreignManualControl))
    }
}
