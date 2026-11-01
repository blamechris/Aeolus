import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// #670: while the helper grants a lease only over every fan, the main window draws no fan's own
/// control. A per-fan Custom would ask for one fan and be refused `leaseMustCoverEveryFan`, and a
/// per-fan Auto would release the lease every fan is held under, so the control for all fans is
/// the window's only control. The presentation itself is unchanged, for the day the rule lifts.
@Suite("No fan's own control while the helper takes every fan or none (#670)")
@MainActor
struct FanRowControlOfferedTests {

    typealias Rows = RowFixtures

    /// A row the presentation would draw a control for, free fans beside an idle driver, draws
    /// none, so the change-of-fan-set sentence is not said either.
    ///
    /// **Mutation:** set `FanRowControlPresentation.isOffered` to `true`. Run: red here, the row
    /// drawing its Auto and Custom segments.
    @Test("A row whose presentation would draw a control draws none")
    func aRowDrawsNoControl() throws {
        let inputs = try Rows.inputs(Rows.free, beside: .idle)
        #expect(
            FanRowControlPresentation(inputs, field: .init()).drawsControl,
            "the presentation draws no control here anyway, so nothing is tested")

        #expect(!FanListView.drawsControl(inputs), "the window draws fan 0's own control")
    }
}
