import Foundation
import Testing

@testable import SMCCore
@testable import fanctl

@Suite("fanctl list — fetch")
struct ListCommandFetchTests {

    @Test("No SMC on this machine surfaces a clear error, not a bare throw")
    func noSMCThrowsClearError() async {
        let provider = FakeSensorProvider(isAvailable: false)
        await #expect(throws: FanctlError.noSMC) {
            try await ListCommand.fetch(provider: provider)
        }
    }

    @Test("Two fans read cleanly, each paired with its own raw keys")
    func twoFansReadCleanly() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 2)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "F1Ac": .success(.fake(key: "F1Ac", value: 1690, kind: .rpm)),
                "F1Mn": .success(.fake(key: "F1Mn", value: 1150, kind: .rpm)),
                "F1Mx": .success(.fake(key: "F1Mx", value: 5100, kind: .rpm)),
            ])

        let result = try await ListCommand.fetch(provider: provider)

        #expect(result.fanCount == 2)
        #expect(result.fanCountKey == "FNum")
        #expect(result.fans.count == 2)

        let fan0 = try #require(result.fans.first { $0.index == 0 })
        #expect(fan0.displayName == "Fan 0")
        #expect(fan0.actual == .success(key: "F0Ac", value: 1712))
        #expect(fan0.minimum == .success(key: "F0Mn", value: 1200))
        #expect(fan0.maximum == .success(key: "F0Mx", value: 5312))

        let fan1 = try #require(result.fans.first { $0.index == 1 })
        #expect(fan1.actual == .success(key: "F1Ac", value: 1690))
    }

    @Test("A zero fan count (fanless Mac) returns an empty list, not an error")
    func fanlessMacReturnsEmptyList() async throws {
        let provider = FakeSensorProvider(
            keyedResults: ["FNum": .success(.fake(key: "FNum", value: 0))])

        let result = try await ListCommand.fetch(provider: provider)

        #expect(result.fanCount == 0)
        #expect(result.fans.isEmpty)
    }

    @Test("A single missing per-fan key is recorded on that fan, not thrown")
    func missingPerFanKeyIsRecordedNotThrown() async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                // F0Mx deliberately unstubbed — the fake reports .unknownKey for it.
            ])

        let result = try await ListCommand.fetch(provider: provider)

        let fan = try #require(result.fans.first)
        #expect(fan.actual.value == 1712)
        #expect(fan.maximum.value == nil)
        #expect(fan.maximum.error != nil)
        #expect(fan.maximum.key == "F0Mx")
    }

    @Test("An implausible FNum value is refused rather than trusted")
    func implausibleFanCountIsRefused() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 9_000_000))
            ])

        await #expect(throws: FanctlError.implausibleFanCount("9000000")) {
            try await ListCommand.fetch(provider: provider)
        }
    }

    @Test("A negative FNum decode is refused rather than trusted")
    func negativeFanCountIsRefused() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: -1))
            ])

        await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
    }

    @Test(
        "A non-finite FNum decode is refused without trapping, validated before conversion",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteFanCountIsRefusedWithoutTrapping(_ nonFiniteValue: Double) async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: nonFiniteValue))
            ])

        await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
    }

    @Test("A failure reading FNum itself is a clear, actionable error")
    func fnumReadFailureIsClear() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .failure(.readFailed(reason: "firmware rejected the read"))
            ])

        await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
    }

    // MARK: - Classified-error surfacing (proving the shared enumeration's error is
    // reclassified into FanctlError's own vocabulary, not flattened to a generic case)

    @Test("An FNum read failure that is not absence surfaces as .connectionFailed, with its reason")
    func fnumReadFailureSurfacesClassifiedConnectionFailed() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .failure(.readFailed(reason: "firmware rejected the read"))
            ])

        let error = await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
        guard case .connectionFailed(_, let reason) = error else {
            Issue.record("expected .connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "firmware rejected the read")
    }

    @Test("An implausible FNum surfaces as .implausibleFanCount carrying the decoded value")
    func implausibleFanCountSurfacesClassifiedCase() async {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 9_000_000))
            ])

        let error = await #expect(throws: FanctlError.self) {
            try await ListCommand.fetch(provider: provider)
        }
        #expect(error == .implausibleFanCount("9000000"))
    }

    @Test("An absent FNum key (not just FNum == 0) is treated as zero fans, not an error")
    func absentFNumIsTreatedAsZeroFans() async throws {
        // FakeSensorProvider with no FNum stub reports .unknownKey for it by
        // construction — see FakeSensorProvider.read(keys:) — modelling a machine
        // whose firmware does not expose a fan-count key at all, not one that reports
        // it as zero.
        let provider = FakeSensorProvider()

        let result = try await ListCommand.fetch(provider: provider)

        #expect(result.fanCount == 0)
        #expect(result.fans.isEmpty)
    }

    @Test(
        "A non-finite per-fan reading is sanitised into a failure, never fabricated or trapping",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteFanReadingIsSanitisedIntoFailure(_ nonFiniteValue: Double) async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: nonFiniteValue, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        let result = try await ListCommand.fetch(provider: provider)
        let fan = try #require(result.fans.first)

        #expect(fan.actual.value == nil)
        #expect(fan.actual.error != nil)

        // Neither renderer traps or throws — the whole point of sanitising before
        // either one ever sees the value.
        let table = ListCommand.renderTable(result)
        #expect(table.contains("unavailable"))
        let json = try ListCommand.renderJSON(result)
        #expect(json.contains("\"error\""))
    }

    @Test(
        "A large-but-finite reading renders successfully, not as a sanitised failure",
        arguments: [Double(UInt64.max), Double(Float.greatestFiniteMagnitude)]
    )
    func largeFiniteFanReadingRendersSuccessfully(_ hugeValue: Double) async throws {
        let provider = FakeSensorProvider(
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: hugeValue, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
            ])

        let result = try await ListCommand.fetch(provider: provider)
        let fan = try #require(result.fans.first)

        #expect(fan.actual.value == hugeValue)
        #expect(fan.actual.error == nil)

        // Both renderers must complete without trapping on a magnitude Int(_:) alone
        // cannot hold.
        _ = ListCommand.renderTable(result)
        _ = try ListCommand.renderJSON(result)
    }
}

@Suite("fanctl list — command wiring")
struct ListCommandWiringTests {

    @Test("--json selects the JSON renderer, not just that renderJSON is independently correct")
    func jsonFlagSelectsJSONRenderer() async throws {
        let provider = FakeSensorProvider(
            keyedResults: ["FNum": .success(.fake(key: "FNum", value: 0))])
        let command = try Fanctl.List.parse(["--json"])

        var captured = ""
        try await command.run(provider: provider) { captured = $0 }

        #expect(captured.hasPrefix("{"))
        #expect(captured.contains("\"fanCount\""))
    }

    @Test("Without --json, list renders a table, not JSON")
    func withoutJSONFlagRendersTable() async throws {
        let provider = FakeSensorProvider(
            keyedResults: ["FNum": .success(.fake(key: "FNum", value: 0))])
        let command = try Fanctl.List.parse([])

        var captured = ""
        try await command.run(provider: provider) { captured = $0 }

        #expect(!captured.hasPrefix("{"))
        #expect(captured.contains("No fans detected"))
    }
}

@Suite("fanctl list — rendering")
struct ListCommandRenderTests {

    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func sampleResult() -> ListCommand.Result {
        ListCommand.Result(
            fanCount: 1,
            fanCountKey: "FNum",
            fans: [
                ListCommand.Fan(
                    index: 0,
                    displayName: "Fan 0",
                    actual: .success(key: "F0Ac", value: 1712),
                    minimum: .success(key: "F0Mn", value: 1200),
                    maximum: .success(key: "F0Mx", value: 5312)
                )
            ],
            capturedAt: fixedDate
        )
    }

    @Test("JSON output is stable, pretty-printed, sorted, and self-describing")
    func jsonOutputIsStable() throws {
        let json = try ListCommand.renderJSON(Self.sampleResult())

        let expected = """
            {
              "capturedAt" : "2023-11-14T22:13:20Z",
              "fanCount" : {
                "key" : "FNum",
                "value" : 1
              },
              "fans" : [
                {
                  "actualRPM" : {
                    "error" : null,
                    "key" : "F0Ac",
                    "value" : 1712
                  },
                  "displayName" : "Fan 0",
                  "index" : 0,
                  "maximumRPM" : {
                    "error" : null,
                    "key" : "F0Mx",
                    "value" : 5312
                  },
                  "minimumRPM" : {
                    "error" : null,
                    "key" : "F0Mn",
                    "value" : 1200
                  }
                }
              ]
            }
            """
        #expect(json == expected)
    }

    @Test("The raw key is always present in the table, even alongside a synthesised name")
    func tableAlwaysShowsRawKeys() {
        let table = ListCommand.renderTable(Self.sampleResult())

        #expect(table.contains("Fan 0"))
        #expect(table.contains("F0Ac/F0Mn/F0Mx"))
        #expect(table.contains("1712 RPM"))
    }

    @Test("A fanless Mac renders an explicit, non-empty message rather than a blank table")
    func fanlessMacRendersExplicitMessage() {
        let result = ListCommand.Result(
            fanCount: 0, fanCountKey: "FNum", fans: [], capturedAt: Self.fixedDate)
        let table = ListCommand.renderTable(result)

        #expect(table.contains("No fans detected"))
        #expect(table.contains("FNum"))
    }

    @Test("A per-fan read failure renders its reason, never a fabricated 0")
    func failedReadRendersReasonNotZero() {
        let result = ListCommand.Result(
            fanCount: 1,
            fanCountKey: "FNum",
            fans: [
                ListCommand.Fan(
                    index: 0,
                    displayName: "Fan 0",
                    actual: .failure(key: "F0Ac", reason: "not present on this machine"),
                    // Deliberately not multiples of ten: "1200 RPM" contains "0 RPM" as
                    // a plain substring, which would make the assertion below pass for
                    // the wrong reason. 1111/7777 cannot collide with it.
                    minimum: .success(key: "F0Mn", value: 1111),
                    maximum: .success(key: "F0Mx", value: 7777)
                )
            ],
            capturedAt: Self.fixedDate
        )
        let table = ListCommand.renderTable(result)

        #expect(table.contains("unavailable (not present on this machine)"))
        #expect(!table.contains("0 RPM"))
    }
}
