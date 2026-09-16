import Testing

@testable import smc_sampler

@Suite("TickState")
struct TickStateTests {

    @Test("starts at zero")
    func startsAtZero() async {
        let state = TickState()
        #expect(await state.tickCount() == 0)
    }

    @Test("recordTick increments the count")
    func recordTickIncrements() async {
        let state = TickState()
        await state.recordTick()
        await state.recordTick()
        await state.recordTick()
        #expect(await state.tickCount() == 3)
    }
}

@Suite("SamplerInterval")
struct SamplerIntervalTests {

    @Test("a typical interval converts to whole nanoseconds")
    func typicalIntervalConverts() {
        #expect(SamplerInterval.clampedNanoseconds(forSeconds: 1.0) == 1_000_000_000)
    }

    @Test("a zero or negative interval clamps to zero rather than trapping")
    func nonPositiveIntervalClampsToZero() {
        #expect(SamplerInterval.clampedNanoseconds(forSeconds: 0) == 0)
        #expect(SamplerInterval.clampedNanoseconds(forSeconds: -5) == 0)
    }

    @Test(
        "an interval too large to represent as nanoseconds clamps to UInt64.max rather than trapping"
    )
    func tooLargeIntervalClampsToMax() {
        #expect(SamplerInterval.clampedNanoseconds(forSeconds: 1e30) == UInt64.max)
    }
}
