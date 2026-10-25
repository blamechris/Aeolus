import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `MonitoringModeDisplay` (#157): what "as you chose" rests on, ADR 0015 D1's evidence and the
/// user's own Auto, and the order between the four states. The screens and helpers are
/// `MonitoringModeDisplayTests`'.
@Suite("Monitoring mode — the evidence 'as you chose' rests on, and the order of the states")
struct MonitoringModePrecedenceTests {

    typealias Tests = MonitoringModeDisplayTests
    typealias Fixtures = FanControlFixtures
    typealias Fans = AllFansFixtures
    typealias Support = SnapshotTestSupport
    typealias Display = MonitoringModeDisplay

    // MARK: - "As you chose" rests on ADR 0015 D1 and on the user's own Auto

    /// D1's read timing: while an `apply` is unanswered (`.noRead`), or from a read ticketed before
    /// the floor, no fan reads Automatic, so nothing says "as you chose".
    ///
    /// **Mutation (V5, "chose without D1"):** in `everyFanReadsAutomatic(_:)`, ask
    /// `$0.reading.control` for a fan the helper reports `isClearedToAutomatic` in place of the
    /// presentation's selection. Run: red at each of the four expectations.
    @Test("No 'as you chose' without D1's evidence")
    func notChosenWithoutTheEvidence() async throws {
        let (before, floor) = try await LeaseStateModelTests.twoFloors()

        #expect(
            Tests.state(Tests.cleared, driver: .released, evidence: .noRead, afterAuto: true)
                == nil,
            "an apply unanswered")
        #expect(
            Tests.state(
                Tests.cleared, driver: .released, evidence: .readFrom(floor), readWith: before,
                afterAuto: true) == nil,
            "a read from before the floor")
        #expect(
            Tests.state(
                Tests.cleared, driver: .released, evidence: .readFrom(floor), readWith: nil,
                afterAuto: true) == nil,
            "a read with no ticket")
        let listed = Support.snapshot(
            fans: [Fans.offered(0), Fans.offered(1)], activeLease: Fixtures.theirs)
        #expect(
            Tests.state(listed, driver: .released, afterAuto: true) == nil, "a lease listed")

        // The control: the same screen, read after the floor, is the user's Auto.
        #expect(
            Tests.state(
                Tests.cleared, driver: .released, evidence: .readFrom(floor), readWith: floor,
                afterAuto: true) == .automaticAsChosen)
    }

    @Test("No 'as you chose' over a fan the helper does not report cleared")
    func notChosenOverAFanNotCleared() {
        let snapshot = Support.snapshot(fans: [
            Fans.offered(0), Fans.fan(1, mode: .manualFixed, availability: .available),
        ])
        #expect(Tests.state(snapshot, driver: .released, afterAuto: true) == nil)
    }

    /// `released` alone is not the user's Auto: the last control window closing and fast user
    /// switching release too, and leave the app running in `released`.
    ///
    /// **Mutation (V6, "released is a choice"):** in `isTheUsersAuto(_:)`, drop
    /// `inputs.enteredAfterTheUsersAuto`. Run: red here.
    @Test("No 'as you chose' for a release the user did not ask for")
    func notChosenForAReleaseNobodyAskedFor() {
        #expect(Tests.state(Tests.cleared, driver: .released, afterAuto: false) == nil)
    }

    /// **Mutation (V7, "chose after a loss or a refusal"):** in `isTheUsersAuto(_:)`, accept any
    /// state `isNotActing(_:)` accepts. Run: red at `.lost`, `.refused` and `.idle`.
    @Test(
        "No 'as you chose' beside a loss, a refusal, or a driver that never acted",
        arguments: [
            LeaseDriverState.idle,
            .lost(
                LeaseLoss(
                    lease: FanControlFixtures.ours,
                    cause: .releaseUnconfirmed(.other("no answer")), afterWake: false)),
            .refused(.manualControlUnavailable(reason: .foreignManualControl)),
        ])
    func notChosenBesideALossOrARefusal(driver: LeaseDriverState) throws {
        let screen = Fixtures.screen(Tests.cleared, driver: driver)
        let fans = AllFansControlPresentationTests.fans(screen)
        try #require(
            fans.allSatisfy { $0.presentation.selection == .automatic },
            "the screen must read Automatic, or this test cannot fail")

        #expect(Display.state(given: Tests.inputs(screen, afterAuto: true)) == nil)
    }

    // MARK: - Precedence

    /// **Mutation (V8, "the emergency ignored"):** in `state(given:)`, delete the
    /// `thermalEmergency != .active` guard. Run: red at the reclaimed and refused screens.
    @Test("A thermal emergency silences the banner: ThermalEmergencyBanner speaks")
    func anEmergencySilencesIt() {
        let reclaimed = Support.snapshot(
            fans: [Support.fan(0, reclaimed: true)], isThermalEmergencyActive: true)
        let refused = Support.snapshot(
            fans: [Fans.refused(0, .noThermalTelemetry)], isThermalEmergencyActive: true)

        #expect(Tests.state(reclaimed) == nil)
        #expect(Tests.state(refused) == nil)
        #expect(
            Tests.state(
                Support.snapshot(fans: [Fans.offered(0)], isThermalEmergencyActive: true),
                driver: .released, afterAuto: true) == nil)
    }

    /// A reclaimed fan the helper still reports cleared to automatic reads Automatic, so after the
    /// user's Auto both hold.
    ///
    /// **Mutation (V9, "chose above reclaimed"):** in `state(given:)`, test "as you chose" before
    /// reclamation. Run: red here.
    @Test("Reclaimed outranks 'as you chose'")
    func reclaimedOutranksChosen() throws {
        let snapshot = Support.snapshot(fans: [
            Fans.offered(0),
            FanState(
                index: 1, actualRPM: .measured(2345), minimumRPM: .measured(1200),
                maximumRPM: .measured(4800), targetRPM: nil, mode: .automatic,
                isReclaimedBySystem: true, manualControlAvailability: .available),
        ])
        let screen = Fixtures.screen(snapshot, driver: .released)
        try #require(
            AllFansControlPresentationTests.fans(screen).allSatisfy {
                $0.presentation.selection == .automatic
            }, "the screen must read Automatic, or this test cannot fail")

        #expect(
            Tests.state(snapshot, driver: .released, afterAuto: true)
                == .reclaimedBySystem(fans: ["Fan 1"]))
    }

    /// **Mutation (V10, "refused above reclaimed"):** in `state(given:)`, test refusals before
    /// reclamation. Run: red here.
    @Test("Reclaimed outranks refused")
    func reclaimedOutranksRefused() {
        let snapshot = Support.snapshot(fans: [
            Support.fan(0, reclaimed: true), Support.fan(1),
        ])
        #expect(Tests.state(snapshot) == .reclaimedBySystem(fans: ["Fan 0"]))
    }

    /// Every fan on today's helper is refused `writePathNotBuilt`, which is silent, so a fan reads
    /// cleared and Automatic beside it.
    ///
    /// **Mutation (V11, "chose above refused"):** in `state(given:)`, test "as you chose" before
    /// refusals. Run: red here.
    @Test("Refused outranks 'as you chose'")
    func refusedOutranksChosen() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .writePathNotBuilt), Fans.refused(1, .writePathNotBuilt),
        ])
        #expect(
            Tests.state(snapshot, driver: .released, afterAuto: true)
                == .refused([.init(fans: nil, value: Tests.refusal(.writePathNotBuilt))]))
    }

    /// The three states in which the driver acts.
    enum Acting: CaseIterable {
        case acquiring, held, releasing

        func driver() throws -> LeaseDriverState {
            switch self {
            case .acquiring:
                return .acquiring(fans: [0, 1])
            case .held:
                let target = try FanControlFixtures.target([0: 3000, 1: 3000])
                return FanControlFixtures.held(
                    FanControlFixtures.ours, fans: [0, 1], .confirmed(target))
            case .releasing:
                return .releasing
            }
        }
    }

    /// **Mutation (V12, "monitoring only while acting"):** in `state(given:)`, delete the
    /// `isNotActing` guard. Run: red at each acting state's refused screen.
    @Test(
        "While the driver acts, refused says nothing and reclaimed still speaks",
        arguments: Acting.allCases)
    func actingSilencesRefused(acting: Acting) throws {
        let driver = try acting.driver()
        let refused = Support.snapshot(fans: [
            Fans.refused(0, .noThermalTelemetry), Fans.refused(1, .noThermalTelemetry),
        ])
        #expect(Tests.state(refused, driver: driver) == nil)

        let reclaimed = Support.snapshot(fans: [
            Support.fan(0, availability: .available, reclaimed: true),
            Support.fan(1, availability: .available),
        ])
        #expect(Tests.state(reclaimed, driver: driver) == .reclaimedBySystem(fans: ["Fan 0"]))
    }

    /// Untracked rows report nothing, so every later check already refuses them. The machine's
    /// source is checked first all the same, as `FanControlPresentation`'s licence checks it: a
    /// read that pairs a withdrawn source with rows still carrying the helper's report, as a read
    /// part-way through a withdrawal would, says nothing either.
    ///
    /// **Mutation (V13, "not tracked guesses"):** in `state(given:)`, carry on past `.notTracked`.
    /// Run: red at the mixed read's expectation, for every reason.
    @Test(
        "Nothing tracked, for any reason but the build, says nothing",
        arguments: [
            ControlNotTracked.nothingReadYet, .helperInstallIncomplete, .awaitingSnapshot,
            .snapshotStale, .helperConnection(.unresponsive),
        ])
    func notTrackedSaysNothing(why: ControlNotTracked) {
        let reclaimed = Support.snapshot(fans: [Support.fan(0, reclaimed: true)])
        let withdrawn = Fixtures.withdrawn(why, driver: .released, from: reclaimed)
        #expect(Display.state(given: Tests.inputs(withdrawn, afterAuto: true)) == nil)

        let reported = Tests.inputs(Fixtures.screen(reclaimed, driver: .released), afterAuto: true)
        let mixed = Display.Inputs(
            controlSource: .notTracked(why), thermalEmergency: .unknown, fans: reported.fans,
            driver: .released, enteredAfterTheUsersAuto: true)
        #expect(
            Display.state(given: mixed) == nil, "rows still reporting beside a withdrawn source")
    }

    @Test("Anything else says nothing")
    func anythingElseSaysNothing() {
        #expect(Tests.state(Tests.cleared) == nil, "idle over offered fans")
        #expect(
            Tests.state(
                Support.snapshot(fans: [Fans.refused(0, .noThermalTelemetry), Fans.offered(1)]))
                == nil, "a mix of refused and offered")
        #expect(Tests.state(Support.snapshot(fans: [])) == nil, "no fan on screen")
        #expect(
            Tests.state(Support.snapshot(fans: []), driver: .released, afterAuto: true) == nil,
            "no fan on screen, after the user's Auto")
    }
}
