import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// What the control may show as selected: a function of the driver and the snapshot on screen,
/// never of a click. Custom needs a confirmed apply, a licensed snapshot, and #472's
/// `controlLoss` answering `nil` over every fan the lease covers.
@Suite("FanControlPresentation — the selection is a function of state, never of a click")
struct FanControlSelectionTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias StatusLine = FanControlPresentation.StatusLine

    static let notConfirmed = StatusLine(
        text: "Not confirmed: the helper's snapshot does not show this lease holding its fans.",
        detail: nil)

    /// Two fans held under our lease at 3000 and 3200 RPM, the lease listed, no emergency: every
    /// condition Custom has, met.
    static func heldEverywhere() -> SystemSnapshot {
        Support.snapshot(
            fans: [Fixtures.heldFan(0, target: 3000), Fixtures.heldFan(1, target: 3200)],
            activeLease: Fixtures.ours)
    }

    // MARK: - Custom

    /// The snapshot's held targets, 2900 and 3100 RPM, are not the confirmed ones, 3000 and 3200,
    /// as after an adjust whose apply the snapshot predates. Each fan's line names both of its own.
    ///
    /// **Mutation (SV1):** make the Custom line's snapshot figure the accepted speed. **Mutation
    /// (SV2):** read it from the snapshot's first fan. **Mutation (SV5):** read the accepted speed
    /// from the target's first fan. Run, each: red at fan 1's line.
    @Test("Custom when held, confirmed, a licensed snapshot is on screen and nothing is lost")
    func customWhenEverythingHolds() throws {
        let target = try Fixtures.target([0: 3000, 1: 3200])
        let driver = Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target))
        let snapshot = Support.snapshot(
            fans: [Fixtures.heldFan(0, target: 2900), Fixtures.heldFan(1, target: 3100)],
            activeLease: Fixtures.ours)
        #expect(snapshot.controlLoss(leaseID: Fixtures.ours.id, covering: [0, 1]) == nil)
        let screen = Fixtures.screen(snapshot, driver: driver)

        for index in [0, 1] {
            let presentation = try Fixtures.present(index, on: screen)
            #expect(
                presentation.selection == .custom(try Fixtures.speed(target, index)), "fan \(index)"
            )
            #expect(presentation.affordance == .enabled, "fan \(index)")
        }
        #expect(
            try Fixtures.present(0, on: screen).status?.text
                == "Accepted 3000 RPM; the helper's last snapshot reports 2900 RPM.")
        #expect(
            try Fixtures.present(1, on: screen).status?.text
                == "Accepted 3200 RPM; the helper's last snapshot reports 3100 RPM.")
    }

    /// The snapshot would prove control; only the phase says the apply has not answered.
    ///
    /// **Mutation (C1):** in `heldClaim`'s `.applying` arm, return `.custom(speed)`. Run: red at
    /// the selection. **Mutation (SV4):** make the applying line read the target's first fan. Run:
    /// red at fan 1's line.
    @Test("An apply in flight is drawn as asked for, never as achieved")
    func anApplyInFlightIsNeverCustom() throws {
        let sent = try Fixtures.target([0: 3000, 1: 3200])
        let queued = try Fixtures.target([0: 4000, 1: 4000])
        let driver = Fixtures.held(Fixtures.ours, fans: [0, 1], .applying(sent, queued: queued))
        let screen = Fixtures.screen(Self.heldEverywhere(), driver: driver)
        let presentation = try Fixtures.present(0, on: screen)

        #expect(presentation.selection == .applying(try Fixtures.speed(sent, 0)))
        #expect(
            presentation.status
                == StatusLine(
                    text: "Asked the helper for 3000 RPM. Not confirmed yet.", detail: nil))
        // Fan 1's own speed, not the first fan's.
        let other = try Fixtures.present(1, on: screen)
        #expect(other.selection == .applying(try Fixtures.speed(sent, 1)))
        #expect(other.status?.text == "Asked the helper for 3200 RPM. Not confirmed yet.")
    }

    /// After a wake, the snapshot from before the sleep is stale and is withdrawn: `.snapshotStale`
    /// is one of the arguments, and it needs no state of its own in the driver.
    ///
    /// **Mutation (C2):** in `heldClaim`'s `.confirmed` arm, return `.custom(speed)` instead of
    /// `.checking` when no licensed snapshot is on screen. Run: red for every argument.
    @Test(
        "Held with no licensed snapshot on screen is checking, never Custom",
        arguments: FanControlAffordanceTests.untrackedButBuilt)
    func heldWithNoLicensedSnapshotIsChecking(_ why: ControlNotTracked) throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .confirmed(try Fixtures.target([0: 3000])))
        let presentation = try Fixtures.present(0, on: Fixtures.withdrawn(why, driver: driver))

        #expect(presentation.selection == .checking)
        #expect(
            presentation.status
                == StatusLine(
                    text: "Not confirmed: no current helper snapshot is on screen.", detail: nil))
    }

    /// A two-fan lease. Fan 0 is reported held in every snapshot, and each snapshot is checked
    /// against `controlLoss` itself first, so it is the loss it says. Every row comes from the
    /// snapshot it is presented against.
    ///
    /// **Mutation (C3):** drop the `controlLoss(...) == nil` guard from `heldClaim`'s `.confirmed`
    /// arm. Run: red at the selection for every argument.
    @Test("Custom needs controlLoss to answer nil", arguments: Fixtures.LossTag.allCases)
    func customNeedsNoLoss(_ tag: Fixtures.LossTag) throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0, 1], .confirmed(try Fixtures.target([0: 3000, 1: 3200])))

        for (snapshot, loss) in tag.snapshots {
            #expect(snapshot.controlLoss(leaseID: Fixtures.ours.id, covering: [0, 1]) == loss)
            let presentation = try Fixtures.present(
                0, on: Fixtures.screen(snapshot, driver: driver))
            #expect(presentation.selection == .unknown, "\(loss)")
            #expect(presentation.status == Self.notConfirmed, "\(loss)")
        }
    }

    /// Two fans under one lease, and fan 1 reclaimed. Fan 0's own state reads held, and its own
    /// row would pass any judgement of fan 0 alone; the lease has still lost control.
    ///
    /// **Mutation (C4):** replace the `controlLoss` call with a judgement of this fan alone:
    /// `snapshot.activeLease?.id == held.lease.id`, and this fan's `targetRPM` positive and not
    /// reclaimed. **Mutation (C5):** pass `covering: [index]`. Run, each: red at fan 0's selection.
    @Test("Loss is judged over every fan the lease covers, by controlLoss alone")
    func lossIsJudgedOverTheWholeLease() throws {
        let target = try Fixtures.target([0: 3000, 1: 3200])
        let driver = Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target))
        let reclaimed = Support.fan(
            1, mode: .manualFixed, availability: .available, reclaimed: true)
        let snapshot = Support.snapshot(
            fans: [Fixtures.heldFan(0, target: 3000), reclaimed], activeLease: Fixtures.ours)
        #expect(
            snapshot.controlLoss(leaseID: Fixtures.ours.id, covering: [0, 1])
                == .reclaimedBySystem(fan: 1))
        #expect(snapshot.controlLoss(leaseID: Fixtures.ours.id, covering: [0]) == nil)

        let screen = Fixtures.screen(snapshot, driver: driver)
        #expect(try Fixtures.present(0, on: screen).selection == .unknown)
        #expect(try Fixtures.present(1, on: screen).selection == .unknown)
    }

    @Test("A held fan whose target names no speed for it shows none")
    func aTargetWithNoSpeedForTheFanShowsNone() throws {
        let target = try Fixtures.target([0: 3000])
        let screen = { (phase: HeldLease.Phase) in
            Fixtures.screen(
                Self.heldEverywhere(), driver: Fixtures.held(Fixtures.ours, fans: [0, 1], phase))
        }

        let noSpeed = StatusLine(
            text: "Not confirmed: no speed for this fan has been accepted.", detail: nil)
        for phase in Fixtures.PhaseTag.allCases.map({ $0.phase(target) }) {
            let presentation = try Fixtures.present(1, on: screen(phase))
            #expect(presentation.selection == .unknown, "\(phase)")
            #expect(presentation.status == noSpeed, "\(phase)")
        }
        #expect(
            try Fixtures.present(0, on: screen(.confirmed(target))).selection
                == .custom(try Fixtures.speed(target, 0)))
    }

    // MARK: - Automatic

    /// The reasons a fan reading automatic is not cleared, from `FanRowModelTests`' exhaustive tag.
    ///
    /// **Mutation (A1):** in `automaticOrUnknown`, use `state.mode == .automatic`. Run: red for
    /// every argument.
    @Test(
        "Automatic needs the helper to have cleared the fan, not only its mode",
        arguments: FanRowModelTests.notClearing)
    func automaticNeedsClearance(_ reason: ManualControlAvailability.Reason) throws {
        let fan = Support.fan(0, mode: .automatic, availability: .unavailable(reason))
        let screen = Fixtures.screen(Support.snapshot(fans: [fan]), driver: .idle)

        #expect(try Fixtures.present(0, on: screen).selection == .unknown)
    }

    @Test(
        "A fan cleared to automatic, with nothing held, reads Automatic",
        arguments: [Fixtures.DriverTag.idle, .released, .lost, .refused])
    func aClearedFanReadsAutomatic(_ tag: Fixtures.DriverTag) throws {
        let screen = Fixtures.screen(
            Support.snapshot(fans: [Fixtures.clearedFan(0)]), driver: try tag.state())

        #expect(try Fixtures.present(0, on: screen).selection == .automatic)
    }

    @Test("A fan reading manual with nothing held is unknown, not Custom")
    func aManualFanNobodyHoldsIsUnknown() throws {
        let screen = Fixtures.screen(Support.snapshot(fans: [Fixtures.heldFan(0)]), driver: .idle)

        #expect(try Fixtures.present(0, on: screen).selection == .unknown)
    }

    /// The fan reads cleared to automatic each time, as it does in a snapshot taken before the
    /// first `apply`. Only the driver says it is wanted.
    ///
    /// **Mutation (A2):** delete `claim`'s `.acquiring(let fans) where fans.contains(index)` arm.
    /// **Mutation (A3):** make its `.releasing` arm return `automaticOrUnknown(licence)`.
    /// **Mutation (A4):** delete its `.held(let held) where held.fans.contains(index)` arm, so a
    /// held fan is judged as if nothing held it. Run, each: red at its expectation.
    @Test("A fan the driver holds, is asking for or is releasing never reads Automatic")
    func aFanTheDriverWantsIsNeverAutomatic() throws {
        let cleared = Support.snapshot(fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)])
        let target = try Fixtures.target([0: 3000])
        func selection(
            _ index: Int, _ driver: LeaseDriverState
        ) throws -> FanControlPresentation.Selection {
            try Fixtures.present(index, on: Fixtures.screen(cleared, driver: driver)).selection
        }

        #expect(try selection(0, .acquiring(fans: [0])) == .unknown)
        #expect(try selection(0, .releasing) == .unknown)
        for tag in Fixtures.PhaseTag.allCases {
            let held = Fixtures.held(Fixtures.ours, fans: [0], tag.phase(target))
            let expected: FanControlPresentation.Selection
            switch tag {
            case .applying: expected = .applying(try Fixtures.speed(target, 0))
            case .confirmed: expected = .unknown
            }
            #expect(try selection(0, held) == expected, "\(tag)")
            // A fan the driver does not hold is judged on its own.
            #expect(try selection(1, held) == .automatic, "\(tag)")
        }
        #expect(try selection(1, .acquiring(fans: [0])) == .automatic)
    }

    // MARK: - A click selects nothing

    /// The states a click on a speed walks through, in order. The segment moves only when the
    /// helper has accepted the target and a snapshot shows the fans held.
    @Test("A click on a speed selects nothing until the helper confirms it and a snapshot shows it")
    func aClickSelectsNothingByItself() throws {
        let target = try Fixtures.target([0: 3000])
        let before = Support.snapshot(fans: [Fixtures.clearedFan(0)], activeLease: Fixtures.ours)
        let after = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        struct Step {
            let driver: LeaseDriverState
            let snapshot: SystemSnapshot
            let expected: FanControlPresentation.Selection
        }
        let held = { (phase: HeldLease.Phase) in Fixtures.held(Fixtures.ours, fans: [0], phase) }
        let steps = [
            Step(
                driver: .acquiring(fans: [0]),
                snapshot: Support.snapshot(fans: [Fixtures.clearedFan(0)]), expected: .unknown),
            Step(
                driver: held(.applying(target, queued: nil)), snapshot: before,
                expected: .applying(try Fixtures.speed(target, 0))),
            Step(driver: held(.confirmed(target)), snapshot: before, expected: .unknown),
            Step(
                driver: held(.confirmed(target)), snapshot: after,
                expected: .custom(try Fixtures.speed(target, 0))),
        ]

        for step in steps {
            let presentation = try Fixtures.present(
                0, on: Fixtures.screen(step.snapshot, driver: step.driver))
            #expect(presentation.selection == step.expected, "\(Fixtures.DriverTag(step.driver))")
        }
    }
}
