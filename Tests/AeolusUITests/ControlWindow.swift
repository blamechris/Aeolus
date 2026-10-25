import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// A main window's `PollingViewModel` with a helper snapshot on screen, for the all-fans control's
/// suites: what `FanListView` reads when it draws the control and when it is clicked.
///
/// The view model reads a source of its own, on the suite's hand-wound age clock and an instant
/// pacing clock, rather than the root's, which runs on real clocks with a six-second freshness
/// bound. So a snapshot on screen stays licensed however loaded the machine running the suite is.
/// The root's driver therefore judges none of these snapshots: what the driver does is decided by
/// the scene's fake control helper alone, and these suites are about what the control reads and
/// sends, not about the read connection's judgement (`AppCompositionLeaseTests` has that).
@MainActor
final class ControlWindow {

    let helper: FakeSnapshotHelper
    let source: HelperSnapshotSource
    let polling: PollingViewModel
    private var answered = 1

    private init(helper: FakeSnapshotHelper, source: HelperSnapshotSource) {
        self.helper = helper
        self.source = source
        polling = PollingViewModel(
            provider: SnapshotTestSupport.directProvider(), clock: FakePollingClock(),
            snapshots: source)
    }

    /// A window whose view model has rendered `snapshot`.
    static func showing(_ snapshot: SystemSnapshot) async throws -> ControlWindow {
        let helper = FakeSnapshotHelper()
        let source = try await SnapshotTestSupport.freshSource(helper, answering: snapshot)
        let window = ControlWindow(helper: helper, source: source)
        await SnapshotTestSupport.tickEnds(window.polling)
        try #require(window.polling.renderedSnapshot == snapshot, "the window shows the snapshot")
        return window
    }

    /// Answers the next request with `snapshot`, and renders it.
    func show(_ snapshot: SystemSnapshot) async throws {
        await helper.reply(with: snapshot)
        answered += 1
        try await helper.waitForRequests(answered + 1)
        await SnapshotTestSupport.tickEnds(polling)
        try #require(polling.renderedSnapshot == snapshot, "the window shows the new snapshot")
    }

    /// What the control draws now, against `driver`.
    func control(_ driver: LeaseDriverState) -> AllFansControlPresentation {
        AllFansControlPresentation(polling: polling, driver: driver)
    }

    func close() async {
        await SnapshotTestSupport.tearDown(source, helper)
    }
}

/// Fans, snapshots and speeds for the all-fans control's suites. Namespaced, so nothing here can
/// shadow a global helper another suite in this target declares.
///
/// **Every fan has bounds of its own**, so a speed taken from the wrong fan's envelope is a
/// different number and a red (#497's review, test gap 3):
///
/// | Fan | Bounds | 50 % | 75 % | 100 % |
/// |---|---|---|---|---|
/// | 0 | 1350 to 5777 (`Mac16,5`'s) | 3564 | 4670 | 5777 |
/// | 1 | 1200 to 4800 | 3000 | 3900 | 4800 |
/// | 2 | 1500 to 6000 | 3750 | 4875 | 6000 |
enum AllFansFixtures {

    typealias Support = SnapshotTestSupport

    /// Fan `index`'s declared bounds: see the table above. Any other index has fan 0's.
    static func bounds(_ index: Int) -> (minimum: Double, maximum: Double) {
        switch index {
        case 1: return (1200, 4800)
        case 2: return (1500, 6000)
        default: return (1350, 5777)
        }
    }

    /// A fan with fan `index`'s bounds.
    static func fan(
        _ index: Int, mode: FanControlMode, availability: ManualControlAvailability,
        target: Double? = nil
    ) -> FanState {
        let (minimum, maximum) = bounds(index)
        return FanState(
            index: index, actualRPM: .measured(2345), minimumRPM: .measured(minimum),
            maximumRPM: .measured(maximum), targetRPM: target, mode: mode,
            isReclaimedBySystem: false, manualControlAvailability: availability)
    }

    /// A fan the helper offers and reports on automatic.
    static func offered(_ index: Int) -> FanState {
        fan(index, mode: .automatic, availability: .available)
    }

    /// A fan the helper reports held under a lease at `rpm`.
    static func held(_ index: Int, at rpm: Double) -> FanState {
        fan(index, mode: .manualFixed, availability: .available, target: rpm)
    }

    /// A fan the helper refuses, for `reason`.
    static func refused(_ index: Int, _ reason: ManualControlAvailability.Reason) -> FanState {
        fan(index, mode: .automatic, availability: .unavailable(reason))
    }

    /// Fan `index`'s envelope.
    static func envelope(_ index: Int) throws -> FanControlEnvelope {
        let (minimum, maximum) = bounds(index)
        guard
            case .success(let envelope) = FanControlEnvelope.validating(
                declaredMinimumRPM: minimum, declaredMaximumRPM: maximum)
        else { throw LeaseScene.TargetError.envelopeRefused }
        return envelope
    }

    /// The speed `percent` names for fan `index`.
    static func rpm(_ percent: FanSpeedPercent, fan index: Int) throws -> Double {
        try envelope(index).target(forPercent: percent.percent).rpm
    }

    /// The target `percent` names for each of `fans`, each from its own envelope.
    static func target(_ percent: FanSpeedPercent, fans: [Int]) throws -> LeaseTarget {
        var speeds: [Int: FanTargetRPM] = [:]
        for index in fans {
            speeds[index] = try envelope(index).target(forPercent: percent.percent)
        }
        return try #require(LeaseTarget(speeds: speeds))
    }

    /// What `apply` sends for that target.
    static func settings(_ percent: FanSpeedPercent, fans: [Int]) throws -> [FanSetting] {
        try fans.map { FanSetting(fanIndex: $0, control: .fixed(rpm: try rpm(percent, fan: $0))) }
    }

    /// The snapshot that shows `lease` holding `fans` at `percent`, each at its own speed.
    static func holding(
        _ lease: Lease, _ fans: [Int], at percent: FanSpeedPercent
    ) throws -> SystemSnapshot {
        Support.snapshot(
            fans: try fans.map { held($0, at: try rpm(percent, fan: $0)) }, activeLease: lease)
    }
}
