import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// What a Return or a stepper click in a row's field may send: the clamp, what refuses a speed, and
/// which verb each is (#154's ruling, Q4). An extension, so these run in
/// `FanRowControlPresentationTests`.
extension FanRowControlPresentationTests {

    // MARK: - The clamp

    /// The row displays 1100 to 5300 RPM; the snapshot carries 1350 to 5777. 5500 is inside the
    /// snapshot's range and is sent as typed; 1200 is below it and is clamped to 1350, with the
    /// courtesy line naming the snapshot's range.
    ///
    /// **Mutation (M18, "the row's bounds"):** in `Inputs.init(reading:...)`, build the envelope
    /// with `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)` of the row's
    /// `minimum.value` and `maximum.value`. Run: red at both requests and the courtesy line.
    @Test("Return clamps to the snapshot's envelope, never to the row's bounds")
    func theClampIsTheSnapshots() throws {
        let screen = Fixtures.screen(Rows.holding, driver: try Rows.heldConfirmed())
        let row = Rows.displaying(screen.rows[0], minimum: 1100, maximum: 5300)
        let inputs = Rows.inputs(row, on: screen)
        try #require(inputs.presentation.affordance == .enabled)

        let inRange = Row.submit("5500", inputs)
        #expect(inRange.request == .adjustFan(0, to: try Rows.speed(5500)))
        #expect(inRange.field == Row.FieldState(draft: nil, courtesy: nil))

        let below = Row.submit("1200", inputs)
        #expect(below.request == .adjustFan(0, to: try Rows.speed(1350)))
        #expect(
            below.field.courtesy
                == "1200 RPM is outside this fan's commandable range, 1350 RPM to 5777 RPM: "
                + "clamped to 1350 RPM.")
    }

    /// 0, 99999 and -5 are each clamped, and said to be; 0 RPM is never sent. On a fan whose
    /// firmware declares a minimum of 0, the floor is `FanSafetyLimits.minimumManualRPM`.
    @Test(
        "Out of range is clamped, with a courtesy line, and 0 RPM is never sent",
        arguments: [("0", 1350.0), ("99999", 5777), ("-5", 1350), ("0.4", 1350)])
    func outOfRange(_ typed: String, _ expected: Double) throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())

        let (request, field) = Row.submit(typed, inputs)

        #expect(request == .adjustFan(0, to: try Rows.speed(expected)))
        #expect(field.draft == nil)
        let courtesy = try #require(field.courtesy, "no courtesy line for \(typed)")
        #expect(courtesy.hasSuffix("clamped to \(Int(expected)) RPM."))
    }

    @Test("A firmware minimum of 0 is never commanded: the floor is 100 RPM")
    func aZeroMinimum() throws {
        let snapshot = Support.snapshot(
            fans: [Rows.fan(0, minimum: 0, mode: .manualFixed, target: Rows.snapshotRPM)],
            activeLease: Fixtures.ours)
        let inputs = try Rows.inputs(snapshot, beside: try Rows.heldConfirmed())

        let (request, field) = Row.submit("0", inputs)

        guard case .adjustFan(0, let speed) = request else {
            Issue.record("sent \(String(describing: request))")
            return
        }
        #expect(speed.rpm == FanSafetyLimits.minimumManualRPM)
        #expect(
            field.courtesy
                == "0 RPM is outside this fan's commandable range, 100 RPM to 5777 RPM: "
                + "clamped to 100 RPM.")
    }

    /// Text that is not a finite number reverts: nothing is sent and nothing is said.
    @Test(
        "Text that is not a number reverts and sends nothing",
        arguments: ["abc", "", " ", "1,500", "nan", "inf", "-inf", "3000rpm"])
    func notANumber(_ typed: String) throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())

        let (request, field) = Row.submit(typed, inputs)

        #expect(request == nil)
        #expect(field == Row.FieldState(draft: nil, courtesy: nil))
    }

    @Test("A number in range is rounded to a whole RPM and sent with no courtesy line")
    func inRange() throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())

        let (request, field) = Row.submit(" 3500.6 ", inputs)

        #expect(request == .adjustFan(0, to: try Rows.speed(3501)))
        #expect(field.courtesy == nil)
    }

    // MARK: - No snapshot, or no envelope: nothing is sent

    /// The snapshot is withdrawn while the rows still display what it read. The inputs carry no
    /// envelope and no actual reading: the rows' leftovers are not one.
    ///
    /// **Mutation (M19, "an old envelope"):** in `Inputs.init(reading:...)`, when `snapshot` is
    /// `nil`, build the envelope from the row's `minimum` and `maximum`. Run: red at `envelope`,
    /// and at every request below.
    @Test("With no snapshot, no envelope, and nothing is sent even where the control is enabled")
    func noSnapshotSendsNothing() throws {
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: try Rows.heldConfirmed(), from: Rows.holding)
        let withdrawn = try Rows.inputs(0, on: screen)
        #expect(withdrawn.envelope == nil)
        #expect(withdrawn.actualRPM == nil)

        // Enabled, as a licensed screen would be, so only the missing envelope refuses.
        let licensed = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        let inputs = Row.Inputs(
            index: 0, presentation: licensed.presentation, envelope: withdrawn.envelope,
            actualRPM: licensed.actualRPM, driverTarget: licensed.driverTarget,
            isInCustom: licensed.isInCustom)
        #expect(Row.custom(inputs) == nil)
        #expect(Row.submit("3000", inputs).request == nil)
        for direction in Row.StepDirection.allCases {
            #expect(Row.step(direction, from: .init(), inputs) == nil)
            #expect(Row.step(direction, from: .init(draft: "3000"), inputs) == nil)
        }
    }

    /// The helper offers a fan whose bounds cannot be trusted: the control is enabled, and the
    /// envelope's failure alone refuses every speed.
    @Test("An envelope failure sends nothing")
    func anEnvelopeFailure() throws {
        let snapshot = Support.snapshot(
            fans: [Rows.fan(0, minimum: 6000, maximum: 5000, mode: .manualFixed, target: 3200)],
            activeLease: Fixtures.ours)
        let inputs = try Rows.inputs(snapshot, beside: try Rows.heldConfirmed())
        try #require(inputs.presentation.affordance == .enabled)

        #expect(inputs.envelope == nil)
        #expect(Row.submit("3000", inputs).request == nil)
        #expect(Row.step(.up, from: .init(), inputs) == nil)
        let row = Self.present(inputs)
        #expect(row.field?.canStepUp == false)
        #expect(row.field?.canStepDown == false)
    }

    /// A snapshot that reports the fan twice leaves its bounds ambiguous.
    @Test("A fan reported twice has no envelope")
    func aFanReportedTwice() throws {
        let snapshot = Support.snapshot(fans: [Rows.fan(0), Rows.fan(0, maximum: 4000)])
        let row = try #require(SnapshotReadings.fans(in: snapshot).first)
        let inputs = Row.Inputs(
            reading: row, presentation: try Rows.inputs(Rows.free, beside: .idle).presentation,
            snapshot: snapshot, driver: .idle)

        #expect(inputs.envelope == nil)
        #expect(inputs.actualRPM == nil)
    }

    // MARK: - Return and the stepper: which verb

    /// Return is `adjustFan` while the fan's `canRelease` is true, and `takeFan` otherwise, in
    /// every driver state. While releasing that is every fan, fan 1 included.
    ///
    /// **Mutation (M16a, "Return takes"):** in `submit`, always return `.takeFan`. Run: red at
    /// every state with `canRelease`.
    @Test("Return adjusts while the fan can be released, and takes otherwise")
    func returnRouting() throws {
        for state in try Rows.everyState() {
            for index in [0, 1] {
                let screen = Fixtures.screen(Rows.free, driver: state)
                let inputs = try Rows.inputs(index, on: screen)
                guard inputs.presentation.affordance == .enabled else { continue }
                let speed = try Rows.speed(4000)

                let request = Row.submit("4000", inputs).request

                let expected: Row.Request =
                    inputs.presentation.canRelease
                    ? .adjustFan(index, to: speed) : .takeFan(index, at: speed)
                #expect(request == expected, "fan \(index), \(state)")
            }
        }
    }

    /// The rule's two sides, named: held over fan 0 adjusts it; released, a typed speed is a
    /// deliberate request for control.
    @Test("Return while held adjusts; after the lease is released, it takes")
    func returnRoutingNamed() throws {
        let held = try Rows.inputs(Rows.free, beside: try Rows.heldConfirmed())
        #expect(Row.submit("4000", held).request == .adjustFan(0, to: try Rows.speed(4000)))

        let released = try Rows.inputs(Rows.free, beside: .released)
        #expect(Row.submit("4000", released).request == .takeFan(0, at: try Rows.speed(4000)))

        let releasing = try Rows.inputs(1, on: Fixtures.screen(Rows.free, driver: .releasing))
        #expect(Row.submit("4000", releasing).request == .adjustFan(1, to: try Rows.speed(4000)))
    }

    /// The stepper never takes, in any state, from a draft or from the driver's target.
    ///
    /// **Mutation (M16b, "the stepper takes"):** in `step`, return `.takeFan`. Run: red here.
    @Test("The stepper is always adjustFan")
    func theStepperAdjusts() throws {
        for state in try Rows.everyState() {
            for index in [0, 1] {
                let inputs = try Rows.inputs(
                    index, on: Fixtures.screen(Rows.snapshot(beside: state), driver: state))
                for direction in Row.StepDirection.allCases {
                    for field in [Row.FieldState(), Row.FieldState(draft: "4000")] {
                        let request = Row.step(direction, from: field, inputs)
                        if case .takeFan = request {
                            Issue.record("the stepper took: fan \(index), \(state)")
                        }
                    }
                }
            }
        }
    }

    @Test("The stepper moves the shown speed by 100 RPM, clamped, and stops at each bound")
    func stepping() throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())

        #expect(Row.step(.up, from: .init(), inputs) == .adjustFan(0, to: try Rows.speed(3100)))
        #expect(Row.step(.down, from: .init(), inputs) == .adjustFan(0, to: try Rows.speed(2900)))
        #expect(
            Row.step(.up, from: .init(draft: "4000"), inputs)
                == .adjustFan(0, to: try Rows.speed(4100)), "from the draft")
        #expect(
            Row.step(.up, from: .init(draft: "abc"), inputs)
                == .adjustFan(0, to: try Rows.speed(3100)), "a draft that is no number")
        #expect(
            Row.step(.up, from: .init(draft: "5700"), inputs)
                == .adjustFan(0, to: try Rows.speed(5777)), "clamped to the top")
        #expect(Row.step(.up, from: .init(draft: "5777"), inputs) == nil, "already at the top")
        #expect(Row.step(.down, from: .init(draft: "1350"), inputs) == nil, "at the floor")
        #expect(Row.step(.down, from: .init(draft: "0"), inputs) == nil, "0 is the floor")

        let atTop = Row(inputs, field: .init(draft: "5777"))
        #expect(atTop.field?.canStepUp == false)
        #expect(atTop.field?.canStepDown == true)
    }

    @Test("The stepper has nothing to step from with no target and no draft")
    func nothingToStepFrom() throws {
        let inputs = try Rows.inputs(Rows.free, beside: .released)

        #expect(Row.step(.up, from: .init(), inputs) == nil)
        #expect(
            Row.step(.up, from: .init(draft: "3000"), inputs)
                == .adjustFan(0, to: try Rows.speed(3100)))
    }
}
