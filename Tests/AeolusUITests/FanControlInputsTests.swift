import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `Inputs(polling:driver:)` reads what the view model has on screen, and the snapshot on screen
/// is the one `PollingViewModel.renderedSnapshot` returns until the claims are withdrawn.
@Suite("FanControlPresentation.Inputs — what the view model has on screen", .timeLimit(.minutes(1)))
@MainActor
struct FanControlInputsTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport

    /// **Mutation (R1):** make `renderedSnapshot` return `nil`. Run: red at the first
    /// `renderedSnapshot` expectation and at the first inputs comparison.
    @Test("The inputs are the view model's own; the snapshot is the one on screen until withdrawn")
    func theInputsAreTheViewModels() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0], .confirmed(try Fixtures.target([0: 3000])))

        await viewModel.tick()
        #expect(viewModel.renderedSnapshot == snapshot)
        let shown = Fixtures.screen(snapshot, driver: driver)
        #expect(FanControlPresentation.Inputs(polling: viewModel, driver: driver) == shown.inputs)
        #expect(viewModel.fans == shown.rows)

        try await Support.report(.unresponsive, to: source, from: helper)
        await viewModel.tick()
        #expect(viewModel.renderedSnapshot == nil)
        let gone = Fixtures.withdrawn(
            .helperConnection(.unresponsive), driver: driver, from: snapshot)
        #expect(FanControlPresentation.Inputs(polling: viewModel, driver: driver) == gone.inputs)
        #expect(viewModel.fans.map(\.control) == gone.rows.map(\.control))

        await Support.tearDown(source, helper)
    }

    /// The emergency through the shipping entry, from a snapshot whose flag is set.
    ///
    /// **Mutation (SVEI):** in `Inputs(polling:driver:)`, pass `.inactive` for `.active`. Run: red
    /// at both expectations.
    @Test("The emergency reaches the inputs as the view model has it")
    func theEmergencyReachesTheInputs() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0)], isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)

        await viewModel.tick()
        let inputs = FanControlPresentation.Inputs(polling: viewModel, driver: .idle)
        #expect(inputs.thermalEmergency == .active)
        #expect(inputs == Fixtures.screen(snapshot, driver: .idle).inputs)

        await Support.tearDown(source, helper)
    }

    /// The reviewer's case. Snapshot A lists our lease over fan 0, held at 3000 RPM. Snapshot B
    /// drops the lease and the fan is back on automatic. While `render` moves from A to B, a sink
    /// on `$lastUpdated` runs after the rows, the emergency and the lease have moved to B and
    /// before `renderedSnapshot` has: without the generation check, that read is Custom at 3000
    /// over a lease B no longer lists.
    ///
    /// **Mutation (G):** make `Licence.isOneSnapshot` return `true`. Run: red at the sink's
    /// expectation.
    @Test("A sink part-way through a render never reads Custom over a lease the new snapshot drops")
    func aSinkPartWayThroughARenderClaimsNothing() async throws {
        let helper = FakeSnapshotHelper()
        let older = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        let newer = Support.snapshot(fans: [Fixtures.clearedFan(0)])
        let source = try await Support.freshSource(helper, answering: older)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)
        let target = try Fixtures.target([0: 3000])
        let driver = Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target))

        await viewModel.tick()
        let before = FanControlPresentation.onScreen(in: viewModel, driver: driver)
        #expect(before.map(\.presentation.selection) == [.custom(try Fixtures.speed(target, 0))])

        await helper.reply(with: newer)
        try await helper.waitForRequests(3)
        try #require(Support.freshSnapshot(source) == newer)

        var seen: [FanControlPresentation] = []
        let sink = viewModel.$lastUpdated.dropFirst().sink { _ in
            seen += FanControlPresentation.onScreen(in: viewModel, driver: driver)
                .map(\.presentation)
        }
        await viewModel.tick()
        sink.cancel()

        #expect(seen.count == 1)
        #expect(!seen.contains { if case .custom = $0.selection { true } else { false } })
        #expect(seen.map(\.selection) == [.checking])
        #expect(seen.map(\.affordance) == [.disabled(.betweenSnapshots)])
        let after = FanControlPresentation.onScreen(in: viewModel, driver: driver)
        #expect(after.map(\.presentation.selection) == [.unknown])

        await Support.tearDown(source, helper)
    }

    /// **Mutation (FE):** make `onScreen(in:driver:)` present every row against `.idle`. Run: red.
    @Test("onScreen pairs each row the view model shows with its own presentation")
    func onScreenPairsEachRow() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Fixtures.heldFan(0, target: 3000), Fixtures.heldFan(1, target: 3200)],
            activeLease: Fixtures.ours)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)
        let driver = Fixtures.held(
            Fixtures.ours, fans: [0, 1], .confirmed(try Fixtures.target([0: 3000, 1: 3200])))

        await viewModel.tick()
        let every = FanControlPresentation.onScreen(in: viewModel, driver: driver)
        let screen = Fixtures.screen(snapshot, driver: driver)

        #expect(every.map(\.reading) == screen.rows)
        #expect(
            every.map(\.presentation) == (try [0, 1].map { try Fixtures.present($0, on: screen) }))

        await Support.tearDown(source, helper)
    }

    /// **Mutation (KP):** give `renderedSnapshot` a setter, `private(set) var renderedSnapshot:
    /// SystemSnapshot? { get { rendered?.snapshot } set { _ = newValue } }`. Run: red at the first
    /// expectation: `private(set)` hides the setter from lookup and not from a key path (SR-5218).
    @Test("The snapshot on screen cannot be written through a key path")
    func theSnapshotOnScreenIsReadOnly() {
        let path: AnyKeyPath = \PollingViewModel.renderedSnapshot

        #expect(!(path is ReferenceWritableKeyPath<PollingViewModel, SystemSnapshot?>))
        #expect(path is KeyPath<PollingViewModel, SystemSnapshot?>)
    }
}
