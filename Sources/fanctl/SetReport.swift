import AeolusXPC
import FanKit
import Foundation

extension SetCommand {

    /// How a run ended, in everything the output needs: the exit, the closing event and the
    /// closing line. Built once, at the end, from what the helper reported.
    struct Report: Sendable {
        /// The exit. `nil` is exit 0.
        let failure: HelperCommandFailure?
        let leaseID: UUID?
        let endedBecause: String?
        let signal: HoldSignal?
        let release: Release?
        /// The last snapshot the helper returned, if it returned one.
        let snapshot: SystemSnapshot?
        /// Whether `snapshot` was read after the release was asked for.
        let snapshotFollowsRelease: Bool
        let plans: [SetFanPlan]
        /// The one line a clean ending prints. `nil` for every ending that is not one.
        let closingLine: String?

        /// The closing event's shared fields.
        var facts: SetClosingFacts {
            SetClosingFacts(
                leaseID: leaseID, endedBecause: endedBecause, signal: signal?.name,
                releaseAccepted: release?.isAccepted, capturedAt: snapshot?.capturedAt,
                snapshotFollowsRelease: snapshot == nil ? nil : snapshotFollowsRelease,
                listedLeaseID: snapshot?.activeLease?.id,
                fans: plans.isEmpty
                    ? nil
                    : plans.map { plan in
                        SetFanJSON(
                            plan: plan,
                            observed: snapshot?.fans.first { $0.index == plan.index })
                    })
        }

        // MARK: Before any lease

        /// Nothing was acquired: the helper could not be asked, the request does not fit this
        /// machine, or the helper refused the lease. `refused` is the three refusals a person
        /// can act on (2, 4, 5); the rest are not a "no" to this request.
        static func notStarted(_ failure: HelperCommandFailure) -> Report {
            let refusals: Set<FanctlExitCode> = [
                .requestDoesNotFit, .manualControlRefused, .heldByAnotherClient,
            ]
            return Report(
                failure: failure, leaseID: nil,
                endedBecause: refusals.contains(failure.code) ? "refused" : nil, signal: nil,
                release: nil, snapshot: nil, snapshotFollowsRelease: false, plans: [],
                closingLine: nil)
        }

        /// A signal arrived while connecting. Nothing was held, so nothing is released and no
        /// speed is written for a person who already asked to stop. The hold ended *because of
        /// the signal*, so that is what `endedBecause` says, with the signal named.
        static func interruptedBeforeControl(_ signal: HoldSignal) -> Report {
            Report(
                failure: HelperCommandFailure(
                    .failure, SetMessages.interruptedBeforeControl(signal)),
                leaseID: nil, endedBecause: Ending.signal(signal).endedBecause, signal: signal,
                release: nil, snapshot: nil, snapshotFollowsRelease: false, plans: [],
                closingLine: nil)
        }

        // MARK: A lease, and then no hold

        /// A signal landed while the lease was in flight. The lease was taken and then given
        /// back, and no speed was sent. Exit 1, as for a signal before the lease.
        static func interruptedBeforeApply(
            _ signal: HoldSignal, hold: Hold, release: Release
        ) -> Report {
            Report(
                failure: HelperCommandFailure(
                    .failure,
                    SetMessages.interruptedBeforeApply(signal, hold: hold, release: release)),
                leaseID: hold.leaseID, endedBecause: Ending.signal(signal).endedBecause,
                signal: signal, release: release, snapshot: nil, snapshotFollowsRelease: false,
                plans: hold.plans, closingLine: nil)
        }

        /// `apply` was **refused**: the helper answered with a fault. The lease was released; the
        /// code is the one the fault classified to.
        static func refused(
            _ failure: HelperCommandFailure, hold: Hold, release: Release
        ) -> Report {
            Report(
                failure: HelperCommandFailure(
                    failure.code, SetMessages.refused(failure, hold: hold, release: release)),
                leaseID: hold.leaseID, endedBecause: "refused", signal: nil, release: release,
                snapshot: nil, snapshotFollowsRelease: false, plans: hold.plans,
                closingLine: nil)
        }

        /// `apply` got **no answer**: the speed may have been applied, which is not a refusal.
        /// The lease was released and the safe-state check looked; the exit is still the code the
        /// failure classified to, and the check's verdict is in the message and the facts.
        static func applyUnanswered(
            _ failure: HelperCommandFailure, hold: Hold, release: Release,
            settlement: SafeState.Settlement
        ) -> Report {
            Report(
                failure: HelperCommandFailure(
                    failure.code,
                    SetMessages.unansweredApply(
                        failure, hold: hold, release: release, settlement: settlement)),
                leaseID: hold.leaseID, endedBecause: "controlLost", signal: nil, release: release,
                snapshot: settlement.snapshot,
                snapshotFollowsRelease: settlement.snapshot != nil, plans: hold.plans,
                closingLine: nil)
        }

        // MARK: Control held, then lost

        /// Exit 6: the helper reported that the lease is no longer proof of control.
        static func lost(
            _ loss: Loss, hold: Hold, release: Release, snapshot: SystemSnapshot?
        ) -> Report {
            Report(
                failure: HelperCommandFailure(
                    .controlLost, SetMessages.lost(loss, hold: hold, release: release)),
                leaseID: hold.leaseID, endedBecause: "controlLost", signal: nil,
                release: release, snapshot: snapshot, snapshotFollowsRelease: false,
                plans: hold.plans, closingLine: nil)
        }

        /// The loop's own timer failed: released, and exit 1, because it is neither a loss the
        /// helper reported nor an ending anyone asked for.
        static func timerFailed(
            hold: Hold, release: Release, snapshot: SystemSnapshot?
        ) -> Report {
            Report(
                failure: HelperCommandFailure(
                    .failure, SetMessages.timerFailed(hold: hold, release: release)),
                leaseID: hold.leaseID, endedBecause: nil, signal: nil, release: release,
                snapshot: snapshot, snapshotFollowsRelease: false, plans: hold.plans,
                closingLine: nil)
        }

        // MARK: An ordinary ending, and the safe-state check after it

        /// 0, 8 or 9, from the same check `fanctl auto` ends on.
        ///
        /// A lease still listed when the wait ends is `notConfirmed` here, and so 8: whether
        /// it is this run's (the release did not take) or another client's is named in the
        /// message. `auto` maps that case to 5 because naming the holder is the useful thing
        /// to say there; `set`'s own contract has no such code, and the lease may be its own.
        static func ended(
            _ ending: Ending, hold: Hold, release: Release, settlement: SafeState.Settlement,
            before: SystemSnapshot?
        ) -> Report {
            let snapshot = settlement.snapshot ?? before
            let observed = settlement.snapshot != nil
            let failure: HelperCommandFailure?
            var closing: String?
            switch settlement.verdict {
            case .automatic:
                failure = nil
                closing = SetMessages.closingLine(
                    ending, hold: hold, release: release, snapshot: settlement.snapshot)
            case .cannotReturn(let pinned):
                failure = HelperCommandFailure(
                    .cannotReturnToAutomatic,
                    SetMessages.cannotReturn(
                        lead: SetMessages.lead(ending, hold: hold), hold: hold, release: release,
                        snapshot: settlement.snapshot, pinned: pinned))
            case .notConfirmed:
                failure = HelperCommandFailure(
                    .safeStateNotConfirmed,
                    SetMessages.notConfirmed(
                        lead: SetMessages.lead(ending, hold: hold), hold: hold, release: release,
                        settlement: settlement))
            }
            return Report(
                failure: failure, leaseID: hold.leaseID, endedBecause: ending.endedBecause,
                signal: ending.signal, release: release, snapshot: snapshot,
                snapshotFollowsRelease: observed, plans: hold.plans, closingLine: closing)
        }
    }
}
