import AeolusLeaseControl
import AeolusXPCClient
import FanKit
import Foundation

/// What the main window says, beside the control for all fans, about why Aeolus is only
/// monitoring (#157): the user chose Auto, the helper refuses manual control, the system reclaimed
/// the fans, or this build has no helper. Otherwise it says nothing.
///
/// Pure, in `HelperStatusDisplay`'s style: `state(given:)` decides which of the four holds, and
/// `banner(for:)` says it, so each sentence and the order between them are unit tests rather than
/// a look at a window. `CLAUDE.md` rule 6 governs every word: each state below names the evidence
/// it rests on, and a case that has none says nothing rather than guess.
///
/// ## The four states, and their evidence
///
/// - **No helper in this build.** The window's `ControlSource` is
///   `.notTracked(.noHelperInThisBuild)`, which only a source built with no helper produces (the
///   `Monitor` configuration, `HelperEmbedding.absent`). A fact about the build. The words are
///   `HelperStatusDisplay`'s account of it.
/// - **Reclaimed by the system.** A fan on screen whose control facts are the helper's report and
///   set `FanState.isReclaimedBySystem` (`FanControlSource.reportsReclamation`, which the fan's
///   row and the menu bar read too). The flag is history, which `FanState.isReclaimedBySystem`
///   says can go stale: it is set when the helper asked for manual control and the system took
///   the fan back (`docs/SAFETY.md` § 5). So the banner says what the helper reports happened, in
///   the past tense, and nothing about what the fan does now, which its row shows.
/// - **The helper refuses manual control of every fan.** Every fan's presentation is disabled by
///   the helper's own refusal (`FanControlPresentation`'s rule 5): a licensed snapshot, no thermal
///   emergency, no lease listed but one the driver holds, and `manualControlAvailability`
///   `.unavailable(reason)`. Each
///   reason is said in its own words, `userFacingSummary`, with its wire value beside it: the
///   refusal the fan's row and the control already give (`FanRowModel.Refusal`), so no reason is
///   described two ways. `.supervisorBlind`, which #157's thread asks to keep apart from
///   `.writePathNotBuilt` and from an ordinary automatic fan, is its own reason with its own words,
///   which point at Aeolus's own read of the fan rather than at macOS. And it is never "as you
///   chose": its clearance is pending, so a fan reporting it never reads Automatic.
///   The driver must also hold nothing and be neither acquiring nor releasing, so "monitoring
///   only" is true of Aeolus: rule 5 is reached only with no lease listed, because any listed
///   lease the driver does not hold is rule 4's.
/// - **Auto, as the user chose.** Two things, each with its own evidence:
///   1. *The user chose it.* The driver is `released`, and it entered that state after the user's
///      last request, which was Auto (`LeaseStateModel.enteredAfterTheUsersAuto`). `released`
///      alone is not enough: closing the last control window and fast user switching release
///      through `LeaseLifecycle` and leave the app running in `released`. Never `lost` or
///      `refused`, even after the user's Auto: a release the helper did not confirm ends `lost`.
///   2. *Every fan is automatic.* Every fan's selection is `.automatic`, which
///      `FanControlPresentation.automaticClaim` gives only under all four of ADR 0015 D1's
///      conditions: the driver holds nothing and is not acquiring or releasing; a licensed
///      snapshot is on screen whose read began after the driver last stopped acting, and after
///      every `apply` it sent had answered; that snapshot lists no lease; and it reports every fan
///      `isClearedToAutomatic`. So the banner says "the helper reports", never "the fans are",
///      and says no lease is listed, which is D1's third condition.
///
/// ## Precedence: the first that applies
///
/// 1. **No helper in this build.** A build fact, and nothing else can be known in it: no
///    snapshot, so no emergency, reclamation or refusal is reported.
/// 2. **Nothing, when the control facts are not tracked** for any other reason (the connection is
///    down, a snapshot is stale or overdue, a bundle is damaged). The pane's source line and the
///    control say why. The banner does not guess what the helper would say.
/// 3. **Nothing, during a thermal emergency.** `ThermalEmergencyBanner` is drawn above the window
///    while the snapshot sets the flag, and the control repeats its sentence. This banner adds
///    nothing beside it, and "monitoring only" or "as you chose" beside a red emergency bar would
///    describe the moment by something other than the emergency. Each fan's row still says
///    "Reclaimed by system".
/// 4. **Reclaimed**, whatever the driver is doing: it is the helper reporting that control the
///    helper asked for was taken back, and rule 6 says say so. Above "refused" and "as you chose":
///    `isClearedToAutomatic` does not read the flag, so a reclaimed fan can reach both, and neither
///    says what happened to it.
/// 5. **Nothing, while the driver is acquiring, holding or releasing.** The control's status lines
///    say what it is doing, and "monitoring only" would be false.
/// 6. **Refused.** Above "as you chose": a refusal is the helper's answer now, and it says what
///    the user can do next; the choice is history.
/// 7. **Auto, as you chose.**
/// 8. **Nothing** otherwise: an `idle` driver over fans that read automatic, offered or a mix of
///    refused and offered; a loss; a refused grant; a fan between snapshots.
enum MonitoringModeDisplay {

    typealias Fan = AllFansControlPresentation.Fan
    typealias Attributed = AllFansControlPresentation.Attributed

    /// Which of the four the banner says.
    enum State: Equatable, Sendable {
        case noHelperInThisBuild
        /// `fans` names the fans the helper reports reclaimed, or is `nil` when it reports every
        /// fan on screen so.
        case reclaimedBySystem(fans: [String]?)
        /// Every fan's refusal, each said once, named by the fans that give it unless every fan
        /// does (`AllFansControlPresentation.attributed`).
        case refused([Attributed<FanRowModel.Refusal>])
        case automaticAsChosen
    }

    enum Severity: Equatable {
        /// Working as designed, or as chosen.
        case normal
        /// Something the user did not ask for happened to control: drawn as a warning, as the
        /// fan's row draws "Reclaimed by system".
        case warning
    }

    /// One refusal, as drawn: its summary, after the fans that give it when not every fan does, and
    /// its wire value beside it, as a raw key sits beside a label.
    struct ReasonLine: Equatable {
        let text: String
        let wireValue: String
    }

    struct Banner: Equatable {
        let headline: String
        let detail: String?
        /// Each refusal, for `.refused`; empty for every other state.
        let reasons: [ReasonLine]
        let severity: Severity
    }

    /// Everything the banner is a function of. `fans` come from
    /// `FanControlPresentation.onScreen(in:driver:)`, judged against the same driver state.
    struct Inputs {
        let controlSource: ControlSource
        let thermalEmergency: ThermalEmergencyState
        let fans: [Fan]
        let driver: LeaseDriverState
        /// `LeaseStateModel.enteredAfterTheUsersAuto`, read with `driver`.
        let enteredAfterTheUsersAuto: Bool
    }

    /// The banner for `inputs`, or `nil` when there is nothing it may say.
    static func banner(given inputs: Inputs) -> Banner? {
        state(given: inputs).map(banner(for:))
    }

    /// What `polling` and `lease` have now, read together on the main actor: the presentations
    /// through `onScreen(in:driver:)`, as the control for all fans reads them, beside the same
    /// report. For a SwiftUI `body`, never a sink on one of `polling`'s properties
    /// (`FanControlPresentation`'s contract).
    @MainActor
    static func banner(polling: PollingViewModel, lease: LeaseStateModel) -> Banner? {
        banner(given: Inputs(polling: polling, lease: lease))
    }

    // MARK: - Which state

    /// The first state that applies, in the order this type's documentation gives.
    static func state(given inputs: Inputs) -> State? {
        switch inputs.controlSource {
        case .notTracked(.noHelperInThisBuild):
            return .noHelperInThisBuild
        case .notTracked:
            return nil
        case .helperSnapshot:
            break
        }
        guard inputs.thermalEmergency != .active else { return nil }
        let fans = inputs.fans
        let reclaimed = fans.filter { $0.reading.control.reportsReclamation }
        if !reclaimed.isEmpty {
            let named = reclaimed.count == fans.count ? nil : reclaimed.map(\.reading.displayName)
            return .reclaimedBySystem(fans: named)
        }
        guard isNotActing(inputs.driver) else { return nil }
        if let refusals = refusals(fans) { return .refused(refusals) }
        if isTheUsersAuto(inputs), everyFanReadsAutomatic(fans) { return .automaticAsChosen }
        return nil
    }

    /// Whether the driver holds nothing and is neither acquiring nor releasing. Exhaustive, with no
    /// `default:`, so a state added later has to be decided here.
    private static func isNotActing(_ driver: LeaseDriverState) -> Bool {
        switch driver {
        case .idle, .released, .lost, .refused:
            return true
        case .acquiring, .held, .releasing:
            return false
        }
    }

    /// Every fan's refusal, when every fan on screen is disabled by the helper's own refusal
    /// (`FanControlPresentation`'s rule 5), and `nil` otherwise. Compared whole with the reason
    /// rule 5 gives, so a fan disabled by an earlier rule, which carries no wire value, is not
    /// counted as refused.
    private static func refusals(_ fans: [Fan]) -> [Attributed<FanRowModel.Refusal>]? {
        guard !fans.isEmpty else { return nil }
        var refused: [(FanPollingReading, FanRowModel.Refusal)] = []
        for fan in fans {
            guard let refusal = FanRowModel(reading: fan.reading).refusal,
                fan.presentation.affordance == .disabled(FanControlPresentation.Reason(refusal))
            else { return nil }
            refused.append((fan.reading, refusal))
        }
        return AllFansControlPresentation.attributed(refused, among: fans.count)
    }

    /// The first half of "as you chose": `released`, entered after the user's last request, which
    /// was Auto. Never `lost` or `refused`.
    private static func isTheUsersAuto(_ inputs: Inputs) -> Bool {
        inputs.driver == .released && inputs.enteredAfterTheUsersAuto
    }

    /// The second half: every fan on screen reads Automatic, which only ADR 0015 D1 grants. None on
    /// screen reads nothing.
    private static func everyFanReadsAutomatic(_ fans: [Fan]) -> Bool {
        !fans.isEmpty && fans.allSatisfy { $0.presentation.selection == .automatic }
    }

    // MARK: - What it says

    /// The words for `state`. Each holds on every path into it; see this type's documentation for
    /// the evidence.
    static func banner(for state: State) -> Banner {
        switch state {
        case .noHelperInThisBuild:
            return Banner(
                headline:
                    "Monitoring only: this build ships no privileged helper, so it cannot change "
                    + "fan speeds.",
                detail: nil, reasons: [], severity: .normal)

        case .reclaimedBySystem(let fans):
            let which = fans.map { $0.joined(separator: ", ") } ?? "every fan"
            return Banner(
                headline: "The helper reports \(which) reclaimed by the system.",
                detail: "The system took back manual control the helper had asked for.",
                reasons: [], severity: .warning)

        case .refused(let refusals):
            return Banner(
                headline: "Monitoring only: the helper refuses manual control of every fan.",
                detail: nil,
                reasons: refusals.map { refusal in
                    ReasonLine(
                        text: AllFansControlView.prefixed(refusal.value.summary, by: refusal.fans),
                        wireValue: refusal.value.wireValue)
                },
                severity: .normal)

        case .automaticAsChosen:
            return Banner(
                headline: "Monitoring only: Auto, as you chose.",
                detail:
                    "The helper reports every fan under automatic control, and lists no "
                    + "manual-control lease.",
                reasons: [], severity: .normal)
        }
    }
}

extension MonitoringModeDisplay.Inputs {

    /// What `polling` and `lease` have now, from one main-actor read.
    @MainActor
    init(polling: PollingViewModel, lease: LeaseStateModel) {
        let report = lease.current
        self.init(
            controlSource: polling.controlSource, thermalEmergency: polling.thermalEmergency,
            fans: FanControlPresentation.onScreen(in: polling, driver: report),
            driver: report.state, enteredAfterTheUsersAuto: lease.enteredAfterTheUsersAuto)
    }
}
