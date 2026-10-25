import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// The generation check and `canRelease`: a read that pairs two snapshots claims nothing, and a
/// release is offered from the driver's state alone, under every affordance.
@Suite("FanControlPresentation — one snapshot at a time, and release is not an affordance")
struct FanControlGenerationTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport

    // MARK: - One snapshot at a time

    /// One input taken from a newer snapshot than the one on screen, the rest from the older:
    /// what a sink on a single published property of `PollingViewModel` sees part-way through a
    /// render. Each case changes one input only.
    enum Mismatch: CaseIterable {
        case lease, fanState, emergency
    }

    /// On screen: our lease and fan 0 held at 3000 RPM, which on its own reads Custom.
    ///
    /// **Mutations (G1, G2, G3):** delete the lease, the fan-state, or the emergency `guard` in
    /// `Licence.isOneSnapshot`. Run, each: red at the affordance for its own argument.
    @Test(
        "A read that pairs two snapshots claims nothing", arguments: Mismatch.allCases)
    func aReadThatPairsTwoSnapshotsClaimsNothing(_ mismatch: Mismatch) throws {
        let target = try Fixtures.target([0: 3000])
        let driver = Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target))
        let older = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        let settled = Fixtures.screen(older, driver: driver)
        #expect(
            try Fixtures.present(0, on: settled).selection == .custom(Fixtures.speed(target, 0)))

        var lease = Fixtures.ours as Lease?
        var emergency = ThermalEmergencyState.inactive
        var rows = settled.rows
        switch mismatch {
        case .lease:
            lease = nil
        case .fanState:
            rows = SnapshotReadings.fans(
                in: Support.snapshot(fans: [Fixtures.heldFan(0, target: 2500)]))
        case .emergency:
            emergency = .active
        }
        let mixed = Fixtures.Screen(
            inputs: FanControlPresentation.Inputs(
                controlSource: .helperSnapshot(activeLease: lease), thermalEmergency: emergency,
                renderedSnapshot: older, renderedReadTicket: nil,
                driver: driver, automaticEvidence: .anyRead),
            rows: rows)
        let presentation = try Fixtures.present(0, on: mixed)

        #expect(presentation.affordance == .disabled(.betweenSnapshots))
        #expect(presentation.selection == .checking)
        #expect(
            presentation.status?.text
                == "Not confirmed: the window's inputs come from different helper snapshots.")
    }

    // MARK: - Release is not an affordance

    /// One screen per affordance rule, each with `driver` in it.
    enum Rule: CaseIterable {
        case hidden, notTracked, nothingOnScreen, betweenSnapshots, emergency, anotherLease
        case refused, enabled

        func screen(_ driver: LeaseDriverState) -> Fixtures.Screen {
            let cleared = Fixtures.clearedFan(0)
            switch self {
            case .hidden:
                return Fixtures.withdrawn(.noHelperInThisBuild, driver: driver)
            case .notTracked:
                return Fixtures.withdrawn(.snapshotStale, driver: driver)
            case .nothingOnScreen:
                let rows = Fixtures.screen(Support.snapshot(fans: [cleared]), driver: driver).rows
                return Fixtures.Screen(
                    inputs: FanControlPresentation.Inputs(
                        controlSource: .helperSnapshot(activeLease: nil),
                        thermalEmergency: .inactive, renderedSnapshot: nil, renderedReadTicket: nil,
                        driver: driver, automaticEvidence: .anyRead),
                    rows: rows)
            case .betweenSnapshots:
                let shown = Support.snapshot(fans: [cleared])
                return Fixtures.Screen(
                    inputs: FanControlPresentation.Inputs(
                        controlSource: .helperSnapshot(activeLease: Fixtures.theirs),
                        thermalEmergency: .inactive, renderedSnapshot: shown,
                        renderedReadTicket: nil,
                        driver: driver, automaticEvidence: .anyRead),
                    rows: SnapshotReadings.fans(in: shown))
            case .emergency:
                return Fixtures.screen(
                    Support.snapshot(fans: [cleared], isThermalEmergencyActive: true),
                    driver: driver)
            case .anotherLease:
                return Fixtures.screen(
                    Support.snapshot(fans: [cleared], activeLease: Fixtures.theirs), driver: driver)
            case .refused:
                return Fixtures.screen(Support.snapshot(fans: [Support.fan(0)]), driver: driver)
            case .enabled:
                return Fixtures.screen(Support.snapshot(fans: [cleared]), driver: driver)
            }
        }

        /// The affordance this rule's screen gives, with its exact reason, under every driver
        /// state: no rule's reason depends on the driver, the held lease included.
        var affordance: FanControlPresentation.Affordance {
            let writePath = ManualControlAvailability.Reason.writePathNotBuilt
            switch self {
            case .hidden: return .hidden(.noHelperInThisBuild)
            case .notTracked: return .disabled(.notTracked(.snapshotStale))
            case .nothingOnScreen: return .disabled(.nothingOnScreen)
            case .betweenSnapshots: return .disabled(.betweenSnapshots)
            case .emergency: return .disabled(.thermalEmergencyActive)
            case .anotherLease: return .disabled(.heldElsewhere(Fixtures.theirs))
            case .refused:
                return .disabled(
                    FanControlPresentation.Reason(
                        summary: writePath.userFacingSummary, advice: writePath.recoveryAdvice,
                        wireValue: "writePathNotBuilt"))
            case .enabled: return .enabled
            }
        }
    }

    /// `canRelease` follows the driver and nothing else: true while it is acquiring or holding a
    /// lease over the fan, and for every fan while it is releasing, under every affordance, hidden
    /// included.
    ///
    /// **Changed by #154's ruling (Q2, PR 8a):** `.releasing` used to answer `false`. It answers
    /// `true`, so Auto can cancel a `take` queued behind the release while the snapshot on screen
    /// still lists the old lease. **Mutation (M10):** answer `false` for `.releasing`. Run: red for
    /// `.releasing` under every rule.
    ///
    /// Each rule's screen reaches its own rule, with its exact reason, under every driver state.
    ///
    /// **Mutation (RX):** in `affordance`, return `.disabled(.betweenSnapshots)` for
    /// `.nothingOnScreen`. Run: red here for `.nothingOnScreen` under every driver state, where the
    /// assertion this replaced, `!= .enabled`, passed; and in `FanControlAffordanceTests`.
    /// **Mutation (CR):** in `init(reading:given:)`, compute `canRelease` as
    /// `affordance == .enabled && Self.canRelease(...)`. Run: red for `.acquiring` and `.held`
    /// under every rule but `.enabled`.
    @Test(
        "A release is offered while the driver holds, asks for or releases, whatever the rule",
        arguments: Fixtures.DriverTag.allCases, Rule.allCases)
    func releaseFollowsTheDriverAlone(_ tag: Fixtures.DriverTag, _ rule: Rule) throws {
        let presentation = try Fixtures.present(0, on: rule.screen(try tag.state()))

        let expected: Bool
        switch tag {
        case .acquiring, .held, .releasing: expected = true
        case .idle, .released, .lost, .refused: expected = false
        }
        #expect(presentation.canRelease == expected)
        #expect(presentation.affordance == rule.affordance, "\(rule) reached its own rule")
    }

    /// **Mutation (CR2):** make `canRelease`'s `.held` arm return `true` whatever fans it covers.
    /// Run: red at fan 1's expectation.
    @Test("A release is offered only for the fans the lease covers")
    func releaseIsOnlyForCoveredFans() throws {
        let target = try Fixtures.target([0: 3000])
        let screen = Fixtures.screen(
            Support.snapshot(
                fans: [Fixtures.heldFan(0), Fixtures.clearedFan(1)], activeLease: Fixtures.ours),
            driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)))

        #expect(try Fixtures.present(0, on: screen).canRelease)
        #expect(try !Fixtures.present(1, on: screen).canRelease)
        let asking = Fixtures.screen(
            Support.snapshot(fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)]),
            driver: .acquiring(fans: [0]))
        #expect(try !Fixtures.present(1, on: asking).canRelease)
    }
}
