import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The target a percentage names, and the percentages themselves: the half of
/// `AllFansControlPresentationTests` about what a click may send. An extension, so these run in
/// that suite.
extension AllFansControlPresentationTests {

    // MARK: - The target a percentage names

    /// The row's displayed bounds, 1100 to 5300 for both fans, differ from the `FanState` the
    /// snapshot carries: 1350 to 5777 for fan 0 and 1200 to 4800 for fan 1. The target is the
    /// snapshot's, each fan's from its own: 3564 and 3000 RPM at 50 %, not 3200 for both.
    ///
    /// **Mutation (M2, "the row's bounds"):** in `speed(_:forFan:in:)`, build the envelope from
    /// the row's `minimum` and `maximum` (`FanState.controlEnvelope(declaredMinimum:
    /// declaredMaximum:)` of `.measured` of each `KeyedReading`'s value) instead of the snapshot's
    /// `FanState`. Run: red at the speeds.
    @Test("Each speed comes from the snapshot's fan state, never from the row's bounds")
    func theTargetIsTheSnapshots() throws {
        let snapshot = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let screen = Fixtures.screen(snapshot, driver: .idle)
        let rows = screen.rows.map { row in
            FanPollingReading(
                index: row.index, displayName: row.displayName, actual: row.actual,
                minimum: .value(key: SMCFanEnumeration.minimumKey(forFan: row.index), 1100),
                maximum: .value(key: SMCFanEnumeration.maximumKey(forFan: row.index), 5300),
                control: row.control)
        }
        let fans = rows.map { ($0, FanControlPresentation(reading: $0, given: screen.inputs)) }
        #expect(fans.allSatisfy { $0.1.affordance == .enabled })

        let target = try #require(Control.target(for: .fifty, fans: fans, snapshot: snapshot))

        #expect(target.speeds.mapValues(\.rpm) == [0: 3564, 1: 3000])
        #expect(target == (try Fans.target(.fifty, fans: [0, 1])))
    }

    @Test(
        "Every percentage names its speed in each fan's commandable range",
        arguments: FanSpeedPercent.allCases)
    func everyPercentage(_ percent: FanSpeedPercent) throws {
        let snapshot = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let target = Control.target(
            for: percent, fans: Self.fans(Fixtures.screen(snapshot, driver: .idle)),
            snapshot: snapshot)

        let expected: [Int: Double]
        switch percent {
        case .fifty: expected = [0: 3564, 1: 3000]
        case .seventyFive: expected = [0: 4670, 1: 3900]
        case .hundred: expected = [0: 5777, 1: 4800]
        }
        #expect(target?.speeds.mapValues(\.rpm) == expected)
    }

    /// Each fail-closed condition alone, on a screen that otherwise builds a target.
    enum Refusal: CaseIterable {
        case theFirstFanDisabled, theSecondFanDisabled, noSnapshot, aFanMissingFromTheSnapshot
        case anExtraFanInTheSnapshot
        case aRepeatedFan, anEnvelopeFailure
    }

    /// **Mutation (M10a):** delete the `allSatisfy { ... == .enabled }` guard. Run: red for
    /// `.theFirstFanDisabled` and `.theSecondFanDisabled`.
    /// **Mutation (G-repeat):** delete the guard that each reported fan is reported once. Run:
    /// red for `.aRepeatedFan` only.
    /// **Mutation (G-set):** delete the guard that the snapshot's fans are the fans on screen.
    /// Run: red for `.anExtraFanInTheSnapshot` only: `.aFanMissingFromTheSnapshot` is refused again
    /// by the per-fan lookup, which finds no state for the missing fan.
    @Test("Nothing is sent unless every fan can be given a speed", arguments: Refusal.allCases)
    func failsClosed(_ refusal: Refusal) throws {
        let offered = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])
        let fans = Self.fans(Fixtures.screen(offered, driver: .idle))
        #expect(Control.target(for: .fifty, fans: fans, snapshot: offered) != nil, "the control")

        let refused: LeaseTarget?
        switch refusal {
        case .theFirstFanDisabled, .theSecondFanDisabled:
            let which = refusal == .theFirstFanDisabled ? 0 : 1
            let one = Support.snapshot(
                fans: [0, 1].map {
                    $0 == which ? Fans.refused($0, .supervisorBlind) : Fans.offered($0)
                })
            refused = Control.target(
                for: .fifty, fans: Self.fans(Fixtures.screen(one, driver: .idle)), snapshot: one)
        case .noSnapshot:
            refused = Control.target(for: .fifty, fans: fans, snapshot: nil)
        case .aFanMissingFromTheSnapshot:
            refused = Control.target(
                for: .fifty, fans: fans, snapshot: Support.snapshot(fans: [Fans.offered(0)]))
        case .anExtraFanInTheSnapshot:
            refused = Control.target(
                for: .fifty, fans: fans,
                snapshot: Support.snapshot(fans: [
                    Fans.offered(0), Fans.offered(1), Fans.offered(2),
                ]))
        case .aRepeatedFan:
            // Rows and snapshot agree, both with fan 1 twice, so only the repeat refuses.
            let repeated = Support.snapshot(
                fans: [Fans.offered(0), Fans.offered(1), Fans.offered(1)])
            let both = Self.fans(Fixtures.screen(repeated, driver: .idle))
            #expect(both.count == 3)
            #expect(both.allSatisfy { $0.presentation.affordance == .enabled })
            refused = Control.target(for: .fifty, fans: both, snapshot: repeated)
        case .anEnvelopeFailure:
            let unbounded = FanState(
                index: 1, actualRPM: .measured(2000), minimumRPM: .measured(1350),
                maximumRPM: .unavailable(reason: "not read"), targetRPM: nil, mode: .automatic,
                isReclaimedBySystem: false, manualControlAvailability: .available)
            refused = Control.target(
                for: .fifty, fans: fans,
                snapshot: Support.snapshot(fans: [Fans.offered(0), unbounded]))
        }
        #expect(refused == nil)
    }

    // MARK: - The percentages

    /// **Mutations (O9a, O9b):** make `.hundred` 110, or drop the space from the label. Run: red
    /// here.
    @Test("The percentages are 50, 75 and 100, labelled with a space before the sign")
    func thePercentages() {
        #expect(FanSpeedPercent.allCases == [.fifty, .seventyFive, .hundred])
        #expect(FanSpeedPercent.allCases.map(\.rawValue) == [50, 75, 100])
        #expect(FanSpeedPercent.allCases.map(\.percent) == [50, 75, 100])
        #expect(FanSpeedPercent.allCases.map(\.label) == ["50 %", "75 %", "100 %"])
    }
}
