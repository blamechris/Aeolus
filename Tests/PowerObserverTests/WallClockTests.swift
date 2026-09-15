import Foundation
import Testing

@testable import power_observer

/// Pins `WallClock.iso8601UTC(_:)` against a fixed `Date`, which is the whole reason that
/// function takes `date` as a parameter rather than always reading `Date()` — see its doc
/// comment. Both expected strings below were computed once from `ISO8601DateFormatter`
/// directly (`.withInternetDateTime, .withFractionalSeconds`, `TimeZone(identifier:
/// "UTC")`) and hard-coded here, so this suite is a pin against a known-good value rather
/// than the formatter checking its own output.
@Suite("WallClock")
struct WallClockTests {

    @Test("a fixed date with fractional seconds formats as UTC ISO-8601")
    func aFixedDateFormatsAsUTCISO8601() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        #expect(WallClock.iso8601UTC(date) == "2023-11-14T22:13:20.123Z")
    }

    @Test("the Unix epoch formats with a zero fractional-second field, not an omitted one")
    func theEpochFormatsWithAZeroFractionalField() {
        #expect(WallClock.iso8601UTC(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }
}
