import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `MonitoringModeDisplay` (#157): one test per state with its text pinned by literal, in
/// `HelperStatusDisplayTests`' style, then the evidence "as you chose" rests on, then the order
/// between the states.
///
/// Every screen is built by `FanControlFixtures`, which `FanControlInputsTests` holds to what
/// `PollingViewModel` puts on screen, and every fan's presentation is the shipping one's.
@Suite("Monitoring mode — chose Auto, refused, reclaimed or no helper, and never a guess")
struct MonitoringModeDisplayTests {

    typealias Fixtures = FanControlFixtures
    typealias Fans = AllFansFixtures
    typealias Support = SnapshotTestSupport
    typealias Display = MonitoringModeDisplay
    typealias Reason = ManualControlAvailability.Reason

    /// The banner's inputs for `screen`, as `Inputs(polling:lease:)` reads them.
    static func inputs(_ screen: Fixtures.Screen, afterAuto: Bool) -> Display.Inputs {
        Display.Inputs(
            controlSource: screen.inputs.controlSource,
            thermalEmergency: screen.inputs.thermalEmergency,
            fans: AllFansControlPresentationTests.fans(screen), driver: screen.inputs.driver,
            enteredAfterTheUsersAuto: afterAuto)
    }

    /// The state for `snapshot` on screen beside `driver`, its `evidence`, and whether the driver's
    /// state was entered after the user's Auto.
    static func state(
        _ snapshot: SystemSnapshot, driver: LeaseDriverState = .idle,
        evidence: LeaseDriverReport.AutomaticEvidence = .anyRead,
        readWith ticket: LeaseDriver.SnapshotTicket? = nil, afterAuto: Bool = false
    ) -> Display.State? {
        let screen = Fixtures.screen(snapshot, driver: driver, evidence: evidence, readWith: ticket)
        return Display.state(given: inputs(screen, afterAuto: afterAuto))
    }

    /// Two fans the helper offers and reports cleared to automatic, no lease listed.
    static let cleared = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])

    /// The refusal `reason` gives, as the fan's row shows it.
    static func refusal(_ reason: Reason) -> FanRowModel.Refusal {
        FanRowModel.Refusal(
            summary: reason.userFacingSummary, advice: reason.recoveryAdvice,
            wireValue: reason.wireValue)
    }

    /// One of every state, for the invariants.
    static let everyState: [Display.State] = [
        .noHelperInThisBuild,
        .reclaimedBySystem(fans: nil),
        .reclaimedBySystem(fans: ["Fan 1"]),
        .refused([.init(fans: nil, value: refusal(.writePathNotBuilt))]),
        .automaticAsChosen,
    ]

    // MARK: - One test per state, its text by literal

    /// **Mutation (V1, "no helper says nothing"):** in `state(given:)`, return `nil` for
    /// `.notTracked(.noHelperInThisBuild)`. Run: red at the state, and at `drawn` in
    /// `MonitoringModeBannerTests`' build with no helper.
    @Test("No helper in this build: monitoring only, and why")
    func noHelperInThisBuild() {
        let screen = Fixtures.withdrawn(
            .noHelperInThisBuild, driver: .idle, from: Self.cleared)

        #expect(Display.state(given: Self.inputs(screen, afterAuto: false)) == .noHelperInThisBuild)
        #expect(
            Display.banner(for: .noHelperInThisBuild)
                == Display.Banner(
                    headline:
                        "Monitoring only: this build ships no privileged helper, so it cannot "
                        + "change fan speeds.",
                    detail: nil, reasons: [], severity: .normal))
    }

    @Test("Every fan reclaimed: the helper's report of it, as a warning, naming no fan")
    func everyFanReclaimed() {
        let snapshot = Support.snapshot(fans: [
            Support.fan(0, reclaimed: true), Support.fan(1, reclaimed: true),
        ])

        #expect(Self.state(snapshot) == .reclaimedBySystem(fans: nil))
        #expect(
            Display.banner(for: .reclaimedBySystem(fans: nil))
                == Display.Banner(
                    headline: "The helper reports every fan reclaimed by the system.",
                    detail: "The system took back manual control the helper had asked for.",
                    reasons: [], severity: .warning))
    }

    /// **Mutation (V2, "every fan, always"):** in `state(given:)`, report `fans: nil` whatever
    /// was reclaimed. Run: red at the state, and at every named reclamation in
    /// `MonitoringModePrecedenceTests`.
    @Test("Some fans reclaimed: named, and only those")
    func someFansReclaimed() {
        let snapshot = Support.snapshot(fans: [
            Support.fan(0), Support.fan(1, reclaimed: true), Support.fan(2, reclaimed: true),
        ])

        #expect(Self.state(snapshot) == .reclaimedBySystem(fans: ["Fan 1", "Fan 2"]))
        #expect(
            Display.banner(for: .reclaimedBySystem(fans: ["Fan 1", "Fan 2"])).headline
                == "The helper reports Fan 1, Fan 2 reclaimed by the system.")
    }

    @Test("Refused, the write path not built: the reason's own words and wire value")
    func refusedWritePathNotBuilt() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .writePathNotBuilt), Fans.refused(1, .writePathNotBuilt),
        ])
        let refused = Display.State.refused([
            .init(fans: nil, value: Self.refusal(.writePathNotBuilt))
        ])

        #expect(Self.state(snapshot) == refused)
        #expect(
            Display.banner(for: refused)
                == Display.Banner(
                    headline: "Monitoring only: the helper refuses manual control of every fan.",
                    detail: nil,
                    reasons: [
                        .init(
                            text:
                                "This build of Aeolus has no path to write to the SMC yet, so "
                                + "manual control is not available for any fan.",
                            wireValue: "writePathNotBuilt")
                    ],
                    severity: .normal))
    }

    /// **Mutation (V3, "the wrong reason"):** in `banner(for:)`, draw each refusal's `advice` in
    /// place of its `summary`. Run: red at the reasons in every refused test in this suite: the
    /// write path above, this one, and the three below.
    @Test("Refused, no thermal telemetry: its own words")
    func refusedNoThermalTelemetry() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .noThermalTelemetry), Fans.refused(1, .noThermalTelemetry),
        ])
        let state = Self.state(snapshot)

        #expect(state == .refused([.init(fans: nil, value: Self.refusal(.noThermalTelemetry))]))
        #expect(
            state.map(Display.banner(for:))?.reasons == [
                .init(
                    text:
                        "Aeolus cannot currently read a critical temperature, so it cannot safely "
                        + "watch a fan under manual control.",
                    wireValue: "noThermalTelemetry")
            ])
    }

    @Test("Refused, bounds implausible: its own words")
    func refusedBoundsImplausible() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .boundsImplausible), Fans.refused(1, .boundsImplausible),
        ])

        #expect(
            Self.state(snapshot).map(Display.banner(for:))?.reasons == [
                .init(
                    text:
                        "This fan's firmware speed bounds did not pass a plausibility check, so "
                        + "there is no safe range to control it within.",
                    wireValue: "boundsImplausible")
            ])
    }

    /// `.supervisorBlind` is its own reason, pointing at Aeolus's own read of the fan, never the
    /// write path's sentence and never "as you chose" (#157's thread). Its clearance is pending, so
    /// the fan does not read Automatic even after the user's Auto.
    @Test("Refused, supervisor blind: its own words, never the write path's, never chosen")
    func refusedSupervisorBlind() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .supervisorBlind), Fans.refused(1, .supervisorBlind),
        ])
        let state = Self.state(snapshot, driver: .released, afterAuto: true)

        #expect(
            state.map(Display.banner(for:))?.reasons == [
                .init(
                    text:
                        "Aeolus could not confirm this fan's own control state: a read of it "
                        + "failed, or start-up could not confirm it back under automatic control.",
                    wireValue: "supervisorBlind")
            ])
        let mixed = Support.snapshot(fans: [
            Fans.refused(0, .supervisorBlind), Fans.offered(1),
        ])
        #expect(
            Self.state(mixed, driver: .released, afterAuto: true) == nil,
            "a blind fan beside an offered one read as the user's Auto")
    }

    /// **Mutation (V4, "the first fan's reason for all"):** in `refusals(_:)`, append the first
    /// fan's refusal for every fan. Run: red at the state and at the texts.
    @Test("Refused for different reasons: each named by its fans")
    func refusedForDifferentReasons() {
        let snapshot = Support.snapshot(fans: [
            Fans.refused(0, .noThermalTelemetry), Fans.refused(1, .boundsImplausible),
        ])
        let state = Self.state(snapshot)

        #expect(
            state
                == .refused([
                    .init(fans: ["Fan 0"], value: Self.refusal(.noThermalTelemetry)),
                    .init(fans: ["Fan 1"], value: Self.refusal(.boundsImplausible)),
                ]))
        #expect(
            state.map(Display.banner(for:))?.reasons.map(\.text) == [
                "Fan 0: " + Reason.noThermalTelemetry.userFacingSummary,
                "Fan 1: " + Reason.boundsImplausible.userFacingSummary,
            ])
    }

    @Test("Auto, as the user chose: the helper's report, and no lease listed")
    func automaticAsChosen() {
        #expect(Self.state(Self.cleared, driver: .released, afterAuto: true) == .automaticAsChosen)
        #expect(
            Display.banner(for: .automaticAsChosen)
                == Display.Banner(
                    headline: "Monitoring only: Auto, as you chose.",
                    detail:
                        "The helper reports every fan back under automatic control, and lists no "
                        + "manual-control lease.",
                    reasons: [], severity: .normal))
    }

    // MARK: - Invariants over every state

    @Test("Every state says something", arguments: Self.everyState)
    func everyStateSaysSomething(state: Display.State) {
        #expect(!Display.banner(for: state).headline.isEmpty)
    }

    /// Only the one state with the user's Auto behind it says "chose", and none says what the fans
    /// are rather than what the helper reports.
    @Test("Only 'as you chose' says chose, and nothing says the fans are automatic")
    func onlyTheChoiceSaysChose() {
        for state in Self.everyState {
            let banner = Display.banner(for: state)
            let words = ([banner.headline, banner.detail ?? ""] + banner.reasons.map(\.text))
                .joined(separator: " ").lowercased()
            #expect(words.contains("chose") == (state == .automaticAsChosen), "\(state)")
            #expect(!words.contains("fans are"), "\(state)")
            #expect(!words.contains("is automatic"), "\(state)")
        }
    }
}
