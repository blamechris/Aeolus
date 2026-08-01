import SMCCore
import Testing

/// One fan's three readings, as a fixture. A named type rather than a tuple so the call
/// sites below read as `.init(actual:minimum:maximum:)` and cannot silently transpose two
/// of the three.
private struct FanFixture {
    let actual: Double
    let minimum: Double
    let maximum: Double

    init(actual: Double, minimum: Double = 1350, maximum: Double = 5777) {
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Builds the canned outcome table for a machine reporting `fanCount` fans, each of them
/// reading the given actual/minimum/maximum. Keys not produced here answer `.unknownKey`
/// from the fake, which is what a machine that does not expose them would report.
private func machine(
    fanCount: Double,
    fans: [FanFixture] = []
) -> [String: Result<SensorReading, SensorReadFailure>] {
    var table: [String: Result<SensorReading, SensorReadFailure>] = [
        SMCFanEnumeration.fanCountKey: .rpm(SMCFanEnumeration.fanCountKey, fanCount)
    ]
    for (index, fan) in fans.enumerated() {
        table[SMCFanEnumeration.actualKey(forFan: index)] =
            .rpm(SMCFanEnumeration.actualKey(forFan: index), fan.actual)
        table[SMCFanEnumeration.minimumKey(forFan: index)] =
            .rpm(SMCFanEnumeration.minimumKey(forFan: index), fan.minimum)
        table[SMCFanEnumeration.maximumKey(forFan: index)] =
            .rpm(SMCFanEnumeration.maximumKey(forFan: index), fan.maximum)
    }
    return table
}

/// The value of a fan's key, or `nil` when it is unavailable. Used only to assert on what
/// enumeration surfaced; production code switches on the outcome rather than flattening it.
private func value(_ outcome: SensorReadOutcome) -> Double? {
    guard case .success(let reading) = outcome.result else { return nil }
    return reading.value
}

private func failure(_ outcome: SensorReadOutcome) -> SensorReadFailure? {
    guard case .failure(let failure) = outcome.result else { return nil }
    return failure
}

@Suite("SMC fan enumeration")
struct SMCFanEnumerationTests {

    @Test("A normal multi-fan machine enumerates every fan with all three keys")
    func multiFanMachineEnumerates() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 2,
                fans: [
                    FanFixture(actual: 1343.07),
                    FanFixture(actual: 1454.97),
                ]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 2)
        #expect(enumeration.fanIndices == [0, 1])
        #expect(enumeration.enumeratedFanIndices == [0, 1])
        #expect(enumeration.fans[0].actual.key == "F0Ac")
        #expect(enumeration.fans[0].minimum.key == "F0Mn")
        #expect(enumeration.fans[0].maximum.key == "F0Mx")
        #expect(value(enumeration.fans[0].actual) == 1343.07)
        #expect(value(enumeration.fans[1].maximum) == 5777)
    }

    /// The set handed to `AeolusXPCValidation.validateFanIndices(_:enumeratedFanIndices:)`
    /// is what gates which fans a lease may cover, so it must be exactly the enumerated
    /// indices — not widened by a count, not narrowed by which keys happened to read.
    @Test("The lease-gating index set is exactly the enumerated indices")
    func indexSetMatchesEnumeratedFans() async throws {
        // Fan 1 reads nothing at all: every one of its keys is absent from the table.
        var table = machine(fanCount: 2, fans: [FanFixture(actual: 2000)])
        table["F1Ac"] = .failure(.unknownKey("F1Ac"))

        let provider = FakeSensorProvider(keyedResults: table)
        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.enumeratedFanIndices == [0, 1])
        #expect(enumeration.enumeratedFanIndices.count == enumeration.fanCount)
    }

    /// Enumeration derives every key it needs from `FNum` and must never fall back to a
    /// full walk, read `{fds`, or probe anything architecture-specific. That is a claim
    /// about the requests made, which no assertion on the results could establish.
    @Test("Only FNum and the three keys per fan are ever requested")
    func requestsOnlyTheKeysItNeeds() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 2,
                fans: [
                    FanFixture(actual: 1343.07),
                    FanFixture(actual: 1454.97),
                ]))

        _ = try await SMCFanEnumeration.enumerate(provider: provider)

        let requests = await provider.requests
        #expect(requests == [["FNum"], ["F0Ac", "F0Mn", "F0Mx", "F1Ac", "F1Mn", "F1Mx"]])
    }

    @Test(
        "An implausible FNum throws rather than sizing an enumeration by it",
        arguments: [
            Double(SMCFanEnumeration.maxPlausibleFanCount + 1), -1, 957_153_280,
            .nan, .infinity, -.infinity,
        ])
    func implausibleFanCountThrows(declared: Double) async {
        let provider = FakeSensorProvider(keyedResults: machine(fanCount: declared))

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .implausibleFanCount = error else {
            Issue.record(
                "expected .implausibleFanCount for \(declared), got \(String(describing: error))")
            return
        }
    }

    /// The bound is a ceiling, not a strict one: a machine declaring exactly
    /// `maxPlausibleFanCount` fans is trusted. Asserted so a future off-by-one that tightens
    /// the guard into rejecting the boundary value is a failure rather than a silent
    /// behaviour change.
    @Test("A fan count exactly at the ceiling is accepted")
    func ceilingItselfIsAccepted() async throws {
        let count = SMCFanEnumeration.maxPlausibleFanCount
        let provider = FakeSensorProvider(keyedResults: machine(fanCount: Double(count)))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == count)
    }

    /// A fanless Mac genuinely has no `FNum` in its key table. That is "this machine has no
    /// fans", which every read client must render, not an error it should refuse to work
    /// past — see `.github/ISSUE_TEMPLATE/hardware-report.yml`, whose whole purpose is that
    /// such a machine's owner can still file a report.
    @Test("FNum absent from the key table means zero fans, not an error")
    func absentFanCountKeyMeansZeroFans() async throws {
        let provider = FakeSensorProvider(
            keyedResults: ["FNum": .failure(.unknownKey("FNum"))])

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 0)
        #expect(enumeration.fans.isEmpty)
        #expect(enumeration.enumeratedFanIndices.isEmpty)
        // And it stops there: a machine with no fans must not go on to issue a second,
        // empty subset read. Asserted on the requests rather than the result because an
        // enumeration over an empty range returns the same empty answer either way.
        let requests = await provider.requests
        #expect(requests == [["FNum"]])
    }

    /// The other side of the same guard: `.unknownKey` is the *only* `FNum` failure treated
    /// as "no fans". A key that exists but would not read means something went wrong, and
    /// silently reporting zero fans there would hide it — and, in the helper, would hand
    /// lease validation an empty set built from a failure.
    @Test(
        "An FNum failure that is not absence throws rather than reporting zero fans",
        arguments: [
            SensorReadFailure.readFailed(reason: "firmware(code: 0x82)"),
            .notDecodable(reason: "{fds is not numeric"),
        ])
    func nonAbsenceFanCountFailureThrows(failure: SensorReadFailure) async {
        let provider = FakeSensorProvider(keyedResults: ["FNum": .failure(failure)])

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("No SMC on this machine is refused up front, distinct from having no fans")
    func unavailableProviderThrowsNoSMC() async {
        let provider = FakeSensorProvider(isAvailable: false)

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .noSMC = error else {
            Issue.record("expected .noSMC, got \(String(describing: error))")
            return
        }
    }

    @Test("A whole-request provider failure throws rather than reporting an empty machine")
    func providerThrowIsSurfaced() async {
        let provider = FakeSensorProvider(
            keysError: FakeProviderError(description: "connection closed"))

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed(_, let reason) = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("connection closed"))
    }

    /// A provider that answers `FNum` with no outcome at all breaks
    /// `SensorProvider.read(keys:)`'s one-outcome-per-key contract. Reported as a failure
    /// rather than force-unwrapped, so a violated assumption surfaces as an error instead of
    /// a crash in a root daemon.
    @Test("An FNum request answered with no outcome throws")
    func missingFanCountOutcomeThrows() async {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 2), omittedKeys: ["FNum"])

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
    }

    /// The per-key tolerance rule. A machine reporting `F0Mn` but not `F0Mx` is a machine
    /// with a fan, and dropping the fan entirely would lose two readings that worked.
    @Test("A fan whose maximum is unreadable still enumerates, with that key unavailable")
    func unreadableMaximumDoesNotDropTheFan() async throws {
        var table = machine(fanCount: 1, fans: [FanFixture(actual: 1343.07)])
        table["F0Mx"] = .failure(.readFailed(reason: "firmware(code: 0x82)"))

        let provider = FakeSensorProvider(keyedResults: table)
        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 1)
        #expect(value(enumeration.fans[0].actual) == 1343.07)
        #expect(value(enumeration.fans[0].minimum) == 1350)
        #expect(value(enumeration.fans[0].maximum) == nil)
        #expect(failure(enumeration.fans[0].maximum) == .readFailed(reason: "firmware(code: 0x82)"))
        // The raw key is retained even on failure, so a caller can always say which key it
        // is reporting as unavailable.
        #expect(enumeration.fans[0].maximum.key == "F0Mx")
    }

    /// A key the provider drops from its response entirely is reported as unavailable,
    /// carrying its key — never omitted from the fan and never fabricated as a `0`, which
    /// would read to a user as "this fan has stopped".
    @Test("A fan key with no outcome at all is unavailable, not a fabricated zero")
    func missingFanKeyOutcomeIsUnavailable() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 1, fans: [FanFixture(actual: 1343.07)]),
            omittedKeys: ["F0Mn"])

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 1)
        #expect(value(enumeration.fans[0].minimum) == nil)
        #expect(enumeration.fans[0].minimum.key == "F0Mn")
        #expect(value(enumeration.fans[0].actual) == 1343.07)
    }

    /// **Load-bearing.** `F0Ac` was measured at 1343.07 against a declared `F0Mn` of 1350 on
    /// this project's own development hardware (`docs/SMC-RESEARCH.md`, "Disagreement 3").
    /// Actual fan speed is not bounded by the declared minimum, so an observation below it
    /// is real data and must arrive at the caller unchanged: not raised to the minimum, not
    /// swapped for it, not reported as a failure. Clamping governs targets Aeolus writes,
    /// never values it reads — and a test that asserted `actual >= minimum` would be
    /// encoding on this project's behalf exactly the assumption the hardware disproved.
    @Test("An actual reading below the declared minimum is surfaced as measured, never clamped")
    func actualBelowDeclaredMinimumIsNotClamped() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 1, fans: [FanFixture(actual: 1343.07)]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        let actual = try #require(value(enumeration.fans[0].actual))
        let minimum = try #require(value(enumeration.fans[0].minimum))
        #expect(actual == 1343.07)
        #expect(minimum == 1350)
        #expect(actual < minimum)
    }

    /// `SMCValue.scalar()` applies no finiteness guard, so a byte-swapped `flt` can decode to
    /// `±.infinity` or `.nan` on an otherwise-successful read. Refused here rather than
    /// propagated: `Double.infinity == Double.infinity.rounded()` is `true`, so a non-finite
    /// value can travel a long way downstream without ever looking wrong.
    @Test(
        "A non-finite reading is refused rather than propagated",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteReadingIsRefused(bad: Double) async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 1, fans: [FanFixture(actual: bad)]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(value(enumeration.fans[0].actual) == nil)
        let actual = enumeration.fans[0].actual
        guard case .notDecodable(let reason) = failure(actual) else {
            Issue.record("expected .notDecodable, got \(String(describing: actual))")
            return
        }
        #expect(reason.contains("non-finite"))
        // The rest of the fan is untouched — one bad key never voids the others.
        #expect(value(enumeration.fans[0].minimum) == 1350)
    }

    @Test("Fan keys follow the documented F<n>Ac/Mn/Mx convention")
    func keyBuildersFollowTheConvention() {
        #expect(SMCFanEnumeration.actualKey(forFan: 0) == "F0Ac")
        #expect(SMCFanEnumeration.minimumKey(forFan: 0) == "F0Mn")
        #expect(SMCFanEnumeration.maximumKey(forFan: 1) == "F1Mx")
        #expect(SMCFanEnumeration.fanCountKey == "FNum")
    }

    /// The number itself, pinned. It was two independent constants before this type existed
    /// (`FanPoller.maxPlausibleFanCount`, `ListCommand.maxPlausibleFanCount`), which both now
    /// read; a change here is a change everywhere, which is the point.
    @Test("The plausible fan-count ceiling is one shared constant")
    func ceilingIsOneSharedConstant() {
        #expect(SMCFanEnumeration.maxPlausibleFanCount == 64)
    }
}

/// Assertions that are facts about *this* machine rather than about "a Mac with an SMC" —
/// see `DevelopmentMachine.swift` for why they skip rather than fail elsewhere.
@Suite(
    "SMC fan enumeration, Mac16,5-specific facts",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct SMCFanEnumerationMac165Tests {

    @Test("Enumeration finds this machine's two fans against the real SMC")
    func enumeratesRealFans() async throws {
        let enumeration = try await SMCFanEnumeration.enumerate(provider: SMCSensorProvider())

        #expect(enumeration.fanCount == 2)
        #expect(enumeration.enumeratedFanIndices == [0, 1])

        for fan in enumeration.fans {
            let actual = try #require(value(fan.actual), "F\(fan.index)Ac did not read")
            // docs/RECOVERY.md: 0 RPM is normal on many Macs when cool or idle, and F0Ac has
            // been observed below the declared F0Mn floor on this very machine. The only
            // things worth asserting about an observation are that it is finite and not
            // negative — never that it respects a bound the firmware itself does not.
            #expect(actual.isFinite)
            #expect(actual >= 0)
        }
    }
}
