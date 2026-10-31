import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The field's edit lifecycle (#154's ruling, Q4; #518's review, S2): what focus gained, focus
/// lost, typing, a Return and a stepper click leave in `FieldState`. `FanRowView` only calls
/// these. An extension, so these run in `FanRowControlPresentationTests`.
extension FanRowControlPresentationTests {

    /// **Mutation (G2r, "focus lost keeps the draft"):** in `FieldState.focus(_:showing:)`, return
    /// `self` when focus is lost. Run: red at `draft == nil` and at the reverted text here, and at
    /// the field in the next test.
    @Test("Losing focus reverts the field to the driver's target")
    func losingFocusReverts() throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        let editing = Row.FieldState().focus(true, showing: Row.shownText(inputs)).typed("4200")
        #expect(Row(inputs, field: editing).field?.text == "4200")

        let left = editing.focus(false, showing: "4200")

        #expect(left.draft == nil)
        #expect(Row(inputs, field: left).field?.text == "3000", "the driver's target again")
    }

    /// A draft that outlived Custom, after a loss for instance, goes with the focus, and the field
    /// with it.
    @Test("A draft kept after the fan left Custom goes when focus leaves")
    func aDraftAfterCustomGoesWithTheFocus() throws {
        let inputs = try Rows.inputs(Rows.free, beside: .released)
        let editing = Row.FieldState(draft: "3000")
        #expect(Row(inputs, field: editing).field != nil)

        let left = editing.focus(false, showing: "3000")

        #expect(Row(inputs, field: left).field == nil)
    }

    @Test("Gaining focus starts the draft from what the field shows, and clears the courtesy line")
    func gainingFocus() throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        let said = Row.FieldState(draft: nil, courtesy: "said")

        let editing = said.focus(true, showing: Row.shownText(inputs))

        #expect(editing == Row.FieldState(draft: "3000", courtesy: nil))
        #expect(editing.typed("31") == Row.FieldState(draft: "31", courtesy: nil))
    }

    /// A Return ends the edit by taking focus away, and its courtesy line outlives that. It goes
    /// when the field next gains focus, and with a stepper click.
    @Test(
        "A Return's courtesy line outlives the focus it takes, and goes at the next focus or step")
    func theCourtesyLine() throws {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        let typed = Row.FieldState().focus(true, showing: Row.shownText(inputs)).typed("99999")

        let (request, returned) = Row.submit(try #require(typed.draft), inputs)
        let left = returned.focus(false, showing: Row.shownText(inputs))

        #expect(request == .adjustFan(0, to: try Rows.speed(5777)))
        #expect(left.draft == nil)
        let courtesy = try #require(left.courtesy, "the line went with the focus")
        #expect(courtesy.hasSuffix("clamped to 5777 RPM."))
        #expect(left.clampedTo == (try Rows.speed(5777)))
        let sent = try Rows.inputs(Rows.holding, beside: try Self.heldAt(5777, applying: true))
        #expect(Row(sent, field: left).courtesy == courtesy)
        #expect(left.focus(true, showing: "3000").courtesy == nil, "kept into the next edit")
        #expect(left.focus(true, showing: "3000").clampedTo == nil)
        #expect(Row.FieldState.afterStep == Row.FieldState(), "a step leaves something behind")
    }

    // MARK: - What Return submits (#518's delta review, S-a)

    /// The view reads the live state at the keystroke, and passes the driver's target as `shown`.
    /// A text the view drew before the last keystroke is not what the field holds.
    ///
    /// **Mutation (H1m, "the drawn text"):** in `FieldState.text(showing:)`, return `shown`. Run:
    /// red at both draft expectations.
    @Test("What Return submits is the live draft, else the driver's target")
    func whatReturnSubmits() throws {
        let typing = Row.FieldState(draft: "4200")

        #expect(typing.text(showing: "3000") == "4200", "the draft was dropped for the target")
        #expect(Row.FieldState().text(showing: "3000") == "3000")
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        #expect(
            Row.submit(typing.text(showing: Row.shownText(inputs)), inputs).request
                == .adjustFan(0, to: try Rows.speed(4200)))
    }

    // MARK: - The courtesy line only beside the speed it clamped to (#518's delta review, S-b)

    /// Fan 0 held at `rpm`, its `apply` unanswered or confirmed.
    static func heldAt(_ rpm: Double, applying: Bool) throws -> LeaseDriverState {
        let target = try Rows.target([0: rpm])
        return Rows.held(applying ? .applying(target, queued: nil) : .confirmed(target))
    }

    /// Return with 99999 while held at 3000, then focus leaves, as the view does after a Return.
    static func afterAClampedReturn() throws -> Row.FieldState {
        let inputs = try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed())
        let (_, returned) = Row.submit("99999", inputs)
        let left = returned.focus(false, showing: Row.shownText(inputs))
        try #require(left.courtesy != nil)
        return left
    }

    /// The review's probe: the lease is released after the Return. The fan reads Auto, no field is
    /// drawn, and no speed is named beneath it (`CLAUDE.md` rule 6).
    ///
    /// **Mutation (H2a, "until the next focus"):** in `FanRowControlPresentation.courtesy(_:_:
    /// drawn:)`, return `drawn ? state.courtesy : nil`, round 1's rule. Run: red at `courtesy`.
    @Test("No courtesy line under Auto once the lease is released")
    func noCourtesyLineAfterARelease() throws {
        let field = try Self.afterAClampedReturn()

        let released = Row(try Rows.inputs(Rows.free, beside: .released), field: field)

        #expect(released.automatic.mark == .selected)
        #expect(released.field == nil)
        #expect(released.courtesy == nil, "a clamped speed named under Auto")
    }

    /// The converse: while the driver asks for the speed the Return clamped to, sent or confirmed,
    /// the line stays beside the field showing it.
    @Test("The courtesy line stays while the driver asks for the speed it clamped to")
    func theCourtesyLineStaysWhileHeldAtIt() throws {
        let field = try Self.afterAClampedReturn()

        for applying in [true, false] {
            let row = Row(
                try Rows.inputs(Rows.holding, beside: try Self.heldAt(5777, applying: applying)),
                field: field)
            #expect(row.field?.text == "5777")
            #expect(row.courtesy == field.courtesy, "applying: \(applying)")
        }
    }

    /// Still in Custom, but the field does not show the clamped speed: another control moved the
    /// target (75 % for all fans), the fan is being acquired and the report has no speed, or the
    /// fan was put back in Custom after a release, at its actual speed. No line in any of them.
    ///
    /// **Mutation (H2b, "while in Custom"):** in `courtesy(_:_:drawn:)`, return the line when
    /// `drawn && (inputs.isInCustom || state.draft != nil)`, the delta brief's rule. Run: red at
    /// each of the three.
    @Test("No courtesy line beside another speed, or while the report names no speed")
    func noCourtesyLineBesideAnotherSpeed() throws {
        let field = try Self.afterAClampedReturn()
        let screens: [(String, LeaseDriverState)] = [
            ("another speed", try Self.heldAt(4670, applying: false)),
            ("acquiring", .acquiring(fans: [0])),
            ("Custom again, at the actual speed", try Self.heldAt(2345, applying: true)),
        ]
        for (name, state) in screens {
            let row = Row(
                try Rows.inputs(Rows.snapshot(beside: state), beside: state), field: field)
            #expect(row.courtesy == nil, "\(name)")
        }
    }
}
