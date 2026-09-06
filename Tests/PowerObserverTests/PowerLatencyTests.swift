import Testing

@testable import power_observer

@Suite("PowerLatency")
struct PowerLatencyTests {

    @Test("microseconds truncates rather than rounds")
    func microsecondsTruncatesRatherThanRounds() {
        #expect(
            PowerLatency.microseconds(fromNanoseconds: 1_000_000, toNanoseconds: 1_005_999) == 5)
    }

    @Test("zero elapsed time is zero microseconds")
    func zeroElapsedIsZero() {
        #expect(PowerLatency.microseconds(fromNanoseconds: 42, toNanoseconds: 42) == 0)
    }

    @Test("a whole millisecond is one thousand microseconds")
    func aWholeMillisecondIsAThousandMicroseconds() {
        #expect(
            PowerLatency.microseconds(fromNanoseconds: 0, toNanoseconds: 1_000_000) == 1_000)
    }
}
