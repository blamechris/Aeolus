import Testing

@testable import fanctl

/// `Formatting.number` is the exact site of the trap this suite exists to prevent: see
/// its documentation for why `SMCValue.scalar()` gives no guarantee the `Double`s
/// reaching it are finite or within `Int`'s range.
@Suite("Formatting.number — never traps on a value SMCCore does not itself guard")
struct FormattingNumberTests {

    @Test("NaN renders without trapping")
    func nanRendersWithoutTrapping() {
        #expect(Formatting.number(.nan) == "NaN")
    }

    @Test("Positive infinity renders without trapping")
    func positiveInfinityRendersWithoutTrapping() {
        #expect(Formatting.number(.infinity) == "Infinity")
    }

    @Test("Negative infinity renders without trapping")
    func negativeInfinityRendersWithoutTrapping() {
        #expect(Formatting.number(-.infinity) == "-Infinity")
    }

    @Test("A magnitude beyond Int's range renders without trapping")
    func outOfIntRangeMagnitudeRendersWithoutTrapping() {
        // Double(UInt64.max) alone already sits past Int.max — the naive
        // `value == value.rounded() ? Int(value) : ...` this function used to be would
        // trap on this without needing a byte-swapped flt at all.
        let value = Double(UInt64.max)
        #expect(Formatting.number(value) == String(format: "%.2f", value))
    }

    @Test("Float.greatestFiniteMagnitude, promoted to Double, renders without trapping")
    func greatestFiniteFloatMagnitudeRendersWithoutTrapping() {
        let value = Double(Float.greatestFiniteMagnitude)
        #expect(Formatting.number(value) == String(format: "%.2f", value))
    }

    @Test("An ordinary whole number still renders as a plain integer")
    func ordinaryWholeNumberRendersAsInteger() {
        #expect(Formatting.number(1712) == "1712")
    }

    @Test("An ordinary fractional value still renders to two decimal places")
    func ordinaryFractionalValueRendersToTwoDecimals() {
        #expect(Formatting.number(42.5) == "42.50")
    }

    @Test("Zero renders as a plain integer, never something that could read as absent")
    func zeroRendersAsPlainInteger() {
        #expect(Formatting.number(0) == "0")
    }
}

/// `Formatting.exactNumber` is for a value refused because it is not whole. Rounding it to two
/// places, as `number(_:)` does, would print it as a whole number.
@Suite("Formatting.exactNumber — a fraction is shown in full, never rounded to look whole")
struct FormattingExactNumberTests {

    @Test(
        "A fraction keeps every digit that tells it apart from a whole number",
        arguments: [(1.999_999_9, "1.9999999"), (0.001, "0.001"), (0.25, "0.25"), (2.75, "2.75")])
    func fractionIsShownInFull(_ value: Double, _ rendered: String) {
        #expect(Formatting.exactNumber(value) == rendered)
    }

    @Test("A whole or non-finite value renders as number(_:) renders it")
    func wholeAndNonFiniteMatchNumber() {
        #expect(Formatting.exactNumber(2) == "2")
        #expect(Formatting.exactNumber(9_000_000) == "9000000")
        #expect(Formatting.exactNumber(.nan) == "NaN")
        #expect(Formatting.exactNumber(-.infinity) == "-Infinity")
    }
}
