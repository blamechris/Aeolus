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
        await window.polling.tick()
        try #require(window.polling.renderedSnapshot == snapshot, "the window shows the snapshot")
        return window
    }

    /// Answers the next request with `snapshot`, and renders it.
    func show(_ snapshot: SystemSnapshot) async throws {
        await helper.reply(with: snapshot)
        answered += 1
        try await helper.waitForRequests(answered + 1)
        await polling.tick()
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
enum AllFansFixtures {

    typealias Support = SnapshotTestSupport

    /// A fan the helper offers and reports on automatic, with `Mac16,5`'s bounds, 1350 to 5777.
    static func offered(_ index: Int) -> FanState {
        Support.fan(index, mode: .automatic, availability: .available)
    }

    /// A fan the helper reports held under a lease at `rpm`.
    static func held(_ index: Int, at rpm: Double) -> FanState {
        Support.fan(index, mode: .manualFixed, availability: .available, target: rpm)
    }

    /// A fan the helper refuses, for `reason`.
    static func refused(_ index: Int, _ reason: ManualControlAvailability.Reason) -> FanState {
        Support.fan(index, mode: .automatic, availability: .unavailable(reason))
    }

    /// The speed `percent` names on `Mac16,5`'s 1350 to 5777: 3564, 4670 and 5777.
    static func rpm(_ percent: FanSpeedPercent) throws -> Double {
        guard
            case .success(let envelope) = FanControlEnvelope.validating(
                declaredMinimumRPM: 1350, declaredMaximumRPM: 5777)
        else { throw LeaseScene.TargetError.envelopeRefused }
        return envelope.target(forPercent: percent.percent).rpm
    }

    /// The target `percent` names for each of `fans` on those bounds.
    static func target(_ percent: FanSpeedPercent, fans: [Int]) throws -> LeaseTarget {
        let rpm = try rpm(percent)
        return try LeaseScene.target(Dictionary(uniqueKeysWithValues: fans.map { ($0, rpm) }))
    }

    /// What `apply` sends for that target.
    static func settings(_ percent: FanSpeedPercent, fans: [Int]) throws -> [FanSetting] {
        let rpm = try rpm(percent)
        return fans.map { FanSetting(fanIndex: $0, control: .fixed(rpm: rpm)) }
    }

    /// The snapshot that shows `lease` holding `fans` at `percent`.
    static func holding(
        _ lease: Lease, _ fans: [Int], at percent: FanSpeedPercent
    ) throws -> SystemSnapshot {
        let rpm = try rpm(percent)
        return Support.snapshot(fans: fans.map { held($0, at: rpm) }, activeLease: lease)
    }
}
