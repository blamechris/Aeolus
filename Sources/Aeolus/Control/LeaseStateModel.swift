import AeolusLeaseControl
import Combine

/// The lease driver's reports on the main actor, for views to read in `body` (#153's PR 6b): its
/// state, and which reads may show a fan automatic beside it (ADR 0015 D2).
///
/// `AppComposition` owns the app's one instance. In a build with a helper it follows
/// `LeaseDriver.reportUpdates()` from a task of its own, so a change of the driver's state with no
/// new snapshot still re-renders every view that reads it: a refused renewal turning `held` into
/// `lost` takes Custom off screen at once, rather than at the next snapshot, which can be a minute
/// away (`FanControlPresentation`'s contract: recompute whenever the driver's state changes as
/// well). In a build with no helper it is `LeaseDriverReport.idle`, for good.
///
/// **The state and its evidence are one value.** The driver publishes them as one report, and this
/// stores the report whole, so a view never pairs a state with an older floor.
///
/// **Views read `current`; no view subscribes to the driver.** A view's `.task { for await … }`
/// would be a second reader per window, each started and cancelled by SwiftUI, and a view that
/// read `driver.state` once would keep that answer.
///
/// `current` is get-only and computed, over a `private` stored value, so its key path is a plain
/// `KeyPath`: no other file can write the report views are shown, by a dynamic cast or otherwise
/// (SR-5218, as `PollingViewModel.renderedSnapshot`).
///
/// ## The read it asks for when the driver stops acting
///
/// Automatic is claimed only from a snapshot read after the driver's floor, and the source's next
/// ordinary read can be a minute away. So each report that carries a new floor runs
/// `whenTheDriverStopsActing`, after the report is stored: `AppComposition` passes the source's
/// `readSoon()`. It runs once per floor, never for a report whose evidence is unchanged. A floor
/// also comes without a stop: when a release answers ahead of an acquisition, and when the last
/// unanswered `apply` answers beside a held lease (ADR 0015 D5). Each asks for the read the same
/// way, for the fans that lease does not cover.
///
/// ## Whether the user's own Auto came before the state (#157)
///
/// `released` does not say who released. Closing the last control window and fast user switching
/// away reach the driver through `LeaseLifecycle`, which calls `LeaseDriver.releaseFans()`, and
/// leave the app running in `released`. A power-off notice does the same, and whether a logout
/// cancelled at its dialog leaves the app running after one is a hardware check #153 lists. None
/// of them is the user choosing Auto. So the root tells this model each time the user asks for
/// something (`userAskedForAutomatic()`, `userAskedForControl()`), and
/// `enteredAfterTheUsersAuto` says whether the driver's state now was entered after the user's
/// last request, and that request was Auto. `MonitoringModeDisplay` asks it before it says "as
/// you chose".
@MainActor
final class LeaseStateModel: ObservableObject {

    private var stored: LeaseDriverReport = .idle
    private let whenTheDriverStopsActing: @MainActor () -> Void

    /// Whether the user's last request through the root was Auto, with no `take` or `adjust`
    /// since.
    private var lastAskedForAutomatic = false
    /// Whether the driver's state in `stored` was entered while `lastAskedForAutomatic` held.
    private var stateFollowsAutomatic = false

    /// The driver's report, as last delivered to the main actor.
    var current: LeaseDriverReport { stored }

    /// Whether the driver entered the state in `current` after the user last asked for Auto, with
    /// nothing else asked for since. **A change of state is what counts**, never a report alone:
    /// a report that moves only the evidence (an `apply` answering after the stop) keeps the
    /// answer the state had.
    ///
    /// - `false` until the user asks for Auto, and from each `take` or `adjust` until the next
    ///   Auto.
    /// - `false` for the state the driver is already in when Auto is asked for: that state was
    ///   entered before the request. A second Auto with nothing asked for between changes nothing.
    /// - `true` from the first state the driver enters after it. That can be `releasing`, `lost`
    ///   or `released`, so this says nothing about how the release ended: the caller reads the
    ///   state as well.
    ///
    /// The request is recorded as it is made, on the main actor, before the root starts the
    /// driver call. A state the driver entered before the call reached it, and delivered here
    /// after the request, counts as after it. The user did ask for Auto last in that case too.
    var enteredAfterTheUsersAuto: Bool { stateFollowsAutomatic }

    /// A build with no driver: `.idle`, and nothing ever changes it.
    init() {
        whenTheDriverStopsActing = {}
    }

    /// Follows `reports` from its first value, until this model goes, and runs
    /// `whenTheDriverStopsActing` for each report that carries a new floor.
    init(
        following reports: AsyncStream<LeaseDriverReport>,
        whenTheDriverStopsActing: @escaping @MainActor () -> Void
    ) {
        self.whenTheDriverStopsActing = whenTheDriverStopsActing
        Task { [weak self] in
            for await report in reports {
                // Ends with this model: the driver's stream does not finish on its own.
                guard let self else { return }
                self.publish(report)
            }
        }
    }

    /// The user asked for Auto: the Auto segment, or the release offer, through
    /// `AppComposition.selectAutomatic()`.
    ///
    /// Changes nothing on screen. `enteredAfterTheUsersAuto` is `true` only once a state is entered
    /// with this set, and while it is, the last request was already Auto, so a second one leaves it
    /// as it is. After a `take` or an `adjust` it is already `false`.
    func userAskedForAutomatic() {
        lastAskedForAutomatic = true
    }

    /// The user asked for manual control: `AppComposition.take(_:)` or `adjust(_:)`. The state on
    /// screen was entered before this request, so it no longer follows the user's Auto.
    func userAskedForControl() {
        lastAskedForAutomatic = false
        guard stateFollowsAutomatic else { return }
        objectWillChange.send()
        stateFollowsAutomatic = false
    }

    private func publish(_ report: LeaseDriverReport) {
        guard report != stored else { return }
        let newFloor =
            report.automaticEvidence != stored.automaticEvidence
            && Self.isFloor(report.automaticEvidence)
        objectWillChange.send()
        if report.state != stored.state { stateFollowsAutomatic = lastAskedForAutomatic }
        stored = report
        if newFloor { whenTheDriverStopsActing() }
    }

    /// Whether `evidence` names a floor a read can reach. Exhaustive, with no `default:`.
    private static func isFloor(_ evidence: LeaseDriverReport.AutomaticEvidence) -> Bool {
        switch evidence {
        case .readFrom:
            return true
        case .anyRead, .noRead:
            return false
        }
    }
}
