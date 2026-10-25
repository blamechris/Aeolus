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
        #expect(Row(inputs, field: left).courtesy == courtesy)
        #expect(left.focus(true, showing: "3000").courtesy == nil, "kept into the next edit")
        #expect(Row.FieldState.afterStep == Row.FieldState(), "a step leaves something behind")
    }
}
