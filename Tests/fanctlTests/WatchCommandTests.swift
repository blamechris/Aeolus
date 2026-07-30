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
        let clock = FakeWatchClock(cancelAfterSleeps: 1)
        let options = WatchCommand.Options(interval: 0, count: nil, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options,
            clock: clock, output: { captured.append($0) })

        // One tick renders before the loop asks the clock to sleep and is told to stop —
        // no partial output, no thrown CancellationError reaching the caller.
        #expect(captured.count == 1)
        // The cancelling sleep still counted as a call — `cancelAfterSleeps` fires on the
        // call it names, not silently one call earlier or later.
        #expect(await clock.sleepCount == 1)
    }

    @Test("The loop sleeps once in every gap between ticks, and never once more after the last")
    func sleepsBetweenEveryTickNeverAfterTheLast() async throws {
        let clock = FakeWatchClock()
        let options = WatchCommand.Options(interval: 0, count: 4, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: Self.provider(), options: options, clock: clock, output: { _ in })

        // Four ticks have three gaps between them. `WatchCommand.run` returns as soon as
        // the fourth tick's own count check succeeds, before ever calling
        // `clock.sleep(seconds:)` again — see its own documentation on why the last tick
        // must never pay for a wait nothing is going to read.
        #expect(await clock.sleepCount == 3)
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

/// Tests that need the provider's answer to actually differ between ticks —
/// `FakeSensorProvider`'s fixed `let` fixtures cannot represent any of these, which is
/// exactly why `ScriptedSensorProvider` exists. See issue #58.
@Suite("fanctl watch — streaming across ticks")
struct WatchCommandStreamingTests {

    private static func fan(actual: Double) -> [String: Result<SensorReading, SensorReadFailure>] {
        [
            "FNum": .success(.fake(key: "FNum", value: 1)),
            "F0Ac": .success(.fake(key: "F0Ac", value: actual, kind: .rpm)),
            "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
            "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
        ]
    }

    @Test("A fetch that fails after several successful ticks ends the session, not just that tick")
    func fetchSucceedsThenFailsMidSession() async {
        let provider = ScriptedSensorProvider(ticks: [
            .success(Self.fan(actual: 1712)),
            .success(Self.fan(actual: 1800)),
            .readFailure(FakeProviderError(description: "firmware went dark mid-session")),
        ])
        var captured: [String] = []
        // count: 5 — comfortably more ticks than the script actually survives, so a
        // regression that let the loop run past the failure (rather than ending the
        // session on it) would still show up as a wrong final captured.count below.
        let options = WatchCommand.Options(interval: 0, count: 5, json: false, isTerminal: false)

        await #expect(
            throws: FanctlError.connectionFailed(
                context: "read FNum", reason: "firmware went dark mid-session")
        ) {
            try await WatchCommand.run(
                provider: provider, options: options, clock: FakeWatchClock(),
                output: { captured.append($0) })
        }

        // The two ticks before the failure already reached the terminal — a fetch failure
        // ends the session, it does not retroactively un-render output already produced.
        #expect(captured.count == 2)
        #expect(captured[0].contains("1712 RPM"))
        #expect(captured[1].contains("1800 RPM"))
    }

    /// `Tick.unavailable` was the one scripted variant with no test, which made it the one
    /// member of the "succeeds N ticks then fails" family left unproven. Review of #66 flagged it.
    ///
    /// - Important: this is **not** a model of the sleep/wake case (#68).
    ///   `SMCSensorProvider.isAvailable` is `SMCConnection.isHardwareAvailable()`, which only checks
    ///   that the `AppleSMC` IOService exists — so across a wake holding a stale `io_connect_t` it
    ///   would keep reporting `true`. Nobody should read this test as evidence about sleep/wake.
    @Test("The SMC disappearing mid-session ends the loop with noSMC, not an endless render")
    func providerBecomesUnavailableMidSession() async {
        let provider = ScriptedSensorProvider(ticks: [
            .success(Self.fan(actual: 1712)),
            .unavailable,
        ])
        var captured: [String] = []
        // count: 5 — more ticks than the script survives, so a regression that kept rendering past
        // the disappearance would show up as a wrong final captured.count.
        let options = WatchCommand.Options(interval: 0, count: 5, json: false, isTerminal: false)

        await #expect(throws: FanctlError.noSMC) {
            try await WatchCommand.run(
                provider: provider, options: options, clock: FakeWatchClock(),
                output: { captured.append($0) })
        }

        // The tick before the disappearance already reached the terminal; losing the SMC ends the
        // session rather than retroactively un-rendering output.
        #expect(captured.count == 1)
        #expect(captured[0].contains("1712 RPM"))
    }

    @Test("A NaN mid-stream renders as unavailable on that tick, and the stream stays alive")
    func nanMidStreamStaysAlive() async throws {
        let provider = ScriptedSensorProvider(ticks: [
            .success(Self.fan(actual: 1712)),
            .success(Self.fan(actual: .nan)),
            .success(Self.fan(actual: 1690)),
        ])
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 3, json: false, isTerminal: false)
        try await WatchCommand.run(
            provider: provider, options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        // All three ticks rendered — sanitising the NaN into a failure never ended the
        // loop, and the tick after it is a normal reading again.
        #expect(captured.count == 3)
        #expect(captured[0].contains("1712 RPM"))
        #expect(captured[1].contains("unavailable (decoded to a non-finite value (NaN)"))
        #expect(!captured[1].contains("1712 RPM"))
        #expect(captured[2].contains("1690 RPM"))
    }

    @Test("A value that changes between ticks is reflected in each tick's own output, never stale")
    func changingValueUpdatesEachTick() async throws {
        let provider = ScriptedSensorProvider(ticks: [
            .success(Self.fan(actual: 1712)),
            .success(Self.fan(actual: 1899)),
            .success(Self.fan(actual: 2044)),
        ])
        var captured: [String] = []
        let options = WatchCommand.Options(interval: 0, count: 3, json: true, isTerminal: false)
        try await WatchCommand.run(
            provider: provider, options: options, clock: FakeWatchClock(),
            output: { captured.append($0) })

        #expect(captured.count == 3)
        let actualValues = try captured.map { line -> Double in
            let data = try #require(line.data(using: .utf8))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let fans = try #require(object["fans"] as? [[String: Any]])
            let actualRPM = try #require(fans.first?["actualRPM"] as? [String: Any])
            return try #require(actualRPM["value"] as? Double)
        }
        #expect(actualValues == [1712, 1899, 2044])
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

    @Test("An --interval far larger than a day is rejected before it can reach the clock")
    func hugeIntervalIsRejected() {
        // 1e11 seconds is finite and positive — it would pass the earlier guard — but is
        // also comfortably past UInt64.max nanoseconds (~1.8446744e10 seconds), which is
        // exactly what used to reach SystemWatchClock.sleep and trap. Rejected here, at
        // parse time, well before any conversion is attempted.
        #expect(throws: (any Error).self) {
            try Fanctl.Watch.parse(["--interval", "1e11"])
        }
    }

    @Test("A day-long --interval is accepted; the bound is inclusive, not off-by-one")
    func oneDayIntervalIsAccepted() throws {
        _ = try Fanctl.Watch.parse(["--interval", "86400"])
    }
}

@Suite("SystemWatchClock — nanosecond clamping")
struct SystemWatchClockNanosecondClampingTests {

    @Test("An ordinary interval converts to the expected nanosecond count")
    func ordinaryIntervalConverts() {
        #expect(SystemWatchClock.clampedNanoseconds(forSeconds: 1) == 1_000_000_000)
    }

    @Test("Zero converts to zero, not a trap")
    func zeroConverts() {
        #expect(SystemWatchClock.clampedNanoseconds(forSeconds: 0) == 0)
    }

    @Test(
        "A value whose nanosecond count exceeds UInt64.max clamps rather than traps",
        arguments: [1e11, 1e20, .infinity]
    )
    func outOfRangeValueClampsRatherThanTraps(_ seconds: Double) {
        // The value that used to reach `UInt64(_:)` directly and crash the process on a
        // mistyped --interval — see the reviewer note this test exists to pin down.
        #expect(SystemWatchClock.clampedNanoseconds(forSeconds: seconds) == UInt64.max)
    }

    @Test("A negative value clamps to zero rather than underflowing")
    func negativeValueClampsToZero() {
        #expect(SystemWatchClock.clampedNanoseconds(forSeconds: -5) == 0)
    }
}
