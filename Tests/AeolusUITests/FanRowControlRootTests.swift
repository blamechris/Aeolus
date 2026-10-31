import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// Each fan's row through the root: what a click sends, which driver verb it reaches, and how the
/// root records it (#154, #153's PR 8b).
///
/// Every scene is `CompositionScene`, so the root, its driver and the fake control helper are the
/// ones `AllFansControlRootTests` drives. The window is a `ControlWindow` whose snapshot lists no
/// lease and offers both fans, so every fan's control is enabled and what a click sends is decided
/// by the driver's state alone. No test awaits a driver call or a task's value: each waits on the
/// fake's ledger, boundedly, or for the root's published state.
@Suite("Per-fan row — through the root", .timeLimit(.minutes(1)))
@MainActor
struct FanRowControlRootTests {

    typealias Support = SnapshotTestSupport
    typealias Rows = RowFixtures
    typealias Root = AllFansControlRootTests

    /// A window showing both fans offered, with no lease listed.
    static func window() async throws -> ControlWindow {
        try await ControlWindow.showing(Rows.free)
    }

    /// What `apply` sends for fan `index` at `rpm`.
    static func setting(_ index: Int, _ rpm: Double) -> FanSetting {
        FanSetting(fanIndex: index, control: .fixed(rpm: rpm))
    }

    /// Takes `speeds` on the driver directly, and waits for the root to publish the lease held.
    static func held(
        _ speeds: [Int: Double], on scene: CompositionScene
    ) async throws -> HeldLease {
        let held = try #require(await scene.lease.take(try LeaseScene.target(speeds)))
        try await Root.published(on: scene) { $0 == .held(held) }
        return held
    }

    // MARK: - Custom, Return and the stepper

    /// From `idle`, Custom acquires the fan alone and applies the snapshot's actual speed.
    ///
    /// **Mutation (R1, "Custom adjusts"):** in `FanRowControlActions.send`, call `adjustFan` for
    /// `.takeFan`. Run: red at the wait for the apply, here and in `afterALoss`'s Return.
    @Test("Custom from idle takes the fan alone, at its actual speed")
    func customTakesTheFan() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)

        try await scene.click { actions.chooseCustom(fan: 0, on: window.polling) }

        try #require(await Support.eventually { await !scene.lease.entries.applies.isEmpty })
        #expect(await scene.lease.entries.acquires.map(\.fanIndices) == [[0]])
        #expect(await scene.lease.entries.applies == [[Self.setting(0, 2345)]])
        await window.close()
        await scene.finish()
    }

    /// Return while the fan is held moves its speed under the same lease, and the stepper does too.
    @Test("Return and the stepper move a held fan's speed under the same lease")
    func returnAndStepperAdjust() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)
        _ = try await Self.held([0: 3000], on: scene)

        var field = FanRowControlPresentation.FieldState()
        try await scene.click {
            field = actions.submit("99999", fan: 0, on: window.polling)
        }
        #expect(field.draft == nil)
        #expect(field.courtesy?.hasSuffix("clamped to 5777 RPM.") == true)
        try #require(await Support.eventually { await scene.lease.entries.applies.count == 2 })
        try await Root.published(on: scene) { $0.target(forFan: 0)?.speed.rpm == 5777 }

        try await scene.click { actions.step(.down, from: .init(), fan: 0, on: window.polling) }

        try #require(await Support.eventually { await scene.lease.entries.applies.count == 3 })
        let entries = await scene.lease.entries
        #expect(entries.acquires.count == 1, "one lease")
        #expect(
            entries.applies == [
                [Self.setting(0, 3000)], [Self.setting(0, 5777)], [Self.setting(0, 5677)],
            ])
        await window.close()
        await scene.finish()
    }

    /// Fan 1 goes back to Auto while both are held, so the driver releases and wants fan 0 alone.
    /// A Return in fan 1's field then, while releasing, is `adjustFan`, which never adds a fan:
    /// once the release answers, the grant asked for is fan 0's alone.
    ///
    /// **Mutation (M16a, "Return takes"):** in `FanRowControlPresentation.submit`, always return
    /// `.takeFan`. Run: red at the second acquire's fans, which names both.
    @Test("Return while releasing never puts a fan back in Custom")
    func returnWhileReleasingAddsNoFan() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)
        let held = try await Self.held([0: 3000, 1: 3200], on: scene)
        await scene.lease.helper.script(.release, .parked)

        try await scene.click { actions.chooseAutomatic(fan: 1) }
        try await Root.published(on: scene) { $0 == .releasing }
        try await scene.click { _ = actions.submit("4000", fan: 1, on: window.polling) }
        #expect(await scene.lease.entries.releases == [held.lease.id])

        await scene.lease.helper.answerParked(.release)
        try #require(await Support.eventually { await scene.lease.entries.applies.count == 2 })
        let entries = await scene.lease.entries
        #expect(entries.acquires.map(\.fanIndices) == [[0, 1], [0]])
        #expect(entries.applies.last == [Self.setting(0, 3000)])
        await window.close()
        await scene.finish()
    }

    /// After a loss, the stepper asks for nothing: `adjustFan` never acquires, so a loss stays
    /// final under it. A Return, a deliberate request for control, takes the fan again.
    ///
    /// **Mutation (M16b, "the stepper takes"):** in `FanRowControlPresentation.step`, return
    /// `.takeFan`. Run: red at `!acquired`.
    @Test("After a loss the stepper acquires nothing, and Return takes the fan again")
    func afterALoss() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)
        _ = try await Self.held([0: 3000], on: scene)
        await scene.lease.helper.pushHealth(.unresponsive)
        try await Root.published(on: scene) { $0.isLost }

        let draft = FanRowControlPresentation.FieldState(draft: "3000")
        try await scene.click { actions.step(.up, from: draft, fan: 0, on: window.polling) }
        let acquired = await Support.eventually(turns: 2_000) {
            await scene.lease.entries.acquires.count > 1
        }
        #expect(!acquired, "the stepper asked for the fans again after a loss")
        #expect(await scene.lease.driver.state.isLost)

        try await scene.click { _ = actions.submit("3500", fan: 0, on: window.polling) }
        try #require(await Support.eventually { await scene.lease.entries.acquires.count == 2 })
        #expect(await scene.lease.entries.acquires.last?.fanIndices == [0])
        await window.close()
        await scene.finish()
    }

    /// Drawn enabled, then the helper refuses the fan before the click: Custom reads the screen
    /// again and sends nothing.
    ///
    /// **Mutation (R2, "the click trusts the drawing"):** in `FanRowControlPresentation.custom`,
    /// delete the affordance check. Run: red at `latestDriverCall == nil`.
    @Test("A fan refused between drawing and the click sends nothing")
    func aFanRefusedBeforeTheClickSendsNothing() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let drawn = try #require(
            FanRowControlPresentation.Inputs.onScreen(
                fan: 0, in: window.polling, driver: scene.root.leaseState.current))
        #expect(FanRowControlPresentation(drawn, field: .init()).custom.isEnabled)

        try await window.show(
            Support.snapshot(
                fans: [Rows.fan(0, availability: .unavailable(.foreignManualControl)), Rows.fan(1)])
        )
        let actions = FanRowControlActions(composition: scene.root)
        actions.chooseCustom(fan: 0, on: window.polling)
        _ = actions.submit("3000", fan: 0, on: window.polling)

        #expect(scene.root.latestDriverCall == nil, "the click started no call on the driver")
        let sent = await Support.eventually(turns: 2_000) {
            await !scene.lease.entries.acquires.isEmpty
        }
        #expect(!sent)
        await window.close()
        await scene.finish()
    }

    // MARK: - The Monitor build

    /// No helper in this build: no row draws a control, and no per-fan entry point reaches
    /// anything.
    ///
    /// **Mutation (M20):** red at `drawsControl` (see `FanRowControlPresentationTests.monitor`).
    @Test("The Monitor build draws no row control, and no per-fan entry point sends anything")
    func theMonitorBuildDrawsNoRowControl() async throws {
        var connected = 0
        let ledger = LeaseLedger()
        let control = FakeLeaseHelper(clock: HandWoundClock(), ledger: ledger)
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent,
            connect: {
                connected += 1
                return HelperConnections(read: FakeSnapshotHelper(), control: control)
            },
            makeDriver: { LeaseDriver(control: $0, holderDescription: LeaseScene.holder) },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime(),
            mainRunLoop: TestMainRunLoop(.atOnce))
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: root.snapshots)
        await Support.tickEnds(polling)
        let report = root.leaseState.current
        let fans = FanControlPresentation.onScreen(in: polling, driver: report)
        try #require(!fans.isEmpty, "the direct read put a fan on screen")

        let rows = FanRowControlPresentation.Inputs.rows(
            fans, snapshot: polling.renderedSnapshot, driver: report.state)
        for row in rows {
            #expect(!FanListView.drawsControl(row), "fan \(row.index) drew a control")
        }

        let actions = FanRowControlActions(composition: root)
        actions.chooseAutomatic(fan: 0)
        actions.chooseCustom(fan: 0, on: polling)
        _ = actions.submit("3000", fan: 0, on: polling)
        actions.step(.up, from: .init(draft: "3000"), fan: 0, on: polling)
        let speed = try Rows.speed(3000)
        root.releaseFan(0)
        root.adjustFan(0, to: speed)
        root.takeFan(0, at: speed)

        #expect(root.latestDriverCall == nil, "no entry point started a call")
        let sent = await Support.eventually(turns: 2_000) { await !ledger.entries.isEmpty }
        #expect(!sent, "nothing reached a control connection")
        #expect(connected == 0)
        #expect(root.leaseState.current == .idle)
    }

    // MARK: - The view

    /// **Mutation (R3, "both segments take"):** in `FanRowView.perform`, call `chooseCustom` for
    /// `.automatic`. Run: red here.
    @Test("Each segment's action reaches its own closure")
    func performDispatches() throws {
        let asked = ResultBox<[String]>()
        asked.set([])
        let inputs = try Rows.inputs(Rows.free, beside: .idle)
        let view = FanRowView(
            row: FanRowModel(reading: try #require(SnapshotReadings.fans(in: Rows.free).first)),
            control: inputs,
            chooseAutomatic: { asked.set((asked.value ?? []) + ["auto"]) },
            chooseCustom: { asked.set((asked.value ?? []) + ["custom"]) },
            submit: { _ in .init() },
            step: { _, _ in })

        view.perform(.custom)
        view.perform(.automatic)

        #expect(asked.value == ["custom", "auto"])
    }

    @Test("The segments are Auto then Custom, as the presentation marks them")
    func segments() throws {
        let row = FanRowControlPresentation(
            try Rows.inputs(Rows.holding, beside: try Rows.heldConfirmed()), field: .init())

        #expect(
            FanRowView.segments(for: row) == [
                .init(action: .automatic, mark: .plain, isEnabled: true),
                .init(action: .custom, mark: .selected, isEnabled: false),
            ])
    }

    /// `FanListView` builds its per-fan actions over the root it is given.
    @Test("The fan list's row actions act through the root")
    func theRowActionsAreTheRoots() async throws {
        let scene = await CompositionScene()
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: scene.root.snapshots)
        let view = FanListView(viewModel: polling, composition: scene.root)

        let actions = Reflection.value(of: view, at: "rowActions") as? FanRowControlActions
        #expect(actions?.composition === scene.root)
        await scene.finish()
    }
}
