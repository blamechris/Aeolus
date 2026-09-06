import Testing

@testable import power_observer

@Suite("EventCounters")
struct EventCountersTests {

    @Test("each name is counted independently, including unknown")
    func eachNameIsCountedIndependently() async {
        let counters = EventCounters()
        await counters.increment("kIOMessageSystemWillSleep")
        await counters.increment("kIOMessageSystemWillSleep")
        await counters.increment("unknown")

        let snapshot = await counters.snapshot()
        #expect(snapshot["kIOMessageSystemWillSleep"] == 2)
        #expect(snapshot["unknown"] == 1)
    }

    @Test("a name never recorded is absent, not zero")
    func aNameNeverRecordedIsAbsent() async {
        let counters = EventCounters()
        let snapshot = await counters.snapshot()
        #expect(snapshot["kIOMessageSystemWillSleep"] == nil)
    }
}
