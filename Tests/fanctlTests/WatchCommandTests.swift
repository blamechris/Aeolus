import Foundation
import Testing

@testable import SMCCore
@testable import fanctl

@Suite("fanctl watch — refresh loop")
struct WatchCommandLoopTests {

    static func provider() -> FakeSensorProvider {
        FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])
    }

    @Test("Runs exactly `count` ticks and never emits ANSI when stdout is not a terminal")
    func fixedCountNonTerminalTableProducesPlainBlocks() async throws {
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 3, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        #expect(captured.count == 3)
        for tick in captured {
            #expect(!tick.contains("\u{1B}["))
            #expect(tick.contains("1712 RPM"))
        }
    }

    @Test("Table mode on a real terminal clears and redraws each tick")
    func terminalTableClearsEachTick() async throws {
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 2, json: false, isTerminal: true)
        try await WatchCommand.run(
            provider: Self.provider(), options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        #expect(captured.count == 2)
        for tick in captured {
            #expect(tick.contains("\u{1B}[2J\u{1B}[H"))
            #expect(tick.contains("1712 RPM"))
        }
    }

    @Test("--json emits one compact, independently-parseable line per tick, never pretty-printed")
    func jsonProducesOneCompactLinePerTick() async throws {
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 3, json: true, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        #expect(captured.count == 3)
        for line in captured {
            #expect(!line.contains("\n"))
            #expect(!line.contains("\u{1B}["))
            let data = try #require(line.data(using: .utf8))
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(decoded?["fanCount"] != nil)
        }
    }

    @Test("--json output never carries ANSI even when stdout is a real terminal")
    func jsonNeverCarriesANSIOnATerminal() async throws {
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 1, json: true, isTerminal: true)
        try await WatchCommand.run(
            provider: Self.provider(), options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        let line = try #require(captured.first)
        #expect(!line.contains("\u{1B}["))
    }

    @Test("A cancelled sleep between ticks is a clean stop, not a thrown error")
    func cancellationBetweenTicksIsCleanStop() async throws {
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: nil, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options,
            clock: FakeWatchClock(cancelAfterSleeps: 1), output: { captured.append($0) })

        // One tick renders before the loop asks the clock to sleep and is told to stop —
        // no partial output, no thrown CancellationError reaching the caller.
        #expect(captured.count == 1)
    }

    @Test("A fetch failure ends the command with the same clear error `list` would raise")
    func fetchFailurePropagates() async {
        let provider = FakeSensorProvider(isAvailable: false)
        let options = WatchCommand.Options(interval: 0, count: 5, json: false, isTerminal: false)
        await #expect(throws: FanctlError.noSMC) {
            try await WatchCommand.run(
                provider: provider, options: options, clock: FakeWatchClock(), output: { _ in })
        }
    }

    @Test("An unavailable per-fan reading renders as unavailable, never a fabricated 0 RPM")
    func unavailableReadingNeverRendersAsZero() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                // Deliberately not multiples of ten: "1200 RPM" contains "0 RPM" as a
                // plain substring, which would make the assertion below pass for the
                // wrong reason — see ListCommandRenderTests's identical note.
                "F0Mn": .success(.fake(key: "F0Mn", value: 1111, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 7777, kind: .rpm)),
                // F0Ac deliberately unstubbed: the fake reports .unknownKey for it.
            ])

        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 1, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: provider, options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        let tick = try #require(captured.first)
        #expect(tick.contains("unavailable"))
        #expect(!tick.contains("0 RPM"))
    }

    @Test("watch's --json shape matches list's --json shape exactly for the same reading")
    func matchesListJSONShapeExactly() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let listResult = try await ListCommand.fetch(provider: Self.provider(), now: fixedDate)
        let listJSON = try ListCommand.renderJSON(listResult)

        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 1, json: true, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options,
            clock: FakeWatchClock(fixedDate: fixedDate), output: { captured.append($0) })

        let watchLine = try #require(captured.first)
        let watchObject =
            try JSONSerialization.jsonObject(with: try #require(watchLine.data(using: .utf8)))
            as? NSDictionary
        let listObject =
            try JSONSerialization.jsonObject(with: try #require(listJSON.data(using: .utf8)))
            as? NSDictionary

        #expect(watchObject == listObject)
    }
}

@Suite("fanctl watch — command wiring")
struct WatchCommandWiringTests {

    @Test("--json selects NDJSON, not the redrawing table")
    func jsonFlagSelectsNDJSON() async throws {
        let provider = WatchCommandLoopTests.provider()
        let command = try Fanctl.Watch.parse(["--json", "--count", "1"])

        var captured = ""
        try await command.run(provider: provider, isTerminal: false) { captured = $0 }

        #expect(captured.hasPrefix("{"))
        #expect(!captured.contains("\n"))
    }

    @Test("Without --json, watch renders the same table `list` does")
    func withoutJSONFlagRendersTable() async throws {
        let provider = WatchCommandLoopTests.provider()
        let command = try Fanctl.Watch.parse(["--count", "1"])

        var captured = ""
        try await command.run(provider: provider, isTerminal: false) { captured = $0 }

        #expect(captured.contains("1712 RPM"))
        #expect(!captured.contains("\u{1B}["))
    }

    @Test("--interval 0 is rejected before any hardware I/O")
    func nonPositiveIntervalIsRejected() {
        #expect(throws: (any Error).self) {
            try Fanctl.Watch.parse(["--interval", "0"])
        }
    }

    @Test("A negative --interval is rejected before any hardware I/O")
    func negativeIntervalIsRejected() {
        #expect(throws: (any Error).self) {
            try Fanctl.Watch.parse(["--interval", "-1"])
        }
    }

    @Test("A non-positive --count is rejected before any hardware I/O")
    func nonPositiveCountIsRejected() {
        #expect(throws: (any Error).self) {
            try Fanctl.Watch.parse(["--count", "0"])
        }
    }
}
