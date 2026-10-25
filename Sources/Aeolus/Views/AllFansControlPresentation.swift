import AeolusLeaseControl
import AeolusXPC
import FanKit
import Foundation

/// The speeds the all-fans control offers. Each is a position in a fan's **commandable** range,
/// `FanControlEnvelope.target(forPercent:)`, the one mapping `fanctl set N%` uses too, so no
/// percentage here can name 0 RPM or a speed outside the firmware's bounds (`CLAUDE.md` rules 3
/// and 4).
enum FanSpeedPercent: Int, CaseIterable, Sendable, Hashable {
    case fifty = 50
    case seventyFive = 75
    case hundred = 100

    /// What `target(forPercent:)` is given.
    var percent: Double { Double(rawValue) }

    /// The segment's label.
    var label: String { "\(rawValue) %" }
}

/// What the main window's one control for all fans may claim: Auto, 50 %, 75 % or 100 % (#153's
/// PR 6b, the basic version of the maintainer's request). Per-fan control is PR 8.
///
/// Pure, like `FanControlPresentation`, and derived from it alone: every fan's presentation and
/// the snapshot those presentations were judged against. A control that speaks for several fans
/// claims no more than each of them does (`FanControlPresentation`'s contract, last item).
///
/// ## The affordance
///
/// - **Hidden** when every fan's control is hidden: the `Monitor` build, which ships no helper.
///   The reason is that presentation's, said once, so the build keeps saying there is no helper
///   rather than drawing nothing. Also hidden, with its own sentence, when no fan is on screen.
/// - **Enabled** only when every fan's control is enabled.
/// - **Disabled** otherwise, with every reason a fan gives. That includes a fan whose control is
///   hidden beside one that is not, a mix no build produces today: a control for all fans cannot
///   be offered while one of them has no control at all, so the mix is disabled and says why.
///
/// ## The release offer is not the affordance
///
/// `offersRelease` is true when any fan's `canRelease` is, whatever the affordance says, and Auto
/// is then drawn and enabled (`automaticIsEnabled`). A disabled control refuses only taking or
/// changing manual control; it never refuses giving the fans back.
///
/// ## The selection is the presentations', never the last click
///
/// - **Auto** only when every fan's selection is `.automatic`.
/// - **A percentage** only when every fan's selection is `.custom(rpm)` and each `rpm` is the speed
///   that percentage names for that fan's envelope, read from the same snapshot.
/// - **Pending at a percentage** the same way, when every fan is `.applying` at it.
/// - **Checking**, pending at no percentage, when every fan is `.checking`: a lease is held and no
///   licensed snapshot is on screen to confirm it. No segment is named. In any read `body` can
///   make, `.checking` comes with no snapshot on screen (`PollingViewModel.render` assigns the
///   snapshot with the rest, and a withdrawal removes it), so there are no bounds from which a
///   percentage could be named, and the row's displayed bounds are not what the helper clamps to.
/// - **Nothing** otherwise: a mix, `.unknown`, or a speed no percentage names. The per-fan status
///   lines say what is happening instead.
///
/// When two percentages name the same speed for every fan, as on a fan whose commandable range is
/// a single speed, nothing is selected: the speed alone cannot say which was asked for.
///
/// ## Lines beneath it
///
/// Identical lines are said once. A line or a reason that only some fans give is named by those
/// fans; one every fan gives is said with no names.
///
/// Each fan gives its `status`, then its `awaitingApply`. **The wait is said once, after the
/// event, with no names** (#505): the evidence it follows is the driver's, one value for the
/// machine, and the states it is given beside (`released`, `lost`, `refused`) give every fan the
/// same line whatever its index. **Beside a held lease, only the fans it does not cover give it**
/// (ADR 0015 D5), so there it is named by those fans, after the covered fans' lines. A fan whose
/// control is hidden gives neither, so otherwise the wait is named by the fans that give it only
/// in a mix no build produces, as any other line is.
struct AllFansControlPresentation: Equatable {

    let affordance: Affordance
    let selection: Selection
    /// Whether any fan's `canRelease` is true. Read from the presentations' `canRelease` alone,
    /// never from `affordance`.
    let offersRelease: Bool
    /// The status lines of every fan, each said once: each fan's `status`, then its
    /// `awaitingApply`.
    let statusLines: [Attributed<FanControlPresentation.StatusLine>]

    enum Affordance: Equatable {
        /// No control is drawn, for this reason, said once where the control would be.
        case hidden(FanControlPresentation.Reason)
        /// Drawn, and refuses taking or changing manual control, for these reasons.
        case disabled([Attributed<FanControlPresentation.Reason>])
        case enabled
    }

    enum Selection: Equatable {
        case automatic
        case percent(FanSpeedPercent)
        /// Sent, and the helper has not answered: drawn as asked for, never as achieved.
        case pending(FanSpeedPercent)
        /// A lease is held over every fan, and nothing on screen can confirm it: pending at no
        /// percentage.
        case checking
        case none
    }

    /// A value some fans give, and which ones. `fans` is `nil` when every fan on screen gives it.
    /// `Sendable` when its value is, so `MonitoringModeDisplay.State` can carry the helper's
    /// refusals.
    struct Attributed<Value: Equatable>: Equatable {
        let fans: [String]?
        let value: Value
    }

    typealias Fan = (reading: FanPollingReading, presentation: FanControlPresentation)

    /// - Parameters:
    ///   - fans: Every fan on screen beside its presentation, from
    ///     `FanControlPresentation.onScreen(in:driver:)`.
    ///   - snapshot: The snapshot those presentations were judged against, `renderedSnapshot`.
    init(fans: [Fan], snapshot: SystemSnapshot?) {
        affordance = Self.affordance(fans)
        selection = Self.selection(fans, snapshot)
        offersRelease = fans.contains { $0.presentation.canRelease }
        statusLines = Self.attributed(
            fans.flatMap { fan in
                [fan.presentation.status, fan.presentation.awaitingApply].compactMap { line in
                    line.map { (fan.reading, $0) }
                }
            },
            among: fans.count)
    }

    /// Whether the percentages may be clicked: only when the control is enabled.
    var percentsAreEnabled: Bool { affordance == .enabled }

    /// Whether Auto may be clicked: when the control is enabled, and whenever a release is offered.
    var automaticIsEnabled: Bool { affordance == .enabled || offersRelease }

    /// Whether any control is drawn: unless hidden, and whenever a release is offered.
    var drawsControl: Bool {
        if case .hidden = affordance { return offersRelease }
        return true
    }
}

extension AllFansControlPresentation.Attributed: Sendable where Value: Sendable {}

extension AllFansControlPresentation {

    /// What `polling` has on screen now, beside the driver's report, from **one** main-actor read:
    /// the presentations through `onScreen(in:driver:)` and the snapshot they were judged against,
    /// with no suspension between the two.
    @MainActor
    init(polling: PollingViewModel, driver: LeaseDriverReport) {
        self.init(
            fans: FanControlPresentation.onScreen(in: polling, driver: driver),
            snapshot: polling.renderedSnapshot)
    }
}

// MARK: - The target a percentage names

extension AllFansControlPresentation {

    /// The target `percent` names for every fan on screen, or `nil`, in which case **nothing may
    /// be sent**.
    ///
    /// Each fan's speed is `target(forPercent:)` of the `controlEnvelope` of that fan's `FanState`
    /// in `snapshot`, the snapshot the presentations licensed. Never of the row's `minimum` and
    /// `maximum`: those are what the row displays, not what the helper clamps to.
    ///
    /// Fails closed, all or nothing:
    /// - any fan's control is not enabled, or no fan is on screen;
    /// - no snapshot;
    /// - the snapshot reports a fan more than once, which leaves its bounds ambiguous;
    /// - the snapshot's fans are not exactly the fans on screen;
    /// - any fan's envelope is a `.failure`;
    /// - `LeaseTarget(speeds:)` refuses, which it does for no fans, so an empty screen is refused
    ///   twice over.
    ///
    /// The helper clamps every speed again after it crosses (`CLAUDE.md` rule 7). That is the
    /// second control, not the reason this one may be skipped.
    static func target(
        for percent: FanSpeedPercent, fans: [Fan], snapshot: SystemSnapshot?
    ) -> LeaseTarget? {
        guard !fans.isEmpty, fans.allSatisfy({ $0.presentation.affordance == .enabled }) else {
            return nil
        }
        guard let snapshot else { return nil }
        let shown = fans.map(\.reading.index)
        let reported = snapshot.fans.map(\.index)
        guard Set(reported).count == reported.count else { return nil }
        guard shown.sorted() == reported.sorted() else { return nil }
        var speeds: [Int: FanTargetRPM] = [:]
        for index in shown {
            guard let speed = speed(percent, forFan: index, in: snapshot) else { return nil }
            speeds[index] = speed
        }
        return LeaseTarget(speeds: speeds)
    }

    /// The speed `percent` names for fan `index`, from its `FanState` in `snapshot`.
    private static func speed(
        _ percent: FanSpeedPercent, forFan index: Int, in snapshot: SystemSnapshot?
    ) -> FanTargetRPM? {
        guard let state = snapshot?.fans.first(where: { $0.index == index }),
            case .success(let envelope) = state.controlEnvelope
        else { return nil }
        return envelope.target(forPercent: percent.percent)
    }
}

// MARK: - Deriving it

extension AllFansControlPresentation {

    fileprivate static let noFanOnScreen = FanControlPresentation.Reason(
        summary: "No fan is on screen, so there is nothing to control.", advice: nil,
        wireValue: nil)

    private static func affordance(_ fans: [Fan]) -> Affordance {
        guard !fans.isEmpty else { return .hidden(noFanOnScreen) }
        var refusing: [(FanPollingReading, FanControlPresentation.Reason)] = []
        var hidden = 0
        for fan in fans {
            switch fan.presentation.affordance {
            case .enabled:
                continue
            case .hidden(let reason):
                hidden += 1
                refusing.append((fan.reading, reason))
            case .disabled(let reason):
                refusing.append((fan.reading, reason))
            }
        }
        guard !refusing.isEmpty else { return .enabled }
        let reasons = attributed(refusing, among: fans.count)
        if hidden == fans.count, reasons.count == 1, let only = reasons.first {
            return .hidden(only.value)
        }
        return .disabled(reasons)
    }

    private static func selection(_ fans: [Fan], _ snapshot: SystemSnapshot?) -> Selection {
        guard !fans.isEmpty else { return .none }
        if fans.allSatisfy({ $0.presentation.selection == .automatic }) { return .automatic }
        let held = onlyPercent(fans, snapshot) { fan in
            if case .custom(let speed) = fan.presentation.selection { speed } else { nil }
        }
        if let held { return .percent(held) }
        let asked = onlyPercent(fans, snapshot) { fan in
            if case .applying(let speed) = fan.presentation.selection { speed } else { nil }
        }
        if let asked { return .pending(asked) }
        if fans.allSatisfy({ $0.presentation.selection == .checking }) { return .checking }
        return .none
    }

    /// The one percentage whose speed, for every fan, is the speed `speedOf` reads from that fan's
    /// selection, or `nil` when none is or more than one is.
    private static func onlyPercent(
        _ fans: [Fan], _ snapshot: SystemSnapshot?, at speedOf: (Fan) -> FanTargetRPM?
    ) -> FanSpeedPercent? {
        let matching = FanSpeedPercent.allCases.filter { percent in
            fans.allSatisfy { fan in
                guard let selected = speedOf(fan),
                    let named = speed(percent, forFan: fan.reading.index, in: snapshot)
                else { return false }
                return selected == named
            }
        }
        return matching.count == 1 ? matching.first : nil
    }

    /// `values` said once each, in the order first given, each with the fans that gave it, or with
    /// none when every one of the `among` fans on screen did. `MonitoringModeDisplay` attributes
    /// the helper's refusals with it too, so the banner and the control name them alike.
    static func attributed<Value: Equatable>(
        _ values: [(FanPollingReading, Value)], among total: Int
    ) -> [Attributed<Value>] {
        var groups: [(value: Value, fans: [String])] = []
        for (reading, value) in values {
            if let index = groups.firstIndex(where: { $0.value == value }) {
                groups[index].fans.append(reading.displayName)
            } else {
                groups.append((value, [reading.displayName]))
            }
        }
        return groups.map { group in
            Attributed(fans: group.fans.count == total ? nil : group.fans, value: group.value)
        }
    }
}
