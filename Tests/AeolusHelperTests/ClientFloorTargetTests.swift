import FanKit
import Testing

@testable import AeolusHelper

/// `CommandableFan.clientFloorRPM` and `clientTarget(for:)` as values (#670's (b), ADR 0014's
/// minimal-run amendment, item 7 (b) as re-ruled on 2026-11-01): the floor is 65 % of the way from
/// each permit's own `F<n>Mn` to its `F<n>Mx`, and a request is clamped first and raised after, so
/// whatever the clamp makes of it, the floor still binds.
@Suite("The client floor, as values (#670)")
struct ClientFloorTargetTests {

    /// A permit for a fan declaring `minimum` to `maximum`.
    private static func fan(_ minimum: Double, _ maximum: Double) throws -> CommandableFan {
        try commandableFan(
            0,
            declaring: ScriptedControlPlane.FanCondition(minimumRPM: minimum, maximumRPM: maximum))
    }

    /// Three envelopes, three floors, each its own: `Mac16,5`'s, and two other shapes.
    ///
    /// **Mutation:** in `CommandableFan.clientFloorRPM`, return `min(4_227.55,
    /// envelope.declaredMaximumRPM)`. Run: red on the second and third rows.
    @Test(
        "The floor is 65 % of each fan's own declared range",
        arguments: [(1_350.0, 5_777.0, 4_227.55), (1_200, 4_800, 3_540), (1_500, 6_000, 4_425)])
    func theFloorIsEachFansOwn(minimum: Double, maximum: Double, floor: Double) throws {
        let fan = try Self.fan(minimum, maximum)
        #expect(fan.clientFloorRPM == floor)
        #expect(fan.clientTarget(for: minimum).rpm == floor)
    }

    /// The doc comment's claim: the raise judges the clamped value, so a request the clamp floors,
    /// NaN, 0 or below the firmware's minimum, is raised to the floor, and one the clamp caps is
    /// the maximum. A NaN cannot reach here from a client today, since `FanSetting`'s decoder
    /// refuses one; the guard is what holds if a path ever does.
    ///
    /// **Mutation:** in `clientTarget(for:)`, judge `requestedRPM < clientFloorRPM` in place of
    /// `clamped.rpm < clientFloorRPM`. Run: red on NaN, held at 1,350.
    @Test(
        "A request the clamp floors is raised, and one it caps is the maximum",
        arguments: [Double.nan, 0, -1, 1_000, .infinity, -.infinity])
    func theRaiseJudgesTheClampedValue(requested: Double) throws {
        let fan = try Self.fan(1_350, 5_777)
        let held = fan.clientTarget(for: requested).rpm
        if requested == .infinity {
            #expect(held == 5_777)
        } else {
            #expect(held == 4_227.55, "\(requested) held at \(held)")
        }
    }
}
