import Foundation
import Testing

@testable import FanKit

/// What a percentage means: a position in the **commandable** range, not in `[0, F0Mx]` and not
/// in `[F0Mn, F0Mx]` when the firmware declared a minimum below the floor.
///
/// The mapping lives here once, on `FanControlEnvelope`, so `fanctl set`, the app's slider and a
/// remote caller cannot each round it a different way
/// ([#317](https://github.com/blamechris/Aeolus/issues/317)).
@Suite("Percent targets")
struct FanPercentTargetTests {

    private func envelope(minimum: Double, maximum: Double) throws -> FanControlEnvelope {
        try FanControlEnvelope.validating(
            declaredMinimumRPM: minimum, declaredMaximumRPM: maximum
        ).get()
    }

    /// `Mac16,5`'s declared range, 1350 to 5777. The four figures are the ones the contract
    /// states; 50 % is the one that needs the rounding (1350 + 0.5 x 4427 = 3563.5).
    ///
    /// **Mutation:** delete `.rounded()` in `FanControlEnvelope.target(forPercent:)`. Run: red
    /// on the 50 % row, which reads 3563.5.
    @Test(
        "Mac16,5's envelope maps 0, 50, 75 and 100 percent to the documented speeds",
        arguments: [(0.0, 1350.0), (50, 3564), (75, 4670), (100, 5777)])
    func macSixteenFiveTable(percent: Double, expected: Double) throws {
        let fan = try envelope(minimum: 1350, maximum: 5777)
        #expect(fan.target(forPercent: percent).rpm == expected)
    }

    /// Every target is a whole number of RPM, whatever the percentage: the helper is asked for
    /// a speed a person can read back.
    @Test("Every integer percentage lands on a whole RPM inside the range")
    func everyPercentageIsAWholeNumberInsideTheRange() throws {
        let fan = try envelope(minimum: 1350, maximum: 5777)
        for percent in 0...100 {
            let rpm = fan.target(forPercent: Double(percent)).rpm
            #expect(rpm == rpm.rounded(), "\(percent)% gave \(rpm)")
            #expect(rpm >= fan.lowestCommandableRPM && rpm <= fan.highestCommandableRPM)
        }
    }

    /// A firmware minimum of zero is the case the floor exists for: 0 % is the floor, not a
    /// stop, and the span the percentages share starts at the floor. Measured from the declared
    /// minimum instead, 50 % would be 1500 here, not 1550.
    ///
    /// **Mutation:** in `target(forPercent:)`, build the span from `declaredMinimumRPM` instead
    /// of `lowestCommandableRPM`. Run: red on the 50 % row.
    @Test("A declared minimum of zero starts the range at the floor, never at zero")
    func zeroMinimumStartsAtTheFloor() throws {
        let fan = try envelope(minimum: 0, maximum: 3000)
        #expect(fan.lowestCommandableRPM == FanSafetyLimits.minimumManualRPM)
        #expect(fan.target(forPercent: 0).rpm == 100)
        #expect(fan.target(forPercent: 50).rpm == 1550)
        #expect(fan.target(forPercent: 100).rpm == 3000)
    }

    /// Rule 3 across the whole input line: no percentage, in range or not, is a stop.
    @Test("No percentage is ever zero RPM or outside the firmware range")
    func neverZeroNeverOutside() throws {
        for (minimum, maximum) in [(0.0, 3000.0), (1350, 5777), (99, 100), (10, 20_000)] {
            let fan = try envelope(minimum: minimum, maximum: maximum)
            var percent = -50.0
            while percent <= 200 {
                let rpm = fan.target(forPercent: percent).rpm
                #expect(rpm > 0, "\(percent)% on \(minimum)...\(maximum) gave \(rpm)")
                #expect(rpm >= fan.lowestCommandableRPM)
                #expect(rpm <= fan.highestCommandableRPM)
                percent += 0.5
            }
        }
    }

    /// The same single clamp as `target(for:)` decides what an out-of-range percentage means;
    /// the CLI refuses them (exit 64) and this is the backstop for a caller that does not.
    @Test("Out-of-range and non-finite percentages land on the bounds")
    func outOfRangePercentagesLandOnTheBounds() throws {
        let fan = try envelope(minimum: 1350, maximum: 5777)
        #expect(fan.target(forPercent: -5).rpm == 1350)
        #expect(fan.target(forPercent: 150).rpm == 5777)
        #expect(fan.target(forPercent: .infinity).rpm == 5777)
        #expect(fan.target(forPercent: -.infinity).rpm == 1350)
        #expect(fan.target(forPercent: .nan).rpm == 1350, "NaN resolves to the floor")
    }

    /// The span is the commandable one, so a fan whose maximum is barely above the floor still
    /// maps without dividing the range into nothing.
    @Test("A very narrow range maps to its two ends")
    func narrowRange() throws {
        let fan = try envelope(minimum: 1000, maximum: 1001)
        #expect(fan.target(forPercent: 0).rpm == 1000)
        #expect(fan.target(forPercent: 100).rpm == 1001)
    }
}
