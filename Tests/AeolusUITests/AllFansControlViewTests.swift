import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SwiftUI
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// What the control draws and what a click on it asks for: `AllFansControlView`'s segments and
/// dispatch, and `FanListView.body`, evaluated as SwiftUI would, wired to the root it was given
/// (#497's review, S1).
///
/// What no test here evaluates is `AllFansControlView.body` itself. That leaves its
/// `ForEach(segments)`, both `Button` closures in `button(_:)` that call `perform(_:)`, and the
/// `.disabled(!segment.isEnabled)` beneath them, unpinned: reaching them needs a hosted window.
/// The tests below hold what each of them reads, `segments(for:)` and `perform(_:)`, and
/// `FanListView.body`, which builds the view.
@Suite("All fans — what the view draws, and what a click asks for", .timeLimit(.minutes(1)))
@MainActor
struct AllFansControlViewTests {

    typealias Fans = AllFansFixtures
    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias ControlView = AllFansControlView
    typealias Segment = AllFansControlView.Segment

    /// The control for `snapshot` on screen beside `driver`, and what the view draws for it.
    static func segments(
        _ snapshot: SystemSnapshot?, driver: LeaseDriverState,
        withdrawn why: ControlNotTracked? = nil
    ) -> [Segment] {
        ControlView.segments(for: control(snapshot, driver: driver, withdrawn: why))
    }

    static func control(
        _ snapshot: SystemSnapshot?, driver: LeaseDriverState, withdrawn why: ControlNotTracked?
    ) -> AllFansControlPresentation {
        let shown = snapshot ?? Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        guard let why else {
            return AllFansControlPresentation(
                fans: AllFansControlPresentationTests.fans(Fixtures.screen(shown, driver: driver)),
                snapshot: shown)
        }
        let withdrawn = Fixtures.withdrawn(why, driver: driver, from: shown)
        return AllFansControlPresentation(
            fans: AllFansControlPresentationTests.fans(withdrawn), snapshot: nil)
    }

    static func segment(
        _ action: ControlView.SegmentAction, _ mark: ControlView.Mark, enabled: Bool
    ) -> Segment {
        Segment(action: action, mark: mark, isEnabled: enabled)
    }

    // MARK: - Segments

    /// **Mutations (O8e, O8f):** draw every percentage enabled; enable Auto with the
    /// percentages' rule. **Mutation (O8g):** mark every percentage selected under `.percent`.
    /// Run, each: red here.
    @Test("Held at 75 %: 75 % is selected, everything is enabled")
    func heldAtAPercentage() throws {
        let target = try Fans.target(.seventyFive, fans: [0, 1])
        let segments = Self.segments(
            try Fans.holding(Fixtures.ours, [0, 1], at: .seventyFive),
            driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)))

        #expect(
            segments == [
                Self.segment(.automatic, .plain, enabled: true),
                Self.segment(.percent(.fifty), .plain, enabled: true),
                Self.segment(.percent(.seventyFive), .selected, enabled: true),
                Self.segment(.percent(.hundred), .plain, enabled: true),
            ])
    }

    /// **Mutation (O8m, "pending as selected"):** mark `.pending` as `.selected`. Run: red here.
    @Test("75 % in flight is pending, and nothing is selected")
    func aPercentageInFlight() throws {
        let target = try Fans.target(.seventyFive, fans: [0, 1])
        let segments = Self.segments(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)], activeLease: Fixtures.ours),
            driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .applying(target, queued: nil)))

        #expect(segments.map(\.mark) == [.plain, .plain, .pending, .plain])
        #expect(segments.allSatisfy { $0.isEnabled })
    }

    @Test("Every fan cleared and nothing held: Auto is selected")
    func autoSelected() {
        let segments = Self.segments(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]), driver: .idle)

        #expect(segments.map(\.mark) == [.selected, .plain, .plain, .plain])
        #expect(segments.map(\.title) == ["Auto", "50 %", "75 %", "100 %"])
    }

    /// The release is offered while the control is disabled: only Auto may be clicked.
    @Test("A release offered while disabled: Auto alone is enabled")
    func onlyAutoWhileDisabledAndHeld() throws {
        let target = try Fans.target(.fifty, fans: [0, 1])
        let segments = Self.segments(
            nil, driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)),
            withdrawn: .snapshotStale)

        #expect(segments.map(\.isEnabled) == [true, false, false, false])
        #expect(segments.map(\.mark) == [.plain, .plain, .plain, .plain])
    }

    @Test("Disabled with nothing to release: nothing is enabled")
    func nothingEnabledWhenDisabled() {
        let segments = Self.segments(
            Support.snapshot(fans: [Support.fan(0), Support.fan(1)]), driver: .idle)

        #expect(segments.count == 4)
        #expect(segments.allSatisfy { !$0.isEnabled })
    }

    /// **Mutation (O8h, "drawn while hidden"):** in `segments(for:)`, delete the `drawsControl`
    /// guard. Run: red at the hidden control's empty list.
    @Test("Hidden draws no segment, unless a release is offered")
    func hiddenDrawsNothing() throws {
        #expect(Self.segments(nil, driver: .idle, withdrawn: .noHelperInThisBuild).isEmpty)

        let target = try Fans.target(.fifty, fans: [0, 1])
        let releasing = Self.segments(
            nil, driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)),
            withdrawn: .noHelperInThisBuild)
        #expect(releasing.map(\.isEnabled) == [true, false, false, false])
    }

    /// **Mutation (S2b, "the label never pending"):** make `labelMark` answer `.plain` for
    /// `.checking`. Run: red here.
    @Test("An unconfirmed lease marks the label pending and no segment")
    func checkingMarksTheLabel() throws {
        let target = try Fans.target(.fifty, fans: [0, 1])
        let control = Self.control(
            try Fans.holding(Fixtures.ours, [0, 1], at: .fifty),
            driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)),
            withdrawn: .snapshotStale)

        #expect(control.selection == .checking)
        #expect(ControlView.labelMark(for: control.selection) == .pending)
        #expect(ControlView.segments(for: control).map(\.mark) == [.plain, .plain, .plain, .plain])
        for selection in [AllFansControlPresentation.Selection.automatic, .none] {
            #expect(ControlView.labelMark(for: selection) == .plain)
        }
        for percent in FanSpeedPercent.allCases {
            #expect(ControlView.labelMark(for: .percent(percent)) == .plain)
            #expect(ControlView.labelMark(for: .pending(percent)) == .plain)
        }
    }

    // MARK: - What a click asks for

    /// **Mutation (O8i, "a click asks for 50 %"):** in `perform(_:)`, call `choose(.fifty)` for
    /// every percentage. Run: red at the 75 % and 100 % entries.
    @Test("Each segment's action reaches its own closure with its own percentage")
    func performDispatches() {
        let asked = ResultBox<[String]>()
        asked.set([])
        let view = ControlView(
            control: AllFansControlPresentation(fans: [], snapshot: nil),
            choose: { percent in asked.set((asked.value ?? []) + ["\(percent.rawValue)"]) },
            chooseAutomatic: { asked.set((asked.value ?? []) + ["auto"]) })

        for percent in FanSpeedPercent.allCases { view.perform(.percent(percent)) }
        view.perform(.automatic)

        #expect(asked.value == ["50", "75", "100", "auto"])
    }

    // MARK: - FanListView's body, as SwiftUI evaluates it

    /// The `AllFansControlView` `body` builds, found by walking the value it returns.
    static func control(in view: FanListView) -> AllFansControlView? {
        find(view.body, depth: 0)
    }

    private static func find(_ value: Any, depth: Int) -> AllFansControlView? {
        if let control = value as? AllFansControlView { return control }
        guard depth < 24 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let control = find(child.value, depth: depth + 1) { return control }
        }
        return nil
    }

    /// The body draws the window's control against the root's state, and its 75 % segment's action
    /// takes 75 % of each fan's own range through the root.
    ///
    /// **Mutations (O8c, O8d):** make `FanListView`'s `choose` closure do nothing, or always ask
    /// for 100 %. Run: red at the apply.
    @Test("FanListView's body draws the root's control, and its percentage reaches the root")
    func theBodysPercentageReachesTheRoot() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let view = FanListView(viewModel: window.polling, composition: scene.root)
        let control = try #require(Self.control(in: view), "the body draws the control")
        #expect(control.control == window.control(scene.root.leaseState.current))

        let seventyFive = try #require(
            ControlView.segments(for: control.control).first { $0.action == .percent(.seventyFive) }
        )
        control.perform(seventyFive.action)

        try #require(await Support.eventually { await !scene.lease.entries.applies.isEmpty })
        #expect(
            await scene.lease.entries.applies == [try Fans.settings(.seventyFive, fans: [0, 1])])
        await window.close()
        await scene.finish()
    }

    /// Held at 50 %: the body draws 50 % selected and Auto enabled, from the root's state, and its
    /// Auto action releases through the root.
    ///
    /// **Mutation (O8a, "the body draws against idle"):** in `FanListView.body`, pass `.idle` for
    /// the driver. Run: red at the selection. **Mutation (O8b):** make `FanListView`'s
    /// `chooseAutomatic` closure do nothing. Run: red at the release.
    @Test("FanListView's body draws a held lease from the root, and its Auto releases")
    func theBodysAutoReleases() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let view = FanListView(viewModel: window.polling, composition: scene.root)
        AllFansControlActions(composition: scene.root).choose(.fifty, on: window.polling)
        let held = try await AllFansControlRootTests.confirmed(.fifty, fans: [0, 1], on: scene)
        try await window.show(Fans.holding(held.lease, [0, 1], at: .fifty))
        try await AllFansControlRootTests.published(on: scene) { $0 == .held(held) }

        let control = try #require(Self.control(in: view))
        #expect(control.control.selection == .percent(.fifty))
        #expect(control.control.automaticIsEnabled)
        control.perform(.automatic)

        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] },
            "the body's Auto released the lease")
        await window.close()
        await scene.finish()
    }
}
