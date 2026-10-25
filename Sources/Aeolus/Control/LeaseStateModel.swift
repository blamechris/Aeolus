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
/// `readSoon()`. It runs once per floor, never for a report whose evidence is unchanged.
@MainActor
final class LeaseStateModel: ObservableObject {

    private var stored: LeaseDriverReport = .idle
    private let whenTheDriverStopsActing: @MainActor () -> Void

    /// The driver's report, as last delivered to the main actor.
    var current: LeaseDriverReport { stored }

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

    private func publish(_ report: LeaseDriverReport) {
        guard report != stored else { return }
        let newFloor =
            report.automaticEvidence != stored.automaticEvidence
            && Self.isFloor(report.automaticEvidence)
        objectWillChange.send()
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
