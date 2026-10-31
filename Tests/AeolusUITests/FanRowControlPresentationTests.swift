import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `FanRowControlPresentation`: what one fan's row draws of per-fan control, and what a click on
/// it may send (#154). Pure, so every rule is pinned here, one input at a time; the suites through
/// the root hold that a click reaches the driver as these say.
@Suite("Per-fan row — what it draws, and what a click may send")
struct FanRowControlPresentationTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Row = FanRowControlPresentation
    typealias Rows = RowFixtures

    static func present(_ inputs: Row.Inputs, draft: String? = nil) -> Row {
        Row(inputs, field: Row.FieldState(draft: draft, courtesy: nil))
    }

    // MARK: - The segment

    /// Idle beside a free snapshot: Auto is selected and has nothing to give back, Custom may be
    /// clicked, and no field is drawn.
    @Test("Idle: Auto selected and disabled, Custom enabled, no field")
    func idle() throws {
        let row = Self.present(try Rows.inputs(Rows.free, beside: .idle))

        #expect(row.drawsControl)
        #expect(row.automatic == Row.Segment(mark: .selected, isEnabled: false))
        #expect(row.custom == Row.Segment(mark: .plain, isEnabled: true))
        #expect(row.field == nil)
    }

    /// **Mutation (P1, "pending as selected"):** in `customMark`, return `.selected` for
    /// `.applying`. Run: red at the applying row.
    @Test("Held: Custom selected once confirmed, pending while the apply is unanswered")
    func held() throws {
        let confirmed = Self.present(
            try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed()))
        #expect(confirmed.custom == Row.Segment(mark: .selected, isEnabled: false))
        #expect(confirmed.automatic == Row.Segment(mark: .plain, isEnabled: true))

        let applying = Self.present(
            try Rows.inputs(
                Rows.holding,
                beside: Rows.held(.applying(try Rows.target([0: Rows.driverRPM]), queued: nil))))
        #expect(applying.custom == Row.Segment(mark: .pending, isEnabled: false))
        #expect(applying.automatic == Row.Segment(mark: .plain, isEnabled: true))
    }

    /// A held lease with no licensed snapshot on screen: Custom is pending, never selected, and
    /// Auto still gives the fan back.
    @Test("Held with nothing on screen to confirm it: Custom pending, Auto enabled")
    func heldUnchecked() throws {
        let screen = Fixtures.withdrawn(
            .snapshotStale, driver: try Rows.heldConfirmed(), from: Rows.holding)
        let row = Self.present(try Rows.inputs(0, on: screen))

        #expect(row.custom == Row.Segment(mark: .pending, isEnabled: false))
        #expect(row.automatic == Row.Segment(mark: .plain, isEnabled: true))
        #expect(row.field?.isEnabled == false, "the field is drawn, and greyed")
    }

    /// While releasing, every fan's Auto is enabled (8a's `canRelease`), and nothing is selected.
    @Test("Releasing: Auto enabled for every fan, nothing selected, no field")
    func releasing() throws {
        let screen = Fixtures.screen(Rows.holding, driver: .releasing)
        for index in [0, 1] {
            let row = Self.present(try Rows.inputs(index, on: screen))
            #expect(row.automatic == Row.Segment(mark: .plain, isEnabled: true), "fan \(index)")
            #expect(row.custom.mark == .plain, "fan \(index)")
            #expect(row.field == nil, "fan \(index)")
        }
    }

    /// Acquiring fan 0: it is in Custom, so Custom is not offered again, and Auto gives it back.
    /// Fan 1, not asked for, may be put in Custom.
    @Test("Acquiring: the fan asked for is in Custom; the other may join it")
    func acquiring() throws {
        let screen = Fixtures.screen(Rows.free, driver: .acquiring(fans: [0]))
        let fan0 = Self.present(try Rows.inputs(0, on: screen))
        let fan1 = Self.present(try Rows.inputs(1, on: screen))

        #expect(fan0.custom.isEnabled == false)
        #expect(fan0.automatic.isEnabled)
        #expect(fan0.field == nil, "an acquisition's speeds are not in the report")
        #expect(fan1.custom.isEnabled)
        #expect(!fan1.automatic.isEnabled)
    }

    /// A fan the helper refuses: the row draws its control greyed, with Custom refused, and says
    /// no reason of its own (the row's refusal line and the control for all fans do).
    @Test("A refused fan: the control is drawn greyed, and Custom cannot be clicked")
    func refused() throws {
        let snapshot = Support.snapshot(
            fans: [Rows.fan(0, availability: .unavailable(.writePathNotBuilt)), Rows.fan(1)])
        let row = Self.present(try Rows.inputs(snapshot, beside: .idle))

        #expect(row.drawsControl)
        #expect(!row.custom.isEnabled)
        #expect(!row.automatic.isEnabled)
        #expect(row.courtesy == nil)
    }

    // MARK: - The Monitor build

    /// No helper in this build: no per-row control at all, whatever is being typed or was said.
    /// The reason is the control for all fans' to state, once.
    ///
    /// **Mutation (M20, "a per-row control in Monitor"):** in `FanRowControlPresentation.init`,
    /// set `drawsControl = true` in every case. Run: red here and in
    /// `FanRowControlRootTests.theMonitorBuildDrawsNoRowControl`.
    @Test("The Monitor build draws no per-row control, and no field")
    @MainActor
    func monitor() throws {
        let screen = Fixtures.withdrawn(.noHelperInThisBuild, driver: .idle, from: Rows.free)
        let inputs = try Rows.inputs(0, on: screen)
        let row = Row(inputs, field: Row.FieldState(draft: "3000", courtesy: "said"))

        #expect(!row.drawsControl)
        #expect(row.field == nil)
        #expect(row.courtesy == nil)
        #expect(FanRowView.segments(for: row).isEmpty)
    }

    /// The one hidden control that is drawn: a release offered beside it. No build produces it,
    /// since a build with no helper has no driver; the rule is the all-fans control's.
    @Test("Hidden beside a lease the driver holds: drawn, to offer the release")
    func hiddenWithARelease() throws {
        let screen = Fixtures.withdrawn(
            .noHelperInThisBuild, driver: try Rows.heldConfirmed(), from: Rows.holding)
        let row = Self.present(try Rows.inputs(0, on: screen))

        #expect(row.drawsControl)
        #expect(row.automatic.isEnabled)
        #expect(!row.custom.isEnabled)
    }

    // MARK: - What the field shows

    /// The driver's target, never the snapshot's held target, which is 3200 here.
    ///
    /// **Mutation (M22, "the snapshot's target"):** in `Inputs.init(reading:presentation:snapshot:
    /// driver:)`, build `driverTarget` from `reported?.targetRPM` through the envelope. Run: red
    /// at every text below.
    @Test("The field shows the driver's target, never the snapshot's targetRPM")
    func theFieldShowsTheDriversTarget() throws {
        let confirmed = Self.present(
            try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed()))
        #expect(confirmed.field?.text == "3000")
        #expect(confirmed.field?.isPending == false)

        let sending = try Rows.target([0: Rows.driverRPM])
        let applying = Self.present(
            try Rows.inputs(Rows.holding, beside: Rows.held(.applying(sending, queued: nil))))
        #expect(applying.field?.text == "3000")
        #expect(applying.field?.isPending == true)

        let queued = try Rows.target([0: 3500])
        let behind = Self.present(
            try Rows.inputs(Rows.holding, beside: Rows.held(.applying(sending, queued: queued))))
        #expect(behind.field?.text == "3500", "the newest target asked for")
        #expect(behind.field?.isPending == true)
    }

    /// While typing, the draft, never marked pending: it is the user's, not the driver's.
    @Test("While typing, the field shows the draft, unmarked")
    func theFieldShowsTheDraft() throws {
        let sending = try Rows.target([0: Rows.driverRPM])
        let inputs = try Rows.inputs(
            Rows.holding, beside: Rows.held(.applying(sending, queued: nil)))

        let row = Self.present(inputs, draft: "41")
        #expect(row.field?.text == "41")
        #expect(row.field?.isPending == false)
    }

    /// A draft keeps the field drawn after the fan has left Custom, so a Return can still be
    /// pressed: it is then `takeFan` (below).
    @Test("A draft keeps the field after the fan left Custom")
    func aDraftKeepsTheField() throws {
        let inputs = try Rows.inputs(Rows.free, beside: .released)

        #expect(Self.present(inputs).field == nil)
        #expect(Self.present(inputs, draft: "3000").field?.text == "3000")
    }

    // MARK: - The Custom segment: the default speed

    /// The default is the snapshot's actual reading, clamped: 2345 RPM. Never the row's maximum,
    /// 5300 here, and never the row's actual reading, 2000 here, which differ from the snapshot's.
    ///
    /// **Mutation (M21a, "the row's maximum"):** in `Inputs.init(reading:...)`, pass
    /// `actualRPM: reading.maximum.value`. Run: red at the speed.
    @Test("Custom takes the fan at the snapshot's actual speed, clamped")
    func customTakesTheActualSpeed() throws {
        let screen = Fixtures.screen(Rows.free, driver: .idle)
        let row = Rows.displaying(screen.rows[0], minimum: 1100, maximum: 5300, actual: 2000)
        let inputs = Rows.inputs(row, on: screen)
        try #require(inputs.presentation.affordance == .enabled)

        #expect(Row.custom(inputs) == .takeFan(0, at: try Rows.speed(2345)))
    }

    /// `F0Ac` reads 1343.07 under a declared `F0Mn` of 1350 on the development machine: Custom
    /// starts at 1350, the slowest speed that may be commanded.
    @Test("An actual reading below the floor starts Custom at the floor")
    func anActualBelowTheFloor() throws {
        let snapshot = Support.snapshot(fans: [
            Rows.fan(0, actual: .measured(1343.07)), Rows.fan(1),
        ])
        let inputs = try Rows.inputs(snapshot, beside: .idle)

        #expect(Row.custom(inputs) == .takeFan(0, at: try Rows.speed(1350)))
    }

    /// No actual reading: nothing is sent, and Custom is not offered.
    ///
    /// **Mutation (M21b, "sent with no reading"):** in `custom(_:)`, use
    /// `inputs.actualRPM ?? envelope.lowestCommandableRPM`. Run: red at both expectations.
    @Test("No actual reading: Custom sends nothing, and is not offered")
    func noActualReading() throws {
        let snapshot = Support.snapshot(
            fans: [Rows.fan(0, actual: .unavailable(reason: "read failed")), Rows.fan(1)])
        let inputs = try Rows.inputs(snapshot, beside: .idle)
        try #require(inputs.presentation.affordance == .enabled)

        #expect(Row.custom(inputs) == nil)
        #expect(!Self.present(inputs).custom.isEnabled)
    }
}
