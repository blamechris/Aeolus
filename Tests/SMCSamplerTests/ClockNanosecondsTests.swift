import Testing

@testable import smc_sampler

@Suite("ClockNanoseconds")
struct ClockNanosecondsTests {

    @Test("a whole-second duration converts exactly")
    func wholeSecondConvertsExactly() {
        #expect(ClockNanoseconds.nanoseconds(from: .seconds(3)) == 3_000_000_000)
    }

    @Test("a sub-second duration converts to nanoseconds, truncating any sub-nanosecond remainder")
    func subSecondDurationConverts() {
        #expect(ClockNanoseconds.nanoseconds(from: .nanoseconds(1_500)) == 1_500)
        // 500 attoseconds is well below one nanosecond and must truncate to zero, not round up.
        #expect(ClockNanoseconds.nanoseconds(from: Duration(secondsComponent: 0, attosecondsComponent: 500)) == 0)
    }

    @Test("zero duration converts to zero")
    func zeroDurationConvertsToZero() {
        #expect(ClockNanoseconds.nanoseconds(from: .zero) == 0)
    }

    @Test("delta computes the difference between two increasing samples")
    func deltaComputesDifference() {
        #expect(ClockNanoseconds.delta(from: 1_000, to: 1_900) == 900)
    }

    @Test("delta of a sample against itself is zero")
    func deltaOfSameSampleIsZero() {
        #expect(ClockNanoseconds.delta(from: 500, to: 500) == 0)
    }

    @Test("delta returns nil rather than a negative number when the clock appears to run backwards")
    func deltaReturnsNilOnApparentRegression() {
        #expect(ClockNanoseconds.delta(from: 1_000, to: 500) == nil)
    }
}
