import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `AllFansControlPresentation`: a control for every fan claims no more than each fan's
/// presentation does, and a percentage names each fan's speed from the snapshot those
/// presentations licensed, or nothing is sent.
@Suite("All fans — what the control may claim, and the target it may send")
struct AllFansControlPresentationTests {

    typealias Fixtures = FanControlFixtures
    typealias Fans = AllFansFixtures
    typealias Support = SnapshotTestSupport
    typealias Control = AllFansControlPresentation
    typealias Reason = FanControlPresentation.Reason

    /// The control for `snapshot` on screen beside `driver`.
    static func control(_ snapshot: SystemSnapshot, driver: LeaseDriverState = .idle) -> Control {
        let screen = Fixtures.screen(snapshot, driver: driver)
        return Control(fans: fans(screen), snapshot: snapshot)
    }

    static func fans(_ screen: Fixtures.Screen) -> [Control.Fan] {
        screen.rows.map { ($0, FanControlPresentation(reading: $0, given: screen.inputs)) }
    }

    static let writePath = Reason(
        FanRowModel.Refusal(
            summary: ManualControlAvailability.Reason.writePathNotBuilt.userFacingSummary,
            advice: ManualControlAvailability.Reason.writePathNotBuilt.recoveryAdvice,
            wireValue: "writePathNotBuilt"))

    // MARK: - The affordance

    @Test("Enabled only when every fan is enabled")
    func enabledWhenEveryFanIs() {
        let control = Self.control(Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))

        #expect(control.affordance == .enabled)
        #expect(control.percentsAreEnabled)
        #expect(control.automaticIsEnabled)
        #expect(control.drawsControl)
    }

    /// **Mutation (M3, "enabled beside one disabled fan"):** in `affordance`, return `.enabled`
    /// unless every fan refuses (`refusing.count < fans.count`). Run: red at the affordance.
    @Test("One disabled fan disables the control for all, and names that fan and its reason")
    func oneDisabledFanDisablesAll() {
        let control = Self.control(
            Support.snapshot(fans: [Fans.offered(0), Fans.refused(1, .foreignManualControl)]))

        let foreign = ManualControlAvailability.Reason.foreignManualControl
        #expect(
            control.affordance
                == .disabled([
                    .init(
                        fans: ["Fan 1"],
                        value: Reason(
                            summary: foreign.userFacingSummary, advice: foreign.recoveryAdvice,
                            wireValue: "foreignManualControl"))
                ]))
        #expect(!control.percentsAreEnabled)
        #expect(!control.automaticIsEnabled, "nothing is held, so there is nothing to release")
        #expect(control.drawsControl, "a disabled control is drawn, with its reason")
    }

    /// Today's helper: every fan refused for one reason. Said once, with no fan named, because
    /// every fan gives it.
    @Test("A reason every fan gives is said once, and names no fan")
    func aSharedReasonIsSaidOnce() {
        let control = Self.control(
            Support.snapshot(fans: [Support.fan(0), Support.fan(1), Support.fan(2)]))

        #expect(control.affordance == .disabled([.init(fans: nil, value: Self.writePath)]))
    }

    @Test("Different reasons are each named by their fans")
    func differentReasonsAreNamed() {
        let control = Self.control(
            Support.snapshot(fans: [
                Support.fan(0), Fans.refused(1, .foreignManualControl), Support.fan(2),
            ]))

        guard case .disabled(let reasons) = control.affordance else {
            Issue.record("not disabled: \(control.affordance)")
            return
        }
        #expect(reasons.map(\.fans) == [["Fan 0", "Fan 2"], ["Fan 1"]])
        #expect(reasons.first?.value == Self.writePath)
    }

    /// The `Monitor` build: every fan hidden for one reason. The control says so once, and
    /// offers nothing.
    ///
    /// **Mutation (M8a, "Monitor enabled"):** in `affordance`, return `.enabled` when every fan
    /// is hidden. Run: red at the affordance and at `!drawsControl`.
    @Test("Every fan hidden hides the control, and says why once")
    func everyFanHiddenHides() {
        let screen = Fixtures.withdrawn(
            .noHelperInThisBuild, driver: .idle,
            from: Support.snapshot(fans: [Support.fan(0), Support.fan(1)]))
        let control = Control(fans: Self.fans(screen), snapshot: nil)

        #expect(control.affordance == .hidden(.noHelperInThisBuild))
        #expect(!control.drawsControl)
        #expect(!control.percentsAreEnabled)
        #expect(!control.automaticIsEnabled)
        #expect(control.selection == .none)
        #expect(control.statusLines.isEmpty)
    }

    /// A mix no build produces: one fan's control hidden beside one enabled. A control for every
    /// fan cannot be offered while one has none, so it is disabled, naming the hidden fan.
    @Test("A hidden fan beside an enabled one disables the control and names the hidden fan")
    func hiddenBesideEnabledDisables() {
        let shown = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let screen = Fixtures.screen(shown, driver: .idle)
        let rows = [screen.rows[0], screen.rows[1].untracked(.noHelperInThisBuild)]
        let fans = rows.map { ($0, FanControlPresentation(reading: $0, given: screen.inputs)) }
        let control = Control(fans: fans, snapshot: shown)

        #expect(
            control.affordance == .disabled([.init(fans: ["Fan 1"], value: .noHelperInThisBuild)]))
    }

    @Test("No fan on screen draws no control, and says so")
    func noFanDrawsNothing() {
        let control = Control(fans: [], snapshot: nil)

        #expect(
            control.affordance
                == .hidden(
                    Reason(
                        summary: "No fan is on screen, so there is nothing to control.",
                        advice: nil, wireValue: nil)))
        #expect(control.selection == .none)
        #expect(!control.drawsControl)
        #expect(Control.target(for: .fifty, fans: [], snapshot: nil) == nil)
    }

    // MARK: - The release offer is not the affordance

    /// A held lease, and the read connection gone stale: every fan's control disabled, and the
    /// release still offered.
    ///
    /// **Mutation (M4, "release follows the affordance"):** compute `offersRelease` as
    /// `affordance == .enabled && fans.contains { ... }`. Run: red at `offersRelease`,
    /// `automaticIsEnabled` and `drawsControl`.
    @Test(
        "A release is offered whenever any fan can release, whatever the affordance",
        arguments: [ControlNotTracked.snapshotStale, .noHelperInThisBuild])
    func releaseIsOfferedWhateverTheAffordance(_ why: ControlNotTracked) throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0, 1], .confirmed(try Fans.target(.fifty, fans: [0, 1])))
        let screen = Fixtures.withdrawn(
            why, driver: driver,
            from: Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let control = Control(fans: Self.fans(screen), snapshot: nil)

        #expect(control.affordance != .enabled)
        #expect(control.offersRelease)
        #expect(control.automaticIsEnabled, "Auto gives the fans back")
        #expect(control.drawsControl, "\(why): the release is drawn even when hidden")
        #expect(!control.percentsAreEnabled)
    }

    @Test("A release is offered while acquiring, and not with nothing held or asked for")
    func releaseFollowsTheDriver() {
        let snapshot = Support.snapshot(fans: [Support.fan(0), Support.fan(1)])

        #expect(Self.control(snapshot, driver: .acquiring(fans: [0, 1])).offersRelease)
        for state in [LeaseDriverState.idle, .released, .releasing] {
            #expect(!Self.control(snapshot, driver: state).offersRelease, "\(state)")
        }
    }

    /// Under `.releasing`, `canRelease` is false for every fan, so Auto is enabled only by the
    /// affordance. A take queued behind that release is reachable from this control when a
    /// snapshot that no longer lists the lease is on screen before the release has answered, and
    /// Auto then cancels it (`AllFansControlRootTests.autoWhileReleasingCancelsAQueuedTake`).
    @Test("While releasing, Auto is enabled exactly when the control is")
    func whileReleasingAutoFollowsTheAffordance() {
        let gone = Self.control(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]), driver: .releasing)
        #expect(gone.affordance == .enabled)
        #expect(!gone.offersRelease)
        #expect(gone.automaticIsEnabled)

        let listed = Self.control(
            Support.snapshot(
                fans: [Fans.offered(0), Fans.offered(1)], activeLease: Fixtures.ours),
            driver: .releasing)
        #expect(listed.affordance != .enabled, "the snapshot still lists the lease")
        #expect(!listed.automaticIsEnabled)
    }

    // MARK: - The selection

    @Test("Auto is selected only when every fan reads automatic")
    func autoOnlyWhenEveryFanIs() {
        #expect(
            Self.control(Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])).selection
                == .automatic)
        let unconfirmed = Support.fan(
            1, mode: .automatic, availability: .unavailable(.restoreToAutomaticUnconfirmed))
        #expect(
            Self.control(Support.snapshot(fans: [Fans.offered(0), unconfirmed])).selection
                == .none)
    }

    @Test(
        "A percentage is selected when every fan is Custom at the speed it names",
        arguments: FanSpeedPercent.allCases)
    func aPercentageWhenEveryFanHoldsIt(_ percent: FanSpeedPercent) throws {
        let target = try Fans.target(percent, fans: [0, 1])
        let snapshot = try Fans.holding(Fixtures.ours, [0, 1], at: percent)
        let control = Self.control(
            snapshot, driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)))

        #expect(control.selection == .percent(percent))
        #expect(control.affordance == .enabled)
    }

    @Test("A percentage in flight is pending, never selected", arguments: FanSpeedPercent.allCases)
    func aPercentageInFlightIsPending(_ percent: FanSpeedPercent) throws {
        let target = try Fans.target(percent, fans: [0, 1])
        let snapshot = Support.snapshot(
            fans: [Fans.offered(0), Fans.offered(1)], activeLease: Fixtures.ours)
        let control = Self.control(
            snapshot,
            driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .applying(target, queued: nil)))

        #expect(control.selection == .pending(percent))
    }

    /// **Mutation (M9, "one fan decides"):** in `onlyPercent`, use `contains` for `allSatisfy`.
    /// Run: red at `.none` for the mixed screen.
    @Test("Fans at different choices select nothing")
    func mixedSelectionsSelectNothing() throws {
        let fifty = try Fans.rpm(.fifty)
        let target = try LeaseScene.target([0: fifty])
        let snapshot = Support.snapshot(
            fans: [Fans.held(0, at: fifty), Fans.offered(1)], activeLease: Fixtures.ours)
        let control = Self.control(
            snapshot, driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)))

        let presentations = Self.fans(Fixtures.screen(snapshot, driver: .idle))
        #expect(presentations.count == 2)
        #expect(
            try Fixtures.present(
                0,
                on: Fixtures.screen(
                    snapshot, driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)))
            ).selection == .custom(try Fixtures.speed(target, 0)))
        #expect(control.selection == .none)
    }

    @Test("A held speed no percentage names selects nothing")
    func aSpeedNoPercentageNamesSelectsNothing() throws {
        let target = try LeaseScene.target([0: 3000, 1: 3000])
        let snapshot = Support.snapshot(
            fans: [Fans.held(0, at: 3000), Fans.held(1, at: 3000)], activeLease: Fixtures.ours)
        let control = Self.control(
            snapshot, driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)))

        #expect(control.selection == .none)
        #expect(
            control.statusLines.map(\.value.text)
                == ["Accepted 3000 RPM; the snapshot on screen reports a held target of 3000 RPM."])
    }

    /// One fan whose commandable range is one RPM wide, 2000 to 2001: 50 %, 75 % and 100 % all
    /// round to 2001, so the speed alone cannot say which was asked for.
    @Test("When two percentages name the same speed, nothing is selected")
    func anAmbiguousSpeedSelectsNothing() throws {
        let narrow = FanState(
            index: 0, actualRPM: .measured(2000), minimumRPM: .measured(2000),
            maximumRPM: .measured(2001), targetRPM: 2001, mode: .manualFixed,
            isReclaimedBySystem: false, manualControlAvailability: .available)
        let snapshot = Support.snapshot(fans: [narrow], activeLease: Fixtures.ours)
        guard case .success(let envelope) = narrow.controlEnvelope else {
            Issue.record("the narrow envelope was refused")
            return
        }
        let target = try #require(LeaseTarget(speeds: [0: envelope.target(forPercent: 75)]))
        let control = Self.control(
            snapshot, driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)))

        #expect(envelope.target(forPercent: 50) == envelope.target(forPercent: 75))
        #expect(envelope.target(forPercent: 75) == envelope.target(forPercent: 100))
        #expect(control.selection == .none)
    }

    @Test("A lease checked against no snapshot selects nothing, and says why")
    func checkingSelectsNothing() throws {
        let target = try Fans.target(.fifty, fans: [0])
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)),
            from: Support.snapshot(fans: [Fans.held(0, at: try Fans.rpm(.fifty))]))
        let control = Control(fans: Self.fans(screen), snapshot: nil)

        #expect(control.selection == .none)
        #expect(
            control.statusLines.map(\.value.text)
                == ["Not confirmed: no current helper snapshot is on screen."])
    }

    // MARK: - Lines beneath it

    @Test("Identical status lines are said once; a line only some fans give names them")
    func statusLinesAreSaidOnce() {
        let snapshot = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1), Fans.offered(2)])

        let releasing = Self.control(snapshot, driver: .releasing)
        #expect(
            releasing.statusLines
                == [
                    .init(
                        fans: nil,
                        value: .init(
                            text: "Releasing the lease. The helper has not answered yet.",
                            detail: nil))
                ])

        let asking = Self.control(snapshot, driver: .acquiring(fans: [0, 2]))
        #expect(
            asking.statusLines
                == [
                    .init(
                        fans: ["Fan 0", "Fan 2"],
                        value: .init(text: "Asking the helper for control.", detail: nil))
                ])
    }

    @Test("A line or reason for some fans is drawn after their names; one for all, plainly")
    func prefixesNameTheFans() {
        #expect(AllFansControlView.prefixed("Text.", by: nil) == "Text.")
        #expect(
            AllFansControlView.prefixed("Text.", by: ["Fan 0", "Fan 2"]) == "Fan 0, Fan 2: Text.")
    }

    // MARK: - The target a percentage names

    /// The row's displayed bounds differ from the `FanState` the snapshot carries: 1200 to 5312
    /// against 1350 to 5777. The target is the snapshot's: 3564 RPM at 50 %, not 3256.
    ///
    /// **Mutation (M2, "the row's bounds"):** in `speed(_:forFan:in:)`, build the envelope from
    /// the row's `minimum` and `maximum` (`FanState.controlEnvelope(declaredMinimum:
    /// declaredMaximum:)` of `.measured` of each `KeyedReading`'s value) instead of the snapshot's
    /// `FanState`. Run: red at the speeds.
    @Test("Each speed comes from the snapshot's fan state, never from the row's bounds")
    func theTargetIsTheSnapshots() throws {
        let snapshot = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let screen = Fixtures.screen(snapshot, driver: .idle)
        let rows = screen.rows.map { row in
            FanPollingReading(
                index: row.index, displayName: row.displayName, actual: row.actual,
                minimum: .value(key: SMCFanEnumeration.minimumKey(forFan: row.index), 1200),
                maximum: .value(key: SMCFanEnumeration.maximumKey(forFan: row.index), 5312),
                control: row.control)
        }
        let fans = rows.map { ($0, FanControlPresentation(reading: $0, given: screen.inputs)) }
        #expect(fans.allSatisfy { $0.1.affordance == .enabled })

        let target = try #require(Control.target(for: .fifty, fans: fans, snapshot: snapshot))

        #expect(target.speeds.mapValues(\.rpm) == [0: 3564, 1: 3564])
        #expect(target == (try Fans.target(.fifty, fans: [0, 1])))
    }

    @Test(
        "Every percentage names its speed in each fan's commandable range",
        arguments: FanSpeedPercent.allCases)
    func everyPercentage(_ percent: FanSpeedPercent) throws {
        let snapshot = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let target = Control.target(
            for: percent, fans: Self.fans(Fixtures.screen(snapshot, driver: .idle)),
            snapshot: snapshot)

        let expected: Double
        switch percent {
        case .fifty: expected = 3564
        case .seventyFive: expected = 4670
        case .hundred: expected = 5777
        }
        #expect(target?.speeds.mapValues(\.rpm) == [0: expected, 1: expected])
    }

    /// Each fail-closed condition alone, on a screen that otherwise builds a target.
    enum Refusal: CaseIterable {
        case aFanDisabled, noSnapshot, aFanMissingFromTheSnapshot, anExtraFanInTheSnapshot
        case aRepeatedFan, anEnvelopeFailure
    }

    /// **Mutation (M10a):** delete the `allSatisfy { ... == .enabled }` guard. Run: red for
    /// `.aFanDisabled`. **Mutation (G-repeat):** delete the guard that each reported fan is
    /// reported once. Run: red for `.aRepeatedFan` only. **Mutation (G-set):** delete the guard
    /// that the snapshot's fans are the fans on screen. Run: red for `.anExtraFanInTheSnapshot`
    /// only: `.aFanMissingFromTheSnapshot` is refused again by the per-fan lookup, which finds no
    /// state for the missing fan.
    @Test("Nothing is sent unless every fan can be given a speed", arguments: Refusal.allCases)
    func failsClosed(_ refusal: Refusal) throws {
        let offered = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let fans = Self.fans(Fixtures.screen(offered, driver: .idle))
        #expect(Control.target(for: .fifty, fans: fans, snapshot: offered) != nil, "the control")

        let refused: LeaseTarget?
        switch refusal {
        case .aFanDisabled:
            let one = Support.snapshot(fans: [Fans.offered(0), Fans.refused(1, .supervisorBlind)])
            refused = Control.target(
                for: .fifty, fans: Self.fans(Fixtures.screen(one, driver: .idle)), snapshot: one)
        case .noSnapshot:
            refused = Control.target(for: .fifty, fans: fans, snapshot: nil)
        case .aFanMissingFromTheSnapshot:
            refused = Control.target(
                for: .fifty, fans: fans, snapshot: Support.snapshot(fans: [Fans.offered(0)]))
        case .anExtraFanInTheSnapshot:
            refused = Control.target(
                for: .fifty, fans: fans,
                snapshot: Support.snapshot(fans: [
                    Fans.offered(0), Fans.offered(1), Fans.offered(2),
                ]))
        case .aRepeatedFan:
            // Rows and snapshot agree, both with fan 1 twice, so only the repeat refuses.
            let repeated = Support.snapshot(
                fans: [Fans.offered(0), Fans.offered(1), Fans.offered(1)])
            let both = Self.fans(Fixtures.screen(repeated, driver: .idle))
            #expect(both.count == 3)
            #expect(both.allSatisfy { $0.presentation.affordance == .enabled })
            refused = Control.target(for: .fifty, fans: both, snapshot: repeated)
        case .anEnvelopeFailure:
            let unbounded = FanState(
                index: 1, actualRPM: .measured(2000), minimumRPM: .measured(1350),
                maximumRPM: .unavailable(reason: "not read"), targetRPM: nil, mode: .automatic,
                isReclaimedBySystem: false, manualControlAvailability: .available)
            refused = Control.target(
                for: .fifty, fans: fans,
                snapshot: Support.snapshot(fans: [Fans.offered(0), unbounded]))
        }
        #expect(refused == nil)
    }
}
