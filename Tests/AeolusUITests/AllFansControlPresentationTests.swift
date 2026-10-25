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

    /// Fan 0 refused, then fan 1, so a rule that looks at one end of the list is a red.
    ///
    /// **Mutation (M3, "enabled beside one disabled fan"):** in `affordance`, return `.enabled`
    /// unless every fan refuses (`refusing.count < fans.count`). Run: red at the affordance.
    @Test(
        "One disabled fan disables the control for all, and names that fan and its reason",
        arguments: [0, 1])
    func oneDisabledFanDisablesAll(_ which: Int) {
        let fans = [0, 1].map {
            $0 == which ? Fans.refused($0, .foreignManualControl) : Fans.offered($0)
        }
        let control = Self.control(Support.snapshot(fans: fans))

        let foreign = ManualControlAvailability.Reason.foreignManualControl
        #expect(
            control.affordance
                == .disabled([
                    .init(
                        fans: ["Fan \(which)"],
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

    /// A lease over one of two fans, with the read connection stale: only the release can enable
    /// Auto, and it must, whichever fan the lease covers.
    @Test("A release is offered when any one fan can release", arguments: [0, 1])
    func releaseIsOfferedForAnyFan(_ which: Int) throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [which], .confirmed(try Fans.target(.fifty, fans: [which])))
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: driver,
            from: Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let fans = Self.fans(screen)
        let control = Control(fans: fans, snapshot: nil)

        #expect(fans.map(\.presentation.canRelease) == [which == 0, which == 1])
        #expect(control.offersRelease)
        #expect(control.automaticIsEnabled)
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

    /// One fan held at 50 % and the other on automatic, fan 0 held and then fan 1.
    ///
    /// **Mutation (M9, "one fan decides"):** in `onlyPercent`, use `contains` for `allSatisfy`.
    /// Run: red at `.none` for the mixed screen.
    @Test("Fans at different choices select nothing", arguments: [0, 1])
    func mixedSelectionsSelectNothing(_ which: Int) throws {
        let target = try Fans.target(.fifty, fans: [which])
        let fans = try [0, 1].map {
            $0 == which ? Fans.held($0, at: try Fans.rpm(.fifty, fan: $0)) : Fans.offered($0)
        }
        let snapshot = Support.snapshot(fans: fans, activeLease: Fixtures.ours)
        let driver = Fixtures.held(Fixtures.ours, fans: [which], .confirmed(target))
        let control = Self.control(snapshot, driver: driver)

        let screen = Fixtures.screen(snapshot, driver: driver)
        #expect(
            try Fixtures.present(which, on: screen).selection
                == .custom(try Fixtures.speed(target, which)))
        // Beside a lease over its neighbour, the other fan claims nothing (ADR 0015 D1).
        #expect(try Fixtures.present(1 - which, on: screen).selection == .unknown)
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

    /// A held lease that nothing on screen can confirm is pending, at no percentage: with no
    /// snapshot on screen there are no bounds to name one from (#497's review, S2).
    ///
    /// **Mutation (S2a, "checking selects nothing"):** delete the `.checking` arm of `selection`.
    /// Run: red at `.checking`.
    @Test("A lease checked against no snapshot is pending at no percentage, and says why")
    func checkingIsPendingAtNoPercentage() throws {
        let target = try Fans.target(.fifty, fans: [0, 1])
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)),
            from: try Fans.holding(Fixtures.ours, [0, 1], at: .fifty))
        let control = Control(fans: Self.fans(screen), snapshot: nil)

        #expect(control.selection == .checking)
        #expect(
            control.statusLines.map(\.value.text)
                == ["Not confirmed: no current helper snapshot is on screen."])
    }

    /// A lease over fan 0 alone, unconfirmed, beside fan 1 that nothing holds: a mix.
    @Test("Checking over some fans and not others selects nothing")
    func checkingOverSomeFansIsAMix() throws {
        let target = try Fans.target(.fifty, fans: [0])
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)),
            from: Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let control = Control(fans: Self.fans(screen), snapshot: nil)

        #expect(control.selection == .none)
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
}
