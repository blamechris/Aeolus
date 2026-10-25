import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// When the control is hidden, disabled with a reason, or enabled: `FanControlPresentation`'s
/// five rules, in order, each against a screen where it alone applies.
@Suite("FanControlPresentation — hidden, disabled with a reason, or enabled")
struct FanControlAffordanceTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Reason = FanControlPresentation.Reason

    /// Every reason nothing is tracked, but the build's own.
    static let untrackedButBuilt = ControlSourceDisplayTests.everyReason.filter {
        $0 != .noHelperInThisBuild
    }

    // MARK: - 1. No helper in this build

    /// **Mutation (H):** delete `affordance`'s `.notTracked(.noHelperInThisBuild)` arm. Run: red
    /// at the affordance for every argument; the fan falls to rule 2 and reads disabled.
    /// **Mutation (HS):** delete `init(reading:given:)`'s early return for `.hidden`. Run: red at
    /// the selection and the status, for the driver states that have one.
    @Test(
        "A build with no helper hides the control, in the pane's and the footer's words",
        arguments: Fixtures.DriverTag.allCases)
    func aBuildWithNoHelperHidesTheControl(_ tag: Fixtures.DriverTag) throws {
        let screen = Fixtures.withdrawn(.noHelperInThisBuild, driver: try tag.state())
        let presentation = try Fixtures.present(0, on: screen)

        #expect(
            presentation.affordance
                == .hidden(
                    Reason(
                        summary: ControlSourceDisplay.explanation(.noHelperInThisBuild),
                        advice: HelperStatusDisplay.text(for: .unavailableInThisBuild).detail,
                        wireValue: nil)))
        #expect(
            Fixtures.reason(presentation.affordance)?.summary
                == "No privileged helper in this build.")
        #expect(presentation.selection == .unknown)
        #expect(presentation.status == nil)
    }

    // MARK: - 2. No licensed snapshot

    /// **Mutation (NT):** in `affordance`'s `.notTracked(let why)` arm, return `.enabled`. Run:
    /// red for every argument.
    @Test(
        "No licensed snapshot disables the control, with the pane's sentence for why",
        arguments: untrackedButBuilt)
    func noLicensedSnapshotDisables(_ why: ControlNotTracked) throws {
        let presentation = try Fixtures.present(0, on: Fixtures.withdrawn(why, driver: .idle))

        #expect(
            presentation.affordance
                == .disabled(
                    Reason(
                        summary: ControlSourceDisplay.explanation(why), advice: nil, wireValue: nil)
                ))
    }

    /// Every input that can say "not tracked" must say "tracked". `PollingViewModel` never
    /// publishes these mixtures; a caller that read its inputs in two turns could.
    ///
    /// **Mutation (L1):** add a first arm to `Licence.init` that licenses any reported fan with a
    /// snapshot on screen, `case (_, .reported(let state, _), .some(let snapshot))`, whatever the
    /// machine's source says. Run: red at the machine's expectation. **Mutation (L2):** add a first
    /// arm that licenses a fan its row says is not tracked, from the snapshot's first fan,
    /// `case (.helperSnapshot(let lease), .notTracked, .some(let snapshot))`. Run: red at the
    /// fan's expectation.
    @Test("A claim needs the machine, the fan and the screen to agree that a snapshot is tracked")
    func everySourceMustSayTracked() throws {
        let snapshot = Support.snapshot(fans: [Fixtures.clearedFan(0)])
        let tracked = Fixtures.screen(snapshot, driver: .idle)
        let row = try #require(tracked.rows.first)

        let machineNotTracked = FanControlPresentation.Inputs(
            controlSource: .notTracked(.snapshotStale), thermalEmergency: .inactive,
            renderedSnapshot: snapshot, renderedReadTicket: nil,
            driver: .idle, automaticEvidence: .anyRead)
        #expect(
            FanControlPresentation(reading: row, given: machineNotTracked).affordance
                == .disabled(.notTracked(.snapshotStale)))

        let fanNotTracked = row.untracked(.awaitingSnapshot)
        #expect(
            FanControlPresentation(reading: fanNotTracked, given: tracked.inputs).affordance
                == .disabled(.notTracked(.awaitingSnapshot)))

        let nothingOnScreen = FanControlPresentation.Inputs(
            controlSource: .helperSnapshot(activeLease: nil), thermalEmergency: .inactive,
            renderedSnapshot: nil, renderedReadTicket: nil,
            driver: .idle, automaticEvidence: .anyRead)
        let blank = FanControlPresentation(reading: row, given: nothingOnScreen)
        #expect(blank.affordance == .disabled(.nothingOnScreen))
        #expect(Fixtures.reason(blank.affordance)?.summary == "No helper snapshot is on screen.")

        #expect(FanControlPresentation(reading: row, given: tracked.inputs).affordance == .enabled)
    }

    // MARK: - 3. Thermal emergency

    /// The fan reads `.available`, as the helper reports it during an emergency: § 3's latch is
    /// stated machine-wide, never per fan. So nothing below this rule would disable it.
    ///
    /// **Mutation (E):** delete `affordance`'s emergency `if`. Run: red at the affordance.
    @Test("An emergency disables the control, and says only that no new lease is granted")
    func anEmergencyDisables() throws {
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0)], isThermalEmergencyActive: true)
        let presentation = try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: .idle))

        #expect(presentation.affordance == .disabled(.thermalEmergencyActive))
        let summary = try #require(Fixtures.reason(presentation.affordance)?.summary)
        #expect(
            summary
                == "Thermal emergency reported by the helper — it grants no new manual-control "
                + "lease while this lasts.")
        // Nothing about protecting, driving or holding any fan: § 3 acts only on fans in its own
        // registers, and on a helper that cannot write it has none.
        for word in ["protect", "driv", "maximum", "held by"] {
            #expect(!summary.lowercased().contains(word), "\(word)")
        }
    }

    /// The window between § 3 firing and its revocation of the lease: the snapshot lists the
    /// app's own lease with the flag set. The emergency rule still applies.
    @Test("An emergency disables the control while the app's own lease is still listed")
    func anEmergencyDisablesOverOurOwnLease() throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .confirmed(try Fixtures.target([0: 3000])))
        let snapshot = Support.snapshot(
            fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours, isThermalEmergencyActive: true)
        let presentation = try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: driver))

        #expect(presentation.affordance == .disabled(.thermalEmergencyActive))
        #expect(presentation.selection == .unknown, "controlLoss answers .thermalEmergency")
    }

    /// Every emergency state, beside a snapshot whose flag is set exactly when the state is
    /// `.active`. `.unknown` beside a snapshot is an emergency input that is not that snapshot's,
    /// so the generation check refuses it.
    ///
    /// **Mutation (G3):** delete the emergency `guard` in `Licence.isOneSnapshot`. Run: red for
    /// the `.unknown` argument, which then reads enabled.
    @Test(
        "Only a reported absence of an emergency leaves the control enabled",
        arguments: Fixtures.EmergencyTag.allCases)
    func eachEmergencyStateHasItsAffordance(_ tag: Fixtures.EmergencyTag) throws {
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0)], isThermalEmergencyActive: tag == .active)
        let screen = Fixtures.screen(snapshot, driver: .idle)
        let inputs = FanControlPresentation.Inputs(
            controlSource: screen.inputs.controlSource, thermalEmergency: tag.state,
            renderedSnapshot: snapshot, renderedReadTicket: nil,
            driver: .idle, automaticEvidence: .anyRead)
        let row = try #require(screen.rows.first)

        let expected: FanControlPresentation.Affordance
        switch tag {
        case .active:
            expected = .disabled(.thermalEmergencyActive)
        case .inactive:
            expected = .enabled
        case .unknown:
            expected = .disabled(.betweenSnapshots)
        }
        #expect(FanControlPresentation(reading: row, given: inputs).affordance == expected)
    }

    // MARK: - 4. Another lease

    /// The fan reads `.available`, as the helper reports it beside another client's lease, which
    /// no fan's availability states.
    ///
    /// **Mutation (AH):** delete `affordance`'s held-elsewhere `if`. Run: red for every argument.
    @Test(
        "Another lease listed disables the control, whatever the driver is doing",
        arguments: Fixtures.DriverTag.allCases)
    func anotherLeaseDisables(_ tag: Fixtures.DriverTag) throws {
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0)], activeLease: Fixtures.theirs)
        let screen = Fixtures.screen(snapshot, driver: try tag.state())
        let presentation = try Fixtures.present(0, on: screen)

        #expect(
            presentation.affordance
                == .disabled(
                    Reason(
                        summary: "Manual-control lease held by “fanctl 0.3.0”.",
                        advice: ManualControlAvailability.Reason.leaseHeldByAnotherClient
                            .recoveryAdvice,
                        wireValue: nil)))
    }

    /// Another client chose our holder string. Only the identifier says it is not ours, in every
    /// driver state: `.lost` carries the app's old lease, whose holder string is the same.
    ///
    /// **Mutation (US):** in `isHeldByThisDriver`, compare `holderDescription`s instead of `id`s.
    /// Run: red for the `.held` argument. **Mutation (SVLOSTUS):** make `isHeldByThisDriver` also
    /// accept `.lost(let loss)` when `loss.lease?.holderDescription == lease.holderDescription`.
    /// Run: red for the `.lost` argument.
    @Test(
        "This is us by identifier only: our holder string under another id is another lease",
        arguments: Fixtures.DriverTag.allCases)
    func anImpostorIsNeverUs(_ tag: Fixtures.DriverTag) throws {
        #expect(Fixtures.impostor.holderDescription == Fixtures.ours.holderDescription)
        #expect(Fixtures.impostor.id != Fixtures.ours.id)
        let impostor = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.impostor)
        let presentation = try Fixtures.present(
            0, on: Fixtures.screen(impostor, driver: try tag.state()))

        #expect(presentation.affordance == .disabled(.heldElsewhere(Fixtures.impostor)))
        #expect(presentation.selection == .unknown)
    }

    /// **Mutation (AH2):** make `isHeldByThisDriver` return `false` always. Run: red.
    @Test("The lease the driver holds, by identifier, is ours")
    func ourLeaseByIdentifierIsOurs() throws {
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .confirmed(try Fixtures.target([0: 3000])))
        let ours = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)

        #expect(
            try Fixtures.present(0, on: Fixtures.screen(ours, driver: driver)).affordance
                == .enabled)
    }

    /// **Mutation (SH):** in `Reason.heldElsewhere(_:)`, build the summary as
    /// `"Manual-control lease held by “" + lease.holderDescription + "”."`. Run: red.
    @Test("The holder of another lease is shown through the sanitiser, cap included")
    func theHolderIsSanitised() throws {
        let hostile = Lease(holderDescription: Fixtures.hostileLong, expiresAt: Date())
        let snapshot = Support.snapshot(fans: [Fixtures.clearedFan(0)], activeLease: hostile)
        let presentation = try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: .idle))
        let summary = try #require(Fixtures.reason(presentation.affordance)?.summary)

        #expect(summary == "Manual-control lease held by “\(Fixtures.cleanedLong)”.")
        #expect(!summary.unicodeScalars.contains(where: HelperAuthoredText.isRemoved))
    }

    // MARK: - 5. The helper refuses the fan

    /// **Mutation (UA):** delete `affordance`'s refusal `if`. Run: red for every argument.
    /// **Mutation (UA2):** add `case .reported(let s, _) = reading.control,
    /// s.manualControlAvailability.clearance != .silent` to its condition, so a silent reason,
    /// today's `.writePathNotBuilt` among them, is enabled. Run: red for every silent reason, and
    /// in `todayEveryFanIsDisabled`.
    @Test(
        "A fan the helper refuses is disabled, in its row's words",
        arguments: FanRowModelTests.Tag.allCases)
    func aRefusedFanIsDisabled(_ tag: FanRowModelTests.Tag) throws {
        let reason = tag.reason
        let snapshot = Support.snapshot(fans: [Support.fan(0, availability: .unavailable(reason))])
        let presentation = try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: .idle))

        #expect(
            presentation.affordance
                == .disabled(
                    Reason(
                        summary: reason.userFacingSummary, advice: reason.recoveryAdvice,
                        wireValue: HelperAuthoredText.sanitised(reason.wireValue))))
    }

    @Test("On today's helper, which cannot write, every fan is disabled")
    func todayEveryFanIsDisabled() throws {
        let snapshot = Support.snapshot(fans: [Support.fan(0), Support.fan(1), Support.fan(2)])
        let screen = Fixtures.screen(snapshot, driver: .idle)

        for index in 0...2 {
            let presentation = try Fixtures.present(index, on: screen)
            #expect(
                Fixtures.reason(presentation.affordance)?.wireValue == "writePathNotBuilt",
                "fan \(index)")
            #expect(presentation.affordance != .enabled, "fan \(index)")
        }
    }

    // MARK: - 6. Enabled, and the order

    @Test("Enabled when tracked, with no emergency, no other lease and the fan offered")
    func enabledWhenNothingIsInTheWay() throws {
        let idle = Support.snapshot(fans: [Fixtures.clearedFan(0)])
        #expect(
            try Fixtures.present(0, on: Fixtures.screen(idle, driver: .idle)).affordance == .enabled
        )

        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .confirmed(try Fixtures.target([0: 3000])))
        let held = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        #expect(
            try Fixtures.present(0, on: Fixtures.screen(held, driver: driver)).affordance
                == .enabled)
    }

    /// **Mutation (O1):** move the held-elsewhere `if` above the emergency one. Run: red at the
    /// first expectation. **Mutation (O2):** move the refusal `if` above the held-elsewhere one.
    /// Run: red at the second.
    @Test("The rules apply in order: the emergency, then another lease, then the fan's refusal")
    func theRulesApplyInOrder() throws {
        let refused = Support.fan(0, availability: .unavailable(.writePathNotBuilt))

        let all = Support.snapshot(
            fans: [refused], activeLease: Fixtures.theirs, isThermalEmergencyActive: true)
        #expect(
            try Fixtures.present(0, on: Fixtures.screen(all, driver: .idle)).affordance
                == .disabled(.thermalEmergencyActive))

        let leaseAndRefusal = Support.snapshot(fans: [refused], activeLease: Fixtures.theirs)
        #expect(
            try Fixtures.present(0, on: Fixtures.screen(leaseAndRefusal, driver: .idle)).affordance
                == .disabled(.heldElsewhere(Fixtures.theirs)))
    }
}
