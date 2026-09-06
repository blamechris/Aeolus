import Testing

@testable import AeolusUI

@Suite("SensorSelectionFilter — empty means show everything, never show nothing")
struct SensorSelectionFilterTests {

    private func sensor(_ key: String) -> SensorPollingReading {
        SensorPollingReading(key: key, kind: .unknown, sample: .value(key: key, 1))
    }

    @Test("An empty selection passes every sensor through unfiltered")
    func emptySelectionShowsEverything() {
        let sensors = [sensor("Tp09"), sensor("TC0P")]
        #expect(SensorSelectionFilter.apply([], to: sensors) == sensors)
    }

    @Test("A non-empty selection keeps only matching keys, in the original order")
    func nonEmptySelectionFiltersByKey() {
        let sensors = [sensor("Tp09"), sensor("TC0P"), sensor("F0Ac")]
        let filtered = SensorSelectionFilter.apply(["F0Ac", "Tp09"], to: sensors)

        #expect(filtered.map(\.key) == ["Tp09", "F0Ac"])
    }

    @Test("A selected key with no matching sensor contributes nothing, never a crash")
    func selectedKeyWithNoMatchIsIgnored() {
        let sensors = [sensor("Tp09")]
        #expect(SensorSelectionFilter.apply(["does-not-exist"], to: sensors).isEmpty)
    }
}
