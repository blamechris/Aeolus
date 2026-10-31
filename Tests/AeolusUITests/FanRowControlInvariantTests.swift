import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// What holds over every driver state, envelope and input, what a report says is in Custom, and
/// which route per-fan Auto takes (#154). An extension, so these run in
/// `FanRowControlPresentationTests`.
extension FanRowControlPresentationTests {

    // MARK: - Every state, every envelope, every input

    /// The properties that hold whatever is on screen: over every driver state, with the
    /// snapshot's envelope present, failed and absent, and every kind of input.
    ///
    /// - nothing is sent without an envelope;
    /// - every speed sent lies in the envelope's commandable range, so never 0 RPM;
    /// - Return adjusts exactly when the fan can be released, and the stepper never takes;
    /// - the field, when nobody types, never shows the snapshot's held target.
    @Test(
        "Over every state, envelope and input: no envelope sends nothing, and no speed is 0",
        arguments: EnvelopeCase.allCases)
    func everyStateEnvelopeAndInput(_ envelopeCase: EnvelopeCase) throws {
        let inputsTyped = ["3000", "0", "99999", "-5", "abc", "", "1e3", "nan"]
        for state in try Rows.everyState() {
            let screen = envelopeCase.screen(beside: state)
            for index in [0, 1] {
                let inputs = try Rows.inputs(index, on: screen)
                let row = Self.present(inputs)
                if row.field?.text == ReadingFormatting.number(Rows.snapshotRPM) {
                    Issue.record("the snapshot's target on screen: fan \(index), \(state)")
                }
                var requests = [Row.custom(inputs)]
                for typed in inputsTyped {
                    let request = Row.submit(typed, inputs).request
                    requests.append(request)
                    if let request {
                        let adjusts = if case .adjustFan = request { true } else { false }
                        #expect(adjusts == inputs.presentation.canRelease, "\(typed), \(state)")
                    }
                    for direction in Row.StepDirection.allCases {
                        requests.append(Row.step(direction, from: .init(draft: typed), inputs))
                    }
                }
                for request in requests.compactMap({ $0 }) {
                    try Self.expectCommandable(request, under: inputs, state)
                }
            }
        }
    }

    /// The snapshot's envelope for fan 0, present, refused, or with no snapshot at all.
    enum EnvelopeCase: CaseIterable, Sendable {
        case present, failed, noSnapshot

        func screen(beside state: LeaseDriverState) -> FanControlFixtures.Screen {
            switch self {
            case .present:
                return Fixtures.screen(Rows.snapshot(beside: state), driver: state)
            case .failed:
                let fan0 = Rows.fan(0, minimum: 6000, maximum: 5000)
                let snapshot = Support.snapshot(
                    fans: [fan0, Rows.fan(1, minimum: 6000, maximum: 5000)],
                    activeLease: state.isHeld ? Fixtures.ours : nil)
                return Fixtures.screen(snapshot, driver: state)
            case .noSnapshot:
                return Fixtures.withdrawn(
                    .snapshotStale, driver: state, from: Rows.snapshot(beside: state))
            }
        }
    }

    static func expectCommandable(
        _ request: Row.Request, under inputs: Row.Inputs, _ state: LeaseDriverState
    ) throws {
        let envelope = try #require(inputs.envelope, "sent \(request) with no envelope: \(state)")
        let speed: FanTargetRPM
        switch request {
        case .takeFan(let index, let rpm), .adjustFan(let index, let rpm):
            #expect(index == inputs.index)
            speed = rpm
        }
        #expect(speed.rpm > 0)
        #expect(speed.rpm >= envelope.lowestCommandableRPM)
        #expect(speed.rpm <= envelope.highestCommandableRPM)
    }

    // MARK: - What the report says is in Custom

    @Test("The fans in Custom, and each fan's target, as the report says")
    func whatTheReportSays() throws {
        let sending = try Rows.target([0: 3000, 1: 3200])
        let queued = try Rows.target([0: 3500, 1: 3200])
        let applying = Rows.held(.applying(sending, queued: queued), fans: [0, 1])

        #expect(applying.fansInCustom == [0, 1])
        #expect(applying.target(forFan: 0) == .init(speed: try Rows.speed(3500), isPending: true))
        #expect(applying.target(forFan: 2) == nil)
        let confirmed = Rows.held(.confirmed(sending), fans: [0, 1])
        #expect(confirmed.target(forFan: 1) == .init(speed: try Rows.speed(3200), isPending: false))

        #expect(LeaseDriverState.acquiring(fans: [1]).fansInCustom == [1])
        #expect(LeaseDriverState.acquiring(fans: [1]).target(forFan: 1) == nil)
        #expect(LeaseDriverState.releasing.fansInCustom == nil, "the report cannot say")
        for tag in [Fixtures.DriverTag.idle, .released, .lost, .refused] {
            let state = try tag.state()
            #expect(state.fansInCustom == [], "\(tag)")
            #expect(state.target(forFan: 0) == nil, "\(tag)")
        }
    }

    // MARK: - Per-fan Auto: the route and how it is recorded

    /// **Mutation (M17r, "the route swapped"):** in `automaticRoute`, swap the two answers. Run:
    /// red here, and in `FanRowControlRootTests`' attribution tests.
    @Test("Per-fan Auto: the last fan in Custom is Auto; otherwise the fan is released alone")
    func theAutomaticRoute() throws {
        let one = try Rows.heldConfirmed()
        #expect(Row.automaticRoute(forFan: 0, in: one) == .selectAutomatic)
        #expect(Row.automaticRoute(forFan: 1, in: one) == .releaseFan)

        let both = Rows.held(.confirmed(try Rows.target([0: 3000, 1: 3000])), fans: [0, 1])
        #expect(Row.automaticRoute(forFan: 0, in: both) == .releaseFan)
        #expect(Row.automaticRoute(forFan: 1, in: both) == .releaseFan)

        #expect(Row.automaticRoute(forFan: 0, in: .acquiring(fans: [0])) == .selectAutomatic)
        #expect(Row.automaticRoute(forFan: 0, in: .acquiring(fans: [0, 1])) == .releaseFan)
    }

    /// While releasing, the report does not say what is in Custom, so the record fails safe,
    /// whichever fan, however many are on screen.
    @Test("Releasing: per-fan Auto fails safe to a request for control")
    func theAutomaticRouteWhileReleasing() {
        for index in [0, 1, 7] {
            #expect(Row.automaticRoute(forFan: index, in: .releasing) == .releaseFan)
        }
    }

    @Test("Nothing in Custom: per-fan Auto is Auto, as Auto for all fans is")
    func theAutomaticRouteWithNothingInCustom() throws {
        for tag in [Fixtures.DriverTag.idle, .released, .lost, .refused] {
            #expect(Row.automaticRoute(forFan: 0, in: try tag.state()) == .selectAutomatic)
        }
    }
}
